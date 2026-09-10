import Foundation

public enum WatchStatus: String, Codable, CaseIterable, Sendable {
    case planning
    case watching
    case completed
    case paused
    case dropped
    case rewatching

    public var displayName: String {
        switch self {
        case .planning: "Planning"
        case .watching: "Watching"
        case .completed: "Completed"
        case .paused: "Paused"
        case .dropped: "Dropped"
        case .rewatching: "Rewatching"
        }
    }
}

public struct AnimeProfile: Codable, Identifiable, Hashable, Sendable {
    public let animeID: UUID
    public var status: WatchStatus
    public var score: Double?
    public var notes: String
    public var review: String
    public var tags: [String]
    public var isFavorite: Bool
    public var ranking: Int?
    public var firstWatchedAt: Date?
    public var completedAt: Date?
    public var rewatchCount: Int
    public var updatedAt: Date

    public var id: UUID { animeID }

    public init(
        animeID: UUID,
        status: WatchStatus = .planning,
        score: Double? = nil,
        notes: String = "",
        review: String = "",
        tags: [String] = [],
        isFavorite: Bool = false,
        ranking: Int? = nil,
        firstWatchedAt: Date? = nil,
        completedAt: Date? = nil,
        rewatchCount: Int = 0,
        updatedAt: Date = .now
    ) {
        self.animeID = animeID
        self.status = status
        self.score = score
        self.notes = notes
        self.review = review
        self.tags = tags
        self.isFavorite = isFavorite
        self.ranking = ranking
        self.firstWatchedAt = firstWatchedAt
        self.completedAt = completedAt
        self.rewatchCount = rewatchCount
        self.updatedAt = updatedAt
    }
}

public struct WatchEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let animeID: UUID
    public let episodeID: UUID?
    public let animeTitle: String
    public let episodeLabel: String
    public let startedAt: Date
    public let endedAt: Date
    public let watchedDuration: Double
    public let completion: Double
    public let completedEpisode: Bool

    public init(
        id: UUID = UUID(),
        animeID: UUID,
        episodeID: UUID?,
        animeTitle: String,
        episodeLabel: String,
        startedAt: Date,
        endedAt: Date = .now,
        watchedDuration: Double,
        completion: Double,
        completedEpisode: Bool
    ) {
        self.id = id
        self.animeID = animeID
        self.episodeID = episodeID
        self.animeTitle = animeTitle
        self.episodeLabel = episodeLabel
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.watchedDuration = watchedDuration
        self.completion = min(max(completion, 0), 1)
        self.completedEpisode = completedEpisode
    }
}

public struct DiarySummary: Hashable, Sendable {
    public let totalWatchTime: Double
    public let sessionCount: Int
    public let completedEpisodeCount: Int
    public let animeCount: Int

    public init(totalWatchTime: Double, sessionCount: Int, completedEpisodeCount: Int, animeCount: Int) {
        self.totalWatchTime = totalWatchTime
        self.sessionCount = sessionCount
        self.completedEpisodeCount = completedEpisodeCount
        self.animeCount = animeCount
    }
}
