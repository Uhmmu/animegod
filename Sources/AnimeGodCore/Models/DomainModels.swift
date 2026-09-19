import Foundation

public enum AnimeKind: String, Codable, CaseIterable, Sendable {
    case tv
    case movie
    case ova
    case ona
    case special
    case unknown

    public var displayName: String {
        switch self {
        case .tv: "TV"
        case .movie: String(localized: "Movie", bundle: .module)
        case .ova: "OVA"
        case .ona: "ONA"
        case .special: String(localized: "Special", bundle: .module)
        case .unknown: ""
        }
    }
}

public enum EpisodeKind: String, Codable, CaseIterable, Sendable {
    case regular
    case special
    case opening
    case ending
    case music
    case trailer
    case extra

    /// Presentation grouping inside an anime's episode list.
    public var category: EpisodeCategory {
        switch self {
        case .regular: .main
        case .special: .special
        case .opening, .ending, .music: .music
        case .trailer: .trailer
        case .extra: .extra
        }
    }
}

public enum EpisodeCategory: Int, CaseIterable, Sendable {
    case main
    case special
    case music
    case trailer
    case extra

    public var displayName: String {
        switch self {
        case .main: String(localized: "Episodes", bundle: .module)
        case .special: String(localized: "Specials (SP)", bundle: .module)
        case .music: String(localized: "Music & Credits", bundle: .module)
        case .trailer: String(localized: "Trailers", bundle: .module)
        case .extra: String(localized: "Extras", bundle: .module)
        }
    }
}

public struct LibraryRoot: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var lastKnownPath: String
    public var bookmarkData: Data?
    public var addedAt: Date
    public var lastScannedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        lastKnownPath: String,
        bookmarkData: Data? = nil,
        addedAt: Date = .now,
        lastScannedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.lastKnownPath = lastKnownPath
        self.bookmarkData = bookmarkData
        self.addedAt = addedAt
        self.lastScannedAt = lastScannedAt
    }
}

public struct Anime: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var sortTitle: String
    public var kind: AnimeKind
    public var posterPath: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        sortTitle: String? = nil,
        kind: AnimeKind = .unknown,
        posterPath: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.sortTitle = sortTitle ?? title
        self.kind = kind
        self.posterPath = posterPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Episode: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let animeID: UUID
    public var number: Double?
    public var numberText: String?
    public var title: String?
    public var kind: EpisodeKind
    public var sortIndex: Double

    public init(
        id: UUID = UUID(),
        animeID: UUID,
        number: Double?,
        numberText: String? = nil,
        title: String? = nil,
        kind: EpisodeKind = .regular,
        sortIndex: Double
    ) {
        self.id = id
        self.animeID = animeID
        self.number = number
        self.numberText = numberText
        self.title = title
        self.kind = kind
        self.sortIndex = sortIndex
    }

    /// Short human label ("Episode 3", "Special 2", "Creditless Opening") used
    /// by watch history and the episode cache manager.
    public var displayLabel: String {
        Self.displayLabel(kind: kind, numberText: numberText)
    }

    public static func displayLabel(kind: EpisodeKind, numberText: String?) -> String {
        switch kind {
        case .opening: "Creditless Opening"
        case .ending: "Creditless Ending"
        case .music: "Music Video"
        case .trailer: "Trailer"
        case .special: numberText.map { "Special \($0)" } ?? "Special"
        case .extra: "Extra"
        case .regular: numberText.map { "Episode \($0)" } ?? "Movie / Episode"
        }
    }

    /// Shows a `displayLabel` in the interface language. The English label
    /// is what gets stored (watch history, cache entries), so records made
    /// under one language still read correctly after switching to another.
    public static func localizedLabel(_ label: String) -> String {
        switch label {
        case "Creditless Opening": return String(localized: "Creditless Opening", bundle: .module)
        case "Creditless Ending": return String(localized: "Creditless Ending", bundle: .module)
        case "Music Video": return String(localized: "Music Video", bundle: .module)
        case "Trailer": return String(localized: "Trailer", bundle: .module)
        case "Special": return String(localized: "Special", bundle: .module)
        case "Extra": return String(localized: "Extra", bundle: .module)
        case "Movie / Episode": return String(localized: "Movie / Episode", bundle: .module)
        default:
            if label.hasPrefix("Episode ") {
                let number = String(label.dropFirst("Episode ".count))
                return String(localized: "Episode \(number)", bundle: .module)
            }
            if label.hasPrefix("Special ") {
                let number = String(label.dropFirst("Special ".count))
                return String(localized: "Special \(number)", bundle: .module)
            }
            return label
        }
    }
}

public struct MediaFile: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let libraryRootID: UUID
    public let episodeID: UUID
    public var relativePath: String
    public var fileSize: Int64
    public var modifiedAt: Date
    public var discoveredAt: Date

    public init(
        id: UUID = UUID(),
        libraryRootID: UUID,
        episodeID: UUID,
        relativePath: String,
        fileSize: Int64,
        modifiedAt: Date,
        discoveredAt: Date = .now
    ) {
        self.id = id
        self.libraryRootID = libraryRootID
        self.episodeID = episodeID
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.discoveredAt = discoveredAt
    }
}

public struct PlaybackProgress: Codable, Hashable, Sendable {
    public let episodeID: UUID
    public var position: Double
    public var duration: Double
    public var updatedAt: Date
    public var isWatched: Bool

    public var completion: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    public init(
        episodeID: UUID,
        position: Double,
        duration: Double,
        updatedAt: Date = .now,
        isWatched: Bool = false
    ) {
        self.episodeID = episodeID
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
        self.isWatched = isWatched
    }
}

public struct LibraryAnime: Identifiable, Hashable, Sendable {
    public let anime: Anime
    public let episodeCount: Int
    public let unwatchedCount: Int
    public var id: UUID { anime.id }

    public init(anime: Anime, episodeCount: Int, unwatchedCount: Int) {
        self.anime = anime
        self.episodeCount = episodeCount
        self.unwatchedCount = unwatchedCount
    }
}

public struct EpisodeMedia: Identifiable, Hashable, Sendable {
    public let episode: Episode
    public let mediaFile: MediaFile
    public let progress: PlaybackProgress?
    /// Every encode of this episode; `mediaFile` is the preferred one.
    public let versions: [MediaFile]
    public var id: UUID { episode.id }

    public init(episode: Episode, mediaFile: MediaFile, progress: PlaybackProgress?, versions: [MediaFile]? = nil) {
        self.episode = episode
        self.mediaFile = mediaFile
        self.progress = progress
        self.versions = versions ?? [mediaFile]
    }
}

