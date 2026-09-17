import CryptoKit
import Foundation
import Testing
@testable import AnimeGodCore

struct TorrentInfoHashTests {
    @Test func normalizesHexAndBase32ToTheSameHash() throws {
        // The same Ave Mujica batch as published by Nyaa (hex) and dmhy (base32).
        let hex = try #require(TorrentInfoHash("6E54509DE959FBE569C135B4F46B35789D53AAA6"))
        let base32 = try #require(TorrentInfoHash("NZKFBHPJLH56K2OBGW2PI2ZVPCOVHKVG"))
        #expect(hex == base32)
        #expect(hex.hex == "6e54509de959fbe569c135b4f46b35789d53aaa6")
        #expect(TorrentInfoHash("not-a-hash") == nil)
        #expect(TorrentInfoHash(String(repeating: "g", count: 40)) == nil)
    }

    @Test func parsesAndRebuildsMagnets() throws {
        let magnet = try #require(MagnetLink(
            "magnet:?xt=urn:btih:BWFZXCNYAICX2F7UTYL5F2JMRGF63EEA&dn=%5BSubsPlease%5D%20BanG%20Dream%21%20Ave%20Mujica%20-%2013%20%28480p%29.mkv&xl=437041125&tr=http%3A%2F%2Fnyaa.tracker.wf%3A7777%2Fannounce&tr=http%3A%2F%2Fnyaa.tracker.wf%3A7777%2Fannounce"
        ))
        #expect(magnet.displayName == "[SubsPlease] BanG Dream! Ave Mujica - 13 (480p).mkv")
        #expect(magnet.exactLength == 437041125)
        #expect(magnet.trackers == ["http://nyaa.tracker.wf:7777/announce"])

        let rebuilt = try #require(MagnetLink(magnet.uri))
        #expect(rebuilt == magnet)
        #expect(magnet.uri.hasPrefix("magnet:?xt=urn:btih:\(magnet.infoHash.hex)&dn="))
    }

    @Test func rejectsMagnetsWithConflictingHashes() {
        let conflicting = "magnet:?xt=urn:btih:6e54509de959fbe569c135b4f46b35789d53aaa6&xt=urn:btih:938762a9ee0278dfcbd269badd8c064b5e18a90d"
        #expect(MagnetLink(conflicting) == nil)
        #expect(MagnetLink("https://example.com/?xt=urn:btih:6e54509de959fbe569c135b4f46b35789d53aaa6") == nil)
        // The same hash twice (hex + base32) is not a conflict.
        #expect(MagnetLink("magnet:?xt=urn:btih:6e54509de959fbe569c135b4f46b35789d53aaa6&xt=urn:btih:NZKFBHPJLH56K2OBGW2PI2ZVPCOVHKVG") != nil)
    }
}

struct TorrentReleaseInfoTests {
    @Test func parsesChineseFansubBatch() {
        let info = TorrentReleaseInfo.parse(title: "[Prejudice-Studio] 颂乐人偶 BanG Dream! Ave Mujica [01-13][Bilibili WEB-DL HDR10 2160P HEVC 10bit AAC MP4][简日内嵌][Reseed]")
        #expect(info.group == "Prejudice-Studio")
        #expect(info.firstEpisode == 1)
        #expect(info.lastEpisode == 13)
        #expect(info.isBatch)
        #expect(info.episodeLabel == "01–13")
        #expect(info.resolution == "2160p")
        #expect(info.videoCodec == "HEVC")
        #expect(info.videoSource == "WEB")
        #expect(info.subtitleLanguages == [.simplifiedChinese, .japanese])
        #expect(info.subtitleStyle == .hardcoded)
    }

