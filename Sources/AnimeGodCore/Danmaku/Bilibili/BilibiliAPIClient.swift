import Foundation

/// Typed access to the handful of Bilibili web endpoints the danmaku
/// provider needs. Transport concerns (cookies, WBI, risk control) belong to
/// `BilibiliSession`; this layer only maps JSON/protobuf onto the models.
public struct BilibiliAPIClient: Sendable {
    /// Bilibili splits a video's danmaku into fixed six-minute segments.
    public static let segmentDuration: Double = 360
    /// A hard ceiling on the sweep so an implausible duration cannot turn
    /// into hundreds of requests.
    public static let maximumSegments = 60

    private let session: BilibiliSession

    public init(session: BilibiliSession) {
        self.session = session
    }

    // MARK: - Search

    /// Comprehensive search. Bilibili requires WBI signing here, and a
    /// device cookie — both are handled by the session.
    public func searchAll(keyword: String) async throws -> [BilibiliSearchHit] {
        let response = try await session.json(
            SearchAllResponse.self,
            path: "x/web-interface/wbi/search/all/v2",
            parameters: ["keyword": keyword],
            signed: true
        )
        var hits: [BilibiliSearchHit] = []
        for group in response.result ?? [] {
            switch group.result_type {
            case "media_bangumi", "media_ft":
                hits += (group.data ?? []).compactMap(\.bangumiHit)
            case "video":
                hits += (group.data ?? []).compactMap(\.videoHit)
            default:
                continue
            }
        }
        return hits
    }

    // MARK: - Episode resolution

    /// Full episode list for a licensed season, each with its own `cid`.
    public func season(seasonID: Int64) async throws -> BilibiliBangumiSeason {
        let result = try await session.json(
            SeasonResponse.self,
            host: URL(string: "https://api.bilibili.com")!,
            path: "pgc/view/web/season",
            parameters: ["season_id": String(seasonID)],
            signed: false
        )
        return BilibiliBangumiSeason(
            seasonID: result.season_id ?? seasonID,
            title: result.title ?? "",
            seasonTypeName: result.type_name ?? "",
            episodes: (result.episodes ?? []).map(\.episode)
        )
    }

