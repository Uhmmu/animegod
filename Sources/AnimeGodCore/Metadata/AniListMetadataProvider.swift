import Foundation

public struct AniListMetadataProvider: MetadataProvider {
    public let id: MetadataProviderID = .anilist
    private let session: URLSession
    private let endpoint: URL

    public init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://graphql.anilist.co")!
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    public func search(_ query: String, limit: Int = 10) async throws -> [AnimeMetadataCandidate] {
        let response: SearchData = try await request(
            query: Self.searchQuery,
            variables: ["search": .string(query), "perPage": .int(min(max(limit, 1), 20))]
        )
        return response.Page.media.map { media in
            AnimeMetadataCandidate(
                provider: id,
                externalID: String(media.id),
                title: media.title.preferred,
                originalTitle: media.title.native ?? media.title.romaji ?? media.title.preferred,
                summary: Self.plainText(media.description ?? ""),
                posterURL: media.coverImage.extraLarge.flatMap(URL.init(string:)),
                airDate: media.startDate.text,
                score: media.averageScore.map { Double($0) / 10 },
                rank: media.rank,
                ratingCount: media.popularity
            )
        }
    }

    public func metadata(externalID: String, animeID: UUID) async throws -> AnimeMetadata {
        guard let numericID = Int(externalID) else { throw MetadataProviderError.invalidResponse }
        let response: MetadataData = try await request(
            query: Self.metadataQuery,
            variables: ["id": .int(numericID)]
        )
        let media = response.Media
        var references: [ExternalAnimeReference] = []
        if let malID = media.idMal {
            references.append(.init(provider: .myAnimeList, externalID: String(malID)))
        }
        return AnimeMetadata(
            animeID: animeID,
            provider: id,
            externalID: String(media.id),
            title: media.title.preferred,
            originalTitle: media.title.native ?? media.title.romaji ?? media.title.preferred,
            summary: Self.plainText(media.description ?? ""),
            posterURL: media.coverImage.extraLarge.flatMap(URL.init(string:)),
            airDate: media.startDate.text,
            platform: media.format,
            score: media.averageScore.map { Double($0) / 10 },
            rank: media.rank,
            ratingCount: media.popularity,
            scoreMaximum: 10,
            sourceURL: media.siteUrl.flatMap(URL.init(string:)),
            kind: Self.kind(fromFormat: media.format),
            studios: media.studios.flatMap { nodes in
                let names = nodes.nodes.map(\.name).filter { !$0.isEmpty }
                return names.isEmpty ? nil : names
            },
            externalReferences: references
        )
    }

    static func kind(fromFormat format: String?) -> AnimeKind? {
        switch format?.uppercased() {
        case "TV", "TV_SHORT": .tv
        case "MOVIE": .movie
        case "OVA": .ova
        case "ONA": .ona
        case "SPECIAL": .special
        default: nil
        }
    }

    public func communityPosts(externalID: String) async throws -> [CommunityPost] {
        guard let numericID = Int(externalID) else { throw MetadataProviderError.invalidResponse }
        let response: ReviewsData = try await request(
            query: Self.reviewsQuery,
            variables: ["id": .int(numericID), "perPage": .int(20)]
        )
        return response.Page.reviews.compactMap { review in
            guard let url = review.siteUrl.flatMap(URL.init(string:)) else { return nil }
            return CommunityPost(
                provider: id,
                externalID: externalID,
                postID: String(review.id),
                kind: .review,
                title: review.summary,
                summary: Self.plainText(review.body).prefixText(320),
                url: url,
                author: review.user.name,
                replyCount: review.ratingAmount,
                publishedAt: Date(timeIntervalSince1970: TimeInterval(review.createdAt)),
                body: Self.plainText(review.body),
                originalLanguage: "en"
            )
        }
    }

    private func request<Value: Decodable>(query: String, variables: [String: GraphQLValue]) async throws -> Value {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw MetadataProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw MetadataProviderError.httpStatus(http.statusCode) }
        let envelope = try JSONDecoder().decode(GraphQLEnvelope<Value>.self, from: data)
        guard let value = envelope.data else {
            throw MetadataProviderError.serviceMessage(envelope.errors?.first?.message ?? "AniList returned no data.")
        }
        return value
    }

    private static func plainText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let searchQuery = """
    query ($search: String!, $perPage: Int!) {
      Page(perPage: $perPage) { media(search: $search, type: ANIME, sort: [SEARCH_MATCH]) {
        id title { romaji english native } description(asHtml: false) coverImage { extraLarge }
        startDate { year month day } averageScore popularity rankings { rank type allTime }
      } }
    }
    """

    private static let metadataQuery = """
    query ($id: Int!) {
      Media(id: $id, type: ANIME) {
        id idMal title { romaji english native } description(asHtml: false) coverImage { extraLarge }
        startDate { year month day } format averageScore popularity siteUrl
        studios(isMain: true) { nodes { name isMain } }
        rankings { rank type allTime }
      }
    }
    """

    private static let reviewsQuery = """
    query ($id: Int!, $perPage: Int!) {
      Page(perPage: $perPage) { reviews(mediaId: $id, sort: [RATING_DESC]) {
        id summary body(asHtml: false) ratingAmount createdAt siteUrl user { name }
      } }
    }
    """
}

private enum GraphQLValue: Encodable {
    case string(String)
    case int(Int)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        }
    }
}

private struct GraphQLRequest: Encodable { let query: String; let variables: [String: GraphQLValue] }
private struct GraphQLEnvelope<Value: Decodable>: Decodable { let data: Value?; let errors: [GraphQLError]? }
private struct GraphQLError: Decodable { let message: String }
private struct SearchData: Decodable { let Page: MediaPage }
private struct MetadataData: Decodable { let Media: AniListMedia }
private struct ReviewsData: Decodable { let Page: ReviewPage }
private struct MediaPage: Decodable { let media: [AniListMedia] }
private struct ReviewPage: Decodable { let reviews: [AniListReview] }

private struct AniListMedia: Decodable {
    let id: Int
    let idMal: Int?
    let title: AniListTitle
    let description: String?
    let coverImage: AniListCover
    let startDate: AniListDate
    let format: String?
    let averageScore: Int?
    let popularity: Int?
    let siteUrl: String?
    let studios: AniListStudios?
    let rankings: [AniListRanking]?

    var rank: Int? {
        rankings?.first(where: { $0.type == "RATED" && $0.allTime == true })?.rank
    }
}

private struct AniListStudios: Decodable {
    let nodes: [AniListStudio]

    struct AniListStudio: Decodable {
        let name: String
        let isMain: Bool
    }
}

private struct AniListTitle: Decodable {
    let romaji: String?
    let english: String?
    let native: String?
    var preferred: String { english ?? romaji ?? native ?? "Untitled" }
}
private struct AniListCover: Decodable { let extraLarge: String? }
private struct AniListDate: Decodable {
    let year: Int?
    let month: Int?
    let day: Int?
    var text: String? {
        guard let year else { return nil }
        return [String(format: "%04d", year), month.map { String(format: "%02d", $0) }, day.map { String(format: "%02d", $0) }]
            .compactMap { $0 }.joined(separator: "-")
    }
}
private struct AniListRanking: Decodable { let rank: Int; let type: String; let allTime: Bool? }
private struct AniListReview: Decodable {
    let id: Int
    let summary: String
    let body: String
    let ratingAmount: Int
    let createdAt: Int
    let siteUrl: String?
    let user: AniListUser
}
private struct AniListUser: Decodable { let name: String }

private extension String {
    func prefixText(_ length: Int) -> String { String(prefix(length)) }
}
