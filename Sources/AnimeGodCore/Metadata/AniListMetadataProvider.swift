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
                ratingCount: media.popularity,
                aliases: [media.title.romaji, media.title.english, media.title.native].compactMap { $0 },
                totalEpisodes: media.episodes
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
            totalEpisodes: media.episodes,
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
        // AniList allows 30 requests a minute (its long-standing degraded
        // limit; the documented figure is 90). Enriching a library asks it
        // about every title under up to two names, plus a details and a
        // reviews call each — well over a hundred requests — so running into
        // the ceiling is the normal case, not an error. Waiting it out is the
        // only correct response, and it is done here rather than in the
        // caller so every path gets it.
        var attempt = 0
        while true {
            do {
                return try await send(query: query, variables: variables)
            } catch let MetadataProviderError.rateLimited(retryAfter) where attempt < Self.rateLimitRetries {
                attempt += 1
                try await Task.sleep(for: .seconds(min(max(retryAfter, 1), 70)))
            }
        }
    }

    /// How many times a rate-limited request waits and tries again. Three
    /// covers a full library pass: the budget refills every minute.
    private static let rateLimitRetries = 3
    /// How long to hold off when the remaining budget for this minute is
    /// spent. The window is a minute, so this is one.
    private static let rateLimitPause: TimeInterval = 60

    private func send<Value: Decodable>(query: String, variables: [String: GraphQLValue]) async throws -> Value {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw MetadataProviderError.invalidResponse }
        // AniList rate-limits at 90 requests a minute and says how long to
        // wait. Enriching a whole library asks it about every title, so
        // hitting that is ordinary rather than exceptional — and the caller
        // treats a throw as "this provider is down" and stops asking it for
        // the rest of the run.
        if http.statusCode == 429 {
            let advised = (http.value(forHTTPHeaderField: "Retry-After") as NSString?)?.doubleValue ?? 0
            throw MetadataProviderError.rateLimited(retryAfter: advised > 0 ? advised : 60)
        }
        // One request short of the ceiling, pause rather than earn a 429: the
        // header says how many are left in this minute.
        if let remaining = (http.value(forHTTPHeaderField: "X-RateLimit-Remaining") as NSString?)?.integerValue,
           remaining <= 1 {
            try await Task.sleep(for: .seconds(Self.rateLimitPause))
        }
        guard (200..<300).contains(http.statusCode) else {
            // GraphQL answers a malformed query with 400 and says exactly what
            // is wrong with it. Throwing the bare status instead turned "this
            // query asks for a field that no longer exists" into "AniList is
            // down", which is neither true nor actionable.
            if let envelope = try? JSONDecoder().decode(GraphQLEnvelope<GraphQLIgnored>.self, from: data),
               let message = envelope.errors?.first?.message {
                throw MetadataProviderError.serviceMessage("AniList: \(message)")
            }
            throw MetadataProviderError.httpStatus(http.statusCode)
        }
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
        startDate { year month day } averageScore popularity episodes rankings { rank type allTime }
      } }
    }
    """

    private static let metadataQuery = """
    query ($id: Int!) {
      Media(id: $id, type: ANIME) {
        id idMal title { romaji english native } description(asHtml: false) coverImage { extraLarge }
        startDate { year month day } format averageScore popularity siteUrl episodes
        studios(isMain: true) { nodes { name } }
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
/// Stands in for the payload when only the errors are being read.
private struct GraphQLIgnored: Decodable {}
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
    /// Nil while a season is airing and AniList does not know yet, which is
    /// exactly the case a subscription cares about — so nil must stay nil
    /// rather than becoming a guess.
    let episodes: Int?

    var rank: Int? {
        rankings?.first(where: { $0.type == "RATED" && $0.allTime == true })?.rank
    }
}

private struct AniListStudios: Decodable {
    let nodes: [AniListStudio]

    /// Only the name: `isMain` is an argument to `studios(…)`, not a field on
    /// `Studio`. Asking for it made every metadata fetch fail with HTTP 400,
    /// which the app reported as "AniList could not be reached" — so search
    /// worked, nothing was ever saved, and the provider silently never
    /// appeared beside Bangumi on an anime's page.
    struct AniListStudio: Decodable {
        let name: String
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