    @Test func parsesSingleEpisodesInCommonLayouts() {
        let subsPlease = TorrentReleaseInfo.parse(title: "[SubsPlease] BanG Dream! Ave Mujica - 13 (1080p) [E40B0C28].mkv")
        #expect(subsPlease.group == "SubsPlease")
        #expect(subsPlease.firstEpisode == 13)
        #expect(!subsPlease.isBatch)
        #expect(subsPlease.resolution == "1080p")

        let bracketed = TorrentReleaseInfo.parse(title: "【喵萌奶茶屋】★01月新番★[BanG Dream! Ave Mujica][05][1080p][简日双语][招募翻译]")
        #expect(bracketed.group == "喵萌奶茶屋")
        #expect(bracketed.firstEpisode == 5)
        #expect(bracketed.subtitleLanguages == [.simplifiedChinese, .japanese])

        let lolihouse = TorrentReleaseInfo.parse(title: "[LoliHouse] Ave Mujica - 07v2 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]")
        #expect(lolihouse.firstEpisode == 7)
        #expect(lolihouse.subtitleLanguages == [.simplifiedChinese, .traditionalChinese])
        #expect(lolihouse.subtitleStyle == .embeddedTrack)

        let chinese = TorrentReleaseInfo.parse(title: "[北宇治字幕组] 颂乐人偶 第12话 [WebRip][1080p][简体内嵌]")
        #expect(chinese.firstEpisode == 12)

        let scene = TorrentReleaseInfo.parse(title: "BanG Dream Ave Mujica S01E05 1080p WEB H264")
        #expect(scene.season == 1)
        #expect(scene.firstEpisode == 5)
        #expect(scene.videoCodec == "AVC")
    }

    @Test func technicalNumbersAreNotEpisodes() {
        let info = TorrentReleaseInfo.parse(title: "[JMAX] [2026.06.17] BanG Dream! Ave Mujica ベストアルバム「Ave Música」[FLAC 96kHz/24bit]")
        #expect(info.group == "JMAX")
        #expect(info.firstEpisode == nil)

        let movie = TorrentReleaseInfo.parse(title: "[DBD-Raws][剧场版 BanG Dream! It's MyGO!!!!!][前篇+后篇][1080P][BDRip][HEVC-10bit][简繁内封][FLAC][MKV]")
        #expect(movie.firstEpisode == nil)
        #expect(movie.videoSource == "BD")
        #expect(movie.subtitleStyle == .embeddedTrack)
    }

    @Test func titleCharactersDoNotReadAsSubtitleLanguages() {
        let info = TorrentReleaseInfo.parse(title: "[Nekomoe kissaten] 日常 - 03 [1080p]")
        #expect(info.subtitleLanguages.isEmpty)
    }

    @Test func coversRangesAndSingles() {
        let batch = TorrentReleaseInfo(firstEpisode: 1, lastEpisode: 13, isBatch: true)
        #expect(batch.covers(episode: 7))
        #expect(!batch.covers(episode: 14))
        #expect(TorrentReleaseInfo(firstEpisode: 5, lastEpisode: 5).covers(episode: 5))
        #expect(!TorrentReleaseInfo().covers(episode: 1))
    }
}

struct TorrentRelevanceTests {
    @Test func wholePhraseBeatsPartialCoverage() {
        let queries = ["BanG Dream! Ave Mujica"]
        let exact = TorrentRelevance.score(title: "[SubsPlease] BanG Dream! Ave Mujica - 13 (1080p)", queries: queries)
        let partial = TorrentRelevance.score(title: "[SubsPlease] BanG Dream! It's MyGO!!!!! - 13 (1080p)", queries: queries)
        let none = TorrentRelevance.score(title: "[SubsPlease] Frieren - 13 (1080p)", queries: queries)
        #expect(exact > partial)
        #expect(partial > none)
        #expect(none == 0)
    }

    @Test func punctuationAndCaseDoNotMatter() {
        let score = TorrentRelevance.score(title: "bang dream ave-mujica 05", queries: ["BanG Dream! Ave Mujica"])
        #expect(score >= 3)
    }

    @Test func coversChineseByBigrams() {
        let full = TorrentRelevance.score(title: "[喵萌奶茶屋] 葬送的芙莉莲 [05][1080p]", queries: ["葬送的芙莉莲"])
        let partial = TorrentRelevance.score(title: "[某字幕组] 葬送的魔法使 [05]", queries: ["葬送的芙莉莲"])
        #expect(full == 3)
        #expect(partial > 0)
        #expect(partial < 1)
    }

