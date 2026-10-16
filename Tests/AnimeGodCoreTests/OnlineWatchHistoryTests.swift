import Foundation
import Testing
@testable import AnimeGodCore

/// Watch records for episodes watched from a site.
///
/// The section is independent and the record is shared, which is two claims
/// in one: an online work must never reach the grid, the continue shelf or
/// any pass that looks for something to identify — and it must reach the
/// resume point, the diary and the statistics exactly as a local episode
/// does.
struct OnlineWatchHistoryTests {
    private func ref(
        rule: String = "樱花动漫",
        work: String = "https://yhdm.example/show/1234",
        name: String = "药师少女的独语",
        road: String = "线路1",
        label: String = "第5集",
        index: Int = 4,
        page: String = "https://yhdm.example/play/1234/1/5"
    ) -> OnlineEpisodeRef {
        OnlineEpisodeRef(
            ruleName: rule, workPageURL: work, workName: name,
            roadName: road, label: label, index: index, pageURL: page
        )
    }

    // MARK: - Reading a site's labels

    @Test func aLabelStatingOneNumberIsThatEpisode() {
        for label in ["第5集", "05", "5", "EP5", "第５集"] {
            let identity = OnlineWatchIdentity.episodeIdentity(label: label, index: 4)
            #expect(identity.key == "E5", "\(label)")
            #expect(identity.number == 5)
            #expect(identity.numberText == "5")
            #expect(identity.kind == .regular)
        }
    }

    /// Two numbers in a label are not an episode number. `1080P第5集` would
    /// otherwise be episode 1080, and `第2季第1集` would be episode 2 of a
    /// season this list does not distinguish.
    @Test func aLabelStatingTwoNumbersIsItself() {
        let crowded = OnlineWatchIdentity.episodeIdentity(label: "1080P第5集", index: 4)
        #expect(crowded.number == nil)
        #expect(crowded.kind == .special)
        let season = OnlineWatchIdentity.episodeIdentity(label: "第2季第1集", index: 0)
        #expect(season.number == nil)
        #expect(season.key != crowded.key)
    }

    /// A trailer is not the season. Counting one as a regular episode would
    /// keep a finished work from ever reading as finished.
    @Test func anUnnumberedLabelIsASpecialAndKeepsItsOwnName() {
        let identity = OnlineWatchIdentity.episodeIdentity(label: " OVA ", index: 2)
        #expect(identity.kind == .special)
        #expect(identity.numberText == "OVA")
        #expect(identity.key == OnlineWatchIdentity.episodeIdentity(label: "ova", index: 7).key)
    }

