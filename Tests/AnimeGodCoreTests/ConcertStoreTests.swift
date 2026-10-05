import Foundation
import Testing
@testable import AnimeGodCore

/// The concert store, and the two rules in it that are easy to get wrong:
/// a concert must leave the library grid, and neither a hand-made correction
/// nor a song already seen may be undone by something running on its own.
struct ConcertStoreTests {
    private func library() async throws -> (LibraryDatabase, LibraryRoot) {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Concerts", lastKnownPath: "/Volumes/T7/concerts")
        try await database.save(root: root)
        return (database, root)
    }

    /// Imports one disc and returns the work and the episode standing for it.
    private func importDisc(
        into database: LibraryDatabase,
        root: LibraryRoot,
        folder: String = "結束バンドLIVE-恒星-",
        file: String = "結束バンドLIVE-恒星-.iso"
    ) async throws -> (animeID: UUID, episodeID: UUID) {
        let scan = LibraryScanResult(root: root, files: [
            ScannedMediaFile(
                relativePath: "\(folder)/\(file)",
                fileSize: 42_000_000_000,
                modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: folder, episode: nil, confidence: 0.9)
            )
        ], skippedUnreadableCount: 0)
        try await database.importScan(scan)
        let grid = try await database.library()
        let animeID = try #require(grid.first?.id)
        let episodes = try await database.episodes(animeID: animeID)
        return (animeID, try #require(episodes.first?.episode.id))
    }

    private func release(discs: [ConcertDisc] = []) -> ConcertRelease {
        ConcertRelease(
            provider: .musicBrainz,
            externalID: "295db787-13c3-4aae-8265-da1cfdd7a5dc",
            title: "結束バンドLIVE-恒星-",
            artistNames: ["結束バンド", "Kessoku Band"],
            releaseDate: "2023-11-22",
            country: "JP",
            labels: ["Aniplex"],
            catalogNumbers: ["ANZX-10294", "ANZX-10295", "ANZX-10296"],
            barcode: "4534530147127",
            genres: ["Rock", "J-Rock"],
            discs: discs,
            coverImageURLs: [URL(string: "https://coverartarchive.org/release/x/1-500.jpg")!],
            sourceURL: URL(string: "https://musicbrainz.org/release/x")!,
            score: 8.2,
            ratingCount: 18,
            summary: "Zepp Haneda（TOKYO）で開催された",
            venue: "Zepp Haneda（TOKYO）",
            performedOn: "2023-05-21",
            officialSiteURL: URL(string: "https://bocchi.rocks")!
        )
    }

    private func liveDisc() -> ConcertDisc {
        ConcertDisc(position: 1, title: "結束バンドLIVE-恒星-", format: "Blu-ray", tracks: [
            ConcertTrack(position: 1, title: "ひとりぼっち東京", duration: 233),
            ConcertTrack(position: 2, title: "ギターと孤独と蒼い惑星", duration: 239),
            ConcertTrack(position: 3, title: "青春コンプレックス", duration: 332, isEncore: true),
            ConcertTrack(position: 4, title: "オーディオコメンタリー", duration: 4200, kind: .commentary)
        ])
    }

    // MARK: - Leaving the grid

    /// The one thing asked for outright: a concert does not appear on the home
    /// screen. It also must not appear on the continue shelf — both open the
    /// anime page, which a concert does not use, and a concert has nothing to
    /// continue *towards*.
    @Test func aConcertLeavesTheGridAndTheContinueShelf() async throws {
        let (database, root) = try await library()
        let disc = try await importDisc(into: database, root: root)
        try await database.save(progress: PlaybackProgress(
            episodeID: disc.episodeID, position: 600, duration: 5600, updatedAt: .now
        ))

        #expect(try await database.library().count == 1)
        #expect(try await database.continueWatching().count == 1)

        #expect(try await database.markAnimeAsConcert(id: disc.animeID))
        #expect(try await database.library().isEmpty)
        #expect(try await database.continueWatching().isEmpty)

        let concerts = try await database.concerts()
        #expect(concerts.count == 1)
        #expect(concerts.first?.discCount == 1)
        #expect(concerts.first?.anime.kind == .live)
    }

