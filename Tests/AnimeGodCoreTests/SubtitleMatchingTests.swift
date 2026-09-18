import Compression
import Foundation
import Testing
@testable import AnimeGodCore

struct SubtitleIdentityTests {
    @Test func parsesAnimeReleaseFileName() {
        let identity = SubtitleVideoIdentity.fromFileName("[ANi] Sousou no Frieren - 14 [1080P][Baha][WEB-DL][AAC AVC][CHT].mkv")
        #expect(identity.titles == ["Sousou no Frieren"])
        #expect(identity.episode == 14)
        #expect(identity.releaseGroup == "ANi")
        #expect(identity.source == "WEB")
        #expect(identity.resolution == "1080p")
        #expect(identity.isMovie == false)
        #expect(identity.episodeLabel == "S01E14")
    }

    @Test func parsesBluRayScene() {
        let identity = SubtitleVideoIdentity.fromFileName(
            "[VCB-Studio] Sousou no Frieren [14][Ma10p_1080p][x265_flac].mkv",
            titles: ["葬送的芙莉莲"]
        )
        #expect(identity.releaseGroup == "VCB-Studio")
        #expect(identity.episode == 14)
        #expect(identity.titles.first == "葬送的芙莉莲")
    }

    @Test func keepsTitleBracketsThatOnlyLookLikeTags() {
        let parsed = SubtitleReleaseParsing.parseFileName("[桜都字幕组][日常][01][1080P][简繁内封].mkv")
        #expect(parsed.title.contains("日常"))
        #expect(parsed.episode == 1)
    }

    @Test func mapsTrackLanguages() {
        #expect(SubtitleLanguage.fromTrack(language: "chi", title: "简体中文") == .simplifiedChinese)
        #expect(SubtitleLanguage.fromTrack(language: "chi", title: "繁體中文") == .traditionalChinese)
        #expect(SubtitleLanguage.fromTrack(language: nil, title: "CHT") == .traditionalChinese)
        #expect(SubtitleLanguage.fromTrack(language: "zh-Hans", title: nil) == .simplifiedChinese)
        #expect(SubtitleLanguage.fromTrack(language: "zho", title: "Subtitle 1") == .chinese)
        #expect(SubtitleLanguage.fromTrack(language: "jpn", title: nil) == .japanese)
        #expect(SubtitleLanguage.fromTrack(language: "eng", title: "Full Subtitles") == .english)
        #expect(SubtitleLanguage.fromTrack(language: nil, title: "Signs & Songs") == nil)
    }

    @Test func readsSubtitleFileNameTags() {
        #expect(SubtitleReleaseParsing.language(inFileName: "[LoliHouse] Frieren - 14 [WebRip 1080p].chs.ass") == .simplifiedChinese)
        #expect(SubtitleReleaseParsing.language(inFileName: "Frieren - 14.zh-Hant.srt") == .traditionalChinese)
        #expect(SubtitleReleaseParsing.language(inFileName: "[Nekomoe kissaten][Frieren][14][JPTC].ass") == .traditionalChinese)
        #expect(SubtitleReleaseParsing.episode(inFileName: "[LoliHouse] Sousou no Frieren - 14 [WebRip 1080p HEVC-10bit AAC].sc.ass") == 14)
        #expect(SubtitleReleaseParsing.episode(inFileName: "Sousou.no.Frieren.S01E15.1080p.WEB-DL.tc.srt") == 15)
    }
}

struct SubtitleScorerTests {
    let video = SubtitleVideoIdentity.fromFileName(
        "[LoliHouse] Sousou no Frieren - 14 [WebRip 1080p HEVC-10bit AAC SRTx2].mkv",
        titles: ["葬送的芙莉莲", "葬送のフリーレン"]
    )

    func result(
        id: String,
        release: String? = "[LoliHouse] Sousou no Frieren - 14 [WebRip 1080p HEVC-10bit AAC SRTx2]",
        languages: [SubtitleLanguage] = [.simplifiedChinese],
        format: SubtitleFormat? = .ass,
        episode: Double? = 14,
        title: String = "葬送的芙莉莲",
        basis: SubtitleMatchBasis = .title,
        isPack: Bool = false,
        rangeEnd: Double? = nil,
        hash: Bool = false,
        machine: Bool = false
    ) -> SubtitleResult {
        SubtitleResult(
            provider: .assrt, providerSubtitleID: id, title: title, releaseName: release,
            languages: languages, format: format, episode: episode, episodeRangeEnd: rangeEnd,
            isPack: isPack, basis: basis, isMachineTranslated: machine, isHashMatch: hash, downloadContext: id
        )
    }

