import Foundation
import Testing
@testable import AnimeGodCore

struct DanmakuCommentFilterTests {
    private func comment(_ id: String, at time: Double, text: String, mode: DanmakuMode = .scroll) -> DanmakuComment {
        DanmakuComment(id: id, time: time, text: text, mode: mode)
    }

    private func settings(_ configure: (inout DanmakuDisplaySettings) -> Void) -> DanmakuDisplaySettings {
        var settings = DanmakuDisplaySettings.default
        configure(&settings)
        return settings
    }

    // MARK: - Merging

    @Test func duplicatesWithinTheWindowMergeIntoTheFirstWithACount() {
        let result = DanmakuCommentFilter(settings: .default).apply(to: [
            comment("1", at: 10, text: "哈哈哈哈"),
            comment("2", at: 12, text: "哈哈"),
            comment("3", at: 15, text: "  哈哈哈！"),
            comment("4", at: 11, text: "好耶"),
        ])
        #expect(result.comments.map(\.id) == ["1", "4"])
        #expect(result.comments[0].text == "哈哈哈哈 ×3")
        #expect(result.comments[1].text == "好耶")
        #expect(result.mergedCount == 2)
    }

    @Test func repeatsOutsideTheWindowStartANewGroup() {
        let window = DanmakuCommentFilter.mergeWindow
        let result = DanmakuCommentFilter(settings: .default).apply(to: [
            comment("1", at: 0, text: "233"),
            comment("2", at: window - 0.5, text: "2333"),
            // Anchored at the first occurrence, not the latest repeat.
            comment("3", at: window + 0.5, text: "23333"),
        ])
        #expect(result.comments.map(\.text) == ["233 ×2", "23333"])
    }

    @Test func mergingCanBeDisabled() {
        let filter = DanmakuCommentFilter(settings: settings { $0.mergeDuplicates = false })
        let result = filter.apply(to: [comment("1", at: 0, text: "草"), comment("2", at: 1, text: "草")])
        #expect(result.comments.map(\.text) == ["草", "草"])
        #expect(result.mergedCount == 0)
    }

    @Test func normalizationFoldsCaseWhitespacePunctuationAndRuns() {
        #expect(DanmakuCommentFilter.normalizedKey("WWW www!") == "ww")
        #expect(DanmakuCommentFilter.normalizedKey("前方高能！！") == "前方高能")
        // Punctuation-only text keeps its own identity.
        #expect(DanmakuCommentFilter.normalizedKey("？？？") == "？？？")
    }

    // MARK: - Density

    @Test func densityThinsDeterministically() {
        let comments = (0..<2000).map { comment("\($0)", at: Double($0), text: "c\($0)") }
        let filter = DanmakuCommentFilter(settings: settings { $0.density = 0.5 })
        let first = filter.apply(to: comments)
        let second = filter.apply(to: comments.shuffled())
        #expect(first.comments.map(\.id) == second.comments.map(\.id))
        #expect((850...1150).contains(first.comments.count))
        #expect(first.hiddenCount == 2000 - first.comments.count)
    }

    @Test func lowerDensityKeepsASubsetOfHigherDensity() {
        let comments = (0..<500).map { comment("\($0)", at: Double($0), text: "c\($0)") }
        let half = Set(DanmakuCommentFilter(settings: settings { $0.density = 0.5 }).apply(to: comments).comments.map(\.id))
        let fifth = Set(DanmakuCommentFilter(settings: settings { $0.density = 0.2 }).apply(to: comments).comments.map(\.id))
        #expect(fifth.isSubset(of: half))
    }

    @Test func popularMergedCommentsSurviveThinning() {
        let repeats = (0..<DanmakuCommentFilter.popularThreshold).map { comment("p\($0)", at: Double($0), text: "名场面") }
        let noise = (0..<200).map { comment("n\($0)", at: Double($0) * 0.01, text: "n\($0)") }
        let result = DanmakuCommentFilter(settings: settings { $0.density = 0.2 }).apply(to: repeats + noise)
        #expect(result.comments.contains { $0.text == "名场面 ×\(DanmakuCommentFilter.popularThreshold)" })
    }

    // MARK: - Rules

    @Test func longCommentsAreHidden() {
        let result = DanmakuCommentFilter(settings: settings { $0.maxLength = 5 }).apply(to: [
            comment("short", at: 0, text: "12345"),
            comment("long", at: 1, text: "123456"),
        ])
        #expect(result.comments.map(\.id) == ["short"])
        #expect(result.hiddenCount == 1)
    }

    @Test func keywordsMatchSubstringsAndRegularExpressions() {
        let filter = DanmakuCommentFilter(settings: settings {
            $0.blockedKeywords = ["剧透", "/^第[一二三]$/", "/[unclosed/", "  "]
        })
        let result = filter.apply(to: [
            comment("spoiler", at: 0, text: "前方剧透注意"),
            comment("first", at: 1, text: "第一"),
            comment("firstQ", at: 2, text: "第一？"),
            comment("ok", at: 3, text: "[unclosed"),
        ])
        #expect(result.comments.map(\.id) == ["firstQ", "ok"])
    }

    @Test func keywordValidation() {
        #expect(DanmakuCommentFilter.isValidKeyword("剧透"))
        #expect(DanmakuCommentFilter.isValidKeyword("/^233+$/"))
        #expect(!DanmakuCommentFilter.isValidKeyword("/[unclosed/"))
        #expect(!DanmakuCommentFilter.isValidKeyword("   "))
    }

    // MARK: - Persistence

    @Test func legacySettingsDecodeWithNewDefaults() throws {
        let legacy = #"{"opacity":0.5,"fontScale":1.2,"displayArea":0.5,"speedMultiplier":1,"maxSimultaneous":50,"hideScroll":false,"hideTop":true,"hideBottom":false,"hideColored":false,"timeOffset":1.5}"#
        let decoded = try JSONDecoder().decode(DanmakuDisplaySettings.self, from: Data(legacy.utf8))
        #expect(decoded.opacity == 0.5)
        #expect(decoded.hideTop)
        #expect(decoded.timeOffset == 1.5)
        #expect(decoded.mergeDuplicates == DanmakuDisplaySettings.default.mergeDuplicates)
        #expect(decoded.lineSpacing == DanmakuDisplaySettings.default.lineSpacing)
        #expect(decoded.blockedKeywords.isEmpty)
    }
}
