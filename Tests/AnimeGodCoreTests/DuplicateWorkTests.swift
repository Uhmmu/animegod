import Foundation
import Testing
@testable import AnimeGodCore

/// One work filed twice because two fansubs named its folder differently, and
/// the two halves of the answer: finding it, and folding it back together.
@Suite("Duplicate works")
struct DuplicateWorkDetectorTests {
    private func work(
        _ title: String,
        kind: AnimeKind = .tv,
        files: Int = 1,
        createdAt: Date = Date(timeIntervalSince1970: 0)
    ) -> DuplicateWorkDetector.Work {
        DuplicateWorkDetector.Work(id: UUID(), title: title, kind: kind, fileCount: files, createdAt: createdAt)
    }

    @Test("two rows the same subject landed on are one work")
    func pairsBySubject() {
        let one = work("FX Senshi Kurumi-chan JPSC", files: 1)
        let other = work("FX Senshi Kurumi-chan CHS_JP&CHT_JP", files: 2)
        let groups = DuplicateWorkDetector.groups(works: [one, other], links: [
            .init(animeID: one.id, provider: .bangumi, externalID: "622288"),
            .init(animeID: other.id, provider: .bangumi, externalID: "622288")
        ])
        #expect(groups.count == 1)
        // The row holding the most files is the one to keep.
        #expect(groups.first?.primary.id == other.id)
        #expect(groups.first?.duplicates.map(\.id) == [one.id])
        #expect(groups.first?.evidence == [.init(provider: .bangumi, externalID: "622288")])
    }

    @Test("names are never the evidence")
    func doesNotGuessFromTitles() {
        // The same show, spelled two ways, with nothing but the names to go
        // on. This is the case `TorrentWorkIdentity` already refuses, and
        // refusing it is the point: without a provider's answer there is no
        // way to tell a second team's spelling from a second season.
        let one = work("FX Senshi Kurumi-chan JPSC")
        let other = work("FX Senshi Kurumi-chan CHS_JP&CHT_JP")
        #expect(DuplicateWorkDetector.groups(works: [one, other], links: []).isEmpty)
    }

    @Test("a later season is its own work")
    func keepsSeasonsApart() {
        // Two seasons carry two subjects. The detector sees two links and no
        // shared id, which is exactly how a season that looks like a
        // duplicate stays out of this.
        let first = work("Yani Neko")
        let second = work("Yani Neko S2")
        let groups = DuplicateWorkDetector.groups(works: [first, second], links: [
            .init(animeID: first.id, provider: .bangumi, externalID: "1"),
            .init(animeID: second.id, provider: .bangumi, externalID: "2")
        ])
        #expect(groups.isEmpty)
    }