    @Test func exactReleaseScoresHighAndLoadsAutomatically() {
        let scorer = SubtitleMatchScorer()
        let score = scorer.score(result(id: "1"), for: video)
        #expect(score.percent >= 90)
        #expect(score.warnings.isEmpty)
        #expect(score.isAutoLoadable(threshold: 0.7))
    }

    @Test func wrongEpisodeIsCappedWhateverElseMatches() {
        let score = SubtitleMatchScorer().score(result(id: "1", release: "[LoliHouse] Sousou no Frieren - 13 [WebRip 1080p]", episode: 13), for: video)
        #expect(score.total <= 0.15)
        #expect(score.warnings.contains(.wrongEpisode))
        #expect(!score.isAutoLoadable(threshold: 0.1))
    }

    @Test func bluRaySubtitleOnWebVideoNeverLoadsAutomatically() {
        let bd = result(id: "bd", release: "[VCB-Studio] Sousou no Frieren [14][Ma10p_1080p][BDRip]")
        let score = SubtitleMatchScorer().score(bd, for: video)
        #expect(score.warnings.contains(.sourceMismatch))
        #expect(!score.isAutoLoadable(threshold: 0.5))
        let web = SubtitleMatchScorer().score(result(id: "web", release: "[Nekomoe kissaten] Sousou no Frieren - 14 [WebRip 1080p]"), for: video)
        #expect(web.total > score.total)
    }

    @Test func differentGroupSameSourceStillLoadsButRanksBelowExactGroup() {
        let scorer = SubtitleMatchScorer()
        let exact = scorer.score(result(id: "a"), for: video)
        let other = scorer.score(result(id: "b", release: "[Nekomoe kissaten] Sousou no Frieren - 14 [WebRip 1080p]"), for: video)
        #expect(other.warnings.contains(.groupMismatch))
        #expect(other.total < exact.total)
        #expect(other.isAutoLoadable(threshold: 0.7))
    }

    @Test func languageAndFormatFollowThePreferenceOrder() {
        let scorer = SubtitleMatchScorer()
        let ranked = scorer.rank([
            result(id: "hant-srt", languages: [.traditionalChinese], format: .srt),
            result(id: "hans-srt", languages: [.simplifiedChinese], format: .srt),
            result(id: "hant-ass", languages: [.traditionalChinese], format: .ass),
            result(id: "hans-ass", languages: [.simplifiedChinese], format: .ass),
            result(id: "hans-ssa", languages: [.simplifiedChinese], format: .ssa)
        ], for: video)
        #expect(ranked.map(\.result.providerSubtitleID) == ["hans-ass", "hans-ssa", "hant-ass", "hans-srt", "hant-srt"])

        let traditionalFirst = SubtitleMatchScorer(preferences: SubtitleRankingPreferences(
            languages: [.traditionalChinese, .simplifiedChinese]
        ))
        let reranked = traditionalFirst.rank([
            result(id: "hans-ass", languages: [.simplifiedChinese]),
            result(id: "hant-ass", languages: [.traditionalChinese])
        ], for: video)
        #expect(reranked.first?.result.providerSubtitleID == "hant-ass")
    }

    @Test func unpreferredLanguageIsListedButNotLoaded() {
        let score = SubtitleMatchScorer().score(result(id: "en", languages: [.english]), for: video)
        #expect(score.warnings.contains(.unpreferredLanguage))
        #expect(!score.isAutoLoadable(threshold: 0.5))
    }

    @Test func titleMismatchIsCapped() {
        let score = SubtitleMatchScorer().score(result(id: "x", release: "[LoliHouse] Kusuriya no Hitorigoto - 14 [WebRip 1080p]", title: "药屋少女的呢喃"), for: video)
        #expect(score.warnings.contains(.titleMismatch))
        #expect(score.total <= 0.35)
    }

    @Test func seasonPackContainingTheEpisodeIsAcceptable() {
        let pack = result(id: "pack", release: "[LoliHouse] Sousou no Frieren [01-28][WebRip 1080p]", episode: 1, isPack: true, rangeEnd: 28)
        let score = SubtitleMatchScorer().score(pack, for: video)
        #expect(score.warnings.contains(.seasonPack))
        #expect(!score.warnings.contains(.wrongEpisode))
        #expect(score.total > 0.6)
    }

