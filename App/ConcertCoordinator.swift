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
    /// Reads a work's release folder inside the sandbox. Set by `AppModel`,
    /// which owns the library roots and their security scopes — the folder can
    /// only be opened while a scope is held, so the reading happens there.
    var releaseFilesResolver: ((UUID) async -> ConcertReleaseFiles?)?

    func attach(database: LibraryDatabase?) {
        self.database = database
    }

    /// What a work's own folder says about itself — the catalogue number in a
    /// cue sheet's name, the jacket scans, the track list. Read before any
    /// service is asked, because the number is usually here and almost never in
    /// the folder's name.
    private func releaseFiles(forAnimeID animeID: UUID) async -> ConcertReleaseFiles {
        await releaseFilesResolver?(animeID) ?? ConcertReleaseFiles()
    }

    var hasDiscogsKey: Bool { CredentialStore.Concert.loadDiscogsCredentials() != nil }
    var hasSetlistFMKey: Bool { CredentialStore.Concert.loadSetlistFMKey() != nil }

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
                // A record already there is left alone — unless it is a thin
                // one. A release identified before the folder itself was read
                // has no setlist and nothing from the box, and re-asking is
                // cheap next to leaving a page that stays empty for ever.
                if let existing = try await database.concertRelease(animeID: work.animeID),
                   existing.songCount > 0 || !existing.extras.isEmpty {
                    // Unless it was filed under something that was never a
                    // catalogue number, in which case the record is wrong
                    // rather than thin and keeping it is keeping the wrong
                    // concert on the page for ever.
                    guard !existing.wasFiledUnderARealCatalogueNumber else { continue }
                    try await database.deleteConcertRelease(animeID: work.animeID)
                }
                progress = String(localized: "Looking up \(work.title)…")
                let files = await releaseFiles(forAnimeID: work.animeID)
                let found = await identifier().identify(folderName: work.folderName, files: files)
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
            identified += await identifyConcertsNoProviderKnows(isAutomatic: isAutomatic)
            progress = identified == 0 ? nil : String(localized: "Identified \(identified) discs")
            await reload()
        } catch {
            if !isAutomatic { errorMessage = error.localizedDescription }
        }
    }

    /// Picks up the concerts that are not discs.
    ///
    /// A live Blu-ray ripped to MKV has no disc structure and usually no
    /// catalogue number, so nothing above would ever offer it — and **no anime
    /// index lists a concert**, so the match review asks about it at every
    /// launch and can never be satisfied. That is what this is for: a work no
    /// provider has heard of, which Bangumi files as a 演出, is a concert.
    ///
    /// Requiring the 演出 subject is what keeps it safe to point at every
    /// unmatched work. A 音乐 subject would also match an album, and a loose
    /// title would match the artist's other concerts; a performance subject
    /// whose title plainly matches is an event that happened in a hall.
    private func identifyConcertsNoProviderKnows(isAutomatic: Bool) async -> Int {
        guard let database else { return 0 }
        // Works no provider knows, plus concerts already here whose record is a
        // thin one — the second group is how a page identified before the
        // folder was read ever gets its setlist and its scans.
        var works = (try? await database.worksWithNoMetadata()) ?? []
        for concert in concerts where concert.release?.songCount ?? 0 == 0
            && concert.release?.extras.isEmpty != false {
            works.append((animeID: concert.id, title: concert.anime.title))
        }
        // And the ones that are wrong rather than thin: a record filed under a
        // key that is no longer a catalogue number was matched by something
        // that never was one. Measured in this library — a folder of scans
        // named `IMG-01.png` … `IMG-13.png` put MyGO's 7th LIVE and its Extra
        // Studio Live under a compilation Discogs files as `IMG015`. The record
        // is thrown away first, so a lookup that now finds nothing leaves an
        // honest blank rather than the wrong concert.
        for concert in concerts {
            guard let release = concert.release, !release.wasFiledUnderARealCatalogueNumber,
                  !works.contains(where: { $0.animeID == concert.id })
            else { continue }
            try? await database.deleteConcertRelease(animeID: concert.id)
            works.append((animeID: concert.id, title: concert.anime.title))
        }
        guard !works.isEmpty else { return 0 }
        let folders = (try? await database.releaseFolders()) ?? []
        let folderByAnime = Dictionary(
            folders.map { ($0.animeID, $0.folderName) },
            uniquingKeysWith: { first, _ in first }
        )
        var moved = 0
        for work in works {
            progress = String(localized: "Looking up \(work.title)…")
            // The folder first: a release with a catalogue number in it is
            // identified outright, and only a folder with nothing in it has to
            // fall back to asking Bangumi about the title.
            let files = await releaseFiles(forAnimeID: work.animeID)
            var found = await identifier().identify(folderName: work.title, files: files)
            if found.release?.isLiveRecording != true {
                var byTitle = await identifier().identify(title: work.title, requiringPerformance: true)
                if byTitle.release != nil {
                    // Keep what the folder gave — the scans and the cue sheet —
                    // and add the hall the title lookup found.
                    byTitle.release = ConcertReleaseMerge.merge(
                        [found.release, byTitle.release].compactMap { $0 }
                    )
                    found = byTitle
                }
            }
            guard let release = found.release, release.isLiveRecording else {
                // No service knows it, and for a BDRip of a live plenty never
                // will: no disc, no catalogue number, and no subject filed
                // anywhere. Its own name is then the only evidence there is —
                // and it is enough, because the alternative is the match review
                // asking about a concert as if it were an anime at every
                // launch, with no answer that is not wrong.
                let names = [work.title, folderByAnime[work.animeID]].compactMap { $0 }
                guard ConcertNameHeuristics.isConcert(names) else { continue }
                if (try? await database.markAnimeAsConcert(id: work.animeID)) == true { moved += 1 }
                continue
            }
            do {
                try await database.saveConcertRelease(release, forAnimeID: work.animeID)
                try await database.markAnimeAsConcert(id: work.animeID)
                moved += 1
            } catch {
                if !isAutomatic { errorMessage = error.localizedDescription }
            }
        }
        return moved
    }

    /// Looks one concert up again, from scratch.
    ///
    /// Reached from the section's context menu, and it is the only way to make
    /// a record that is already complete be re-read: the automatic pass leaves
    /// anything with a setlist alone, so a release identified before a source
    /// existed would never see that source. It is also the only path that works
    /// for a **BDRip** — it used to ask `discWorks()` alone, which lists `.iso`
    /// and `BDMV` works only, so for the one concert actually in this library it
    /// returned in silence and the menu item did nothing at all.
    func identify(animeID: UUID) async {
        guard let database else { return }
        do {
            let title = try await database.anime(id: animeID)?.title
            // The folder is what carries the catalogue number; a rip that is not
            // a disc work still has one.
            var folder = try await database.discWorks().first { $0.animeID == animeID }?.folderName
            if folder == nil {
                folder = try await database.releaseFolders()
                    .first { $0.animeID == animeID }?.folderName
            }
            guard let name = folder ?? title else { return }
            isIdentifying = true
            defer { isIdentifying = false; progress = nil }
            progress = String(localized: "Looking up \(title ?? name)…")

            let files = await releaseFiles(forAnimeID: animeID)
            var found = await identifier().identify(folderName: name, files: files)
            // No catalogue number anywhere, which is the ordinary case for a
            // rip: fall back to the title, the way the automatic pass does.
            if found.release?.isLiveRecording != true, let title, !title.isEmpty {
                var byTitle = await identifier().identify(title: title)
                if byTitle.release != nil {
                    byTitle.release = ConcertReleaseMerge.merge(
                        [found.release, byTitle.release].compactMap { $0 }
                    )
                    found = byTitle
                }
            }
            if let release = found.release {
                try await database.saveConcertRelease(release, forAnimeID: animeID)
                if found.isConcert { try await database.markAnimeAsConcert(id: animeID) }
            } else if let failure = found.failures.values.first {
                errorMessage = failure
            } else {
                errorMessage = String(localized: "No source has a release under “\(name)”. A disc is matched by the catalogue number in its folder — ANZX-10294, BRMM-10716 — or by a title Bangumi files as a 演出.")
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Identifies a work from a catalogue number the viewer typed.
    ///
    /// The escape hatch for everything the folder name cannot answer: a BDRip
    /// whose folder carries no catalogue number, a disc filed under a number the
    /// reader did not recognise. It is the same key the automatic path uses, so
    /// the answer is the same answer — it just arrives by hand.
    func identify(animeID: UUID, catalogNumber text: String) async {
        guard let database else { return }
        guard let number = ConcertCatalogNumber.first(in: text) else {
            errorMessage = String(localized: "“\(text)” is not a catalogue number. They look like ANZX-10294 or BRMM-10716.")
            return
        }
        isIdentifying = true
        defer { isIdentifying = false; progress = nil }
        progress = String(localized: "Looking up \(number.description)…")
        let found = await identifier().identify(folderName: number.description)
        guard let release = found.release else {
            errorMessage = found.failures.values.first
                ?? String(localized: "No source has a release under \(number.description).")
            return
        }
        do {
            try await database.saveConcertRelease(release, forAnimeID: animeID)
            try await database.markAnimeAsConcert(id: animeID)
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
            bangumi: BangumiConcertProvider(),
            setlistFM: CredentialStore.Concert.loadSetlistFMKey()
                .map { SetlistFMConcertProvider(apiKey: $0) }
        )
    }

    // MARK: - Moving a work in and out by hand

    /// `title` is for a work whose files have not landed yet: a download that
    /// named itself a concert is marked the moment it starts, and the section's
    /// own list is built from media files, so it cannot supply the name.
    func markAsConcert(animeID: UUID, title: String? = nil) async {
        guard let database else { return }
        do {
            try await database.markAnimeAsConcert(id: animeID)
            await reload()
            // A work moved in by hand is usually one nothing could identify: a
            // BDRip, no disc, no catalogue number anywhere. Bangumi is the one
            // source that will answer a title, and what it adds — the hall, the
            // date, the cover, a score — is the difference between a page and a
            // folder name.
            guard try await database.concertRelease(animeID: animeID) == nil,
                  let title = concerts.first(where: { $0.id == animeID })?.anime.title ?? title
            else { return }
            isIdentifying = true
            defer { isIdentifying = false; progress = nil }
            progress = String(localized: "Looking up \(title)…")
            let found = await identifier().identify(title: title)
            if let release = found.release {
                try await database.saveConcertRelease(release, forAnimeID: animeID)
                await reload()
            }
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
            // Stored even when it places nothing. "We looked and there was
            // nothing to go on" is a different state from "nobody has looked
            // yet", and only the first one lets the page stop promising times
            // that are never coming — a rip whose chapter marks were stripped
            // has no source for them at all.
            try await database.saveConcertSetlist(
                StoredConcertSetlist(episodeID: episodeID, alignment: alignment, chapters: chapters)
            )
            setlists[episodeID] = alignment
            chaptersByEpisode[episodeID] = chapters
            return alignment.placements.isEmpty ? nil : alignment
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

    /// The disc has been opened and carried no chapter marks, so there is
    /// nothing to place the songs on and nothing further to wait for.
    func discHasNoChapters(forEpisodeID episodeID: UUID) -> Bool {
        guard let alignment = setlists[episodeID] else { return false }
        return alignment.placements.isEmpty && (chaptersByEpisode[episodeID] ?? []).isEmpty
    }

    /// Nobody has opened this disc yet, so its chapter marks have not been read.
    func setlistNotLookedAtYet(forEpisodeID episodeID: UUID) -> Bool {
        setlists[episodeID] == nil
    }

    /// Loads whatever timeline is already stored, without a player.
    func loadStoredSetlist(forEpisodeID episodeID: UUID) async {
        guard let database, setlists[episodeID] == nil else { return }
        if let stored = try? await database.concertSetlist(episodeID: episodeID) {
            setlists[episodeID] = stored.alignment
            chaptersByEpisode[episodeID] = stored.chapters
        }
    }

    /// What a pasted timeline would do, before it does it.
    struct PastedTimelinePreview: Sendable {
        var discs: [ConcertTimelineParser.Disc]
        var discCount: Int { discs.count }
        var entryCount: Int { discs.reduce(0) { $0 + $1.entries.count } }
        var isUsable: Bool { !discs.isEmpty }
    }

    func previewPastedTimeline(_ text: String) -> PastedTimelinePreview {
        PastedTimelinePreview(discs: ConcertTimelineParser.parse(text))
    }

    /// Takes a timeline somebody found and pasted in, and makes it the setlist.
    ///
    /// Not an overlay on the setlist that is already there: the paste *is* the
    /// programme, in the order it happened, including the parts no catalogue
    /// lists — the encore, the curtain call. It is stored as a hand-made
    /// correction, so nothing computed may overwrite it.
    ///
    /// A disc matches by the number the paste gave it, and by order when the
    /// paste gave none.
    @discardableResult
    func applyPastedTimeline(_ text: String, forAnimeID animeID: UUID) async -> Int {
        guard let database else { return 0 }
        let parsed = ConcertTimelineParser.parse(text)
        guard !parsed.isEmpty else { return 0 }
        let episodes = (try? await database.episodes(animeID: animeID)) ?? []
        guard !episodes.isEmpty else { return 0 }

        var release = (try? await database.concertRelease(animeID: animeID))
        var applied = 0

        for (index, disc) in parsed.enumerated() {
            let number = disc.number ?? index + 1
            let episode = episodes.first { $0.episode.numberText.flatMap { Int($0) } == number }
                ?? (episodes.indices.contains(index) ? episodes[index] : nil)
            guard let episode else { continue }

            let (tracks, placements) = disc.programme()
            let alignment = ConcertSetlistAlignment(
                placements: placements, method: .chapterTitles, confidence: 1
            )
            try? await database.saveConcertSetlist(StoredConcertSetlist(
                episodeID: episode.episode.id, alignment: alignment,
                chapters: chaptersByEpisode[episode.episode.id] ?? [], isManual: true
            ))
            setlists[episode.episode.id] = alignment
            release = replacing(disc: number, in: release, with: tracks, animeID: animeID)
            applied += 1
        }

        if let release {
            try? await database.saveConcertRelease(release, forAnimeID: animeID)
        }
        await reload()
        return applied
    }

    /// Writes a pasted disc into the stored release, creating one when no
    /// service ever answered — which is the case this exists for.
    private func replacing(
        disc number: Int,
        in release: ConcertRelease?,
        with tracks: [ConcertTrack],
        animeID: UUID
    ) -> ConcertRelease? {
        var release = release ?? ConcertRelease(
            provider: .localFiles,
            externalID: animeID.uuidString,
            title: concerts.first { $0.id == animeID }?.displayTitle ?? "",
            isLiveRecording: true
        )
        let videoPositions = release.videoDiscs.map(\.position)
        if videoPositions.indices.contains(number - 1) {
            let position = videoPositions[number - 1]
            if let slot = release.discs.firstIndex(where: { $0.position == position }) {
                release.discs[slot].tracks = tracks
                return release
            }
        }
        release.discs.append(ConcertDisc(
            position: (release.discs.map(\.position).max() ?? 0) + 1,
            title: nil, format: "Blu-ray", tracks: tracks
        ))
        return release
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
