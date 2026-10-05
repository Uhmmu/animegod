import AnimeGodCore
import Foundation

/// The concert section's own model: what is in the library, what the providers
/// said about it, and where each song starts.
///
/// Its own object rather than more properties on `AppModel` because a concert
/// shares almost nothing with an anime — no episodes to count, no season, no
/// synopsis — and because identifying a library of discs takes minutes at the
/// rate the services allow, which should not be able to hold anything else up.
@MainActor
final class ConcertCoordinator: ObservableObject {
    @Published private(set) var concerts: [LibraryConcert] = []
    /// Disc works that are not concerts — an anime Blu-ray is a disc too. Kept
    /// so the section can offer them: a disc no service has heard of still has
    /// to be reachable.
    @Published private(set) var unidentifiedDiscs: [UUID] = []
    @Published private(set) var isIdentifying = false
    @Published private(set) var progress: String?
    @Published var errorMessage: String?
    /// Setlist timelines by episode, once worked out.
    @Published private(set) var setlists: [UUID: ConcertSetlistAlignment] = [:]
    /// The chapter marks each timeline was made from, so the page can correct
    /// it. They only reach the app while mpv has the disc open, so they are
    /// stored with the timeline rather than re-read.
    private var chaptersByEpisode: [UUID: [ConcertChapterMark]] = [:]

    private var database: LibraryDatabase?

    func attach(database: LibraryDatabase?) {
        self.database = database
    }

    var hasDiscogsKey: Bool { CredentialStore.Concert.loadDiscogsCredentials() != nil }

    // MARK: - Loading

    func reload() async {
        guard let database else { return }
        do {
            let loaded = try await database.concerts()
            let discs = try await database.discWorks()
            concerts = loaded
            unidentifiedDiscs = discs
                .filter { $0.kind != .live }
                .map(\.animeID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Identifying

    /// Looks up every disc in the library that has not been identified yet.
    ///
    /// `isAutomatic` keeps it quiet: a pass that runs on its own must not put a
    /// failure on screen, since the usual reason is that a service is busy and
    /// the next pass will get it.
    func identifyAll(isAutomatic: Bool = false) async {
        guard let database, !isIdentifying else { return }
        isIdentifying = true
        defer {
            isIdentifying = false
            progress = nil
        }
        do {
            let works = try await database.discWorks()
            var identified = 0
            for work in works {
                if try await database.concertRelease(animeID: work.animeID) != nil { continue }
                progress = String(localized: "Looking up \(work.title)…")
                let found = await identifier().identify(folderName: work.folderName)
                guard let release = found.release else {
                    if !isAutomatic, let failure = found.failures.values.first {
                        errorMessage = failure
                    }
                    continue
                }
                try await database.saveConcertRelease(release, forAnimeID: work.animeID)
                // Only a source saying so moves a disc into the section. An
                // anime Blu-ray has a catalogue number too.
                if found.isConcert { try await database.markAnimeAsConcert(id: work.animeID) }
                identified += 1
            }
            progress = identified == 0 ? nil : String(localized: "Identified \(identified) discs")
            await reload()
        } catch {
            if !isAutomatic { errorMessage = error.localizedDescription }
        }
    }

    /// Looks one disc up again, for the disc that was added while a service was
    /// down.
    func identify(animeID: UUID) async {
        guard let database else { return }
        do {
            guard let work = try await database.discWorks().first(where: { $0.animeID == animeID })
            else { return }
            isIdentifying = true
            defer { isIdentifying = false; progress = nil }
            progress = String(localized: "Looking up \(work.title)…")
            let found = await identifier().identify(folderName: work.folderName)
            if let release = found.release {
                try await database.saveConcertRelease(release, forAnimeID: animeID)
                if found.isConcert { try await database.markAnimeAsConcert(id: animeID) }
            } else if let failure = found.failures.values.first {
                errorMessage = failure
            } else {
                errorMessage = String(localized: "No source has a release under “\(work.folderName)”. The folder needs a catalogue number in its name — ANZX-10294, BRMM-10716 — for a disc to be looked up.")
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func identifier() -> ConcertIdentifier {
        ConcertIdentifier(
            discogs: CredentialStore.Concert.loadDiscogsCredentials()
                .map { DiscogsConcertProvider(credentials: $0) },
            musicBrainz: MusicBrainzConcertProvider(),
            bangumi: BangumiConcertProvider()
        )
    }

    // MARK: - Moving a work in and out by hand

    func markAsConcert(animeID: UUID) async {
        guard let database else { return }
        do {
            try await database.markAnimeAsConcert(id: animeID)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFromConcerts(animeID: UUID) async {
        guard let database else { return }
        do {
            try await database.unmarkAnimeAsConcert(id: animeID)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - The timeline

    func release(forAnimeID animeID: UUID) -> ConcertRelease? {
        concerts.first { $0.id == animeID }?.release
    }

    /// Where each song of this disc starts.
    ///
    /// A timeline somebody corrected is returned untouched. Otherwise one is
    /// worked out from the disc's own chapter marks and stored, so the page and
    /// the player agree and the work is not repeated every time the page opens.
    @discardableResult
    func resolveSetlist(
        for episode: EpisodeMedia,
        chapters: [ConcertChapterMark],
        duration: TimeInterval
    ) async -> ConcertSetlistAlignment? {
        guard let database else { return nil }
        let episodeID = episode.episode.id
        do {
            if let stored = try await database.concertSetlist(episodeID: episodeID), stored.isManual {
                setlists[episodeID] = stored.alignment
                chaptersByEpisode[episodeID] = stored.chapters
                return stored.alignment
            }
            guard let release = release(forAnimeID: episode.episode.animeID),
                  let disc = release.videoDisc(
                      forDiscNumber: episode.episode.numberText.flatMap { Int($0) }
                  )
            else { return nil }

            let alignment = ConcertSetlistAligner.align(
                tracks: disc.tracks, chapters: chapters, duration: duration
            )
            guard !alignment.placements.isEmpty else { return nil }
            try await database.saveConcertSetlist(
                StoredConcertSetlist(episodeID: episodeID, alignment: alignment, chapters: chapters)
            )
            setlists[episodeID] = alignment
            chaptersByEpisode[episodeID] = chapters
            return alignment
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Whether a stored timeline can still be corrected — which needs the marks
    /// it was made from.
    func canNudgeSetlist(forEpisodeID episodeID: UUID) -> Bool {
        !(chaptersByEpisode[episodeID] ?? []).isEmpty
    }

    /// Loads whatever timeline is already stored, without a player.
    func loadStoredSetlist(forEpisodeID episodeID: UUID) async {
        guard let database, setlists[episodeID] == nil else { return }
        if let stored = try? await database.concertSetlist(episodeID: episodeID) {
            setlists[episodeID] = stored.alignment
            chaptersByEpisode[episodeID] = stored.chapters
        }
    }

    /// Moves the whole timeline along by a chapter, for the viewer who can see
    /// it is one song out. Stored as a correction, which nothing computed may
    /// overwrite afterwards.
    func nudgeSetlist(forEpisodeID episodeID: UUID, by offset: Int) async {
        guard let database, let current = setlists[episodeID] else { return }
        let chapters = chaptersByEpisode[episodeID] ?? []
        guard !chapters.isEmpty else { return }
        let moved = ConcertSetlistAligner.shifting(current, by: offset, chapters: chapters)
        setlists[episodeID] = moved
        try? await database.saveConcertSetlist(
            StoredConcertSetlist(episodeID: episodeID, alignment: moved, chapters: chapters, isManual: true)
        )
    }
}