    @Test("three rows sharing one subject are asked about once")
    func groupsTransitively() {
        // The real library's shape: two scanned rows plus the parked row the
        // download created before any file existed. Two of them also share an
        // AniList id and a MyAnimeList id — reporting three overlapping pairs
        // would ask the same question three times.
        let parked = work("FX Senshi Kurumi-chan", files: 0, createdAt: Date(timeIntervalSince1970: 10))
        let jpsc = work("FX Senshi Kurumi-chan JPSC", files: 1, createdAt: Date(timeIntervalSince1970: 20))
        let uha = work("FX Senshi Kurumi-chan CHS_JP&CHT_JP", files: 2, createdAt: Date(timeIntervalSince1970: 30))
        let groups = DuplicateWorkDetector.groups(works: [parked, jpsc, uha], links: [
            .init(animeID: parked.id, provider: .bangumi, externalID: "622288"),
            .init(animeID: jpsc.id, provider: .bangumi, externalID: "622288"),
            .init(animeID: uha.id, provider: .bangumi, externalID: "622288"),
            .init(animeID: jpsc.id, provider: .anilist, externalID: "206401"),
            .init(animeID: uha.id, provider: .anilist, externalID: "206401"),
            .init(animeID: jpsc.id, provider: .myAnimeList, externalID: "63337"),
            .init(animeID: uha.id, provider: .myAnimeList, externalID: "63337")
        ])
        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.primary.id == uha.id)
        #expect(group.duplicates.map(\.id) == [jpsc.id, parked.id])
        #expect(group.evidence.count == 3)
        // Every provider that said so, so the viewer can check one.
        #expect(group.evidence.map(\.provider) == [.anilist, .bangumi, .myAnimeList])
    }

    @Test("a concert is never merged into the series it is a concert of")
    func refusesAcrossKinds() {
        let series = work("MyGO!!!!!", kind: .tv, files: 12)
        let live = work("MyGO!!!!! 6th LIVE", kind: .live, files: 2)
        let groups = DuplicateWorkDetector.groups(works: [series, live], links: [
            .init(animeID: series.id, provider: .bangumi, externalID: "400602"),
            .init(animeID: live.id, provider: .bangumi, externalID: "400602")
        ])
        #expect(groups.isEmpty)
    }

    @Test("a dismissed group stays the same group")
    func identityIsStableAcrossRuns() {
        let one = work("A"), other = work("B")
        let links: [DuplicateWorkDetector.Link] = [
            .init(animeID: one.id, provider: .bangumi, externalID: "1"),
            .init(animeID: other.id, provider: .bangumi, externalID: "1")
        ]
        let forwards = DuplicateWorkDetector.groups(works: [one, other], links: links)
        let backwards = DuplicateWorkDetector.groups(works: [other, one], links: links.reversed())
        #expect(forwards.first?.id == backwards.first?.id)
    }

    @Test("a tie is broken by age, not by chance")
    func tieGoesToTheOlderRow() {
        let older = work("A", files: 2, createdAt: Date(timeIntervalSince1970: 100))
        let newer = work("B", files: 2, createdAt: Date(timeIntervalSince1970: 200))
        let groups = DuplicateWorkDetector.groups(works: [newer, older], links: [
            .init(animeID: older.id, provider: .bangumi, externalID: "1"),
            .init(animeID: newer.id, provider: .bangumi, externalID: "1")
        ])
        #expect(groups.first?.primary.id == older.id)
    }

    @Test("a link about a work that is not in the library is ignored")
    func ignoresUnknownWorks() {
        let one = work("A")
        let groups = DuplicateWorkDetector.groups(works: [one], links: [
            .init(animeID: one.id, provider: .bangumi, externalID: "1"),
            .init(animeID: UUID(), provider: .bangumi, externalID: "1")
        ])
        #expect(groups.isEmpty)
    }
}

@Suite("Merging two works")
struct WorkMergeTests {
    /// Titles as the parser derives them from the folders, which is where the
    /// whole problem starts: one team's subtitle-language tag ends up in the
    /// title and the other's does not, so one show is two works.
    private struct Scanned {
        var path: String
        var title: String
        var episode: Int
    }

