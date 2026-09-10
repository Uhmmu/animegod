import Foundation
import Testing
@testable import AnimeGodCore

struct AnimeFilenameParserTests {
    private let parser = AnimeFilenameParser()

    @Test func parsesSubsPleaseEpisode() {
        let result = parser.parse(url: URL(fileURLWithPath: "/Anime/[SubsPlease] Anime Title - 07 (1080p) [ABC123].mkv"))
        #expect(result.title == "Anime Title")
        #expect(result.episode == 7)
        #expect(result.releaseGroup == "SubsPlease")
        #expect(result.resolution?.lowercased() == "1080p")
    }

    @Test func parsesSeasonEpisodePattern() {
        let result = parser.parse(url: URL(fileURLWithPath: "/Anime/Anime.Title.S02E04.1080p.mkv"))
        #expect(result.title == "Anime Title")
        #expect(result.season == 2)
        #expect(result.episode == 4)
    }

    @Test func parsesChineseSeasonAndEpisode() {
        let result = parser.parse(url: URL(fileURLWithPath: "/Anime/动画名称 第三季 第16集 简繁日内封 1080p HEVC.mkv"))
        #expect(result.title == "动画名称 简繁日内封")
        #expect(result.season == 3)
        #expect(result.episode == 16)
    }

    @Test func usesParentForNumericFilenames() {
        let root = URL(fileURLWithPath: "/Anime")
        let result = parser.parse(url: root.appending(path: "BanG Dream! It's MyGO!!!!!/01.mkv"), libraryRoot: root)
        #expect(result.title == "BanG Dream! It's MyGO!!!!!")
        #expect(result.episode == 1)
    }

    @Test func classifiesCreditlessOpening() {
        let result = parser.parse(url: URL(fileURLWithPath: "/Anime/Show/Show NCOP 01.mkv"))
        #expect(result.episodeKind == .opening)
    }

    @Test func classifiesCreditlessEndingAndTrailer() {
        let ending = parser.parse(url: URL(fileURLWithPath: "/Anime/Show/Show NCED.mkv"))
        #expect(ending.episodeKind == .ending)
        let trailer = parser.parse(url: URL(fileURLWithPath: "/Anime/Show/[Group] Show PV v2 [1080p].mkv"))
        #expect(trailer.episodeKind == .trailer)
    }

    @Test func classifiesSpecialEpisodes() {
        let special = parser.parse(url: URL(fileURLWithPath: "/Anime/Show/Show SP01 [1080p].mkv"))
        #expect(special.episodeKind == .special)
        let music = parser.parse(url: URL(fileURLWithPath: "/Anime/Show/[Group] Show MV01.mkv"))
        #expect(music.episodeKind == .music)
        let credits = parser.parse(url: URL(fileURLWithPath: "/Anime/Show/[Group] Show Music Video 02.mkv"))
        #expect(credits.episodeKind == .music)
        let menu = parser.parse(url: URL(fileURLWithPath: "/Anime/Show/[Group] Show [Menu01][2160p].mkv"))
        #expect(menu.episodeKind == .extra)
    }

    @Test(arguments: [
        ("[VCB-Studio] Anime Title [01][1080p][x265_flac].mkv", "Anime Title", 1.0),
        ("[SubsPlease] Anime Title - 07v2 (1080p) [ABC123].mkv", "Anime Title", 7.0),
        ("Anime.Title.S02E04.1080p.mkv", "Anime Title", 4.0),
        ("Anime Title - 13.5 [1080p].mkv", "Anime Title", 13.5),
        ("[Group] Movie Name (2026) [BDRip 1080p].mkv", "Movie Name", nil)
    ])
    func parsesCommonReleasePatterns(input: String, expectedTitle: String, expectedEpisode: Double?) {
        let result = parser.parse(url: URL(fileURLWithPath: "/Anime/Show/\(input)"))
        #expect(result.title == expectedTitle)
        #expect(result.episode == expectedEpisode)
    }

    @Test(arguments: [
        ("动画名称 第三季 第16集 简繁日内封 1080p HEVC.mkv", 3, 16.0),
        ("动画名称 第2季 第08话 [1080P].mp4", 2, 8.0),
        ("剧场版 动画名称 第六章.mkv", nil, 6.0)
    ])
    func parsesChineseReleasePatterns(input: String, expectedSeason: Int?, expectedEpisode: Double) {
        let result = parser.parse(url: URL(fileURLWithPath: "/Anime/Show/\(input)"))
        #expect(result.season == expectedSeason)
        #expect(result.episode == expectedEpisode)
    }

    @Test(arguments: [
        (
            "【更多蓝光电影访问 www.BBQDDQ.com】红辣椒[简繁中文字幕].Paprika.2006.RERiP.1080p.BuRay.x264.DTS-WiKi.mp4",
            "红辣椒 Paprika"
        ),
        (
            "【首发于高清影视之家 www.BBQDDQ.com】萤火虫之墓[简繁英字幕].Grave.of.the.Fireflies.1988.BluRay.1080p.DTS.HDMA2.0.x265.10bit-Xiaomi.mp4",
            "萤火虫之墓 Grave of the Fireflies"
        ),
        (
            "東京ゴッドファーザーズ.Tokyo.Godfathers.2003.REMASTERED.BluRay.1080p.HEVC.10bit.DTS.GOA.mkv",
            "東京ゴッドファーザーズ Tokyo Godfathers"
        )
    ])
    func stripsPirateAdsAndTechnicalTails(input: String, expected: String) {
        let result = parser.parse(url: URL(fileURLWithPath: "/Anime/\(input)"), libraryRoot: URL(fileURLWithPath: "/Anime"))
        #expect(result.title == expected)
    }

    @Test(arguments: [
        ("SONE-615", true),
        ("IPX-177", true),
        ("300MIUM-712", true),
        ("FC2-PPV-1234567", true),
        ("SSIS-001-C", true),
        ("K-ON!", false),
        ("5-toubun no Hanayome", false),
        ("Penguin Highway", false),
        ("東京ゴッドファーザーズ Tokyo Godfathers", false)
    ])
    func recognisesAVCatalogueCodes(input: String, expected: Bool) {
        #expect(AnimeFilenameParser.isAVCodeTitle(input) == expected)
    }

    @Test(arguments: [
        ("[DBD-Raws][4K_HDR][夏日大作战][美版][2160P][UHDBDRip][HEVC-10bit][简繁外挂][FLACx2][MKV]", "夏日大作战"),
        ("[Nekomoe kissaten][Penguin Highway]", "Penguin Highway"),
        ("[SweetSub&VCB-Studio] Josee to Tora to Sakana-tachi [Ma10p_1080p]", "Josee to Tora to Sakana-tachi"),
        ("[Snow-Raws] 劇場版メイドインアビス 深き魂の黎明", "劇場版メイドインアビス 深き魂の黎明")
    ])
    func parsesReleaseFolderTitle(input: String, expected: String) {
        #expect(parser.collectionTitle(from: input) == expected)
    }
}
