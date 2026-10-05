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
    /// When any disc of it was last played. A position, not a verdict: there is
    /// no finishing a concert, so nothing here counts how much is left.
    public let lastPlayedAt: Date?

    public var id: UUID { anime.id }

    /// What the card shows: **the library's own name for the work**.
    ///
    /// It used to be the release's title, on the reasoning that a catalogue
    /// knows better than whoever named the folder. Measured against this
    /// library, that is wrong more often than it is right, because **a live
    /// Blu-ray is usually a disc inside an album**: MyGO's 1st and 2nd LIVE
    /// both came back as *音一会*, the 3rd as *壱雫空*, Ave Mujica's 2nd as
    /// *ELEMENTS*, and the 4th as *「Adventus」特典CD ドロリス ver.* — four
    /// concerts wearing the name of the CD they were bundled with. The folder
    /// is named after the concert because that is what somebody went looking
    /// for.
    public var displayTitle: String {
        anime.title.isEmpty ? (release?.title ?? "") : anime.title
    }

    /// The release this concert came in, when that is a different thing — the
    /// album the Blu-ray was bundled with. Nil when the catalogue is simply
    /// spelling the same concert, which is most of the time.
    public var releasedOn: String? {
        guard let title = release?.title, !title.isEmpty, !anime.title.isEmpty else { return nil }
        let left = ConcertSetlistAligner.normalise(title)
        let right = ConcertSetlistAligner.normalise(anime.title)
        guard !left.isEmpty, !right.isEmpty, !ConcertSetlistAligner.titlesMatch(left, right)
        else { return nil }
        return title
    }

    public var songCount: Int { release?.songCount ?? 0 }

    public init(
        anime: Anime,
        release: ConcertRelease?,
        discCount: Int,
        lastPlayedAt: Date? = nil
    ) {
        self.anime = anime
        self.release = release
        self.discCount = discCount
        self.lastPlayedAt = lastPlayedAt
    }
}

/// A setlist timeline as it was stored: what was worked out, and whether a
/// person corrected it.
public struct StoredConcertSetlist: Hashable, Sendable {
    public let episodeID: UUID
    public var alignment: ConcertSetlistAlignment
    /// The disc's chapter marks, as they were when this was worked out.
    ///
    /// Stored rather than re-read because they cannot be re-read: they live in
    /// the disc's playlists and only reach the app while mpv has the disc open.
    /// Without them the page could show a timeline it has no way to correct.
    public var chapters: [ConcertChapterMark]
    /// A viewer moved this by hand, so nothing may recompute over it.
    public var isManual: Bool
    public var updatedAt: Date

    public init(
        episodeID: UUID,
        alignment: ConcertSetlistAlignment,
        chapters: [ConcertChapterMark] = [],
        isManual: Bool = false,
        updatedAt: Date = .now
    ) {
        self.episodeID = episodeID
        self.alignment = alignment
        self.chapters = chapters
        self.isManual = isManual
        self.updatedAt = updatedAt
    }
}
