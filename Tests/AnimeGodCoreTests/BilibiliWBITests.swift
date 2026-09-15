import Foundation
import Testing
@testable import AnimeGodCore

@Suite struct BilibiliWBITests {
    // The key pair and expected results published with Bilibili's own WBI
    // description. Reproducing them exactly is the only way to know the
    // permutation table and hashing order are right.
    private let imgKey = "7cd084941338484aae1ad9425b84077c"
    private let subKey = "4932caff0ff746eab6f01bf08b70ac45"

    @Test func derivesTheDocumentedMixinKey() {
        #expect(
            BilibiliWBI.mixinKey(imgKey: imgKey, subKey: subKey) == "ea1db124af3c7062474693fa704f4ff8"
        )
    }

    @Test func reproducesTheDocumentedSignature() throws {
        let items = BilibiliWBI.sign(
            parameters: ["foo": "114", "bar": "514", "zab": "1919810"],
            keys: BilibiliWBI.Keys(imgKey: imgKey, subKey: subKey),
            timestamp: Date(timeIntervalSince1970: 1_702_204_169)
        )
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(values["wts"] == "1702204169")
        #expect(values["w_rid"] == "8f6f2b5b3d485fe1886cec6a0be8c5d4")
        // Parameters must go out sorted, with the signature appended last.
        #expect(items.map(\.name) == ["bar", "foo", "wts", "zab", "w_rid"])
    }

    @Test func stripsCharactersBilibiliExcludesBeforeHashing() {
        // Leaving these in produces a signature the server cannot reproduce.
        #expect(BilibiliWBI.sanitize("hello!'()*world") == "helloworld")
        let items = BilibiliWBI.sign(
            parameters: ["keyword": "It's (a) test!"],
            keys: BilibiliWBI.Keys(imgKey: imgKey, subKey: subKey),
            timestamp: Date(timeIntervalSince1970: 1_702_204_169)
        )
        #expect(items.first { $0.name == "keyword" }?.value == "Its a test")
    }

    @Test func queryStringEncodesEverythingOutsideTheUnreservedSet() {
        // URLComponents would leave "+" and ":" alone, so the bytes sent
        // would not match the bytes signed.
        let query = BilibiliWBI.queryString(for: [
            URLQueryItem(name: "keyword", value: "BanG Dream! YUME∞MITA"),
            URLQueryItem(name: "plus", value: "a+b:c/d")
        ])
        #expect(query.contains("keyword=BanG%20Dream%21%20YUME%E2%88%9EMITA"))
        #expect(query.contains("plus=a%2Bb%3Ac%2Fd"))
    }

    @Test func extractsKeysFromRotatingAssetURLs() {
        #expect(
            BilibiliWBI.key(fromAssetURL: "https://i0.hdslb.com/bfs/wbi/\(imgKey).png") == imgKey
        )
        #expect(BilibiliWBI.key(fromAssetURL: "") == nil)
    }

    @Test func keysExpireWithBilibilisCalendarDay() {
        // The keys roll over at midnight UTC+8, not local midnight.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 9))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 23))!
        let nextDay = calendar.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 1))!

        let keys = BilibiliWBI.Keys(imgKey: imgKey, subKey: subKey, fetchedAt: morning)
        #expect(keys.isFresh(at: evening))
        #expect(!keys.isFresh(at: nextDay))
    }
}

@Suite struct DanmakuCommentMergerTests {
    private func comment(_ id: String, _ time: Double, _ text: String, source: String) -> DanmakuComment {
        DanmakuComment(id: id, time: time, text: text, mode: .scroll, source: source)
    }

    @Test func collapsesTheSameCommentAcrossSources() {
        let dandanplay = [comment("d1", 12.0, "这段BGM太神了", source: "dandanplay")]
        // Same line, posted against a slightly different encode, with the
        // punctuation and width the other pool happens to use.
        let bilibili = [comment("b1", 13.1, "这段 BGM 太神了！", source: "bilibili")]

        let merged = DanmakuCommentMerger.merge([dandanplay, bilibili])
        #expect(merged.count == 1)
        // Priority order decides the survivor, so the first source wins.
        #expect(merged.first?.source == "dandanplay")
    }

    @Test func keepsRepeatsThatAreFarApartInTime() {
        let merged = DanmakuCommentMerger.merge([
            [comment("d1", 10, "前方高能预警", source: "dandanplay")],
            [comment("b1", 400, "前方高能预警", source: "bilibili")]
        ])
        #expect(merged.count == 2)
    }

    @Test func neverDeduplicatesShortReactions() {
        // "草" and "8888" are independent reactions, not copies of one another.
        let merged = DanmakuCommentMerger.merge([
            [comment("d1", 30, "草", source: "dandanplay"), comment("d2", 30.2, "8888", source: "dandanplay")],
            [comment("b1", 30.1, "草", source: "bilibili"), comment("b2", 30.3, "8888", source: "bilibili")]
        ])
        #expect(merged.count == 4)
    }

    @Test func mergesIntoOneSortedTimelineAndDropsDuplicateIDs() {
        let merged = DanmakuCommentMerger.merge([
            [comment("d2", 50, "second", source: "dandanplay"), comment("d1", 10, "first", source: "dandanplay")],
            [comment("d1", 10, "first", source: "dandanplay"), comment("b9", 30, "middle", source: "bilibili")]
        ])
        #expect(merged.map(\.id) == ["d1", "b9", "d2"])
        #expect(merged.map(\.time) == [10, 30, 50])
    }

    @Test func aSingleSourcePassesThroughSorted() {
        let merged = DanmakuCommentMerger.merge([
            [comment("b2", 9, "late", source: "bilibili"), comment("b1", 1, "early", source: "bilibili")]
        ])
        #expect(merged.map(\.id) == ["b1", "b2"])
    }
}