    @Test func hashMatchBeatsEverything() {
        let hashed = result(id: "hash", release: "whatever", format: .srt, episode: nil, basis: .fileHash, hash: true)
        let score = SubtitleMatchScorer().score(hashed, for: video)
        #expect(score.percent >= 85)
    }

    @Test func machineTranslationNeverLoadsAutomatically() {
        let score = SubtitleMatchScorer().score(result(id: "mt", machine: true), for: video)
        #expect(score.warnings.contains(.machineTranslated))
        #expect(!score.isAutoLoadable(threshold: 0.5))
    }

    @Test func automaticChoiceRequiresAnExplicitEpisode() {
        let scorer = SubtitleMatchScorer()
        let ranked = scorer.rank([result(id: "vague", release: "葬送的芙莉莲 字幕", episode: nil)], for: video)
        #expect(ranked.first?.score.warnings.contains(.unknownEpisode) == true)
        #expect(scorer.automaticChoice(from: ranked) == nil)
    }
}

struct SubtitleTextTests {
    let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))

    let simplifiedSRT = """
    1
    00:00:01,000 --> 00:00:03,000
    这个魔法是我们的老师留下来的。

    2
    00:00:04,000 --> 00:00:06,000
    你说的对，时间过得真快，还没有见过这样的人。
    """

    let traditionalSRT = """
    1
    00:00:01,000 --> 00:00:03,000
    這個魔法是我們的老師留下來的。

    2
    00:00:04,000 --> 00:00:06,000
    你說的對，時間過得真快，還沒有見過這樣的人。
    """

    @Test func decodesGBKAndBig5() throws {
        let gbk = try #require(simplifiedSRT.data(using: gb18030))
        let decodedGBK = try #require(SubtitleTextDecoder.decode(gbk))
        #expect(decodedGBK.text == simplifiedSRT)
        #expect(decodedGBK.encoding == .gb18030)

        let big5Data = try #require(traditionalSRT.data(using: big5))
        let decodedBig5 = try #require(SubtitleTextDecoder.decode(big5Data))
        #expect(decodedBig5.text == traditionalSRT)
        #expect(decodedBig5.encoding == .big5)
    }

    @Test func decodesUTF8AndUTF16() throws {
        let utf8 = Data([0xEF, 0xBB, 0xBF]) + Data(simplifiedSRT.utf8)
        #expect(SubtitleTextDecoder.decode(utf8)?.text == simplifiedSRT)
        let utf16 = try #require(simplifiedSRT.data(using: .utf16LittleEndian))
        #expect(SubtitleTextDecoder.decode(Data([0xFF, 0xFE]) + utf16)?.text == simplifiedSRT)
    }

    @Test func validatesFormats() {
        let ass = """
        [Script Info]
        ScriptType: v4.00+

        [V4+ Styles]
        Style: Default,Arial,20

        [Events]
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,测试
        """
        #expect(SubtitleValidator.detectFormat(of: ass) == .ass)
        #expect(SubtitleValidator.detectFormat(of: simplifiedSRT) == .srt)
        #expect(SubtitleValidator.detectFormat(of: "WEBVTT\n\n00:01.000 --> 00:02.000\nhi") == .vtt)
        #expect(SubtitleValidator.detectFormat(of: "<!DOCTYPE html><html>Just a moment...</html>") == nil)
    }

    @Test func detectsChineseScript() {
        #expect(ChineseScriptDetector.detect(simplifiedSRT) == .simplifiedChinese)
        #expect(ChineseScriptDetector.detect(traditionalSRT) == .traditionalChinese)
        // A 简日双语 event: the Japanese half (時, 間, 見 …) must not count
        // as Traditional.
        let bilingual = String(repeating: "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,这个时间我们还没有见过\\N時間がありません、見てください\n", count: 3)
        #expect(ChineseScriptDetector.detect(bilingual) == .simplifiedChinese)
        #expect(ChineseScriptDetector.detect("Hello") == nil)
    }

    @Test func computesOpenSubtitlesHash() {
        let zeros = Data(count: 65_536)
        #expect(OpenSubtitlesHash.compute(size: 131_072, head: zeros, tail: zeros) == "0000000000020000")
        var head = Data(count: 65_536)
        head[0] = 1
        #expect(OpenSubtitlesHash.compute(size: 131_072, head: head, tail: zeros) == "0000000000020001")
    }
}