    @Test func usesTheBestAliasRatherThanTheSum() {
        let aliases = ["颂乐人偶", "BanG Dream! Ave Mujica"]
        let chineseOnly = TorrentRelevance.score(title: "[字幕组] 颂乐人偶 [05]", queries: aliases)
        let both = TorrentRelevance.score(title: "[字幕组] 颂乐人偶 BanG Dream! Ave Mujica [05]", queries: aliases)
        #expect(chineseOnly == both)
    }
}

struct TorrentResultMergerTests {
    private let hash = TorrentInfoHash("6e54509de959fbe569c135b4f46b35789d53aaa6")!
    private let title = "[Prejudice-Studio] 颂乐人偶 BanG Dream! Ave Mujica [01-13][Bilibili WEB-DL HDR10 2160P HEVC 10bit AAC MP4][简日内嵌][Reseed]"

    @Test func mergesTheSameReleaseAcrossSources() throws {
        var nyaa = TorrentObservation(
            source: .nyaa, title: title, infoHash: hash, trackers: ["http://nyaa.tracker.wf:7777/announce"],
            size: 10_093_000_000, seeders: 4, leechers: 0, publishedAt: Date(timeIntervalSince1970: 1_786_600_000),
            torrentURL: URL(string: "https://nyaa.si/download/2145552.torrent"), pageURL: URL(string: "https://nyaa.si/view/2145552")
        )
        nyaa.query = "Ave Mujica"
        var mikan = TorrentObservation(
            source: .mikan, title: title, infoHash: hash, size: 10_093_172_736,
            publishedAt: Date(timeIntervalSince1970: 1_786_600_100),
            torrentURL: URL(string: "https://mikanani.me/Download/x.torrent"), sizeIsExact: true
        )
        mikan.query = "颂乐人偶"
        var dmhy = TorrentObservation(
            source: .dmhy, title: title, infoHash: hash, trackers: ["https://tracker.anibt.net/announce"],
            publishedAt: Date(timeIntervalSince1970: 1_786_600_050), category: .batch
        )
        dmhy.query = "Ave Mujica"

        // Order of arrival must not change the outcome.
        let forward = TorrentResultMerger.merge([nyaa, mikan, dmhy], queries: ["Ave Mujica", "颂乐人偶"])
        let backward = TorrentResultMerger.merge([dmhy, mikan, nyaa], queries: ["Ave Mujica", "颂乐人偶"])
        #expect(forward == backward)

        let result = try #require(forward.first)
        #expect(forward.count == 1)
        #expect(result.sources == [.dmhy, .mikan, .nyaa])
        #expect(result.size == 10_093_172_736, "the exact byte count wins over a rounded one")
        #expect(result.seeders == 4)
        #expect(result.publishedAt == Date(timeIntervalSince1970: 1_786_600_000))
        #expect(result.category == .batch)
        #expect(result.matchedQueries == ["Ave Mujica", "颂乐人偶"])
        #expect(result.torrentURLs.count == 2)
        #expect(result.pageURLs[.nyaa]?.absoluteString == "https://nyaa.si/view/2145552")
        #expect(result.trackers.prefix(2) == ["http://nyaa.tracker.wf:7777/announce", "https://tracker.anibt.net/announce"] ||
                result.trackers.prefix(2) == ["https://tracker.anibt.net/announce", "http://nyaa.tracker.wf:7777/announce"])
        #expect(result.trackers.contains(TorrentTrackers.common[0]))
        #expect(result.release.isBatch)
        #expect(result.group == "Prejudice-Studio")
    }

    @Test func ranksRelevantReleasesAboveBusierUnrelatedOnes() {
        let relevant = TorrentObservation(
            source: .nyaa, title: "[SubsPlease] BanG Dream! Ave Mujica - 13 (1080p)",
            infoHash: TorrentInfoHash("938762a9ee0278dfcbd269badd8c064b5e18a90d")!, seeders: 3
        )
        let busy = TorrentObservation(
            source: .nyaa, title: "[SubsPlease] Frieren - 13 (1080p)",
            infoHash: TorrentInfoHash("6e54509de959fbe569c135b4f46b35789d53aaa6")!, seeders: 900
        )
        let merged = TorrentResultMerger.merge([busy, relevant], queries: ["Ave Mujica"])
        #expect(merged.map(\.title) == [relevant.title, busy.title])
        #expect(TorrentResultMerger.sort(merged, by: .seeders).first?.title == busy.title)
    }
}

