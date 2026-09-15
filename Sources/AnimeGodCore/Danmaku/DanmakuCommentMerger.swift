import Foundation

/// Combines the comment lists of several providers into one stream.
///
/// The same joke lands in both pools when a viewer watched on Bilibili and
/// someone re-posted it to dandanplay — and official Bilibili pools are a
/// common upstream for dandanplay's own data, so overlap is the norm rather
/// than the exception. Near-duplicates are collapsed on normalized text
/// within a short time window; exact-duplicate detection alone would miss
/// almost all of them, because the two pools differ in punctuation, width
/// and the exact millisecond.
public enum DanmakuCommentMerger {
    public struct Options: Hashable, Sendable {
        /// Two comments with the same normalized text this close together
        /// are treated as one. Pools drift by a second or two because the
        /// encodes they were posted against differ.
        public var timeWindow: Double
        /// Texts shorter than this are never deduplicated across sources:
        /// "草", "w", "?" are independent reactions, not copies.
        public var minimumTextLength: Int
        /// Nor are texts built from too few distinct characters. "8888",
        /// "wwww" and "哈哈哈哈" clear the length bar but carry almost no
        /// information, and two viewers typing them seconds apart is the
        /// normal case, not a duplicate.
        public var minimumDistinctCharacters: Int

        public init(timeWindow: Double = 2.5, minimumTextLength: Int = 3, minimumDistinctCharacters: Int = 3) {
            self.timeWindow = timeWindow
            self.minimumTextLength = minimumTextLength
            self.minimumDistinctCharacters = minimumDistinctCharacters
        }

        public static let `default` = Options()
    }

    /// Merges `sources` in priority order: when a duplicate is found, the
    /// copy from the earlier source is the one kept, so the provider the
    /// user ranked first also owns the timing.
    public static func merge(_ sources: [[DanmakuComment]], options: Options = .default) -> [DanmakuComment] {
        let nonEmpty = sources.filter { !$0.isEmpty }
        guard nonEmpty.count > 1 else { return nonEmpty.first.map { sorted($0) } ?? [] }

        var accepted: [DanmakuComment] = []
        accepted.reserveCapacity(nonEmpty.reduce(0) { $0 + $1.count })
        // Times already accepted for each normalized text, kept sorted so a
        // duplicate check is a scan of one small bucket instead of the list.
        var timesByText: [String: [Double]] = [:]
        var seenIDs = Set<String>()

        for source in nonEmpty {
            for comment in sorted(source) {
                guard seenIDs.insert(comment.id).inserted else { continue }
                let key = normalize(comment.text)
                if isDistinctive(key, options: options) {
                    let bucket = timesByText[key, default: []]
                    if bucket.contains(where: { abs($0 - comment.time) <= options.timeWindow }) { continue }
                    timesByText[key, default: []].append(comment.time)
                }
                accepted.append(comment)
            }
        }
        return sorted(accepted)
    }

    /// Whether a text carries enough information that seeing it twice
    /// really does mean the two pools share a comment.
    static func isDistinctive(_ key: String, options: Options) -> Bool {
        key.count >= options.minimumTextLength
            && Set(key).count >= options.minimumDistinctCharacters
    }

    /// Folds away the differences that are not meaningful between pools:
    /// case, full/half width, diacritics, whitespace and punctuation.
    public static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
    }

    private static func sorted(_ comments: [DanmakuComment]) -> [DanmakuComment] {
        comments.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    }
}