    /// A disc on disk that no provider has answered about yet is still a disc.
    /// Hiding it until the lookup succeeds would look like a failed scan.
    @Test func listsADiscThatHasNotBeenIdentifiedYet() async throws {
        let (database, root) = try await library()
        let disc = try await importDisc(into: database, root: root)
        try await database.markAnimeAsConcert(id: disc.animeID)

        let concert = try #require(try await database.concerts().first)
        #expect(concert.release == nil)
        #expect(concert.songCount == 0)
        // With nothing matched, the folder's own name is what there is.
        #expect(concert.displayTitle == "結束バンドLIVE-恒星-")
    }

    // MARK: - The release

    @Test func roundTripsAReleaseWithItsDiscs() async throws {
        let (database, root) = try await library()
        let disc = try await importDisc(into: database, root: root)
        try await database.markAnimeAsConcert(id: disc.animeID)
        try await database.saveConcertRelease(release(discs: [liveDisc()]), forAnimeID: disc.animeID)

        let stored = try #require(try await database.concertRelease(animeID: disc.animeID))
        #expect(stored.title == "結束バンドLIVE-恒星-")
        #expect(stored.venue == "Zepp Haneda（TOKYO）")
        #expect(stored.performedOn == "2023-05-21")
        #expect(stored.score == 8.2)
        #expect(stored.artistNames == ["結束バンド", "Kessoku Band"])
        #expect(stored.catalogNumbers == ["ANZX-10294", "ANZX-10295", "ANZX-10296"])
        #expect(stored.coverImageURLs.count == 1)
        // The commentary is on the disc and off the setlist.
        #expect(stored.discs.first?.tracks.count == 4)
        #expect(stored.songCount == 3)
        #expect(stored.totalSongDuration == 804)

        // And the section reads the release rather than the folder name.
        let concert = try #require(try await database.concerts().first)
        #expect(concert.songCount == 3)
        #expect(concert.release?.venue == "Zepp Haneda（TOKYO）")
    }

    @Test func savingAReleaseAgainReplacesIt() async throws {
        let (database, root) = try await library()
        let disc = try await importDisc(into: database, root: root)
        try await database.saveConcertRelease(release(), forAnimeID: disc.animeID)
        var corrected = release(discs: [liveDisc()])
        corrected.venue = "Kアリーナ横浜"
        try await database.saveConcertRelease(corrected, forAnimeID: disc.animeID)

        let stored = try #require(try await database.concertRelease(animeID: disc.animeID))
        #expect(stored.venue == "Kアリーナ横浜")
        #expect(stored.discs.count == 1)
    }