    /// A UGC submission with all of its parts. `pages` is the authoritative
    /// source of per-part `cid`s.
    public func video(bvid: String? = nil, aid: Int64? = nil) async throws -> BilibiliVideo {
        var parameters: [String: String] = [:]
        if let bvid, !bvid.isEmpty {
            parameters["bvid"] = bvid
        } else if let aid {
            parameters["aid"] = String(aid)
        } else {
            throw DanmakuProviderError.invalidResponse
        }
        let data = try await session.json(
            VideoResponse.self,
            path: "x/web-interface/view",
            parameters: parameters,
            signed: false
        )
        let parts = (data.pages ?? []).map {
            BilibiliVideoPart(
                cid: $0.cid,
                page: $0.page ?? 1,
                title: $0.part ?? "",
                duration: Double($0.duration ?? 0)
            )
        }
        return BilibiliVideo(
            aid: data.aid ?? 0,
            bvid: data.bvid ?? bvid ?? "",
            title: data.title ?? "",
            duration: Double(data.duration ?? 0),
            parts: parts,
            typeName: data.tname ?? "",
            publishedAt: data.pubdate.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    // MARK: - Danmaku

    /// Number of six-minute segments a video of `duration` seconds holds.
    /// Bilibili indexes segments from 1.
    public static func segmentCount(forDuration duration: Double) -> Int {
        guard duration > 0 else { return 1 }
        return min(maximumSegments, max(1, Int((duration / segmentDuration).rounded(.up))))
    }

    /// Fetches one protobuf segment and decodes it.
    ///
    /// Segments past the end of the video answer with an error envelope
    /// rather than an empty message, which is how the sweep knows to stop;
    /// that is reported as `nil` instead of throwing.
    public func danmakuSegment(
        cid: Int64,
        aid: Int64?,
        index: Int
    ) async throws -> [BilibiliDanmakuElem]? {
        var parameters = ["type": "1", "oid": String(cid), "segment_index": String(index)]
        if let aid, aid > 0 { parameters["pid"] = String(aid) }

        let endpoint = await session.segmentEndpoint
        switch endpoint {
        case .plain:
            return try await segment(path: "x/v2/dm/web/seg.so", parameters: parameters, signed: false)
        case .wbi:
            return try await segment(path: "x/v2/dm/wbi/web/seg.so", parameters: parameters, signed: true)
        case .automatic:
            do {
                return try await segment(path: "x/v2/dm/web/seg.so", parameters: parameters, signed: false)
            } catch let error as DanmakuProviderError where Self.isEndpointRejection(error) {
                // The plain endpoint is the one at risk of being locked
                // down; when it refuses, the web player's signed path is
                // the supported replacement.
                return try await segment(path: "x/v2/dm/wbi/web/seg.so", parameters: parameters, signed: true)
            }
        }
    }

    private static func isEndpointRejection(_ error: DanmakuProviderError) -> Bool {
        switch error {
        case .rejectedByRiskControl, .httpStatus, .invalidResponse: true
        default: false
        }
    }

    private func segment(path: String, parameters: [String: String], signed: Bool) async throws -> [BilibiliDanmakuElem]? {
        let body = try await session.data(path: path, parameters: parameters, signed: signed)
        // A successful reply is protobuf; failures come back as JSON.
        if body.first == UInt8(ascii: "{") {
            if let envelope = try? JSONDecoder().decode(CodeOnlyEnvelope.self, from: body) {
                // -352/-101 style rejections must surface; "no such segment"
                // simply ends the sweep.
                if envelope.code == 0 { return [] }
                if let error = BilibiliAPIError.make(code: envelope.code, message: envelope.message ?? "") {
                    if case .serviceMessage = error { return nil }
                    throw error
                }
                return nil
            }
            return nil
        }
        guard !body.isEmpty else { return [] }
        return try BilibiliDanmakuSegmentDecoder.decodeSegment(body)
    }

    /// The pre-protobuf XML pool, kept for debugging and as a last resort.
    ///
    /// It returns a capped, server-sampled subset of the rolling pool, so it
    /// is never the primary path: a full episode fetched through the
    /// segmented endpoint routinely returns several times more comments.
    public func legacyXMLDanmaku(cid: Int64) async throws -> [BilibiliDanmakuElem] {
        let body = try await session.data(
            path: "x/v1/dm/list.so",
            parameters: ["oid": String(cid)],
            signed: false
        )
        let xml = String(data: body, encoding: .utf8)
            ?? BilibiliDeflate.inflate(body).flatMap { String(data: $0, encoding: .utf8) }
        guard let xml else { throw DanmakuProviderError.invalidResponse }
        return BilibiliLegacyXMLParser.parse(xml)
    }

    // MARK: - DTOs

    private struct CodeOnlyEnvelope: Decodable {
        let code: Int
        let message: String?
    }

    private struct SearchAllResponse: Decodable {
        let result: [Group]?

        struct Group: Decodable {
            let result_type: String?
            let data: [Item]?
        }

        struct Item: Decodable {
            let season_id: Int64?
            let media_id: Int64?
            let title: String?
            let org_title: String?
            let season_type_name: String?
            let ep_size: Int?
            let aid: Int64?
            let bvid: String?
            let author: String?
            let typename: String?
            let duration: String?

            var bangumiHit: BilibiliSearchHit? {
                guard let season_id, season_id > 0 else { return nil }
                return .bangumi(BilibiliSearchBangumi(
                    seasonID: season_id,
                    mediaID: media_id ?? 0,
                    title: BilibiliSearchMarkup.strip(title ?? ""),
                    originalTitle: BilibiliSearchMarkup.strip(org_title ?? ""),
                    seasonTypeName: season_type_name ?? "",
                    episodeCount: ep_size
                ))
            }

            var videoHit: BilibiliSearchHit? {
                guard let aid, aid > 0 else { return nil }
                return .video(BilibiliSearchVideo(
                    aid: aid,
                    bvid: bvid ?? "",
                    title: BilibiliSearchMarkup.strip(title ?? ""),
                    author: author ?? "",
                    typeName: typename ?? "",
                    duration: duration.flatMap(BilibiliSearchMarkup.seconds(fromClock:))
                ))
            }
        }
    }

    private struct SeasonResponse: Decodable {
        let season_id: Int64?
        let title: String?
        let type_name: String?
        let episodes: [Episode]?

        struct Episode: Decodable {
            let id: Int64?
            let aid: Int64?
            let bvid: String?
            let cid: Int64?
            let title: String?
            let long_title: String?
            /// Milliseconds.
            let duration: Int64?

            var episode: BilibiliBangumiEpisode {
                BilibiliBangumiEpisode(
                    episodeID: id ?? 0,
                    aid: aid ?? 0,
                    bvid: bvid ?? "",
                    cid: cid ?? 0,
                    title: title ?? "",
                    longTitle: long_title ?? "",
                    duration: Double(duration ?? 0) / 1000
                )
            }
        }
    }

    private struct VideoResponse: Decodable {
        let aid: Int64?
        let bvid: String?
        let title: String?
        let tname: String?
        let duration: Int64?
        let pubdate: Int64?
        let pages: [Page]?

        struct Page: Decodable {
            let cid: Int64
            let page: Int?
            let part: String?
            /// Seconds.
            let duration: Int64?
        }
    }
}

/// Search results arrive with the matched terms wrapped in `<em>` markup.
public enum BilibiliSearchMarkup {
    public static func strip(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses search's "MM:SS" / "HH:MM:SS" duration strings.
    public static func seconds(fromClock value: String) -> Double? {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
