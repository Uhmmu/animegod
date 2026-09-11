import Foundation

public enum MetadataProviderError: LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case serviceMessage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The metadata service returned an invalid response."
        case let .httpStatus(status): "The metadata service returned HTTP \(status)."
        case let .serviceMessage(message): message
        }
    }
}

public struct BangumiMetadataProvider: MetadataProvider {
    public let id: MetadataProviderID = .bangumi
    private let session: URLSession
    private let baseURL: URL
    private let commentsBaseURL: URL
    private let userAgent: String

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.bgm.tv")!,
        commentsBaseURL: URL = URL(string: "https://next.bgm.tv")!,
        userAgent: String = "AnimeGod/0.2 (https://github.com/Uhmmu/animegod)"
    ) {
        self.session = session
        self.baseURL = baseURL
        self.commentsBaseURL = commentsBaseURL
        self.userAgent = userAgent
    }

    public func search(_ query: String, limit: Int = 10) async throws -> [AnimeMetadataCandidate] {
        var components = URLComponents(url: baseURL.appending(path: "v0/search/subjects"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 20))),
            URLQueryItem(name: "offset", value: "0")
        ]
        var request = request(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SearchBody(keyword: query, sort: "match", filter: .init(type: [2])))
        let response: SearchResponse = try await load(request)
        return response.data.map(\.candidate)
    }

    public func metadata(externalID: String, animeID: UUID) async throws -> AnimeMetadata {
        let subject: Subject = try await load(request(url: baseURL.appending(path: "v0/subjects/\(externalID)")))
        return AnimeMetadata(
            animeID: animeID,
            provider: id,
            externalID: String(subject.id),
            title: subject.preferredTitle,
            originalTitle: subject.name,
            summary: subject.summary,
            posterURL: secureURL(subject.images?.large ?? subject.images?.common),
            airDate: subject.date,
            platform: subject.platform,
            score: subject.rating?.score,
            rank: subject.rank,
            ratingCount: subject.rating?.total,
            sourceURL: URL(string: "https://bgm.tv/subject/\(subject.id)"),
            kind: Self.kind(fromPlatform: subject.platform),
            studios: Self.studios(fromInfobox: subject.infobox)
        )
    }

    /// Bangumi reports the animation studio under different keys depending on
    /// who edited the entry; the production committee ("製作") is a different
    /// entity and must not be credited as the studio.
    private static func studios(fromInfobox infobox: [InfoboxEntry]?) -> [String]? {
        let entries = (infobox ?? []).filter { entry in
            entry.key == "动画制作" || entry.key == "アニメーション制作"
        }
        let names = entries.flatMap { entry in
            (entry.values ?? []).compactMap(\.value).filter { !$0.isEmpty }
        }
        return names.isEmpty ? nil : names
    }

    static func kind(fromPlatform platform: String?) -> AnimeKind? {
        guard let platform, !platform.isEmpty else { return nil }
        if platform.contains("剧场")
            || platform.range(of: #"(?i)movie"#, options: .regularExpression) != nil { return .movie }
        if platform.range(of: #"(?i)\b(?:ova|oad)\b"#, options: .regularExpression) != nil { return .ova }
        if platform.contains("网络")
            || platform.range(of: #"(?i)\b(?:web|stream(?:ing)?)\b"#, options: .regularExpression) != nil { return .ona }
        if platform.range(of: #"(?i)\btv\b"#, options: .regularExpression) != nil || platform == "TV" { return .tv }
        return nil
    }

    public func communityPosts(externalID: String) async throws -> [CommunityPost] {
        var components = URLComponents(url: baseURL.appending(path: "subject/\(externalID)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "responseGroup", value: "large")]
        let subject: LegacySubject = try await load(request(url: components.url!))
        let topics = (subject.topic ?? []).compactMap { post in
            post.communityPost(provider: id, externalID: externalID, kind: .discussion)
        }
        let blogs = (subject.blog ?? []).compactMap { post in
            post.communityPost(provider: id, externalID: externalID, kind: .review)
        }
        // Bangumi's current web client exposes the subject shoutbox through
        // its read-only p1 endpoint. Keep it best-effort because p1 is not
        // part of the stable v0 API and must never hide cached discussions or
        // reviews when it is temporarily unavailable.
        let shoutbox = (try? await shoutboxPosts(externalID: externalID)) ?? []
        return (shoutbox + topics + blogs).sorted {
            ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
        }
    }

    private func shoutboxPosts(externalID: String) async throws -> [CommunityPost] {
        var components = URLComponents(
            url: commentsBaseURL.appending(path: "p1/subjects/\(externalID)/comments"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "offset", value: "0")
        ]
        let response: ShoutboxResponse = try await load(request(url: components.url!))
        return response.data.compactMap { $0.communityPost(externalID: externalID) }
    }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func load<Value: Decodable>(_ request: URLRequest) async throws -> Value {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MetadataProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw MetadataProviderError.httpStatus(http.statusCode) }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func secureURL(_ value: String?) -> URL? {
        guard var components = value.flatMap({ URLComponents(string: $0) }) else { return nil }
        if components.scheme == "http" { components.scheme = "https" }
        return components.url
    }
}

private struct SearchBody: Encodable {
    let keyword: String
    let sort: String
    let filter: Filter

    struct Filter: Encodable { let type: [Int] }
}

private struct SearchResponse: Decodable { let data: [Subject] }

private struct Subject: Decodable {
    let id: Int
    let name: String
    let nameCN: String?
    let summary: String
    let date: String?
    let platform: String?
    let infobox: [InfoboxEntry]?
    let images: Images?
    let rating: Rating?
    let rank: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, summary, date, platform, infobox, images, rating, rank
        case nameCN = "name_cn"
    }

    var preferredTitle: String { nameCN.flatMap { $0.isEmpty ? nil : $0 } ?? name }
    var candidate: AnimeMetadataCandidate {
        AnimeMetadataCandidate(
            provider: .bangumi,
            externalID: String(id),
            title: preferredTitle,
            originalTitle: name,
            summary: summary,
            posterURL: secureURL(images?.large ?? images?.common),
            airDate: date,
            score: rating?.score,
            rank: rank,
            ratingCount: rating?.total
        )
    }

    private func secureURL(_ value: String?) -> URL? {
        guard var components = value.flatMap({ URLComponents(string: $0) }) else { return nil }
        if components.scheme == "http" { components.scheme = "https" }
        return components.url
    }
}

private struct Images: Decodable {
    let large: String?
    let common: String?
}

private struct InfoboxEntry: Decodable {
    let key: String
    let values: [InfoboxValue]?

    enum CodingKeys: String, CodingKey {
        case key, value, values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        // Bangumi mixes shapes: "value" (string, number, {v}, or [{v}]) and
        // "values" ([{v}]). Never let an exotic shape break the whole subject.
        if let list = try? container.decodeIfPresent([InfoboxValue].self, forKey: .values) {
            values = list
        } else if let single = try? container.decodeIfPresent(InfoboxValue.self, forKey: .value) {
            values = [single]
        } else {
            values = nil
        }
    }
}

private struct InfoboxValue: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Double.self) {
            value = number.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(number))
                : String(number)
        } else if let nested = try? container.decode(Nested.self), let text = nested.v {
            value = text
        } else if let list = try? container.decode([Nested].self) {
            value = list.compactMap(\.v).joined(separator: "、")
        } else {
            value = nil
        }
    }

    private struct Nested: Decodable { let v: String? }
}

