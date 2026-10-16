import Foundation
import Testing
@testable import AnimeGodCore

struct SubtitleLanguageTagTests {
    /// Every spelling this library and the usual teams actually publish.
    @Test(arguments: [
        "CHS", "CHT", "CHI", "JPN", "ENG", "GB", "BIG5", "GBK",
        "CHS_JP", "CHT_JP", "CHS_JP&CHT_JP", "CHS&CHT&JPN", "CHI_JPN_ENG",
        "JPSC", "JPTC", "chs", "Chs_Jp",
        "简日", "繁日", "简繁日内封", "简繁内封字幕", "简繁外挂", "简繁日双语外挂",
        "简体外挂", "日语中字", "中字", "双语"
    ])
    func readsEverySpellingAsATag(_ value: String) {
        #expect(SubtitleLanguageTag.isTag(value), "\(value) should read as a language tag")
    }

    /// The expensive half. Each of these has to survive, and several are the
    /// reason the rule is a whole-run match rather than a contains: `[END]` is
    /// a fansub's finale tag and the season-finished test depends on it,
    /// `Chi.` is a 2024 series, and `Koko` is why Korean is not in the table.
    @Test(arguments: [
        "END", "Fin", "完", "OVA", "SP", "NCOP", "NCED", "TV", "Movie", "Menu",
        "Koko", "Kokoro", "Scene", "Chen", "Japan", "Chinese", "English",
        "言叶之庭", "中二病", "日常", "英雄", "简爱", "日本語", "鬼灭之刃",
        "1080p", "HEVC-10bit", "FLAC", "UHA-WINGS", "Studio GreenTea",
        "FX Senshi Kurumi-chan", "日", "中"
    ])
    func leavesEverythingElseAlone(_ value: String) {
        #expect(!SubtitleLanguageTag.isTag(value), "\(value) should not read as a language tag")
    }

    /// Outside brackets a short Latin run is a word as readily as a code, so
    /// only the unmistakable spellings are removed there.
    @Test func readsBareRunsMoreCautiouslyThanBracketedOnes() {
        #expect(SubtitleLanguageTag.isBareTag("CHS_JP&CHT_JP"))
        #expect(SubtitleLanguageTag.isBareTag("JPSC"))
        #expect(SubtitleLanguageTag.isBareTag("日语中字"))
        #expect(SubtitleLanguageTag.isBareTag("CHS"))
        // Bracketed these are tags; bare they are a storage unit, a country
        // code and an ordinary word.
        #expect(SubtitleLanguageTag.isTag("GB") && !SubtitleLanguageTag.isBareTag("GB"))
        #expect(SubtitleLanguageTag.isTag("CN") && !SubtitleLanguageTag.isBareTag("CN"))
        #expect(SubtitleLanguageTag.isTag("EN") && !SubtitleLanguageTag.isBareTag("EN"))
        // `Chi.` is 「チ。地球の運動について」, and `parse` turns that dot into a
        // space: bare, it is the work's whole name.
        #expect(SubtitleLanguageTag.isTag("CHI") && !SubtitleLanguageTag.isBareTag("Chi"))
    }

    /// The three real files that made one folder into three library entries.
    @Test func dropsTheTagFromARealEpisodeTitle() {
        let parser = AnimeFilenameParser()
        let root = URL(fileURLWithPath: "/library")
        let folder = root.appending(path: "FX Senshi Kurumi-chan", directoryHint: .isDirectory)
        let names = [
            "[UHA-WINGS][FX Senshi Kurumi-chan][01][1080p HEVC][CHS_JP&CHT_JP].mkv",
            "[UHA-WINGS][FX Senshi Kurumi-chan][02][1080p HEVC][CHS_JP&CHT_JP].mkv",
            "[Studio GreenTea] FX Senshi Kurumi-chan [01][WebRip][HEVC-10bit 1080p AAC][JPSC].mp4"
        ]
        let titles = names.map { parser.parse(url: folder.appending(path: $0), libraryRoot: root).title }
        #expect(titles == Array(repeating: "FX Senshi Kurumi-chan", count: 3))
    }

    @Test(arguments: [
        ("[Sakurato] Domestic na Kanojo [01][HEVC-10bit 1080p FLAC][CHS&CHT&JPN].mkv", "Domestic na Kanojo"),
        ("[Haruhana] Hana [BDRip][HEVC-10bit 1080p][CHI_JPN_ENG].mkv", "Hana"),
        ("[MCE][Eiga Daisuki Pompo-san][BDrip][GB][1080P][x264 AAC].mp4", "Eiga Daisuki Pompo-san"),
        ("[Sakurato] Toumei na Yoru. [01][AVC-8bit 1080P AAC][CHS].mp4", "Toumei na Yoru"),
        ("某番 [01] 简繁日内封.mkv", "某番")
    ])
    func dropsTheTagWhereverItSits(_ name: String, _ expected: String) {
        let parser = AnimeFilenameParser()
        #expect(parser.parse(url: URL(fileURLWithPath: "/library/\(name)")).title == expected)
    }

    /// The whole point: one folder, two teams, one work — and the rule that
    /// splits a folder holding two shows is still there, which the scanner
    /// suite's own cases cover.
    @Test func twoTeamsInOneFolderAreOneWork() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let folderURL = rootURL.appending(path: "FX Senshi Kurumi-chan", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        for name in [
            "[UHA-WINGS][FX Senshi Kurumi-chan][01][1080p HEVC][CHS_JP&CHT_JP].mkv",
            "[UHA-WINGS][FX Senshi Kurumi-chan][02][1080p HEVC][CHS_JP&CHT_JP].mkv",
            "[Studio GreenTea] FX Senshi Kurumi-chan [01][WebRip][HEVC-10bit 1080p AAC][JPSC].mp4"
        ] {
            try Data([0x01]).write(to: folderURL.appending(path: name))
        }

        let root = LibraryRoot(displayName: "Test", lastKnownPath: rootURL.path)
        let result = try await LibraryScanner().scan(root: root, resolvedURL: rootURL)

        #expect(result.files.count == 3)
        #expect(Set(result.files.map(\.parsed.title)) == ["FX Senshi Kurumi-chan"])
        // The two teams' episode 1 is one episode with two files.
        #expect(Set(result.files.compactMap(\.parsed.episode)) == [1, 2])
    }
}
