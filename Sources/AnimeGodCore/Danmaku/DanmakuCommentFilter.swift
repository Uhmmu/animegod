import Foundation

/// Content filtering for dense danmaku: rule-based hiding (mode, color,
/// length, keywords), duplicate merging, and deterministic density
/// thinning. Pure and order-stable, so seeks and reloads always produce the
/// same visible set.
public struct DanmakuCommentFilter {
    /// Comments with the same normalized text within this many media seconds
    /// of the group's first occurrence collapse into that first comment.
    public static let mergeWindow: Double = 10
    /// Merged comments repeated at least this often survive density thinning.
    public static let popularThreshold = 3

    public struct Result: Equatable, Sendable {
        /// Visible comments, sorted by time then id. Merged comments carry a
        /// "×N" suffix.
        public var comments: [DanmakuComment]
        /// Removed by mode/color/length/keyword rules or density thinning.
        public var hiddenCount: Int
        /// Folded into an earlier identical comment.
        public var mergedCount: Int
    }

    /// Why a rule hides a comment. Merging and density thinning depend on
    /// the whole comment set and are not reported here.
    public enum HidingReason: Equatable, Sendable {
        case mode
        case colored
        case tooLong
        /// The blocked keyword entry that matched, as stored in settings.
        case keyword(String)
        case sender
    }

    private let settings: DanmakuDisplaySettings
    private let substrings: [(text: String, keyword: String)]
    private let patterns: [(regex: NSRegularExpression, keyword: String)]
    private let blockedSenders: Set<String>

    public init(settings: DanmakuDisplaySettings) {
        self.settings = settings
        var substrings: [(text: String, keyword: String)] = []
        var patterns: [(regex: NSRegularExpression, keyword: String)] = []
        for keyword in settings.blockedKeywords {
            if let pattern = Self.regexPattern(from: keyword) {
                // Invalid expressions are ignored; the settings UI rejects them.
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    patterns.append((regex, keyword))
                }
            } else {
                let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { substrings.append((trimmed, keyword)) }
            }
        }
        self.substrings = substrings
        self.patterns = patterns
        blockedSenders = Set(settings.blockedSenders)
    }

    public func apply(to comments: [DanmakuComment]) -> Result {
        var hidden = 0
        let sorted = comments
            .filter { comment in
                let allowed = isAllowed(comment)
                if !allowed { hidden += 1 }
                return allowed
            }
            .sorted { lhs, rhs in
                lhs.time < rhs.time || (lhs.time == rhs.time && lhs.id < rhs.id)
            }

        var grouped: [DanmakuComment] = []
        var counts: [Int] = []
        var merged = 0
        if settings.mergeDuplicates {
            var groups: [String: (index: Int, time: Double)] = [:]
            for comment in sorted {
                let key = Self.normalizedKey(comment.text)
                if let group = groups[key], comment.time - group.time <= Self.mergeWindow {
                    counts[group.index] += 1
                    merged += 1
                    continue
                }
                groups[key] = (grouped.count, comment.time)
                grouped.append(comment)
                counts.append(1)
            }
        } else {
            grouped = sorted
            counts = Array(repeating: 1, count: sorted.count)
        }

        let density = min(max(settings.density, 0), 1)
        var visible: [DanmakuComment] = []
        visible.reserveCapacity(grouped.count)
        for (index, comment) in grouped.enumerated() {
            let count = counts[index]
            if density < 1, count < Self.popularThreshold, Self.densityFraction(for: comment.id) >= density {
                hidden += 1
                continue
            }
            if count > 1 {
                visible.append(DanmakuComment(
                    id: comment.id, time: comment.time, text: "\(comment.text) ×\(count)",
                    mode: comment.mode, color: comment.color,
                    senderID: comment.senderID, timestamp: comment.timestamp
                ))
            } else {
                visible.append(comment)
            }
        }
        return Result(comments: visible, hiddenCount: hidden, mergedCount: merged)
    }

    private func isAllowed(_ comment: DanmakuComment) -> Bool {
        hidingReason(for: comment) == nil
    }

    /// The first rule that hides `comment`, or nil when rules allow it.
    public func hidingReason(for comment: DanmakuComment) -> HidingReason? {
        switch comment.mode {
        case .scroll: if settings.hideScroll { return .mode }
        case .top: if settings.hideTop { return .mode }
        case .bottom: if settings.hideBottom { return .mode }
        }
        if let sender = comment.senderID, blockedSenders.contains(sender) { return .sender }
        if settings.hideColored && comment.isColored { return .colored }
        if settings.maxLength > 0 && comment.text.count > settings.maxLength { return .tooLong }
        for entry in substrings where comment.text.range(of: entry.text, options: .caseInsensitive) != nil {
            return .keyword(entry.keyword)
        }
        if !patterns.isEmpty {
            let range = NSRange(comment.text.startIndex..., in: comment.text)
            for entry in patterns where entry.regex.firstMatch(in: comment.text, range: range) != nil {
                return .keyword(entry.keyword)
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Duplicate identity: case-folded, whitespace and punctuation removed,
    /// and character runs capped at two ("哈哈哈哈" ≡ "哈哈", "23333" ≡ "233").
    /// Text made only of punctuation keeps its original form.
    public static func normalizedKey(_ text: String) -> String {
        var result = ""
        var last: Character?
        var run = 0
        for character in text.lowercased() {
            if character.isWhitespace || character.isPunctuation { continue }
            if character == last {
                run += 1
                if run > 2 { continue }
            } else {
                last = character
                run = 1
            }
            result.append(character)
        }
        return result.isEmpty ? text : result
    }

    /// `/pattern/` keywords are regular expressions; anything else is a
    /// case-insensitive substring.
    public static func regexPattern(from keyword: String) -> String? {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2, trimmed.hasPrefix("/"), trimmed.hasSuffix("/") else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    public static func isValidKeyword(_ keyword: String) -> Bool {
        guard let pattern = regexPattern(from: keyword) else {
            return !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    /// Stable position of a comment in [0, 1) for density thinning. FNV-1a
    /// (Swift's `hashValue` is randomized per launch) plus a splitmix64
    /// finalizer: plain FNV leaves the high bits poorly mixed for short,
    /// similar ids such as sequential comment numbers.
    static func densityFraction(for id: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        hash ^= hash >> 30
        hash &*= 0xbf58_476d_1ce4_e5b9
        hash ^= hash >> 27
        hash &*= 0x94d0_49bb_1331_11eb
        hash ^= hash >> 31
        return Double(hash >> 11) / Double(UInt64(1) << 53)
    }
}
