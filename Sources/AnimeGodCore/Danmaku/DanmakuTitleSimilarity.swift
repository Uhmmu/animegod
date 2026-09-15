import Foundation

/// Title normalization and fuzzy comparison shared by every danmaku
/// matcher. Extracted so the dandanplay and Bilibili matchers score titles
/// the same way instead of drifting apart.
public enum DanmakuTitleSimilarity {
    /// Folds case, width and diacritics, drops season markers, and keeps
    /// only letters and digits. Season markers are removed because
    /// providers localize them inconsistently ("Season 2", "第二季", "II");
    /// use `seasonNumber(in:)` to compare seasons explicitly.
    public static func normalize(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(
                of: #"(?i)\b(?:season|part)\s*\d+\b|第\s*[一二三四五六七八九十百\d]+\s*季"#,
                with: "", options: .regularExpression
            )
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }

    /// 0...1 similarity between two already-normalized titles. Exact match
    /// scores 1, containment scores high (providers append "TV版",
    /// "(仅限港澳台)" and similar), otherwise Dice coefficient on bigrams.
    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        if lhs.contains(rhs) || rhs.contains(lhs) {
            return 0.82 + 0.16 * Double(min(lhs.count, rhs.count)) / Double(max(lhs.count, rhs.count))
        }
        let left = bigrams(lhs)
        let right = bigrams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return lhs.first == rhs.first ? 0.4 : 0 }
        return 2 * Double(left.intersection(right).count) / Double(left.count + right.count)
    }

    /// Convenience: normalizes both sides before comparing.
    public static func similarityOfRawTitles(_ lhs: String, _ rhs: String) -> Double {
        similarity(normalize(lhs), normalize(rhs))
    }

    public static func bigrams(_ value: String) -> Set<String> {
        let characters = Array(value)
        guard characters.count > 1 else { return Set(characters.map(String.init)) }
        return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
    }

    /// The season a title advertises, in any of the common spellings.
    /// A title with no marker is season 1 by convention, reported as nil so
    /// callers can tell "unstated" from "explicitly first".
    public static func seasonNumber(in title: String) -> Int? {
        let folded = title.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let patterns = [
            #"(?i)\bseason\s*(\d{1,2})\b"#,
            #"(?i)\bS(\d{1,2})\b"#,
            #"第\s*(\d{1,2})\s*季"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: folded),
                  let value = Int(folded[range]) else { continue }
            return value
        }
        if let range = folded.range(of: #"第\s*([一二三四五六七八九十]+)\s*季"#, options: .regularExpression) {
            let digits = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10]
            for (character, value) in digits where folded[range].contains(character) { return value }
        }
        return nil
    }
}