/// Builds small ZIP archives for tests: stored or deflated entries, with
/// UTF-8 or GBK names.
enum TestZip {
    static func make(_ entries: [(name: String, data: Data)], deflate: Bool = true, gbkNames: Bool = false) -> Data {
        var archive = Data()
        var central = Data()
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for entry in entries {
            let name = gbkNames ? entry.name.data(using: gb18030)! : Data(entry.name.utf8)
            let payload = deflate ? raw(entry.data) : entry.data
            let flags: UInt16 = gbkNames ? 0 : 0x0800
            let method: UInt16 = deflate ? 8 : 0
            let offset = UInt32(archive.count)
            let compressed = UInt32(payload.count)
            let size = UInt32(entry.data.count)
            let nameLength = UInt16(name.count)

            append(&archive, u32: [0x04034B50])
            append(&archive, u16: [20, flags, method, 0, 0])
            append(&archive, u32: [0, compressed, size])
            append(&archive, u16: [nameLength, 0])
            archive.append(name)
            archive.append(payload)

            append(&central, u32: [0x02014B50])
            append(&central, u16: [20, 20, flags, method, 0, 0])
            append(&central, u32: [0, compressed, size])
            append(&central, u16: [nameLength, 0, 0, 0, 0])
            append(&central, u32: [0, offset])
            central.append(name)
        }
        let centralOffset = UInt32(archive.count)
        let count = UInt16(entries.count)
        archive.append(central)
        append(&archive, u32: [0x06054B50])
        append(&archive, u16: [0, 0, count, count])
        append(&archive, u32: [UInt32(central.count), centralOffset])
        append(&archive, u16: [0])
        return archive
    }

    static func append(_ data: inout Data, u16 values: [UInt16]) {
        for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    }

    static func append(_ data: inout Data, u32 values: [UInt32]) {
        for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    }

    static func raw(_ data: Data) -> Data {
        let source = [UInt8](data)
        var destination = [UInt8](repeating: 0, count: source.count + 1024)
        let written = compression_encode_buffer(&destination, destination.count, source, source.count, nil, COMPRESSION_ZLIB)
        return Data(destination.prefix(written))
    }

}

struct SubtitleArchiveTests {
    func ass(_ text: String) -> Data {
        Data("""
        [Script Info]
        ScriptType: v4.00+

        [V4+ Styles]
        Style: Default,Arial,20

        [Events]
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,\(text)
        """.utf8)
    }

    let simplified = String(repeating: "这个时间我们还没有说过，你来对了。", count: 3)
    let traditional = String(repeating: "這個時間我們還沒有說過，你來對了。", count: 3)

    @Test func expandsDeflatedAndStoredEntries() throws {
        for deflate in [true, false] {
            let zip = TestZip.make([("a.ass", ass("一")), ("sub/b.srt", Data("1\n00:00:01,000 --> 00:00:02,000\nhi\n".utf8))], deflate: deflate)
            let files = try SubtitleArchive.zipEntries(zip)
            #expect(files.map(\.name) == ["a.ass", "sub/b.srt"])
            #expect(files.first?.data == ass("一"))
        }
    }

    @Test func decodesGBKEntryNames() throws {
        let zip = TestZip.make([("葬送的芙莉莲 第14集.简体.ass", ass("一"))], gbkNames: true)
        #expect(try SubtitleArchive.zipEntries(zip).first?.name == "葬送的芙莉莲 第14集.简体.ass")
    }

