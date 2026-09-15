import CryptoKit
import Foundation

/// Client for the official dandanplay Open Danmaku Network API v2
/// (https://doc.dandanplay.com/open/).
///
/// Authentication follows the documented signature mode:
/// `X-AppId`, `X-Timestamp` (Unix seconds), and
/// `X-Signature = base64(sha256(AppId + Timestamp + Path + AppSecret))`
/// where `Path` is the URL path (leading `/`, no query string, not URL
/// encoded). Credential mode (`X-AppId` + `X-AppSecret`) is used when the
/// caller only has raw credentials. Secrets are never logged.
///
/// Business errors arrive as HTTP 200 with `success: false`; those are
/// surfaced as `.serviceMessage`.
public struct DandanplayDanmakuProvider: DanmakuProvider {
    public let metadata = DanmakuProviderMetadata(
        id: "dandanplay",
        displayName: "dandanplay",
        attribution: "Danmaku from the dandanplay Open Danmaku Network (弹弹play开放弹幕网络)"
    )

    public enum Credentials: Sendable {
        case signature(appID: String, appSecret: String)
        case credential(appID: String, appSecret: String)

        var appID: String {
            switch self {
            case let .signature(appID, _), let .credential(appID, _): appID
            }
        }
    }

    private let credentials: Credentials
    private let session: URLSession
    private let baseURL: URL

    public init(
        credentials: Credentials,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.dandanplay.net")!
    ) {
        self.credentials = credentials
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: - DanmakuProvider

    public func match(
        fileName: String,
        fileHash: String?,
        fileSize: Int64?,
        videoDuration: Double?
    ) async throws -> DanmakuMatchResult {
        var body: [String: Any] = ["fileName": fileName]
        if let fileHash { body["fileHash"] = fileHash }
        if let fileSize { body["fileSize"] = fileSize }
        if let videoDuration {
            // The API expects whole seconds.
            body["videoDuration"] = Int(videoDuration.rounded())
        }
        body["matchMode"] = fileHash != nil ? "hashAndFileName" : "fileNameOnly"
        let response: MatchResponse = try await post("api/v2/match", body: body)
        return DanmakuMatchResult(
            isMatched: response.isMatched,
            candidates: (response.matches ?? []).map(\.candidate)
        )
    }

    public func searchAnime(query: String) async throws -> [DanmakuSearchedAnime] {
        var components = URLComponents(
            url: baseURL.appending(path: "api/v2/search/episodes"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "anime", value: query)]
        let response: SearchResponse = try await get(components.url!)
        return (response.animes ?? []).map { anime in
            DanmakuSearchedAnime(
                animeID: anime.animeId,
                animeTitle: anime.animeTitle ?? "",
                typeDescription: anime.typeDescription ?? "",
                episodes: (anime.episodes ?? []).map {
                    DanmakuSearchedEpisode(episodeID: $0.episodeId, episodeTitle: $0.episodeTitle ?? "")
                },
                providerID: metadata.id
            )
        }
    }

    /// dandanplay identifies an episode entirely by its own episode id, so
    /// the fetch context is unused here.
    public func fetchComments(episodeID: Int64, context: DanmakuFetchContext = .none) async throws -> [DanmakuComment] {
        var components = URLComponents(
            url: baseURL.appending(path: "api/v2/comment/\(episodeID)"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "withRelated", value: "true")]
        let response: CommentResponse = try await get(components.url!)
        return (response.comments ?? []).compactMap { $0.comment }
    }

    // MARK: - Transport

    private func get<Response: Decodable>(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    private func post<Response: Decodable>(_ path: String, body: [String: Any]) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        var request = request
        for (name, value) in authHeaders(path: request.url!.path, query: request.url!.query) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DanmakuProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw DanmakuProviderError.httpStatus(http.statusCode)
        }
        // Current public endpoints return their payload directly, while older
        // responses and business failures include success/errorCode fields.
        // Accept both contracts; an explicit failure envelope must still win.
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           !envelope.success {
            throw DanmakuProviderError.serviceMessage(
                envelope.errorMessage?.isEmpty == false ? envelope.errorMessage! : "The danmaku service rejected the request (code \(envelope.errorCode))."
            )
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw DanmakuProviderError.invalidResponse
        }
    }

    private func authHeaders(path: String, query: String?) -> [(String, String)] {
        let appID = credentials.appID
        switch credentials {
        case let .credential(_, appSecret):
            return [("X-AppId", appID), ("X-AppSecret", appSecret)]
        case let .signature(_, appSecret):
            let timestamp = String(Int(Date.now.timeIntervalSince1970))
            let payload = appID + timestamp + path + appSecret
            let digest = SHA256.hash(data: Data(payload.utf8))
            let signature = Data(digest).base64EncodedString()
            return [("X-AppId", appID), ("X-Timestamp", timestamp), ("X-Signature", signature)]
        }
    }

    // MARK: - DTOs

    private struct Envelope: Decodable {
        let success: Bool
        let errorCode: Int
        let errorMessage: String?
    }

    private struct MatchResponse: Decodable {
        let isMatched: Bool
        let matches: [MatchedEpisode]?

        struct MatchedEpisode: Decodable {
            let animeId: Int64
            let animeTitle: String?
            let episodeId: Int64
            let episodeTitle: String?
            let shift: Double?
            let typeDescription: String?

            var candidate: DanmakuMatchCandidate {
                DanmakuMatchCandidate(
                    animeID: animeId,
                    animeTitle: animeTitle ?? "",
                    episodeID: episodeId,
                    episodeTitle: episodeTitle ?? "",
                    shift: shift ?? 0,
                    typeDescription: typeDescription ?? ""
                )
            }
        }
    }

    private struct SearchResponse: Decodable {
        let hasMore: Bool?
        let animes: [SearchedAnime]?

        struct SearchedAnime: Decodable {
            let animeId: Int64
            let animeTitle: String?
            let typeDescription: String?
            let episodes: [SearchedEpisode]?
        }

        struct SearchedEpisode: Decodable {
            let episodeId: Int64
            let episodeTitle: String?
        }
    }

    private struct CommentResponse: Decodable {
        let count: Int?
        let comments: [RawComment]?

        /// dandanplay comment: `p` is "time,mode,color,uid[,source]",
        /// `m` is the text. Modes: 1 scroll, 4 bottom, 5 top (others are
        /// ignored rather than guessed).
        struct RawComment: Decodable {
            let cid: Int64
            let p: String
            let m: String

            var comment: DanmakuComment? {
                let fields = p.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 4,
                      let time = Double(fields[0]),
                      let modeCode = Int(fields[1]),
                      let color = Int(fields[2]) else { return nil }
                let mode: DanmakuMode
                switch modeCode {
                case 1: mode = .scroll
                case 4: mode = .bottom
                case 5: mode = .top
                default: return nil
                }
                let text = m.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return DanmakuComment(
                    id: String(cid),
                    time: max(0, time),
                    text: text,
                    mode: mode,
                    color: color & 0xFFFFFF,
                    senderID: String(fields[3]),
                    source: "dandanplay"
                )
            }
        }
    }
}
