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

/// Following a site's playback line.
///
/// The claim is that a followed work is an ordinary library work in every way
/// the viewer can see — it is in the grid, it has an episode list, the
/// metadata pass reaches it — while still being a page on somebody's site:
/// no files, no concert pass, and gone from the grid the moment nobody
/// follows it.
struct OnlineSubscriptionTests {
    private let rule = "樱花动漫"
    private let work = "https://yhdm.example/show/1234"

    private func line(_ road: String, count: Int) -> [(label: String, pageURL: String, index: Int)] {
        (1...count).map { ("第\($0)集", "https://yhdm.example/play/1234/\(road)/\($0)", $0 - 1) }
    }

    private func follow(
        _ database: LibraryDatabase, road: String = "1", count: Int = 12
    ) async throws -> UUID {
        try await database.followOnlineRoad(
            ruleName: rule, workPageURL: work, workName: "药师少女的独语",
            roadName: road, episodes: line(road, count: count)
        )
    }

    @Test func followingALinePutsTheWorkInTheGrid() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let before = try await database.library()
        #expect(before.isEmpty)

        let animeID = try await follow(database)
        let grid = try await database.library()
        #expect(grid.count == 1)
        let card = try #require(grid.first)
        #expect(card.id == animeID)
        #expect(card.anime.title == "药师少女的独语")
        // What the card's globe is drawn from.
        #expect(card.isOnline)
        #expect(card.episodeCount == 12)
        #expect(card.watchedCount == 0)
    }

    /// The whole line up front, not one row per click: the work is in the
    /// grid now, and a card reading "0 episodes" would be a card that lies.
    @Test func theWholeLineIsMaterializedAtOnce() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let animeID = try await follow(database)
        let episodes = try await database.episodes(animeID: animeID)
        #expect(episodes.count == 12)
        #expect(episodes.first?.online?.roadName == "1")
        #expect(episodes.first?.online?.label == "第1集")
        #expect(episodes.map(\.episode.numberText) == (1...12).map(String.init))
    }

    @Test func aRefreshBringsInOnlyTheNewEpisodes() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let animeID = try await follow(database, count: 12)
        let added = try await database.refreshOnlineRoad(
            ruleName: rule, workPageURL: work, workName: "药师少女的独语",
            roadName: "1", episodes: line("1", count: 14)
        )
        #expect(added == 2)
        let episodes = try await database.episodes(animeID: animeID)
        #expect(episodes.count == 14)
        let unchanged = try await database.refreshOnlineRoad(
            ruleName: rule, workPageURL: work, workName: "药师少女的独语",
            roadName: "1", episodes: line("1", count: 14)
        )
        #expect(unchanged == 0)
    }

    /// Two lines of one work are two feeds into one list, not two cards: the
    /// lines are different uploads of the same episodes.
    @Test func twoLinesOfOneWorkAreOneCard() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let first = try await follow(database, road: "1", count: 12)
        let second = try await follow(database, road: "2", count: 12)
        #expect(first == second)
        let grid = try await database.library()
        #expect(grid.count == 1)
        #expect(grid.first?.episodeCount == 12)
        let followed = try await database.followedRoadNames(ruleName: rule, workPageURL: work)
        #expect(followed == ["1", "2"])
    }

    @Test func unfollowingTakesItOutOfTheGridButKeepsWhatWasWatched() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let animeID = try await follow(database)
        let episodes = try await database.episodes(animeID: animeID)
        let fifth = try #require(episodes.first { $0.episode.numberText == "5" })
        try await database.save(progress: PlaybackProgress(
            episodeID: fifth.episode.id, position: 1_430, duration: 1_440, isWatched: true
        ))

        try await database.unfollowOnlineRoad(ruleName: rule, workPageURL: work, roadName: "1")
        let grid = try await database.library()
        #expect(grid.isEmpty)
        // A line dropped is not a season unwatched.
        let states = try await database.onlineWatchStates(
            ruleName: rule, pageURLs: [fifth.online?.pageURL ?? ""]
        )
        #expect(states.values.first?.isWatched == true)
    }

    @Test func aFollowedWorkCountsWhatHasBeenWatched() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let animeID = try await follow(database)
        let episodes = try await database.episodes(animeID: animeID)
        for episode in episodes.prefix(3) {
            try await database.save(progress: PlaybackProgress(
                episodeID: episode.episode.id, position: 1_430, duration: 1_440, isWatched: true
            ))
        }
        let card = try #require(try await database.library().first)
        #expect(card.watchedCount == 3)
        #expect(card.episodeCount == 12)
        #expect(!card.isFinished)
    }

    /// Half-watched online episodes belong on the continue shelf for the same
    /// reason local ones do.
    @Test func aHalfWatchedOnlineEpisodeIsOnTheContinueShelf() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let animeID = try await follow(database)
        let episodes = try await database.episodes(animeID: animeID)
        let second = try #require(episodes.first { $0.episode.numberText == "2" })
        try await database.save(progress: PlaybackProgress(
            episodeID: second.episode.id, position: 400, duration: 1_440, isWatched: false
        ))
        let shelf = try await database.continueWatching()
        #expect(shelf.count == 1)
        #expect(shelf.first?.episode.id == second.episode.id)
        #expect(shelf.first?.online?.pageURL == second.online?.pageURL)
    }

    /// A followed work is matched like any other — the pass reads `library()`
    /// — but it must never reach the concert pass, which is about discs.
    @Test func aFollowedWorkIsMatchedButIsNeverAConcert() async throws {
        let database = try LibraryDatabase(inMemory: true)
        _ = try await follow(database)
        let grid = try await database.library()
        #expect(grid.count == 1)
        let unmatched = try await database.worksWithNoMetadata()
        let notConcerts = try await database.worksThatAreNotConcerts()
        let discs = try await database.discWorks()
        #expect(unmatched.isEmpty)
        #expect(notConcerts.isEmpty)
        #expect(discs.isEmpty)
    }

    /// A site's copy and the files on disk are two cards, which is what was
    /// asked for — and the scan must not disturb the online one.
    @Test func aFollowedWorkAndTheLocalOneAreTwoCards() async throws {
        let database = try LibraryDatabase(inMemory: true)
        _ = try await follow(database)
        let root = LibraryRoot(displayName: "T7", lastKnownPath: "/Volumes/T7/video")
        try await database.save(root: root)
        try await database.importScan(LibraryScanResult(root: root, files: [
            ScannedMediaFile(
                relativePath: "药师少女的独语/EP01.mkv", fileSize: 1_400_000_000, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "药师少女的独语", episode: 1, confidence: 0.9)
            )
        ], skippedUnreadableCount: 0))

        let grid = try await database.library()
        #expect(grid.count == 2)
        #expect(grid.filter(\.isOnline).count == 1)
        #expect(grid.filter { !$0.isOnline }.count == 1)
        #expect(grid.first(where: \.isOnline)?.episodeCount == 12)
    }
}
