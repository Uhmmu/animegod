import Foundation

/// A concert in the library: the work, what is known about the release, and
/// how far through it the viewer is.
public struct LibraryConcert: Identifiable, Hashable, Sendable {
    public let anime: Anime
    /// What the providers said, merged. Nil while a disc has been scanned but
    /// not yet identified — which is an ordinary state, not an error, and the
    /// section says so rather than hiding the disc.
    public let release: ConcertRelease?
    /// How many playable discs of this work are on disk.
    public let discCount: Int
    public let watchedDiscCount: Int
    public let lastPlayedAt: Date?

    public var id: UUID { anime.id }

    /// What the card shows. The release's own title is better than the folder's
    /// — the folder is named by whoever ripped it — but there may not be one
    /// yet.
    public var displayTitle: String { release?.title ?? anime.title }

    public var songCount: Int { release?.songCount ?? 0 }

    public init(
        anime: Anime,
        release: ConcertRelease?,
        discCount: Int,
        watchedDiscCount: Int = 0,
        lastPlayedAt: Date? = nil
    ) {
        self.anime = anime
        self.release = release
        self.discCount = discCount
        self.watchedDiscCount = watchedDiscCount
        self.lastPlayedAt = lastPlayedAt
    }
}

/// A setlist timeline as it was stored: what was worked out, and whether a
/// person corrected it.
public struct StoredConcertSetlist: Hashable, Sendable {
    public let episodeID: UUID
    public var alignment: ConcertSetlistAlignment
    /// A viewer moved this by hand, so nothing may recompute over it.
    public var isManual: Bool
    public var updatedAt: Date

    public init(
        episodeID: UUID,
        alignment: ConcertSetlistAlignment,
        isManual: Bool = false,
        updatedAt: Date = .now
    ) {
        self.episodeID = episodeID
        self.alignment = alignment
        self.isManual = isManual
        self.updatedAt = updatedAt
    }
}

/// Which songs of one disc have been seen.
public struct ConcertSongProgress: Hashable, Sendable {
    public let songPosition: Int
    public var isWatched: Bool
    public var lastPlayedAt: Date?

    public init(songPosition: Int, isWatched: Bool, lastPlayedAt: Date? = nil) {
        self.songPosition = songPosition
        self.isWatched = isWatched
        self.lastPlayedAt = lastPlayedAt
    }
}
