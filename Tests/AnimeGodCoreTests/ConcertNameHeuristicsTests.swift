import Foundation
import Testing

@testable import AnimeGodCore

@Suite("Recognising a concert from its name")
struct ConcertNameHeuristicsTests {
    @Test("the real download in the library")
    func realDownload() {
        let verdict = ConcertNameHeuristics.verdict(
            for: "[DBD-Raws][MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」][1080P][BDRip][HEVC-10bit][FLAC][MKV]"
        )
        #expect(verdict.isConcert)
        #expect(verdict.signals.contains(.ordinalLive))
    }

    @Test("an ordinal before the live word, however it is punctuated", arguments: [
        "BanG Dream! 11th☆LIVE DAY1",
        "TrySail First Live Tour \"The Age of Discovery\"",
        "ラブライブ！サンシャイン!! Aqours 5th LoveLive! ~Next SPARKLING!!~",
        "結束バンド 1st LIVE -恒星-",
        "水樹奈々 NANA MIZUKI LIVE GALAXY 2016",
        "Roselia 2nd・LIVE",
    ])
    func ordinalForms(_ name: String) {
        #expect(ConcertNameHeuristics.verdict(for: name).isConcert, "\(name)")
    }

    @Test("one strong word is enough", arguments: [
        "初音ミク マジカルミライ 2023 演唱会",
        "Aimer コンサート 2022",
        "Kessoku Band LIVE -Kosei-",
        "ASIAN KUNG-FU GENERATION Tour 2016 武道館",
        "幾田りら Zepp Tour 2023",
    ])
    func oneStrongWord(_ name: String) {
        #expect(ConcertNameHeuristics.verdict(for: name).isConcert, "\(name)")
    }

    @Test("one weak word is never enough", arguments: [
        "Sousou no Frieren - 12 [1080p]",
        "劇場版 夜は短し歩けよ乙女 (E7E8AD1D)",
        "Ave Mujica -The Die is Cast- [BDRip][ANZX-10294]",
        "SENNEN_JYOYU",
        "Shirobako Movie [Blu-ray]",
    ])
    func weakAlone(_ name: String) {
        let verdict = ConcertNameHeuristics.verdict(for: name)
        #expect(!verdict.isConcert, "\(name) scored \(verdict.score) from \(verdict.signals)")
    }

    /// The words that look like the answer and are not. Every one of these is
    /// a real release name; `Live-eviL` is a fansub group, and reading the
    /// group's own bracket would make every series it subbed a concert.
    @Test("the live word does not mean a concert here", arguments: [
        "[Live-eviL] Legend of the Galactic Heroes - 01",
        "Love Live! Superstar!! S2 [BDRip]",
        "ラブライブ！虹ヶ咲学園スクールアイドル同好会",
        "Live A Live (2022)",
        "Rurouni Kenshin Live Action 2012",
        "Deliverance",
    ])
    func falsePositives(_ name: String) {
        let verdict = ConcertNameHeuristics.verdict(for: name)
        #expect(!verdict.isConcert, "\(name) scored \(verdict.score) from \(verdict.signals)")
    }

    @Test("a series' own concert still reads as one")
    func loveLiveConcert() {
        // The bare word is suppressed for this title, so what has to carry it
        // is the ordinal — which is how these discs are always titled.
        #expect(ConcertNameHeuristics.isConcert(["ラブライブ! μ's Final LoveLive! ~μ'sic Forever~"]))
    }

    @Test("a catalogue number alone is not a concert — anime discs have them too")
    func catalogueNumberAlone() {
        let verdict = ConcertNameHeuristics.verdict(for: "ANZX-14501 [BDMV]")
        #expect(verdict.signals == [.catalogNumber])
        #expect(!verdict.isConcert)
    }

    @Test("a weak signal plus a catalogue number is still not a concert")
    func weakPlusCatalogue() {
        let verdict = ConcertNameHeuristics.verdict(for: "Something DAY1 [ANZX-10294]")
        #expect(!verdict.isConcert)
    }

    @Test("the file names count too, not just the folder")
    func readsEveryName() {
        let verdict = ConcertNameHeuristics.verdict(for: [
            "BRMM-10876",
            "MyGO!!!!! LIVE DAY1.mkv",
            "MyGO!!!!! LIVE DAY2.mkv",
        ])
        #expect(verdict.isConcert)
        #expect(verdict.signals.contains(.catalogNumber))
        #expect(verdict.signals.contains(.dayLabel))
    }

    @Test("reasons come back worth-first, for the page to show")
    func reasonsOrdered() {
        let verdict = ConcertNameHeuristics.verdict(for: "Roselia 6th LIVE DAY1 武道館")
        #expect(verdict.reasons.first == .ordinalLive)
        #expect(verdict.reasons.last == .dayLabel)
        #expect(verdict.isConcert)
    }
}

/// The nine downloads that were actually in flight in this library when the
/// recogniser shipped — read off the running app, not invented. Every one is a
/// concert, and every one used to raise the "which anime is this?" sheet.
@Suite("The concerts in the queue")
struct ConcertNameHeuristicsRealQueueTests {
    @Test(arguments: [
        "[DBD-Raws][Ave Mujica 4th LIVE 「Adventus」][1080P][BDRip][HEVC-10bit][FLAC][MKV]",
        "[DBD-Raws][Ave Mujica 3rd LIVE 「Veritas」][1080P][BDRip][HEVC-10bit][FLAC][MKV]",
        "[DBD-Raws][Ave Mujica 1st LIVE 「Perdere Omnia」][1080P][BDRip][HEVC-10bit][FLAC][MKV]",
        // `0th` — a zeroth live is a real thing and a numeric ordinal has to
        // allow it.
        "[DBD-Raws][Ave Mujica 0th LIVE 「Primo die in scaena」][1080P][BDRip][HEVC-10bit][FLAC][MKV]",
        // Two acts, both nights and the bonus disc in one folder.
        "[DBD-Raws][MyGO!!!!!×Ave Mujica 合同ライブ「わかれ道の、その先へ」][DAY1+2+特典][1080P][BDRip][HEVC-10bit][FLAC][MKV]",
        "[DBD-Raws][MyGO!!!!! ZEPP TOUR 2024「彷徨する渇望」愛知公演][1080P][BDRip][HEVC-10bit][FLAC][MKV]",
        // A bare file name, no group bracket, the ordinal punctuated with ☆.
        "BanG Dream! 12th☆LIVE DAY2 : MyGO!!!!!「ちいさな一瞬」.mkv",
        "[DBD-Raws][MyGO!!!!! 7th LIVE「こたえなんてなくても」+Extra Studio Live][1080P][BDRip][HEVC-10bit][FLAC][MKV]",
        "[DBD-Raws][MyGO!!!!! 3rd LIVE「声を抱えて生きる」][1080P][BDRip][HEVC-10bit][FLAC][MKV]",
    ])
    func everyOneInTheQueueIsRecognised(_ name: String) {
        let verdict = ConcertNameHeuristics.verdict(for: name)
        #expect(verdict.isConcert, "\(name) scored \(verdict.score) from \(verdict.signals)")
    }
}
