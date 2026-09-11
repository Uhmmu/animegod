import Foundation
import Testing
@testable import AnimeGodCore

struct EpisodeCacheTests {
    /// Builds one anime with two episodes and returns their media files.
    private func makeLibrary() async throws -> (LibraryDatabase, LibraryRoot, [EpisodeMedia]) {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime SSD", lastKnownPath: "/Volumes/AnimeSSD/Anime")
        try await database.save(root: root)
        let scan = LibraryScanResult(root: root, files: [
            ScannedMediaFile(
                relativePath: "MyGO/01.mkv", fileSize: 1_400_000_000, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "MyGO", episode: 1, episodeText: "01", confidence: 0.95)
            ),
            ScannedMediaFile(
                relativePath: "MyGO/SP01.mkv", fileSize: 800_000_000, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "MyGO", episode: 1, episodeText: "01", episodeKind: .special, confidence: 0.95)
            )
        ], skippedUnreadableCount: 0)
        try await database.importScan(scan)
        let anime = try #require(await database.library().first?.anime)
        let episodes = try await database.episodes(animeID: anime.id)
        return (database, root, episodes)
    }

    @Test func roundTripsEntryAndQueriesJoinLabels() async throws {
        let (database, _, episodes) = try await makeLibrary()
        let regular = try #require(episodes.first { $0.episode.kind == .regular })
        try await database.saveCacheEntry(EpisodeCacheEntry(
            mediaFileID: regular.mediaFile.id,
            libraryRootID: regular.mediaFile.libraryRootID,
            relativePath: regular.mediaFile.relativePath,
            fileName: "01.mkv",
            fileSize: regular.mediaFile.fileSize,
            policy: .auto
        ))

        // Progress ticks only touch the byte counter.
        try await database.updateCacheProgress(mediaFileID: regular.mediaFile.id, bytesCopied: 500_000_000)
        var loaded = try #require(await database.cacheEntry(mediaFileID: regular.mediaFile.id))
        #expect(loaded.state == .copying)
        #expect(loaded.bytesCopied == 500_000_000)
        #expect(loaded.progress > 0.3 && loaded.progress < 0.4)

        try await database.markCacheComplete(mediaFileID: regular.mediaFile.id, fileSize: 1_400_000_000)
        loaded = try #require(await database.cacheEntry(mediaFileID: regular.mediaFile.id))
        #expect(loaded.state == .complete)
        #expect(loaded.progress == 1)
        #expect(loaded.completedAt != nil)

        // The list query joins library labels for the cache manager.
        let listed = try #require(await database.cacheEntries().first)
        #expect(listed.animeTitle == "MyGO")
        #expect(listed.episodeLabel == "Episode 01")
        #expect(listed.isEpisodeWatched == false)
        #expect(listed.fileName == "01.mkv")
    }

    @Test func specialEpisodeLabelCarriesItsNumber() async throws {
        let (database, _, episodes) = try await makeLibrary()
        let special = try #require(episodes.first { $0.episode.kind == .special })
        try await database.saveCacheEntry(EpisodeCacheEntry(
            mediaFileID: special.mediaFile.id,
            libraryRootID: special.mediaFile.libraryRootID,
            relativePath: special.mediaFile.relativePath,
            fileName: "SP01.mkv",
            fileSize: special.mediaFile.fileSize,
            policy: .manual
        ))
        let listed = try #require(await database.cacheEntries().first)
        #expect(listed.episodeLabel == "Special 01")
        #expect(listed.policy == .manual)
    }

    @Test func watchedEpisodesAreFlaggedInTheList() async throws {
        let (database, _, episodes) = try await makeLibrary()
        let regular = try #require(episodes.first { $0.episode.kind == .regular })
        try await database.saveCacheEntry(EpisodeCacheEntry(
            mediaFileID: regular.mediaFile.id,
            libraryRootID: regular.mediaFile.libraryRootID,
            relativePath: regular.mediaFile.relativePath,
            fileName: "01.mkv",
            fileSize: regular.mediaFile.fileSize,
            policy: .auto
        ))
        try await database.save(progress: PlaybackProgress(
            episodeID: regular.id, position: 1_380, duration: 1_400, isWatched: true
        ))
        let listed = try #require(await database.cacheEntries().first)
        #expect(listed.isEpisodeWatched == true)
    }

    @Test func removingTheSourceFileCascadesItsCacheRow() async throws {
        let (database, _, episodes) = try await makeLibrary()
        let regular = try #require(episodes.first { $0.episode.kind == .regular })
        try await database.saveCacheEntry(EpisodeCacheEntry(
            mediaFileID: regular.mediaFile.id,
            libraryRootID: regular.mediaFile.libraryRootID,
            relativePath: regular.mediaFile.relativePath,
            fileName: "01.mkv",
            fileSize: regular.mediaFile.fileSize,
            policy: .auto
        ))
        // An incremental scan that no longer sees the file removes its row,
        // and the cached copy must not outlive it.
        try await database.removeCacheEntry(mediaFileID: regular.mediaFile.id)
        #expect(try await database.cacheEntries().isEmpty)
    }

    @Test func removingALibraryRootCascadesAllItsCacheRows() async throws {
        let (database, root, episodes) = try await makeLibrary()
        for episode in episodes {
            try await database.saveCacheEntry(EpisodeCacheEntry(
                mediaFileID: episode.mediaFile.id,
                libraryRootID: episode.mediaFile.libraryRootID,
                relativePath: episode.mediaFile.relativePath,
                fileName: (episode.mediaFile.relativePath as NSString).lastPathComponent,
                fileSize: episode.mediaFile.fileSize,
                policy: .manual
            ))
        }
        #expect(try await database.cacheEntries().count == 2)
        try await database.removeLibraryRoot(id: root.id)
        #expect(try await database.cacheEntries().isEmpty)
    }

    @Test func policyUpgradeKeepsProgress() async throws {
        let (database, _, episodes) = try await makeLibrary()
        let regular = try #require(episodes.first { $0.episode.kind == .regular })
        try await database.saveCacheEntry(EpisodeCacheEntry(
            mediaFileID: regular.mediaFile.id,
            libraryRootID: regular.mediaFile.libraryRootID,
            relativePath: regular.mediaFile.relativePath,
            fileName: "01.mkv",
            fileSize: regular.mediaFile.fileSize,
            policy: .auto
        ))
        try await database.updateCacheProgress(mediaFileID: regular.mediaFile.id, bytesCopied: 700_000_000)
        // A user "keep this one" click upgrades an in-flight auto copy.
        try await database.setCachePolicy(mediaFileID: regular.mediaFile.id, policy: .manual)
        let loaded = try #require(await database.cacheEntry(mediaFileID: regular.mediaFile.id))
        #expect(loaded.policy == .manual)
        #expect(loaded.bytesCopied == 700_000_000)
        #expect(loaded.state == .copying)
    }

    @Test func resavingAnEntryRestartsItsProgress() async throws {
        let (database, _, episodes) = try await makeLibrary()
        let regular = try #require(episodes.first { $0.episode.kind == .regular })
        try await database.saveCacheEntry(EpisodeCacheEntry(
            mediaFileID: regular.mediaFile.id,
            libraryRootID: regular.mediaFile.libraryRootID,
            relativePath: regular.mediaFile.relativePath,
            fileName: "01.mkv",
            fileSize: regular.mediaFile.fileSize,
            policy: .auto
        ))
        try await database.updateCacheProgress(mediaFileID: regular.mediaFile.id, bytesCopied: 900_000_000)
        try await database.saveCacheEntry(EpisodeCacheEntry(
            mediaFileID: regular.mediaFile.id,
            libraryRootID: regular.mediaFile.libraryRootID,
            relativePath: regular.mediaFile.relativePath,
            fileName: "01.mkv",
            fileSize: regular.mediaFile.fileSize,
            policy: .auto
        ))
        let loaded = try #require(await database.cacheEntry(mediaFileID: regular.mediaFile.id))
        #expect(loaded.bytesCopied == 0)
        #expect(loaded.state == .copying)
    }
}
