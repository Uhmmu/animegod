import Foundation
import Testing
@testable import AnimeGodCore

@Suite("Download folder names")
struct TorrentDownloadFolderTests {
    private let season = (1...12).map {
        "[LoliHouse] Yani Neko - \(String(format: "%02d", $0)) [WebRip 1080p HEVC-10bit AAC SRTx2].mkv"
    }

    @Test("The library's own title wins over anything read off a filename")
    func prefersAnimeTitle() {
        #expect(TorrentDownloadFolder.name(animeTitle: "ヤニねこ", releaseNames: season) == "ヤニねこ")
    }

    @Test("A search never bound to an anime is named from the releases themselves")
    func parsesTheSeriesTitle() {
        #expect(TorrentDownloadFolder.name(animeTitle: nil, releaseNames: season) == "Yani Neko")
    }

    @Test("One borrowed episode does not undo the folder")
    func majorityWins() {
        var mixed = season
        mixed[5] = "[Nekomoe kissaten] Chainsmoking Cat - 06 [1080p][JPSC].mkv"
        #expect(TorrentDownloadFolder.name(animeTitle: nil, releaseNames: mixed) == "Yani Neko")
    }

    @Test("Releases that agree on nothing leave every episode in its own folder")
    func noAgreement() {
        let unrelated = [
            "[LoliHouse] Yani Neko - 01 [WebRip 1080p].mkv",
            "[LoliHouse] Frieren - 01 [WebRip 1080p].mkv",
        ]
        #expect(TorrentDownloadFolder.name(animeTitle: nil, releaseNames: unrelated) == nil)
        #expect(TorrentDownloadFolder.name(animeTitle: nil, releaseNames: []) == nil)
        #expect(TorrentDownloadFolder.name(animeTitle: "  .  ", releaseNames: []) == nil)
    }

    @Test("An indexer title listing every alias is named after the one the files use")
    func multiAliasTitles() {
        let listed = (1...12).map {
            "[LoliHouse] 尼古喵喵 (邪竜解放版) / ヤニねこ / Yani Neko / Chainsmoker Cat - "
                + String(format: "%02d", $0)
                + " [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]"
        }
        // Not "Chainsmoker Cat": treating the whole string as a path drops
        // every alias but the last, which is how the folder got that name.
        #expect(TorrentDownloadFolder.name(animeTitle: nil, releaseNames: listed) == "Yani Neko")
        #expect(TorrentDownloadFolder.seriesTitle(of: listed[0]) == "Yani Neko")
    }

    @Test("A work with no Latin alias keeps the first one")
    func noLatinAlias() {
        #expect(TorrentDownloadFolder.seriesTitle(of: "[VCB-Studio] 少女终末旅行 / 少女終末旅行 - 01") == "少女终末旅行")
    }

    @Test("Path separators, control characters and stray dots never reach the file system")
    func sanitises() {
        #expect(TorrentDownloadFolder.sanitised("Fate/stay night") == "Fate stay night")
        #expect(TorrentDownloadFolder.sanitised("Steins;Gate: 0") == "Steins;Gate 0")
        #expect(TorrentDownloadFolder.sanitised("..hidden..") == "hidden")
        #expect(TorrentDownloadFolder.sanitised("a\tb\nc") == "a b c")
        #expect(TorrentDownloadFolder.sanitised("  spaced   out  ") == "spaced out")
    }

    @Test("A long title is cut to something a file system will take")
    func length() {
        let name = TorrentDownloadFolder.sanitised(String(repeating: "長", count: 200))
        #expect(name.utf8.count <= 160)
        #expect(!name.isEmpty)
    }

    @Test("A later season says so")
    func setNamesItsSeason() {
        func set(season: Int?) -> TorrentEpisodeSet {
            TorrentEpisodeSet(
                variant: TorrentReleaseVariant(group: "LoliHouse", season: season),
                entries: [],
                expectedEpisodes: [],
                missingEpisodes: [],
                ownedEpisodes: []
            )
        }
        #expect(set(season: 2).suggestedFolderName(animeTitle: "Yani Neko") == "Yani Neko S2")
        #expect(set(season: 1).suggestedFolderName(animeTitle: "Yani Neko") == "Yani Neko")
        #expect(set(season: nil).suggestedFolderName(animeTitle: nil) == nil)
    }
}