    @Test func rejectsRarWithAClearError() {
        let rar = SubtitleDownloadedFile(name: "x.rar", data: Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]))
        #expect(throws: SubtitleProviderError.unsupportedArchive("RAR")) { try SubtitleArchive.expand([rar]) }
    }

    @Test func selectsTheEpisodeAndPreferredScriptFromAPack() throws {
        let zip = TestZip.make([
            ("[Group] Frieren - 13 [1080p].chs.ass", ass(simplified)),
            ("[Group] Frieren - 14 [1080p].cht.ass", ass(traditional)),
            ("[Group] Frieren - 14 [1080p].chs.ass", ass(simplified)),
            ("[Group] Frieren - 14 [1080p].chs.srt", Data("1\n00:00:01,000 --> 00:00:02,000\n\(simplified)\n".utf8)),
            ("Fonts/FZYaSong.ttf", Data([0, 1, 0, 0]))
        ])
        let video = SubtitleVideoIdentity.fromFileName("[Group] Frieren - 14 [1080p].mkv")
        let prepared = try SubtitleFileSelector().prepare(
            [SubtitleDownloadedFile(name: "pack.zip", data: zip)], for: video, claimedLanguages: [.chinese]
        )
        #expect(prepared.fileName == "[Group] Frieren - 14 [1080p].chs.ass")
        #expect(prepared.language == .simplifiedChinese)
        #expect(prepared.format == .ass)
        #expect(prepared.fonts.map(\.name) == ["Fonts/FZYaSong.ttf"])

        let traditionalFirst = SubtitleFileSelector(preferences: SubtitleRankingPreferences(languages: [.traditionalChinese, .simplifiedChinese]))
        let other = try traditionalFirst.prepare([SubtitleDownloadedFile(name: "pack.zip", data: zip)], for: video, claimedLanguages: [])
        #expect(other.fileName == "[Group] Frieren - 14 [1080p].cht.ass")
    }

    @Test func aPackWithoutTheEpisodeIsRejected() throws {
        let zip = TestZip.make([
            ("Frieren - 12.ass", ass(simplified)),
            ("Frieren - 13.ass", ass(simplified))
        ])
        let video = SubtitleVideoIdentity.fromFileName("Frieren - 14.mkv")
        #expect(throws: SubtitleProviderError.noSuitableFile) {
            try SubtitleFileSelector().prepare([SubtitleDownloadedFile(name: "x.zip", data: zip)], for: video, claimedLanguages: [])
        }
    }

    @Test func htmlInsteadOfASubtitleIsInvalid() {
        let video = SubtitleVideoIdentity.fromFileName("Frieren - 14.mkv")
        #expect(throws: SubtitleProviderError.noSuitableFile) {
            try SubtitleFileSelector().prepare(
                [SubtitleDownloadedFile(name: "14.srt", data: Data("<html>Just a moment…</html>".utf8))],
                for: video, claimedLanguages: []
            )
        }
    }

    @Test func mislabelledScriptIsCorrectedFromText() throws {
        let video = SubtitleVideoIdentity.fromFileName("Frieren - 14.mkv")
        let prepared = try SubtitleFileSelector().prepare(
            [SubtitleDownloadedFile(name: "Frieren - 14.chs.ass", data: ass(traditional))],
            for: video, claimedLanguages: [.simplifiedChinese]
        )
        #expect(prepared.language == .traditionalChinese)
    }
}

struct AnimeIDMappingTests {
    @Test func indexesFribbRecordsOfEveryShape() throws {
        let json = """
        [
          {"type":"TV","anidb_id":17617,"anilist_id":154587,"imdb_id":["tt22248376"],"mal_id":52991,
           "themoviedb_id":{"tv":209867},"season":{"tvdb":1,"tmdb":1}},
          {"type":"MOVIE","anilist_id":1,"imdb_id":"tt0000001","themoviedb_id":{"movie":42}},
          {"type":"TV","anilist_id":2,"themoviedb_id":77,"imdb_id":null}
        ]
        """
        let index = try #require(AnimeIDMappingStore.index(Data(json.utf8)))
        let frieren = try #require(index.aniList[154587])
        #expect(frieren.tmdbID == 209867)
        #expect(frieren.tmdbKind == .tv)
        #expect(frieren.tmdbSeason == 1)
        #expect(frieren.aniDBID == 17617)
        #expect(frieren.imdbID == "tt22248376")
        #expect(index.mal[52991]?.aniListID == 154587)
        #expect(index.aniList[1]?.tmdbKind == .movie)
        #expect(index.aniList[1]?.imdbID == "tt0000001")
        #expect(index.aniList[2]?.tmdbID == 77)
    }

    @Test func resolvesAniListOnlyForNearIdenticalTitlesAndSameYear() {
        func candidate(_ id: String, _ title: String, _ original: String, _ date: String) -> AnimeMetadataCandidate {
            AnimeMetadataCandidate(provider: .anilist, externalID: id, title: title, originalTitle: original,
                                   summary: "", posterURL: nil, airDate: date, score: nil, rank: nil, ratingCount: nil)
        }
        let candidates = [
            candidate("1", "Frieren: Beyond Journey's End Season 2", "葬送のフリーレン 第2期", "2026-01-16"),
            candidate("154587", "Frieren: Beyond Journey's End", "葬送のフリーレン", "2023-09-29")
        ]
        #expect(SubtitleIdentityResolver.bestAniListID(candidates: candidates, titles: ["葬送のフリーレン"], airDate: "2023-09-29") == 154587)
        #expect(SubtitleIdentityResolver.bestAniListID(candidates: candidates, titles: ["葬送のフリーレン"], airDate: "2019-01-01") == nil)
        #expect(SubtitleIdentityResolver.bestAniListID(candidates: candidates, titles: ["Kusuriya no Hitorigoto"], airDate: nil) == nil)
    }
}