    /// A box's three numbers all name one work, so a disc already in the
    /// library is found without asking any service about it.
    @Test func findsAWorkByAnyOfItsCatalogueNumbers() async throws {
        let (database, root) = try await library()
        let disc = try await importDisc(into: database, root: root)
        try await database.saveConcertRelease(release(discs: [liveDisc()]), forAnimeID: disc.animeID)

        for spelling in ["ANZX-10294", "ANZX 10296", "anzx10295"] {
            let number = try #require(ConcertCatalogNumber.first(in: spelling))
            #expect(try await database.concertAnimeID(forCatalogNumber: number) == disc.animeID,
                    "\(spelling) names the same box")
        }
        let other = try #require(ConcertCatalogNumber.first(in: "BRMM-10716"))
        #expect(try await database.concertAnimeID(forCatalogNumber: other) == nil)
    }

    // MARK: - The timeline

    @Test func roundTripsATimeline() async throws {
        let (database, root) = try await library()
        let disc = try await importDisc(into: database, root: root)
        let alignment = ConcertSetlistAligner.align(
            tracks: liveDisc().tracks,
            chapters: [
                ConcertChapterMark(index: 0, startTime: 0),
                ConcertChapterMark(index: 1, startTime: 233),
                ConcertChapterMark(index: 2, startTime: 472)
            ],
            duration: 900
        )
        try await database.saveConcertSetlist(
            StoredConcertSetlist(episodeID: disc.episodeID, alignment: alignment)
        )

        let stored = try #require(try await database.concertSetlist(episodeID: disc.episodeID))
        #expect(stored.alignment.method == alignment.method)
        #expect(stored.alignment.placements.map(\.startTime) == [0, 233, 472])
        #expect(!stored.isManual)
    }

    /// The rule that makes the correction worth offering: once a person has
    /// moved the timeline, nothing that merely worked one out may move it back.
    @Test func aCorrectedTimelineIsNotOverwrittenByAComputedOne() async throws {
        let (database, root) = try await library()
        let disc = try await importDisc(into: database, root: root)
        let chapters = [
            ConcertChapterMark(index: 0, startTime: 0),
            ConcertChapterMark(index: 1, startTime: 233),
            ConcertChapterMark(index: 2, startTime: 472)
        ]
        let computed = ConcertSetlistAligner.align(
            tracks: liveDisc().tracks, chapters: chapters, duration: 900
        )
        let corrected = ConcertSetlistAligner.shifting(computed, by: 1, chapters: chapters)
        try await database.saveConcertSetlist(
            StoredConcertSetlist(episodeID: disc.episodeID, alignment: corrected, isManual: true)
        )

        // A later pass works one out again and tries to store it.
        try await database.saveConcertSetlist(
            StoredConcertSetlist(episodeID: disc.episodeID, alignment: computed, isManual: false)
        )

        let stored = try #require(try await database.concertSetlist(episodeID: disc.episodeID))
        #expect(stored.isManual)
        #expect(stored.alignment.placements.first?.startTime == 233, "the correction stands")

        // A second correction is allowed to replace the first.
        try await database.saveConcertSetlist(
            StoredConcertSetlist(episodeID: disc.episodeID, alignment: computed, isManual: true)
        )
        #expect(try await database.concertSetlist(episodeID: disc.episodeID)?
            .alignment.placements.first?.startTime == 0)
    }

    /// The concert rows hang off the work and the episode by foreign key, so
    /// removing the work takes them with it rather than leaving them to be
    /// matched against the next disc that lands in the same folder.
    @Test func removingTheWorkRemovesItsConcertRows() async throws {
        let (database, root) = try await library()
        let disc = try await importDisc(into: database, root: root)
        try await database.saveConcertRelease(release(discs: [liveDisc()]), forAnimeID: disc.animeID)
        try await database.saveConcertSetlist(StoredConcertSetlist(
            episodeID: disc.episodeID,
            alignment: ConcertSetlistAlignment(placements: [], method: .oneToOne, confidence: 0.6)
        ))

        try await database.database.write { db in
            try db.execute(sql: "DELETE FROM anime WHERE id = ?", arguments: [disc.animeID.uuidString])
        }

        #expect(try await database.concertRelease(animeID: disc.animeID) == nil)
        #expect(try await database.concertSetlist(episodeID: disc.episodeID) == nil)
    }
}

/// The chapter marks travel with the timeline, which is what makes the
/// correction reachable: marks only exist while a player has the disc open, so a
/// page that did not store them could show a timeline it has no way to fix.
struct ConcertSetlistChapterTests {
    @Test func keepsTheMarksTheTimelineWasMadeFrom() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Concerts", lastKnownPath: "/Volumes/T7/concerts")
        try await database.save(root: root)
        try await database.importScan(LibraryScanResult(root: root, files: [
            ScannedMediaFile(
                relativePath: "Live/BDMV/index.bdmv", fileSize: 1, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Live", episode: nil, confidence: 0.9)
            )
        ], skippedUnreadableCount: 0))
        let animeID = try #require(try await database.library().first?.id)
        let episodeID = try #require(try await database.episodes(animeID: animeID).first?.episode.id)

        let chapters = (0..<4).map { ConcertChapterMark(index: $0, startTime: Double($0) * 240) }
        let tracks = (1...3).map { ConcertTrack(position: $0, title: "Song \($0)", duration: 235) }
        let alignment = ConcertSetlistAligner.align(tracks: tracks, chapters: chapters, duration: 1000)

        try await database.saveConcertSetlist(StoredConcertSetlist(
            episodeID: episodeID, alignment: alignment, chapters: chapters
        ))

        let stored = try #require(try await database.concertSetlist(episodeID: episodeID))
        #expect(stored.chapters.map(\.startTime) == [0, 240, 480, 720])
        // Which is enough to shift it without a player.
        let moved = ConcertSetlistAligner.shifting(stored.alignment, by: 1, chapters: stored.chapters)
        #expect(moved.placements.first?.startTime == 240)
    }
}
