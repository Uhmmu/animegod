import Foundation

public enum MetadataProviderID: String, Codable, CaseIterable, Sendable {
    case bangumi
    case anilist
    case myAnimeList

    public var displayName: String {
        switch self {
        case .bangumi: "Bangumi"
        case .anilist: "AniList"
        case .myAnimeList: "MyAnimeList"
        }
    }
}

public struct ExternalAnimeReference: Codable, Hashable, Sendable {
    public let provider: MetadataProviderID
    public let externalID: String

    public init(provider: MetadataProviderID, externalID: String) {
        self.provider = provider
        self.externalID = externalID
    }
}

/// How a provider relationship was established, so auto-guessed links can be
/// flagged and corrected instead of looking hand-picked.
public struct MatchLink: Hashable, Sendable {
    public let provider: MetadataProviderID
    public let confidence: Double
    public let isManual: Bool

    public init(provider: MetadataProviderID, confidence: Double, isManual: Bool) {
        self.provider = provider
        self.confidence = confidence
        self.isManual = isManual
    }
}

public struct AnimeMetadataCandidate: Identifiable, Codable, Hashable, Sendable {
    public let provider: MetadataProviderID
    public let externalID: String
    public let title: String
    public let originalTitle: String
    public let summary: String
    public let posterURL: URL?
    public let airDate: String?
    public let score: Double?
    public let rank: Int?
    public let ratingCount: Int?
    public var id: String { "\(provider.rawValue):\(externalID)" }

    public init(
        provider: MetadataProviderID,
        externalID: String,
        title: String,
        originalTitle: String,
        summary: String,
        posterURL: URL?,
        airDate: String?,
        score: Double?,
        rank: Int?,
        ratingCount: Int?
    ) {
        self.provider = provider
        self.externalID = externalID
        self.title = title
        self.originalTitle = originalTitle
        self.summary = summary
        self.posterURL = posterURL
        self.airDate = airDate
        self.score = score
        self.rank = rank
        self.ratingCount = ratingCount
    }
}

public struct AnimeMetadata: Identifiable, Codable, Hashable, Sendable {
    public let animeID: UUID
    public let provider: MetadataProviderID
    public let externalID: String
    public var title: String
    public var originalTitle: String
    public var summary: String
    public var posterURL: URL?
    public var airDate: String?
    public var platform: String?
    public var score: Double?
    public var rank: Int?
    public var ratingCount: Int?
    public var scoreMaximum: Double?
    public var sourceURL: URL?
    /// The anime type (TV / movie / OVA / ONA / special) as reported by the
    /// provider, used to classify the local entry without guessing.
    public var kind: AnimeKind?
    public var studios: [String]?
    public var externalReferences: [ExternalAnimeReference]?
    public var fetchedAt: Date
    public var id: String { "\(animeID.uuidString):\(provider.rawValue)" }

    public init(
        animeID: UUID,
        provider: MetadataProviderID,
        externalID: String,
        title: String,
        originalTitle: String,
        summary: String,
        posterURL: URL?,
        airDate: String?,
        platform: String?,
        score: Double?,
        rank: Int?,
        ratingCount: Int?,
        scoreMaximum: Double? = 10,
        sourceURL: URL? = nil,
        kind: AnimeKind? = nil,
        studios: [String]? = nil,
        externalReferences: [ExternalAnimeReference] = [],
        fetchedAt: Date = .now
    ) {
        self.animeID = animeID
        self.provider = provider
        self.externalID = externalID
        self.title = title
        self.originalTitle = originalTitle
        self.summary = summary
        self.posterURL = posterURL
        self.airDate = airDate
        self.platform = platform
        self.score = score
        self.rank = rank
        self.ratingCount = ratingCount
        self.scoreMaximum = scoreMaximum
        self.sourceURL = sourceURL
        self.kind = kind
        self.studios = studios
        self.externalReferences = externalReferences
        self.fetchedAt = fetchedAt
    }
}

public enum CommunityPostKind: String, Codable, CaseIterable, Sendable {
    case discussion
    case review
}

public struct CommunityPost: Identifiable, Codable, Hashable, Sendable {
    public let provider: MetadataProviderID
    public let externalID: String
    public let postID: String
    public let kind: CommunityPostKind
    public let title: String
    public let summary: String?
    public let url: URL
    public let author: String
    public let replyCount: Int
    public let publishedAt: Date?
    public let body: String?
    public let originalLanguage: String?
    public var translatedTitle: String?
    public var translatedBody: String?
    public var id: String { "\(provider.rawValue):\(kind.rawValue):\(postID)" }

    public init(
        provider: MetadataProviderID,
        externalID: String,
        postID: String,
        kind: CommunityPostKind,
        title: String,
        summary: String?,
        url: URL,
        author: String,
        replyCount: Int,
        publishedAt: Date?,
        body: String? = nil,
        originalLanguage: String? = nil,
        translatedTitle: String? = nil,
        translatedBody: String? = nil
    ) {
        self.provider = provider
        self.externalID = externalID
        self.postID = postID
        self.kind = kind
        self.title = title
        self.summary = summary
        self.url = url
        self.author = author
        self.replyCount = replyCount
        self.publishedAt = publishedAt
        self.body = body
        self.originalLanguage = originalLanguage
        self.translatedTitle = translatedTitle
        self.translatedBody = translatedBody
    }
}

public protocol MetadataProvider: Sendable {
    var id: MetadataProviderID { get }
    func search(_ query: String, limit: Int) async throws -> [AnimeMetadataCandidate]
    func metadata(externalID: String, animeID: UUID) async throws -> AnimeMetadata
    func communityPosts(externalID: String) async throws -> [CommunityPost]
}
