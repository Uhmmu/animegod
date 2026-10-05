import Foundation

/// Looks a concert up on Bangumi, which files it twice.
///
/// Bangumi has two kinds of entry for the same concert and they carry
/// different halves of the answer:
///
/// * a **演出** subject (`type` 6, `platform` 演出) is the performance — it
///   knows the hall and the date and the official site, and has no track list
///   at all. Measured on subject 540469: `演出地点 = Kアリーナ横浜`, `类型 =
///   Live`, a cover, and a 9.7 from 38 voters.
/// * a **音乐** subject (`type` 3) is the disc — a cover, a score, the number
///   of discs, the price, and a summary with the setlist written out in prose.
///   Measured on subject 512098: 8.2 from 18 voters, `碟片数量 = 3`, and
///   sixteen songs under `〈収録楽曲〉`.
///
/// So this is the only source for the venue, and the only fallback for a
/// setlist on a disc MusicBrainz has never heard of. It is also the only one
/// of the three that has a rating a person wrote, which is what the page shows
/// where an anime page would show its score.
public struct BangumiConcertProvider: Sendable {
    public let id: ConcertProviderID = .bangumi

    /// `type` values in Bangumi's own numbering.
    static let performanceSubjectType = 6
    static let musicSubjectType = 3

    private let session: URLSession
    private let baseURL: URL
    private let userAgent: String

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.bgm.tv")!,
        userAgent: String = "Uhmmu/animegod (https://github.com/Uhmmu/animegod)"
    ) {
        self.session = session
        self.baseURL = baseURL
        self.userAgent = userAgent
    }

    // MARK: - Lookups

    /// Performances and disc releases matching a name, performances first.
    ///
    /// Both types are asked for in one request. The performance is listed
    /// first because it is the one that knows where the concert happened, and
    /// a caller that wants only the setlist can read the flag.
    public func search(_ query: String, limit: Int = 8) async throws -> [ConcertRelease] {
        var components = URLComponents(
            url: baseURL.appending(path: "v0/search/subjects"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 20))),
            URLQueryItem(name: "offset", value: "0")
        ]
        var request = self.request(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SearchBody(
            keyword: query,
            sort: "match",
            filter: .init(type: [Self.performanceSubjectType, Self.musicSubjectType])
        ))
        let payload: SearchPayload = try await load(request)
        return payload.data
            .map { $0.release }
            .sorted { lhs, rhs in
                lhs.isPerformanceRecord && !rhs.isPerformanceRecord
            }
    }

    /// One subject, with its infobox read and its setlist pulled out of the
    /// summary.
    public func release(subjectID: String) async throws -> ConcertRelease {
        let subject: SubjectPayload = try await load(
            request(url: baseURL.appending(path: "v0/subjects/\(subjectID)"))
        )
        return subject.release
    }

    // MARK: - Transport

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func load<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MetadataProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw MetadataProviderError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MetadataProviderError.invalidResponse
        }
    }
}

// MARK: - Wire format

private extension BangumiConcertProvider {
    struct SearchBody: Encodable {
        let keyword: String
        let sort: String
        let filter: Filter
        struct Filter: Encodable { let type: [Int] }
    }

    struct SearchPayload: Decodable {
        let data: [SubjectPayload]
    }

    struct SubjectPayload: Decodable {
        let id: Int
        let type: Int?
        let platform: String?
        let name: String
        let nameCN: String?
        let summary: String?
        let date: String?
        let infobox: [InfoboxEntry]?
        let images: Images?
        let rating: Rating?

        enum CodingKeys: String, CodingKey {
            case id, type, platform, name, summary, date, infobox, images, rating
            case nameCN = "name_cn"
        }

        struct Images: Decodable { let large: String?; let common: String? }
        struct Rating: Decodable { let score: Double?; let total: Int? }

        var isPerformance: Bool { type == BangumiConcertProvider.performanceSubjectType }

        var release: ConcertRelease {
            let infobox = self.infobox ?? []
            // A performance has no track list of its own, and reading the
            // summary of one would pick numbers out of an event description.
            let discs = isPerformance ? [] : discsFromSummary
            return ConcertRelease(
                provider: .bangumi,
                externalID: String(id),
                title: nameCN?.isEmpty == false ? nameCN! : name,
                artistNames: Self.values(in: infobox, keys: ["艺术家", "アーティスト", "出演", "演出者", "歌手"]),
                releaseDate: isPerformance ? nil : (date ?? Self.value(in: infobox, keys: ["发售日期", "発売日"])),
                country: Self.value(in: infobox, keys: ["国家/地区", "国家", "地区"]),
                labels: Self.values(in: infobox, keys: ["厂牌", "レーベル", "发行", "発売元"]),
                catalogNumbers: Self.values(in: infobox, keys: ["品番", "catalog", "番号"]),
                genres: Self.values(in: infobox, keys: ["类型", "ジャンル"]),
                discs: discs,
                coverImageURLs: [Self.secureURL(images?.large ?? images?.common)].compactMap { $0 },
                sourceURL: URL(string: "https://bgm.tv/subject/\(id)"),
                score: rating?.score.flatMap { $0 > 0 ? $0 : nil },
                ratingCount: rating?.total,
                summary: summary,
                venue: Self.value(in: infobox, keys: ["演出地点", "会场", "会場", "场地"]),
                performedOn: isPerformance ? (Self.value(in: infobox, keys: ["开始", "開始", "日期"]) ?? date) : nil,
                officialSiteURL: Self.value(in: infobox, keys: ["官方网站", "公式サイト"]).flatMap(URL.init(string:)),
                isPerformanceRecord: isPerformance
            )
        }

        /// Bangumi has no track-list field, so the setlist is wherever the
        /// editor wrote it: in the summary.
        var discsFromSummary: [ConcertDisc] {
            let songs = ConcertSetlistTextParser.songs(in: summary)
            guard !songs.isEmpty else { return [] }
            return [ConcertDisc(position: 1, title: nil, format: "Blu-ray", tracks: songs)]
        }

        /// How many discs the entry says are in the box, when it says.
        var discCount: Int? {
            Self.value(in: infobox ?? [], keys: ["碟片数量", "枚数", "ディスク枚数"])
                .flatMap { Int($0.filter(\.isNumber)) }
        }

        static func value(in infobox: [InfoboxEntry], keys: [String]) -> String? {
            values(in: infobox, keys: keys).first
        }

        static func values(in infobox: [InfoboxEntry], keys: [String]) -> [String] {
            infobox
                .filter { entry in keys.contains { $0.caseInsensitiveCompare(entry.key) == .orderedSame } }
                .flatMap { ($0.values ?? []).compactMap(\.value) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        /// `lain.bgm.tv` answers over TLS; the field is not always written
        /// that way.
        static func secureURL(_ string: String?) -> URL? {
            guard let string, var components = URLComponents(string: string) else { return nil }
            if components.scheme == "http" { components.scheme = "https" }
            return components.url
        }
    }
}
