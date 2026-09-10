import Foundation
import Testing
@testable import AnimeGodCore

struct LibraryDatabaseTests {
    @Test func importsScanAndKeepsRelativePaths() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Volumes/Anime/Anime")
        try await database.save(root: root)
        let scan = LibraryScanResult(root: root, files: [
            ScannedMediaFile(
                relativePath: "MyGO/01.mkv",
                fileSize: 100,
                modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "MyGO", episode: 1, episodeText: "01", confidence: 0.95)
            ),
            ScannedMediaFile(
                relativePath: "MyGO/02.mkv",
                fileSize: 120,
                modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "MyGO", episode: 2, episodeText: "02", confidence: 0.95)
            )
        ], skippedUnreadableCount: 0)

        try await database.importScan(scan)
        let library = try await database.library()
        #expect(library.count == 1)
        #expect(library.first?.episodeCount == 2)
        let episodes = try await database.episodes(animeID: library[0].id)
        #expect(episodes.map(\.mediaFile.relativePath) == ["MyGO/01.mkv", "MyGO/02.mkv"])
    }

    @Test func removesMissingFilesOnIncrementalScan() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let file = ScannedMediaFile(
            relativePath: "Show/01.mkv",
            fileSize: 1,
            modifiedAt: .now,
            parsed: ParsedAnimeFilename(title: "Show", episode: 1, episodeText: "01", confidence: 0.9)
        )
        try await database.importScan(.init(root: root, files: [file], skippedUnreadableCount: 0))
        try await database.importScan(.init(root: root, files: [], skippedUnreadableCount: 0))
        #expect(try await database.library().isEmpty)
    }

    @Test func keepsSameEpisodeNumberInDifferentSeasonsDistinct() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let seasons: [Int] = [1, 2]
        let files = seasons.map { season in
            ScannedMediaFile(
                relativePath: "Show/Season \(season)/01.mkv",
                fileSize: 1,
                modifiedAt: .now,
                parsed: ParsedAnimeFilename(
                    title: "Show",
                    season: season,
                    episode: 1,
                    episodeText: "01",
                    confidence: 0.9
                )
            )
        }
        try await database.importScan(.init(root: root, files: files, skippedUnreadableCount: 0))
        let anime = try #require(await database.library().first)
        #expect(try await database.episodes(animeID: anime.id).count == 2)
    }

    @Test func persistsMetadataAndCommunityCache() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let file = ScannedMediaFile(
            relativePath: "MyGO/01.mkv",
            fileSize: 1,
            modifiedAt: .now,
            parsed: ParsedAnimeFilename(title: "MyGO", episode: 1, episodeText: "01", confidence: 0.9)
        )
        try await database.importScan(.init(root: root, files: [file], skippedUnreadableCount: 0))
        let anime = try #require(await database.library().first?.anime)
        let metadata = AnimeMetadata(
            animeID: anime.id,
            provider: .bangumi,
            externalID: "428735",
            title: "BanG Dream! It's MyGO!!!!!",
            originalTitle: "BanG Dream! It's MyGO!!!!!",
            summary: "A band story.",
            posterURL: URL(string: "https://lain.bgm.tv/poster.jpg"),
            airDate: "2023-06-29",
            platform: "TV",
            score: 7.9,
            rank: 100,
            ratingCount: 30_000
        )
        let post = CommunityPost(
            provider: .bangumi,
            externalID: "428735",
            postID: "1",
            kind: .review,
            title: "Review",
            summary: "Summary",
            url: URL(string: "https://bgm.tv/blog/1")!,
            author: "Viewer",
            replyCount: 2,
            publishedAt: .now
        )

        try await database.save(metadata: metadata, communityPosts: [post], matchConfidence: 1, isManualMatch: true)

        #expect(try await database.metadata(animeID: anime.id)?.externalID == "428735")
        #expect(try await database.communityPosts(animeID: anime.id).map(\.postID) == ["1"])
        try await database.removeMetadataMatch(animeID: anime.id)
        #expect(try await database.metadata(animeID: anime.id) == nil)
        #expect(try await database.communityPosts(animeID: anime.id).isEmpty)
    }

    @Test func keepsMultipleMetadataSourcesAndCrossProviderIdentity() async throws {
        let context = try await makeSingleEpisodeLibrary()
        let bangumi = AnimeMetadata(
            animeID: context.anime.id, provider: .bangumi, externalID: "400",
            title: "Local Title", originalTitle: "Local Title", summary: "Bangumi synopsis",
            posterURL: nil, airDate: nil, platform: "TV", score: 8.2, rank: 50, ratingCount: 100
        )
        let anilist = AnimeMetadata(
            animeID: context.anime.id, provider: .anilist, externalID: "500",
            title: "Local Title", originalTitle: "Local Title", summary: "AniList synopsis",
            posterURL: nil, airDate: nil, platform: "TV", score: 8.5, rank: 40, ratingCount: 200,
            externalReferences: [.init(provider: .myAnimeList, externalID: "600")]
        )
        let post = CommunityPost(
            provider: .anilist, externalID: "500", postID: "review-1", kind: .review,
            title: "Review", summary: "Original", url: URL(string: "https://anilist.co/review/1")!,
            author: "User", replyCount: 3, publishedAt: .now, body: "Full original", originalLanguage: "en"
        )

        try await context.database.save(metadata: bangumi, communityPosts: [], matchConfidence: 1, isManualMatch: true)
        try await context.database.save(metadata: anilist, communityPosts: [post], matchConfidence: 1, isManualMatch: true)

        let sources = try await context.database.metadataSources(animeID: context.anime.id)
        #expect(Set(sources.map(\.provider)) == [.bangumi, .anilist])
        #expect(try await context.database.communityPosts(animeID: context.anime.id, provider: .bangumi).isEmpty)
        #expect(try await context.database.communityPosts(animeID: context.anime.id, provider: .anilist).map(\.postID) == ["review-1"])
        let references = try await context.database.externalReferences(animeID: context.anime.id)
        #expect(references.contains(.init(provider: .myAnimeList, externalID: "600")))
    }

    @Test func classifiesAnimeKindFromProviderMetadata() async throws {
        let context = try await makeSingleEpisodeLibrary()
        let metadata = AnimeMetadata(
            animeID: context.anime.id, provider: .anilist, externalID: "500",
            title: "Local Title", originalTitle: "Local Title", summary: "",
            posterURL: nil, airDate: nil, platform: "MOVIE", score: nil, rank: nil, ratingCount: nil,
            kind: .movie
        )

        try await context.database.save(metadata: metadata, communityPosts: [], matchConfidence: 1, isManualMatch: true)

        let library = try await context.database.library()
        #expect(library.first?.anime.kind == .movie)
        #expect(try await context.database.metadataSources(animeID: context.anime.id).first?.kind == .movie)
    }

    @Test func recordsMatchConfidenceAndManualFlagPerProvider() async throws {
        let context = try await makeSingleEpisodeLibrary()
        let auto = AnimeMetadata(
            animeID: context.anime.id, provider: .bangumi, externalID: "400",
            title: "Local Title", originalTitle: "Local Title", summary: "", posterURL: nil,
            airDate: nil, platform: nil, score: nil, rank: nil, ratingCount: nil
        )
        let manual = AnimeMetadata(
            animeID: context.anime.id, provider: .anilist, externalID: "500",
            title: "Local Title", originalTitle: "Local Title", summary: "", posterURL: nil,
            airDate: nil, platform: nil, score: nil, rank: nil, ratingCount: nil
        )
        try await context.database.save(metadata: auto, communityPosts: [], matchConfidence: 0.62, isManualMatch: false)
        try await context.database.save(metadata: manual, communityPosts: [], matchConfidence: 1, isManualMatch: true)

        let links = try await context.database.matchLinks(animeID: context.anime.id)
        #expect(links[.bangumi]?.confidence ?? 0 == 0.62)
        #expect(links[.bangumi]?.isManual == false)
        #expect(links[.anilist]?.isManual == true)
    }

    @Test func libraryEpisodeCountExcludesSpecialsAndMusic() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let files = [
            ScannedMediaFile(relativePath: "Show/01.mkv", fileSize: 1, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Show", episode: 1, episodeText: "01", confidence: 0.9)),
            ScannedMediaFile(relativePath: "Show/02.mkv", fileSize: 1, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Show", episode: 2, episodeText: "02", confidence: 0.9)),
            ScannedMediaFile(relativePath: "Show/SP01.mkv", fileSize: 1, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Show", episodeKind: .special, confidence: 0.8)),
            ScannedMediaFile(relativePath: "Show/MV01.mkv", fileSize: 1, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Show", episodeKind: .music, confidence: 0.8))
        ]
        try await database.importScan(.init(root: root, files: files, skippedUnreadableCount: 0))

        let anime = try #require(await database.library().first)
        #expect(anime.episodeCount == 2)
        #expect(anime.unwatchedCount == 2)
    }

    @Test func carriesBindingsAndHistoryAcrossTitleRegrouping() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let original = ScannedMediaFile(
            relativePath: "Paprika/01.mkv", fileSize: 1, modifiedAt: .now,
            parsed: ParsedAnimeFilename(title: "红辣椒 Paprika 2006 RERiP", episode: 1, episodeText: "01", confidence: 0.9)
        )
        try await database.importScan(.init(root: root, files: [original], skippedUnreadableCount: 0))
        let oldAnime = try #require(await database.library().first?.anime)
        let metadata = AnimeMetadata(
            animeID: oldAnime.id, provider: .bangumi, externalID: "1969",
            title: "パプリカ", originalTitle: "パプリカ", summary: "A dream detective story.",
            posterURL: URL(string: "https://lain.bgm.tv/pic/cover/l/paprika.jpg"),
            airDate: "2006-09-02", platform: "剧场版", score: 8.0, rank: 300, ratingCount: 5000
        )
        try await database.save(metadata: metadata, communityPosts: [], matchConfidence: 1, isManualMatch: true)
        var profile = AnimeProfile(animeID: oldAnime.id, status: .completed, score: 9.0)
        profile.firstWatchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await database.save(profile: profile)
        try await database.record(event: WatchEvent(
            animeID: oldAnime.id, episodeID: nil, animeTitle: "红辣椒 Paprika 2006 RERiP",
            episodeLabel: "Movie", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            watchedDuration: 5400, completion: 1, completedEpisode: true
        ))

        // The next scan derives a cleaner title for the same file.
        let regrouped = ScannedMediaFile(
            relativePath: "Paprika/01.mkv", fileSize: 1, modifiedAt: .now,
            parsed: ParsedAnimeFilename(title: "红辣椒 Paprika", episode: 1, episodeText: "01", confidence: 0.9)
        )
        try await database.importScan(.init(root: root, files: [regrouped], skippedUnreadableCount: 0))

        let library = try await database.library()
        #expect(library.count == 1)
        let newAnime = try #require(library.first?.anime)
        #expect(newAnime.title == "红辣椒 Paprika")
        // The manual Bangumi binding followed the file; no re-match needed.
        let references = try await database.externalReferences(animeID: newAnime.id)
        #expect(references == [.init(provider: .bangumi, externalID: "1969")])
        #expect(try await database.metadata(animeID: newAnime.id, provider: .bangumi)?.title == "パプリカ")
        // Personal entry and watch history travel with the identity.
        let migrated = try await database.profile(animeID: newAnime.id)
        #expect(migrated?.score == 9.0)
        #expect(migrated?.status == .completed)
        let events = try await database.allWatchEvents()
        #expect(events.count == 1 && events[0].animeID == newAnime.id)
    }

    @Test func carriesBindingsAndHistoryAcrossTitleRegroupingAmbiguouslyParked() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let files = [
            ScannedMediaFile(relativePath: "Show/01.mkv", fileSize: 1, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Show", episode: 1, episodeText: "01", confidence: 0.9)),
            ScannedMediaFile(relativePath: "Show/02.mkv", fileSize: 1, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Show", episode: 2, episodeText: "02", confidence: 0.9))
        ]
        try await database.importScan(.init(root: root, files: files, skippedUnreadableCount: 0))
        let oldAnime = try #require(await database.library().first?.anime)
        let metadata = AnimeMetadata(
            animeID: oldAnime.id, provider: .bangumi, externalID: "42",
            title: "Show", originalTitle: "Show", summary: "", posterURL: nil,
            airDate: nil, platform: nil, score: nil, rank: nil, ratingCount: nil
        )
        try await database.save(metadata: metadata, communityPosts: [], matchConfidence: 1, isManualMatch: true)

        // One work splitting into two successors is ambiguous: the binding
        // stays parked on the old row instead of guessing.
        let split = [
            ScannedMediaFile(relativePath: "Show/01.mkv", fileSize: 1, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Show 前篇", episode: 1, episodeText: "01", confidence: 0.9)),
            ScannedMediaFile(relativePath: "Show/02.mkv", fileSize: 1, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Show 後篇", episode: 2, episodeText: "02", confidence: 0.9))
        ]
        try await database.importScan(.init(root: root, files: split, skippedUnreadableCount: 0))

        let library = try await database.library()
        #expect(Set(library.map(\.anime.title)) == ["Show 前篇", "Show 後篇"])
        for item in library {
            #expect(try await database.externalReferences(animeID: item.anime.id).isEmpty)
        }
        // The parked binding is not destroyed; it just waits.
        #expect(try await database.externalReferences(animeID: oldAnime.id).count == 1)
    }

    @Test func reconcilesBindingsAfterAFolderRenameOnDisk() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let original = ScannedMediaFile(
            relativePath: "Paprika 2006 RERiP/movie.mkv", fileSize: 1, modifiedAt: .now,
            parsed: ParsedAnimeFilename(title: "红辣椒 Paprika 2006 RERiP", confidence: 0.7)
        )
        try await database.importScan(.init(root: root, files: [original], skippedUnreadableCount: 0))
        let oldAnime = try #require(await database.library().first?.anime)
        let metadata = AnimeMetadata(
            animeID: oldAnime.id, provider: .bangumi, externalID: "1969",
            title: "パプリカ", originalTitle: "パプリカ", summary: "", posterURL: nil,
            airDate: nil, platform: nil, score: 8.0, rank: nil, ratingCount: nil
        )
        try await database.save(metadata: metadata, communityPosts: [], matchConfidence: 1, isManualMatch: true)

        // The folder was renamed on disk: the relative path changed, so no
        // regrouping was ever observed between the two anime rows.
        let renamed = ScannedMediaFile(
            relativePath: "Paprika/movie.mkv", fileSize: 1, modifiedAt: .now,
            parsed: ParsedAnimeFilename(title: "红辣椒 Paprika", confidence: 0.9)
        )
        try await database.importScan(.init(root: root, files: [renamed], skippedUnreadableCount: 0))

        let library = try await database.library()
        #expect(library.count == 1)
        let newAnime = try #require(library.first?.anime)
        #expect(newAnime.title == "红辣椒 Paprika")
        #expect(try await database.externalReferences(animeID: newAnime.id)
                == [.init(provider: .bangumi, externalID: "1969")])
    }

    @Test func mergesAlternativeEncodesOfTheSameMovie() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let files = [
            ScannedMediaFile(relativePath: "VE/movie DoVi.mkv", fileSize: 20_000_000_000, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Gekijouban Violet Evergarden", confidence: 0.9)),
            ScannedMediaFile(relativePath: "VE/movie SDR.mkv", fileSize: 12_000_000_000, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Gekijouban Violet Evergarden", confidence: 0.9))
        ]
        try await database.importScan(.init(root: root, files: files, skippedUnreadableCount: 0))

        let anime = try #require(await database.library().first)
        let episodes = try await database.episodes(animeID: anime.id)
        // Two encodes, one episode entry; SDR leads as the playable default.
        #expect(episodes.count == 1)
        #expect(episodes[0].versions.count == 2)
        #expect(episodes[0].mediaFile.relativePath == "VE/movie SDR.mkv")
        #expect(episodes[0].versions.map(\.relativePath).first == "VE/movie SDR.mkv")
    }

    @Test func preservesProgressWhenARescanRegroupsAFile() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let original = ScannedMediaFile(
            relativePath: "Show/PV/01.mkv",
            fileSize: 1,
            modifiedAt: .now,
            parsed: ParsedAnimeFilename(title: "Show PV", episode: 1, episodeText: "01", confidence: 0.8)
        )
        try await database.importScan(.init(root: root, files: [original], skippedUnreadableCount: 0))
        let oldAnime = try #require(await database.library().first?.anime)
        let oldEpisode = try #require(await database.episodes(animeID: oldAnime.id).first)
        try await database.save(progress: .init(episodeID: oldEpisode.id, position: 60, duration: 120))

        let regrouped = ScannedMediaFile(
            relativePath: original.relativePath,
            fileSize: 1,
            modifiedAt: .now,
            parsed: ParsedAnimeFilename(title: "Show", episode: 1, episodeText: "01", confidence: 0.9)
        )
        try await database.importScan(.init(root: root, files: [regrouped], skippedUnreadableCount: 0))

        let newAnime = try #require(await database.library().first?.anime)
        let newEpisode = try #require(await database.episodes(animeID: newAnime.id).first)
        #expect(newAnime.title == "Show")
        #expect(newEpisode.progress?.position == 60)
    }

    @Test func persistsPersonalProfileIndependentlyFromExternalRatings() async throws {
        let context = try await makeSingleEpisodeLibrary()
        let profile = AnimeProfile(
            animeID: context.anime.id,
            status: .watching,
            score: 9.5,
            notes: "Watch the symbolism in episode 7.",
            review: "A personal review.",
            tags: ["Drama", "Band", "Drama"],
            isFavorite: true,
            ranking: 3,
            rewatchCount: 1
        )

        try await context.database.save(profile: profile)

        let stored = try #require(await context.database.profile(animeID: context.anime.id))
        #expect(stored.score == 9.5)
        #expect(stored.ranking == 3)
        #expect(stored.tags == ["Band", "Drama"])
        #expect(stored.isFavorite)
        #expect(stored.review == "A personal review.")
    }

    @Test func recordsMeaningfulWatchSessionsAndBuildsDiarySummary() async throws {
        let context = try await makeSingleEpisodeLibrary()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        try await context.database.save(progress: .init(
            episodeID: context.episode.id,
            position: 570,
            duration: 600,
            isWatched: true
        ))
        try await context.database.record(event: WatchEvent(
            animeID: context.anime.id,
            episodeID: context.episode.id,
            animeTitle: "MyGO",
            episodeLabel: "Episode 01",
            startedAt: started,
            endedAt: started.addingTimeInterval(540),
            watchedDuration: 530,
            completion: 0.95,
            completedEpisode: true
        ))
        try await context.database.record(event: WatchEvent(
            animeID: context.anime.id,
            episodeID: context.episode.id,
            animeTitle: "MyGO",
            episodeLabel: "Episode 01",
            startedAt: started,
            watchedDuration: 5,
            completion: 0.01,
            completedEpisode: false
        ))

        let events = try await context.database.watchEvents()
        let summary = try await context.database.diarySummary()
        let profile = try #require(await context.database.profile(animeID: context.anime.id))
        #expect(events.count == 1)
        #expect(summary.totalWatchTime == 530)
        #expect(summary.sessionCount == 1)
        #expect(summary.completedEpisodeCount == 1)
        #expect(summary.animeCount == 1)
        #expect(profile.status == .completed)
        #expect(profile.firstWatchedAt == started)
        #expect(profile.completedAt == started.addingTimeInterval(540))
    }

    @Test func keepsDiaryAndPersonalEntryWhenMediaDisappears() async throws {
        let context = try await makeSingleEpisodeLibrary()
        try await context.database.save(profile: .init(animeID: context.anime.id, status: .paused, notes: "Keep me"))
        try await context.database.record(event: WatchEvent(
            animeID: context.anime.id,
            episodeID: context.episode.id,
            animeTitle: "MyGO",
            episodeLabel: "Episode 01",
            startedAt: .now.addingTimeInterval(-120),
            watchedDuration: 100,
            completion: 0.2,
            completedEpisode: false
        ))
        try await context.database.importScan(.init(root: context.root, files: [], skippedUnreadableCount: 0))

        #expect(try await context.database.library().isEmpty)
        #expect(try await context.database.watchEvents().count == 1)
        #expect(try await context.database.profile(animeID: context.anime.id)?.notes == "Keep me")
        #expect(try await context.database.watchEvents().first?.episodeID == nil)
    }

    @Test func insertingAndMovingRanksKeepsAnUnambiguousOrder() async throws {
        let database = try LibraryDatabase(inMemory: true)
        // Profiles require real internal anime identities.
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let files = ["Alpha", "Beta", "Gamma"].enumerated().map { index, title in
            ScannedMediaFile(
                relativePath: "\(title)/01.mkv",
                fileSize: Int64(index + 1),
                modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: title, episode: 1, episodeText: "01", confidence: 1)
            )
        }
        try await database.importScan(.init(root: root, files: files, skippedUnreadableCount: 0))
        let anime = try await database.library().map(\.anime)
        #expect(anime.count == 3)
        try await database.save(profile: .init(animeID: anime[0].id, ranking: 1))
        try await database.save(profile: .init(animeID: anime[1].id, ranking: 2))
        try await database.save(profile: .init(animeID: anime[2].id, ranking: 1))

        var ranks = Dictionary(uniqueKeysWithValues: try await database.profiles().map { ($0.animeID, $0.ranking) })
        #expect(ranks[anime[2].id] == 1)
        #expect(ranks[anime[0].id] == 2)
        #expect(ranks[anime[1].id] == 3)

        var moved = try #require(await database.profile(animeID: anime[0].id))
        moved.ranking = 3
        try await database.save(profile: moved)
        ranks = Dictionary(uniqueKeysWithValues: try await database.profiles().map { ($0.animeID, $0.ranking) })
        #expect(ranks[anime[2].id] == 1)
        #expect(ranks[anime[1].id] == 2)
        #expect(ranks[anime[0].id] == 3)
    }

    private func makeSingleEpisodeLibrary() async throws -> (
        database: LibraryDatabase,
        root: LibraryRoot,
        anime: Anime,
        episode: EpisodeMedia
    ) {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let file = ScannedMediaFile(
            relativePath: "MyGO/01.mkv",
            fileSize: 1,
            modifiedAt: .now,
            parsed: ParsedAnimeFilename(title: "MyGO", episode: 1, episodeText: "01", confidence: 0.9)
        )
        try await database.importScan(.init(root: root, files: [file], skippedUnreadableCount: 0))
        let anime = try #require(await database.library().first?.anime)
        let episode = try #require(await database.episodes(animeID: anime.id).first)
        return (database, root, anime, episode)
    }
}