    private func library(_ files: [Scanned]) async throws -> (LibraryDatabase, [UUID]) {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "T7", lastKnownPath: "/Volumes/T7/video")
        try await database.save(root: root)
        try await database.importScan(LibraryScanResult(
            root: root,
            files: files.map { file in
                ScannedMediaFile(
                    relativePath: file.path,
                    fileSize: 1,
                    modifiedAt: Date(timeIntervalSince1970: 0),
                    parsed: ParsedAnimeFilename(
                        title: file.title,
                        episode: Double(file.episode),
                        episodeText: String(format: "%02d", file.episode),
                        confidence: 0.95
                    )
                )
            },
            skippedUnreadableCount: 0
        ))
        // Most files first: the row to keep, and the one the context menu
        // offers as the target.
        let ranked = try await database.library().sorted { $0.episodeCount > $1.episodeCount }
        return (database, ranked.map(\.anime.id))
    }

    /// The real case: one folder on the T7, episode 1 published by both teams
    /// and episode 2 by only one of them.
    private func kurumi() async throws -> (LibraryDatabase, UUID, UUID) {
        let (database, ids) = try await library([
            .init(path: "FX Senshi Kurumi-chan/[UHA-WINGS][FX Senshi Kurumi-chan][01][1080p HEVC][CHS_JP&CHT_JP].mkv",
                  title: "FX Senshi Kurumi-chan CHS_JP&CHT_JP", episode: 1),
            .init(path: "FX Senshi Kurumi-chan/[UHA-WINGS][FX Senshi Kurumi-chan][02][1080p HEVC][CHS_JP&CHT_JP].mkv",
                  title: "FX Senshi Kurumi-chan CHS_JP&CHT_JP", episode: 2),
            .init(path: "FX Senshi Kurumi-chan/[Studio GreenTea] FX Senshi Kurumi-chan [01][WebRip][JPSC].mp4",
                  title: "FX Senshi Kurumi-chan JPSC", episode: 1)
        ])
        return (database, ids[1], ids[0])
    }

    @Test("two teams' episode one becomes one episode with two files")
    func absorbsCollidingEpisodes() async throws {
        let (database, source, target) = try await kurumi()
        let summary = try await database.mergeWork(source, into: target)
        // The source held only episode 1, which the target already had.
        #expect(summary.episodesAbsorbed == 1)
        #expect(summary.episodesMoved == 0)
        #expect(summary.mediaFilesMoved == 1)

        let after = try await database.library()
        #expect(after.count == 1)
        #expect(after[0].anime.id == target)
        // Two episodes, three files: episode 1 now holds both teams' encodes,
        // which is the shape a DoVi and an SDR rip of one film already have.
        let episodes = try await database.episodes(animeID: target)
        #expect(episodes.count == 2)
        #expect(episodes.map(\.versions.count) == [2, 1])
        #expect(try await database.anime(id: source) == nil)
    }

    @Test("an episode the target does not have simply moves")
    func movesDistinctEpisodes() async throws {
        let (database, ids) = try await library([
            .init(path: "A/[GreenTea] Kurumi [01].mp4", title: "Kurumi JPSC", episode: 1),
            .init(path: "B/[UHA] Kurumi [02].mkv", title: "Kurumi CHS", episode: 2)
        ])
        let summary = try await database.mergeWork(ids[1], into: ids[0])
        #expect(summary.episodesMoved == 1)
        #expect(summary.episodesAbsorbed == 0)
        #expect(summary.mediaFilesMoved == 1)
        #expect(try await database.episodes(animeID: ids[0]).count == 2)
    }

    @Test("watched stays watched, and the further position wins")
    func keepsTheFurtherProgress() async throws {
        let (database, source, target) = try await kurumi()
        let kept = try await database.episodes(animeID: target).first { $0.episode.number == 1 }!
        let dissolved = try await database.episodes(animeID: source)[0]
        // The card about to be dissolved is the one that was watched.
        try await database.save(progress: PlaybackProgress(
            episodeID: kept.episode.id, position: 30, duration: 1440,
            updatedAt: Date(timeIntervalSince1970: 100), isWatched: false
        ))
        try await database.save(progress: PlaybackProgress(
            episodeID: dissolved.episode.id, position: 1430, duration: 1440,
            updatedAt: Date(timeIntervalSince1970: 200), isWatched: true
        ))

        try await database.mergeWork(source, into: target)
        let merged = try await database.episodes(animeID: target).first { $0.episode.number == 1 }
        #expect(merged?.progress?.isWatched == true)
        #expect(merged?.progress?.position == 1430)
    }

    @Test("a stale position never undoes what was watched")
    func neverLowersWatched() async throws {
        let (database, source, target) = try await kurumi()
        let kept = try await database.episodes(animeID: target).first { $0.episode.number == 1 }!
        let dissolved = try await database.episodes(animeID: source)[0]
        try await database.save(progress: PlaybackProgress(
            episodeID: kept.episode.id, position: 1430, duration: 1440,
            updatedAt: Date(timeIntervalSince1970: 200), isWatched: true
        ))
        // Opened once, a minute in, and never finished — and the older of the
        // two writes. Taking it whole would un-finish the episode.
        try await database.save(progress: PlaybackProgress(
            episodeID: dissolved.episode.id, position: 60, duration: 1440,
            updatedAt: Date(timeIntervalSince1970: 100), isWatched: false
        ))

        try await database.mergeWork(source, into: target)
        let merged = try await database.episodes(animeID: target).first { $0.episode.number == 1 }
        #expect(merged?.progress?.isWatched == true)
        #expect(merged?.progress?.position == 1430)
    }

    @Test("a watch event follows the episode it was absorbed into")
    func carriesTheDiary() async throws {
        let (database, source, target) = try await kurumi()
        let dissolved = try await database.episodes(animeID: source)[0].episode
        try await database.record(event: WatchEvent(
            animeID: source,
            episodeID: dissolved.id,
            animeTitle: "FX Senshi Kurumi-chan JPSC",
            episodeLabel: "Episode 1",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 1440),
            watchedDuration: 1440,
            completion: 1,
            completedEpisode: true
        ))
        let summary = try await database.mergeWork(source, into: target)
        #expect(summary.watchEventsMoved == 1)

        // The episode row it pointed at was dissolved. `watchEvent.episodeID`
        // is `ON DELETE SET NULL`, so deleting that row before repointing the
        // event would have left the diary entry without its episode rather
        // than moved it.
        let events = try await database.watchEvents(limit: 10)
        #expect(events.count == 1)
        #expect(events[0].animeID == target)
        let survivor = try await database.episodes(animeID: target).first { $0.episode.number == 1 }
        #expect(events[0].episodeID == survivor?.episode.id)
    }

    @Test("the provider links of both rows end up on the one that stays")
    func carriesProviderLinks() async throws {
        let (database, ids) = try await library([
            .init(path: "A/[GreenTea] Kurumi [01].mp4", title: "Kurumi JPSC", episode: 1),
            .init(path: "B/[UHA] Kurumi [02].mkv", title: "Kurumi CHS", episode: 2)
        ])
        try await database.save(
            metadata: .kurumi(animeID: ids[1], provider: .anilist, externalID: "206401"),
            communityPosts: [], matchConfidence: 1, isManualMatch: false
        )
        let summary = try await database.mergeWork(ids[1], into: ids[0])
        #expect(summary.providerLinksMoved == 1)
        let sources = try await database.metadataSources(animeID: ids[0])
        #expect(sources.map(\.provider) == [.anilist])
        #expect(sources[0].externalID == "206401")
    }

    @Test("a provider the surviving row already has is not duplicated")
    func doesNotDoubleUpOneProvider() async throws {
        let (database, source, target) = try await kurumi()
        for id in [source, target] {
            try await database.save(
                metadata: .kurumi(animeID: id, provider: .bangumi, externalID: "622288"),
                communityPosts: [], matchConfidence: 1, isManualMatch: true
            )
        }
        let summary = try await database.mergeWork(source, into: target)
        #expect(summary.providerLinksMoved == 0)
        #expect(try await database.metadataSources(animeID: target).count == 1)
    }

    @Test("the download and the subscription follow the card")
    func carriesDownloadsAndSubscriptions() async throws {
        let (database, source, target) = try await kurumi()
        try await database.saveTorrentDownload(TorrentDownloadRecord(
            infoHash: String(repeating: "a", count: 40),
            title: "[UHA-WINGS][FX Senshi Kurumi-chan][03]",
            magnet: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40),
            savePath: "/Volumes/T7/video",
            animeID: source,
            animeTitle: "FX Senshi Kurumi-chan JPSC"
        ))
        try await database.saveTorrentSubscription(TorrentSubscription(
            animeID: source, title: "FX Senshi Kurumi-chan", queries: ["FX Senshi Kurumi-chan"]
        ))

        let summary = try await database.mergeWork(source, into: target)
        #expect(summary.downloadsMoved == 1)
        #expect(summary.subscriptionsMoved == 1)
        // A rule bound to a card that was deleted is a season that goes on
        // downloading into nothing — the accident this whole thing started
        // from.
        #expect(try await database.torrentDownloads().first?.animeID == target)
        #expect(try await database.torrentSubscriptions().first?.animeID == target)
    }

    @Test("a cover somebody chose by hand survives the merge")
    func carriesTheChosenCover() async throws {
        let (database, source, target) = try await kurumi()
        _ = try await database.setPosterPath("Posters/kurumi.jpg", forAnimeID: source)
        let summary = try await database.mergeWork(source, into: target)
        #expect(summary.adoptedPoster)
        #expect(try await database.anime(id: target)?.posterPath == "Posters/kurumi.jpg")
    }

    @Test("a cover already on the surviving row is not overwritten")
    func keepsTheTargetsOwnCover() async throws {
        let (database, source, target) = try await kurumi()
        _ = try await database.setPosterPath("Posters/source.jpg", forAnimeID: source)
        _ = try await database.setPosterPath("Posters/target.jpg", forAnimeID: target)
        let summary = try await database.mergeWork(source, into: target)
        #expect(!summary.adoptedPoster)
        #expect(try await database.anime(id: target)?.posterPath == "Posters/target.jpg")
    }

    @Test("a kind nothing had decided is taken from the row that knew it")
    func carriesTheKind() async throws {
        let (database, source, target) = try await kurumi()
        try await database.save(
            metadata: .kurumi(animeID: source, provider: .anilist, externalID: "206401", kind: .ona),
            communityPosts: [], matchConfidence: 1, isManualMatch: false
        )
        #expect(try await database.anime(id: target)?.kind == .unknown)
        let summary = try await database.mergeWork(source, into: target)
        #expect(summary.adoptedKind)
        #expect(try await database.anime(id: target)?.kind == .ona)
    }

    @Test("the next scan does not undo the merge")
    func survivesARescan() async throws {
        // The case this is for: both titles are derived from files in *one*
        // folder — the teams' `[JPSC]` and `[CHS_JP&CHT_JP]` tags end up in
        // the title — so the parse that produced the row the merge dissolved
        // produces it again, unchanged, on the very next scan.
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "T7", lastKnownPath: "/Volumes/T7/video")
        try await database.save(root: root)
        let files = [
            Scanned(path: "FX Senshi Kurumi-chan/[UHA-WINGS][FX Senshi Kurumi-chan][01][CHS_JP&CHT_JP].mkv",
                    title: "FX Senshi Kurumi-chan CHS_JP&CHT_JP", episode: 1),
            Scanned(path: "FX Senshi Kurumi-chan/[UHA-WINGS][FX Senshi Kurumi-chan][02][CHS_JP&CHT_JP].mkv",
                    title: "FX Senshi Kurumi-chan CHS_JP&CHT_JP", episode: 2),
            Scanned(path: "FX Senshi Kurumi-chan/[Studio GreenTea] FX Senshi Kurumi-chan [01][JPSC].mp4",
                    title: "FX Senshi Kurumi-chan JPSC", episode: 1)
        ]
        func rescan() async throws {
            try await database.importScan(LibraryScanResult(
                root: root,
                files: files.map {
                    ScannedMediaFile(
                        relativePath: $0.path, fileSize: 1, modifiedAt: Date(timeIntervalSince1970: 0),
                        parsed: ParsedAnimeFilename(
                            title: $0.title, episode: Double($0.episode),
                            episodeText: String(format: "%02d", $0.episode), confidence: 0.95
                        )
                    )
                },
                skippedUnreadableCount: 0
            ))
        }
        try await rescan()
        let ranked = try await database.library().sorted { $0.episodeCount > $1.episodeCount }
        try await database.mergeWork(ranked[1].anime.id, into: ranked[0].anime.id)
        #expect(try await database.library().count == 1)

        try await rescan()
        let after = try await database.library()
        #expect(after.count == 1)
        #expect(after[0].anime.id == ranked[0].anime.id)
        #expect(try await database.episodes(animeID: after[0].anime.id).count == 2)
        // And the third team's episode still has its file: an alias that only
        // stopped the row being recreated would have orphaned it.
        #expect(try await database.episodes(animeID: after[0].anime.id).map(\.versions.count) == [2, 1])
    }

    @Test("merging a work into itself does nothing")
    func refusesToMergeAWorkIntoItself() async throws {
        let (database, ids) = try await library([
            .init(path: "A/[GreenTea] Kurumi [01].mp4", title: "Kurumi JPSC", episode: 1)
        ])
        let summary = try await database.mergeWork(ids[0], into: ids[0])
        #expect(summary == WorkMergeSummary())
        #expect(try await database.library().count == 1)
    }

    @Test("merging into a work that is not there refuses rather than deleting one")
    func refusesAMissingTarget() async throws {
        let (database, ids) = try await library([
            .init(path: "A/[GreenTea] Kurumi [01].mp4", title: "Kurumi JPSC", episode: 1)
        ])
        await #expect(throws: (any Error).self) {
            try await database.mergeWork(ids[0], into: UUID())
        }
        #expect(try await database.library().count == 1)
    }

    @Test("the providers' own answer reaches the store")
    func reportsGroupsFromTheStore() async throws {
        let (database, source, target) = try await kurumi()
        #expect(try await database.duplicateWorkGroups().isEmpty)
        for id in [source, target] {
            try await database.save(
                metadata: .kurumi(animeID: id, provider: .bangumi, externalID: "622288"),
                communityPosts: [], matchConfidence: 1, isManualMatch: true
            )
        }
        let groups = try await database.duplicateWorkGroups()
        #expect(groups.count == 1)
        #expect(Set(groups[0].works.map(\.id)) == Set([source, target]))
        #expect(groups[0].primary.id == target)
        #expect(groups[0].evidence == [.init(provider: .bangumi, externalID: "622288")])
    }

    @Test("the parked row a download created counts as a duplicate too")
    func findsTheParkedRow() async throws {
        let (database, source, target) = try await kurumi()
        // The row the download made before any file existed: no episodes, a
        // manual Bangumi link, and three downloads hanging off it.
        let parked = try await database.findOrCreateAnime(title: "FX Senshi Kurumi-chan")
        for id in [parked.id, source, target] {
            try await database.save(
                metadata: .kurumi(animeID: id, provider: .bangumi, externalID: "622288"),
                communityPosts: [], matchConfidence: 1, isManualMatch: true
            )
        }
        let groups = try await database.duplicateWorkGroups()
        #expect(groups.count == 1)
        #expect(groups[0].primary.id == target)
        // Fewest files last, so the row with nothing in it is not the one
        // offered as the keeper.
        #expect(groups[0].duplicates.last?.id == parked.id)
    }
}

extension AnimeMetadata {
    fileprivate static func kurumi(
        animeID: UUID,
        provider: MetadataProviderID,
        externalID: String,
        kind: AnimeKind? = nil
    ) -> AnimeMetadata {
        AnimeMetadata(
            animeID: animeID,
            provider: provider,
            externalID: externalID,
            title: "FX战士久留美",
            originalTitle: "FX戦士くるみちゃん",
            summary: "",
            posterURL: nil,
            airDate: nil,
            platform: nil,
            score: nil,
            rank: nil,
            ratingCount: nil,
            kind: kind
        )
    }
}