    /// The namespace is what keeps a site's copy of a show out of the row the
    /// scanner made for the files on disk — the `normalizedTitle` column is
    /// unique, and `LibraryDatabase.normalize` strips every character this
    /// key is built out of, so the two can never collide.
    @Test func aWorkIdentityIsNamespacedPerRuleAndPage() {
        let a = OnlineWatchIdentity.workIdentity(ruleName: "樱花动漫", pageURL: "https://a.example/1")
        let b = OnlineWatchIdentity.workIdentity(ruleName: "樱花动漫", pageURL: "https://a.example/2")
        let c = OnlineWatchIdentity.workIdentity(ruleName: "Other", pageURL: "https://a.example/1")
        #expect(a != b)
        #expect(a != c)
        #expect(OnlineWatchIdentity.isOnlineWorkIdentity(a))
        #expect(!OnlineWatchIdentity.isOnlineWorkIdentity("yakushoujinohitorigoto"))
        // Case is not identity for a rule name; the catalog's own spelling is
        // only ever display.
        #expect(OnlineWatchIdentity.workIdentity(ruleName: "ABC", pageURL: "https://a.example/1")
                == OnlineWatchIdentity.workIdentity(ruleName: "abc", pageURL: "https://a.example/1"))
    }

    // MARK: - The rows a play writes

    @Test func playingAnOnlineEpisodeFilesItUnderAWorkOfItsOwn() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let record = try await database.onlineEpisode(for: ref())
        #expect(record.episode.numberText == "5")
        #expect(record.progress == nil)

        let work = try await database.anime(id: record.animeID)
        #expect(work?.title == "药师少女的独语")
    }

    @Test func aSecondPlayFindsTheSameRows() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let first = try await database.onlineEpisode(for: ref())
        let again = try await database.onlineEpisode(for: ref())
        #expect(first.episode.id == again.episode.id)
        #expect(first.animeID == again.animeID)
    }

    /// A site offers the same episode on several playback lines under a
    /// different URL each time. Finishing it on whichever line was up is
    /// finishing it, so both URLs answer with one episode row.
    @Test func thePlaybackLinesOfOneWorkShareAnEpisode() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let line1 = try await database.onlineEpisode(for: ref(road: "线路1", page: "https://yhdm.example/play/1234/1/5"))
        let line2 = try await database.onlineEpisode(for: ref(road: "线路2", label: "05", page: "https://yhdm.example/play/1234/2/5"))
        #expect(line1.episode.id == line2.episode.id)

        try await database.save(progress: PlaybackProgress(
            episodeID: line1.episode.id, position: 1_400, duration: 1_440, isWatched: true
        ))
        let states = try await database.onlineWatchStates(
            ruleName: "樱花动漫",
            pageURLs: ["https://yhdm.example/play/1234/1/5", "https://yhdm.example/play/1234/2/5"]
        )
        #expect(states.count == 2)
        #expect(states.values.filter(\.isWatched).count == 2)
    }

    /// Two different episodes stay two, and a page nobody has opened has no
    /// state at all — which is what the grid draws as unwatched.
    @Test func watchStatesAreReportedPerPage() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let five = try await database.onlineEpisode(for: ref())
        _ = try await database.onlineEpisode(for: ref(label: "第6集", index: 5, page: "https://yhdm.example/play/1234/1/6"))
        try await database.save(progress: PlaybackProgress(
            episodeID: five.episode.id, position: 300, duration: 1_440, isWatched: false
        ))
        let states = try await database.onlineWatchStates(ruleName: "樱花动漫", pageURLs: [
            "https://yhdm.example/play/1234/1/5",
            "https://yhdm.example/play/1234/1/6",
            "https://yhdm.example/play/1234/1/7"
        ])
        #expect(states.count == 1)
        #expect(states["https://yhdm.example/play/1234/1/5"]?.isPartial == true)
        #expect(states["https://yhdm.example/play/1234/1/7"] == nil)
    }

    @Test func markingAnOnlineEpisodeWatchedCreatesItsRowsIfNeeded() async throws {
        let database = try LibraryDatabase(inMemory: true)
        try await database.setOnlineWatched(true, for: ref())
        let states = try await database.onlineWatchStates(
            ruleName: "樱花动漫", pageURLs: ["https://yhdm.example/play/1234/1/5"]
        )
        #expect(states.values.first?.isWatched == true)
        try await database.setOnlineWatched(false, for: ref())
        let after = try await database.onlineWatchStates(
            ruleName: "樱花动漫", pageURLs: ["https://yhdm.example/play/1234/1/5"]
        )
        #expect(after.values.first?.isWatched == false)
    }

    // MARK: - Sharing the record without joining the library

    @Test func anOnlineEpisodeReachesTheDiaryAndTheStatistics() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let record = try await database.onlineEpisode(for: ref())
        let ended = Date.now
        try await database.record(event: WatchEvent(
            animeID: record.animeID,
            episodeID: record.episode.id,
            animeTitle: record.workName,
            episodeLabel: record.episode.displayLabel,
            startedAt: ended.addingTimeInterval(-1_400),
            endedAt: ended,
            watchedDuration: 1_400,
            completion: 0.97,
            completedEpisode: true
        ))
        let events = try await database.watchEvents()
        #expect(events.count == 1)
        #expect(events.first?.animeTitle == "药师少女的独语")
        #expect(events.first?.episodeLabel == "Episode 5")
        let summary = try await database.diarySummary()
        #expect(summary.completedEpisodeCount == 1)
        #expect(summary.totalWatchTime == 1_400)
    }

    @Test func anOnlineWorkStaysOutOfTheGridAndTheContinueShelf() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let record = try await database.onlineEpisode(for: ref())
        try await database.save(progress: PlaybackProgress(
            episodeID: record.episode.id, position: 300, duration: 1_440, isWatched: false
        ))
        let grid = try await database.library()
        let shelf = try await database.continueWatching()
        #expect(grid.isEmpty)
        #expect(shelf.isEmpty)
        // Nor may it be offered up as a work waiting to be identified.
        let unmatched = try await database.worksWithNoMetadata()
        let notConcerts = try await database.worksThatAreNotConcerts()
        let duplicates = try await database.duplicateWorkGroups()
        #expect(unmatched.isEmpty)
        #expect(notConcerts.isEmpty)
        #expect(duplicates.isEmpty)
    }

    /// Every scan drops the episode rows no file stands behind. An online
    /// episode never had one, and losing its rows would lose the progress,
    /// the mark and the history that point at them.
    @Test func aScanDoesNotSweepAwayOnlineEpisodes() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let record = try await database.onlineEpisode(for: ref())
        try await database.save(progress: PlaybackProgress(
            episodeID: record.episode.id, position: 1_400, duration: 1_440, isWatched: true
        ))

        let root = LibraryRoot(displayName: "T7", lastKnownPath: "/Volumes/T7/video")
        try await database.save(root: root)
        try await database.importScan(LibraryScanResult(root: root, files: [
            ScannedMediaFile(
                relativePath: "Kusuriya no Hitorigoto/EP01.mkv",
                fileSize: 1_400_000_000,
                modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Kusuriya no Hitorigoto", episode: 1, confidence: 0.9)
            )
        ], skippedUnreadableCount: 0))

        let states = try await database.onlineWatchStates(
            ruleName: "樱花动漫", pageURLs: ["https://yhdm.example/play/1234/1/5"]
        )
        #expect(states.values.first?.isWatched == true)
        let work = try await database.anime(id: record.animeID)
        #expect(work != nil)
        // And the scanned work is the only thing in the grid.
        let grid = try await database.library()
        #expect(grid.count == 1)
    }

    /// A site carrying a show that is also on disk must not be folded into
    /// it: the two have different numbering, and the local file was not
    /// watched because the stream was.
    @Test func aWorkOnDiskAndTheSameWorkOnlineStayApart() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let local = try await database.findOrCreateAnime(title: "药师少女的独语")
        let online = try await database.onlineEpisode(for: ref())
        #expect(local.id != online.animeID)
    }
}
