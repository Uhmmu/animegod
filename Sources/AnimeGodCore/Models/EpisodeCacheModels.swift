import Foundation

/// Why a cached copy exists. Auto caches are created transparently while
/// playing from an external drive and are deleted once the episode counts as
/// watched; manual caches persist until the user removes them.
public enum EpisodeCachePolicy: String, Codable, CaseIterable, Sendable {
    case auto
    case manual

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .manual: "Manual"
        }
    }
}

public enum EpisodeCacheState: String, Codable, Sendable {
    /// A background copy is in flight; the file is not playable yet.
    case copying
    /// The copy finished and the cached file is playable offline.
    case complete
}

/// One media file copied onto the local volume so it can be played while its
/// library drive is unplugged. `mediaFileID` is stable across rescans, which
/// makes it the cache identity; rows cascade away when the media file does.
public struct EpisodeCacheEntry: Identifiable, Hashable, Sendable {
    public let mediaFileID: UUID
    public let libraryRootID: UUID
    public let relativePath: String
    public let fileName: String
    public let fileSize: Int64
    public var bytesCopied: Int64
    public var state: EpisodeCacheState
    public var policy: EpisodeCachePolicy
    public var createdAt: Date
    public var completedAt: Date?
    /// Joined library labels for display in the cache manager.
    public var animeTitle: String?
    public var episodeLabel: String?
    public var isEpisodeWatched: Bool

    public var id: UUID { mediaFileID }

    public var progress: Double {
        guard fileSize > 0 else { return 0 }
        return min(max(Double(bytesCopied) / Double(fileSize), 0), 1)
    }

    public init(
        mediaFileID: UUID,
        libraryRootID: UUID,
        relativePath: String,
        fileName: String,
        fileSize: Int64,
        bytesCopied: Int64 = 0,
        state: EpisodeCacheState = .copying,
        policy: EpisodeCachePolicy,
        createdAt: Date = .now,
        completedAt: Date? = nil,
        animeTitle: String? = nil,
        episodeLabel: String? = nil,
        isEpisodeWatched: Bool = false
    ) {
        self.mediaFileID = mediaFileID
        self.libraryRootID = libraryRootID
        self.relativePath = relativePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.bytesCopied = bytesCopied
        self.state = state
        self.policy = policy
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.animeTitle = animeTitle
        self.episodeLabel = episodeLabel
        self.isEpisodeWatched = isEpisodeWatched
    }
}
