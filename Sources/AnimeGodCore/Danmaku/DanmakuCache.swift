import Foundation

/// The cached danmaku payload for one provider episode. Cached by the
/// stable provider/episode identity so reopening the same episode — or the
/// same episode from another encode — reuses it without another request.
public struct DanmakuCacheEntry: Codable, Sendable, Equatable {
    public let providerID: String
    public let episodeID: Int64
    public let animeTitle: String
    public let episodeTitle: String
    public let comments: [DanmakuComment]
    public let fetchedAt: Date

    public init(
        providerID: String,
        episodeID: Int64,
        animeTitle: String,
        episodeTitle: String,
        comments: [DanmakuComment],
        fetchedAt: Date = .now
    ) {
        self.providerID = providerID
        self.episodeID = episodeID
        self.animeTitle = animeTitle
        self.episodeTitle = episodeTitle
        self.comments = comments
        self.fetchedAt = fetchedAt
    }
}

/// Which provider episode a local media file is bound to. The media file's
/// stable database UUID survives rescans and renames (identity migration),
/// so the binding follows the file.
public struct DanmakuMatchBinding: Codable, Sendable, Equatable {
    public let mediaFileID: UUID
    public let providerID: String
    public let episodeID: Int64
    public let animeTitle: String
    public let episodeTitle: String
    public let shift: Double
    public let isManual: Bool
    public let matchedAt: Date
    /// See `DanmakuMatchCandidate.providerContext`.
    public let providerContext: String?

    public init(
        mediaFileID: UUID,
        providerID: String,
        episodeID: Int64,
        animeTitle: String,
        episodeTitle: String,
        shift: Double = 0,
        isManual: Bool,
        matchedAt: Date = .now,
        providerContext: String? = nil
    ) {
        self.mediaFileID = mediaFileID
        self.providerID = providerID
        self.episodeID = episodeID
        self.animeTitle = animeTitle
        self.episodeTitle = episodeTitle
        self.shift = shift
        self.isManual = isManual
        self.matchedAt = matchedAt
        self.providerContext = providerContext
    }

    public var episodeRef: DanmakuEpisodeRef {
        DanmakuEpisodeRef(
            providerID: providerID,
            episodeID: episodeID,
            animeTitle: animeTitle,
            episodeTitle: episodeTitle,
            shift: shift,
            providerContext: providerContext
        )
    }

    public init(mediaFileID: UUID, episodeRef: DanmakuEpisodeRef, isManual: Bool, matchedAt: Date = .now) {
        self.init(
            mediaFileID: mediaFileID,
            providerID: episodeRef.providerID,
            episodeID: episodeRef.episodeID,
            animeTitle: episodeRef.animeTitle,
            episodeTitle: episodeRef.episodeTitle,
            shift: episodeRef.shift,
            isManual: isManual,
            matchedAt: matchedAt,
            providerContext: episodeRef.providerContext
        )
    }
}
