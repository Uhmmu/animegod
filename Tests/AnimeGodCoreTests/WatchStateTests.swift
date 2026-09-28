import Foundation
import Testing
@testable import AnimeGodCore

struct WatchedWorkKindTests {
    @Test func believesTheProviderOverTheFileCount() {
        // A season one episode into its run has one main episode on disk. It
        // is still a series, or its premiere would be marked watched ten
        // minutes from the end.
        #expect(WatchedWorkKind.classify(reportedKind: .tv, mainEpisodeCount: 1) == .series)
        #expect(WatchedWorkKind.classify(reportedKind: .movie, mainEpisodeCount: 12) == .film)
        #expect(WatchedWorkKind.classify(reportedKind: .ova, mainEpisodeCount: 1) == .series)
    }

    @Test func fallsBackToTheMainEpisodeCount() {
        for unmatched: AnimeKind? in [nil, .unknown] {
            #expect(WatchedWorkKind.classify(reportedKind: unmatched, mainEpisodeCount: 1) == .film)
            #expect(WatchedWorkKind.classify(reportedKind: unmatched, mainEpisodeCount: 12) == .series)
            // Nothing scanned yet says nothing about what this is.
            #expect(WatchedWorkKind.classify(reportedKind: unmatched, mainEpisodeCount: 0) == .series)
            #expect(WatchedWorkKind.classify(reportedKind: unmatched, mainEpisodeCount: nil) == .series)
        }
    }

    @Test func aSeriesIsWatchedFiveMinutesFromTheEnd() {
        let duration: Double = 24 * 60
        #expect(!WatchedWorkKind.isWatched(position: duration - 5 * 60 - 1, duration: duration, kind: .series))
        #expect(WatchedWorkKind.isWatched(position: duration - 5 * 60, duration: duration, kind: .series))
        #expect(WatchedWorkKind.isWatched(position: duration, duration: duration, kind: .series))
    }

    @Test func aFilmIsWatchedTenMinutesFromTheEnd() {
        let duration: Double = 100 * 60
        #expect(!WatchedWorkKind.isWatched(position: duration - 10 * 60 - 1, duration: duration, kind: .film))
        #expect(WatchedWorkKind.isWatched(position: duration - 10 * 60, duration: duration, kind: .film))
        // A series' tail is the shorter one, so the very same position has
        // five more minutes to run before it counts as seen.
        #expect(!WatchedWorkKind.isWatched(position: duration - 10 * 60, duration: duration, kind: .series))
        #expect(WatchedWorkKind.isWatched(position: duration - 5 * 60, duration: duration, kind: .series))
    }

    @Test func theTailNeverSwallowsShortContent() {
        // A four-minute creditless opening: five minutes from its end is
        // before it started, so the cap has to hold it back.
        let duration: Double = 4 * 60
        #expect(!WatchedWorkKind.isWatched(position: 1, duration: duration, kind: .series))
        #expect(!WatchedWorkKind.isWatched(position: duration / 2, duration: duration, kind: .series))
        #expect(WatchedWorkKind.isWatched(position: duration * 0.8, duration: duration, kind: .series))
    }

    @Test func nothingIsWatchedWithoutAKnownRuntime() {
        #expect(!WatchedWorkKind.isWatched(position: 600, duration: 0, kind: .film))
        #expect(!WatchedWorkKind.isWatched(position: 0, duration: 1_440, kind: .series))
    }
}

struct WatchStatePersistenceTests {
    /// Two episodes of one work, so progress has somewhere to go.
    private func library() async throws -> (LibraryDatabase, [EpisodeMedia]) {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let files = (1...2).map { number in
            ScannedMediaFile(
                relativePath: "Show/0\(number).mkv",
                fileSize: 1,
                modifiedAt: .now,
                parsed: ParsedAnimeFilename(
                    title: "Show",
                    episode: Double(number),
                    episodeText: "0\(number)",
                    confidence: 0.9
                )
            )
        }
        try await database.importScan(.init(root: root, files: files, skippedUnreadableCount: 0))
        let anime = try #require(await database.library().first)
        return (database, try await database.episodes(animeID: anime.id))
    }

    @Test func scrubbingAFinishedEpisodeCannotUnfinishIt() async throws {
        let (database, episodes) = try await library()
        let episode = episodes[0]
        try await database.save(progress: .init(
            episodeID: episode.id, position: 1_400, duration: 1_440, isWatched: true
        ))

        // Coming back to it and dragging the scrubber to the start: the plain
        // overwrite this replaced wrote isWatched back to false, and the
        // player autosaves every ten seconds, so one visit undid the season.
        try await database.save(progress: .init(
            episodeID: episode.id, position: 30, duration: 1_440, isWatched: false
        ))

        let reloaded = try #require(await database.episodes(animeID: episode.episode.animeID).first)
        #expect(reloaded.progress?.isWatched == true)
        #expect(reloaded.progress?.position == 30)
    }

    @Test func theViewerCanTakeTheMarkBack() async throws {
        let (database, episodes) = try await library()
        let episode = episodes[0]
        try await database.save(progress: .init(
            episodeID: episode.id, position: 1_400, duration: 1_440, isWatched: true
        ))

        try await database.setWatched(episodeID: episode.id, isWatched: false)
        var reloaded = try #require(await database.episodes(animeID: episode.episode.animeID).first)
        #expect(reloaded.progress?.isWatched == false)
        // Only wanting the ED must not also throw away where you were.
        #expect(reloaded.progress?.position == 1_400)

        // And an override is what lets the player write it back down while the
        // credits are still inside the tail.
        try await database.save(
            progress: .init(episodeID: episode.id, position: 1_430, duration: 1_440, isWatched: false),
            overridesWatched: true
        )
        reloaded = try #require(await database.episodes(animeID: episode.episode.animeID).first)
        #expect(reloaded.progress?.isWatched == false)
    }

    @Test func marksAnEpisodeThatHasNeverBeenPlayed() async throws {
        let (database, episodes) = try await library()
        try await database.setWatched(episodeID: episodes[1].id, isWatched: true)
        let reloaded = try #require(
            await database.episodes(animeID: episodes[1].episode.animeID).last
        )
        #expect(reloaded.progress?.isWatched == true)
    }
}