private struct Rating: Decodable {
    let score: Double?
    let total: Int?
}

private struct LegacySubject: Decodable {
    let topic: [LegacyPost]?
    let blog: [LegacyPost]?
}

private struct LegacyPost: Decodable {
    let id: Int
    let url: String
    let title: String
    let summary: String?
    let replies: Int?
    let timestamp: TimeInterval?
    let user: LegacyUser?

    func communityPost(provider: MetadataProviderID, externalID: String, kind: CommunityPostKind) -> CommunityPost? {
        guard var components = URLComponents(string: url) else { return nil }
        if components.scheme == "http" { components.scheme = "https" }
        guard let secureURL = components.url else { return nil }
        return CommunityPost(
            provider: provider,
            externalID: externalID,
            postID: String(id),
            kind: kind,
            title: title,
            summary: summary,
            url: secureURL,
            author: user?.nickname ?? user?.username ?? "Bangumi user",
            replyCount: replies ?? 0,
            publishedAt: timestamp.map(Date.init(timeIntervalSince1970:))
        )
    }
}

private struct LegacyUser: Decodable {
    let username: String?
    let nickname: String?
}

private struct ShoutboxResponse: Decodable {
    let data: [ShoutboxComment]
}

private struct ShoutboxComment: Decodable {
    let id: Int
    let user: LegacyUser?
    let rate: Int?
    let comment: String?
    let updatedAt: TimeInterval?

    func communityPost(externalID: String) -> CommunityPost? {
        guard let body = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
        var components = URLComponents(string: "https://bgm.tv/subject/\(externalID)/comments")!
        components.fragment = "likes_grid_\(id)"
        guard let url = components.url else { return nil }
        return CommunityPost(
            provider: .bangumi,
            externalID: externalID,
            postID: String(id),
            kind: .shoutbox,
            title: "",
            summary: nil,
            url: url,
            author: user?.nickname ?? user?.username ?? "Bangumi user",
            replyCount: 0,
            publishedAt: updatedAt.map(Date.init(timeIntervalSince1970:)),
            rating: rate.map(Double.init),
            body: body
        )
    }
}