struct TorrentFileTests {
    private static func bencode(_ text: String) -> Data { Data(text.utf8) }

    @Test func hashesTheRawInfoDictionary() throws {
        let info = "d6:lengthi1024e4:name8:ep01.mkv12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaae"
        let torrent = "d8:announce31:http://nyaa.tracker.wf/announce13:announce-listll31:http://nyaa.tracker.wf/announceel21:https://t.anibt.net/aee4:info\(info)e"
        let file = try TorrentFile(data: Self.bencode(torrent))
        let expected = Insecure.SHA1.hash(data: Data(info.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(file.infoHash.hex == expected)
        #expect(file.name == "ep01.mkv")
        #expect(file.totalSize == 1024)
        #expect(file.announce == ["http://nyaa.tracker.wf/announce", "https://t.anibt.net/a"])
    }

    @Test func readsMultiFileTorrents() throws {
        let info = "d5:filesld6:lengthi10e4:pathl2:SP6:01.mkveed6:lengthi20e4:pathl6:02.mkveee4:name5:Batch12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaae"
        let file = try TorrentFile(data: Self.bencode("d4:info\(info)e"))
        #expect(file.files.map(\.path) == [["SP", "01.mkv"], ["02.mkv"]])
        #expect(file.totalSize == 30)
    }

    @Test func rejectsHostileOrBrokenTorrents() {
        let traversal = "d4:infod5:filesld6:lengthi1e4:pathl2:..6:passwdeee4:name1:x12:piece lengthi1e6:pieces20:aaaaaaaaaaaaaaaaaaaaee"
        #expect(throws: TorrentFile.ParseError.unsafePath) { try TorrentFile(data: Self.bencode(traversal)) }
        #expect(throws: TorrentFile.ParseError.missingInfo) { try TorrentFile(data: Self.bencode("d3:fooi1ee")) }
        #expect(throws: TorrentFile.ParseError.self) { try TorrentFile(data: Self.bencode("d4:infod6:lengthi1e")) }
        #expect(throws: TorrentFile.ParseError.self) { try TorrentFile(data: Self.bencode("<html>error</html>")) }
        #expect(throws: TorrentFile.ParseError.self) { try TorrentFile(data: Self.bencode("d1:ai1e1:ai2ee")) }
        let deep = String(repeating: "l", count: 100) + String(repeating: "e", count: 100)
        #expect(throws: TorrentFile.ParseError.self) { try TorrentFile(data: Self.bencode(deep)) }
    }
}

struct TorrentResultFilterTests {
    private func result(_ title: String, hash: String, category: TorrentCategory = .episode, team: String? = nil, queries: [String] = ["BanG Dream! Ave Mujica"]) -> TorrentSearchResult {
        var observation = TorrentObservation(source: .nyaa, title: title, infoHash: TorrentInfoHash(hash)!, category: category, team: team)
        observation.query = queries[0]
        return TorrentResultMerger.merge([observation], queries: queries)[0]
    }

    private var sample: [TorrentSearchResult] {
        [
            result("[LoliHouse] BanG Dream! Ave Mujica - 05 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]", hash: "1111111111111111111111111111111111111111"),
            result("[Prejudice-Studio] BanG Dream! Ave Mujica [01-13][WEB-DL 2160P][简日内嵌]", hash: "2222222222222222222222222222222222222222", category: .batch),
            result("[SubsPlease] BanG Dream! Ave Mujica - 06 (720p) [ABCDEF12].mkv", hash: "3333333333333333333333333333333333333333"),
            result("Ave Mujica - The Die is Cast S01 1080p WEB", hash: "4444444444444444444444444444444444444444"),
            result("(C108) Some Doujin Anthology [English].zip", hash: "5555555555555555555555555555555555555555"),
            result("[JMAX] BanG Dream! Ave Mujica Best Album [FLAC]", hash: "6666666666666666666666666666666666666666", category: .music)
        ]
    }

    @Test func defaultFilterHidesMusicAndUnrelatedListings() {
        let visible = TorrentResultFilter().apply(sample).map(\.infoHash.hex.first)
        #expect(Set(visible) == ["1", "2", "3", "4"])
    }

    @Test func filtersByResolutionSubtitleGroupAndBatch() {
        var filter = TorrentResultFilter()
        filter.resolutions = ["1080p"]
        #expect(Set(filter.apply(sample).map(\.infoHash.hex.first)) == ["1", "4"])

        filter = TorrentResultFilter(subtitleLanguages: [.japanese])
        #expect(filter.apply(sample).map(\.infoHash.hex.first) == ["2"])

        filter = TorrentResultFilter(groups: ["SubsPlease"])
        #expect(filter.apply(sample).map(\.infoHash.hex.first) == ["3"])

        filter = TorrentResultFilter(batchMode: .batchesOnly)
        #expect(filter.apply(sample).map(\.infoHash.hex.first) == ["2"])

        filter = TorrentResultFilter(text: "subsplease 06")
        #expect(filter.apply(sample).map(\.infoHash.hex.first) == ["3"])
    }

    @Test func missingEpisodesOnlyKeepsBatchesWithGaps() {
        let filter = TorrentResultFilter(ownedEpisodes: Set((1...12).map(Double.init)), missingEpisodesOnly: true)
        // Episodes 5 and 6 are owned; the 01–13 batch still brings episode 13;
        // the release without an episode number can't be ruled out.
        #expect(Set(filter.apply(sample).map(\.infoHash.hex.first)) == ["2", "4"])
        #expect(!TorrentResultFilter.hasMissingEpisode(TorrentReleaseInfo(firstEpisode: 1, lastEpisode: 12), owned: Set((1...12).map(Double.init))))
    }

    @Test func facetsCountGroupsAndOrderResolutions() {
        let facets = TorrentResultFacets(results: sample)
        #expect(facets.resolutions == ["2160p", "1080p", "720p"])
        #expect(facets.groups.map(\.name).contains("LoliHouse"))
    }
}

struct TorrentDownloadRecordTests {
    private func makeDatabase() throws -> LibraryDatabase {
        try LibraryDatabase(inMemory: true)
    }

    @Test func storesUpdatesAndRemovesDownloads() async throws {
        let database = try makeDatabase()
        let record = TorrentDownloadRecord(
            infoHash: "6E54509DE959FBE569C135B4F46B35789D53AAA6",
            title: "Ave Mujica 01-13",
            magnet: "magnet:?xt=urn:btih:6e54509de959fbe569c135b4f46b35789d53aaa6",
            savePath: "/Users/someone/Downloads",
            animeTitle: "BanG Dream! Ave Mujica",
            totalBytes: 10_093_172_736,
            isSequential: true
        )
        try await database.saveTorrentDownload(record)

        var stored = try #require(try await database.torrentDownloads().first)
        #expect(stored.infoHash == "6e54509de959fbe569c135b4f46b35789d53aaa6", "hashes are normalised")
        #expect(stored.isSequential)
        #expect(stored.completedAt == nil)

        // Metadata arrives late; nil fields must not wipe what is known.
        let finished = Date(timeIntervalSince1970: 1_786_600_000)
        try await database.updateTorrentDownload(
            infoHash: stored.infoHash.uppercased(),
            title: nil,
            totalBytes: 10_000,
            completedAt: finished,
            isSequential: nil
        )
        stored = try #require(try await database.torrentDownloads().first)
        #expect(stored.title == "Ave Mujica 01-13")
        #expect(stored.totalBytes == 10_000)
        #expect(stored.completedAt == finished)
        #expect(stored.isSequential)

        // Completion is stamped once: a later update does not move it.
        try await database.updateTorrentDownload(infoHash: stored.infoHash, title: nil, totalBytes: nil, completedAt: .now, isSequential: nil)
        #expect(try await database.torrentDownloads().first?.completedAt == finished)

        try await database.removeTorrentDownload(infoHash: stored.infoHash)
        #expect(try await database.torrentDownloads().isEmpty)
    }

    @Test func savingTwiceKeepsTheAnimeBinding() async throws {
        let database = try makeDatabase()
        // The binding is a real foreign key, so the anime has to exist.
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        try await database.importScan(.init(root: root, files: [
            ScannedMediaFile(
                relativePath: "Ave Mujica/05.mkv",
                fileSize: 1,
                modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Ave Mujica", episode: 5, episodeText: "05", confidence: 0.9)
            )
        ], skippedUnreadableCount: 0))
        let animeID = try #require(try await database.library().first?.anime.id)
        try await database.saveTorrentDownload(TorrentDownloadRecord(
            infoHash: "938762a9ee0278dfcbd269badd8c064b5e18a90d",
            title: "Episode 5",
            magnet: "magnet:?xt=urn:btih:938762a9ee0278dfcbd269badd8c064b5e18a90d",
            savePath: "/tmp",
            animeID: animeID,
            animeTitle: "Ave Mujica",
            episodeLabel: "05"
        ))
        // A later save without the binding (a plain re-add) keeps it.
        try await database.saveTorrentDownload(TorrentDownloadRecord(
            infoHash: "938762a9ee0278dfcbd269badd8c064b5e18a90d",
            title: "Episode 5",
            magnet: "magnet:?xt=urn:btih:938762a9ee0278dfcbd269badd8c064b5e18a90d",
            savePath: "/tmp/other"
        ))
        let stored = try #require(try await database.torrentDownloads().first)
        #expect(stored.animeID == animeID)
        #expect(stored.animeTitle == "Ave Mujica")
        #expect(stored.episodeLabel == "05")
        #expect(stored.savePath == "/tmp/other")
    }
}

struct TorrentPlaybackReadinessTests {
    @Test func completedFilesAreAlwaysPlayable() {
        #expect(TorrentPlaybackReadiness.isPlayable(fileLength: 0, downloadedBytes: 0, isSequential: false, isComplete: true))
    }

    @Test func randomOrderDownloadsAreNotPlayableEarly() {
        // Without sequential order the bytes on disk are scattered, so a
        // half-downloaded file has no usable beginning.
        #expect(!TorrentPlaybackReadiness.isPlayable(
            fileLength: 1_000_000_000, downloadedBytes: 500_000_000, isSequential: false, isComplete: false
        ))
    }

    @Test func sequentialDownloadsNeedAHeadStart() {
        let length: Int64 = 1_000_000_000
        let required = TorrentPlaybackReadiness.requiredHeadBytes(fileLength: length)
        #expect(required == 32 * 1024 * 1024)
        #expect(!TorrentPlaybackReadiness.isPlayable(
            fileLength: length, downloadedBytes: required - 1, isSequential: true, isComplete: false
        ))
        #expect(TorrentPlaybackReadiness.isPlayable(
            fileLength: length, downloadedBytes: required, isSequential: true, isComplete: false
        ))
    }

    @Test func smallFilesUseAProportionalHeadStart() {
        // A 20 MiB extra should not wait for 32 MiB that will never arrive.
        let length: Int64 = 20 * 1024 * 1024
        #expect(TorrentPlaybackReadiness.requiredHeadBytes(fileLength: length) == length / 20)
        #expect(TorrentPlaybackReadiness.isPlayable(
            fileLength: length, downloadedBytes: length / 20, isSequential: true, isComplete: false
        ))
        #expect(TorrentPlaybackReadiness.requiredHeadBytes(fileLength: 0) == .max)
    }
}
