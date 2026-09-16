import Foundation

/// How well a release title matches the searched titles.
///
/// Ported from magnet-crawler's `relevance_score`: a whole-phrase hit beats
/// token coverage, and CJK text (no spaces) is covered by bigrams. Unlike the
/// original, scores are the best single query rather than a sum, so a batch
/// search with three aliases doesn't favor releases that echo all three.
public enum TorrentRelevance {
    public static func score(title: String, queries: [String]) -> Double {
        let text = fold(title)
        let compactText = text.filter { !$0.isWhitespace }
        return queries.map { query -> Double in
            let folded = fold(query)
            guard !folded.isEmpty else { return 0 }
            var score = 0.0
            if compactText.contains(folded.filter { !$0.isWhitespace }) { score += 2 }
            var covered = 0
            var total = 0
            for token in tokens(in: folded) {
                total += 1
                if text.contains(token) { covered += 1 }
            }
            for run in cjkRuns(in: folded) {
                let grams = run.count < 2 ? [run] : (0..<(run.count - 1)).map { index -> String in
                    let start = run.index(run.startIndex, offsetBy: index)
                    return String(run[start...run.index(after: start)])
                }
                total += grams.count
                covered += grams.filter { compactText.contains($0) }.count
            }
            if total > 0 { score += Double(covered) / Double(total) }
            return score
        }.max() ?? 0
    }

    /// Case, width and punctuation-insensitive text, so "BanG Dream! Ave
    /// Mujica" and "Bang Dream Ave-Mujica" compare equal.
    static func fold(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    private static func tokens(in folded: String) -> [String] {
        folded.split(separator: " ").map(String.init).filter { token in
            token.unicodeScalars.allSatisfy { $0.isASCII }
        }
    }

    private static func cjkRuns(in folded: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in folded {
            if character.unicodeScalars.allSatisfy({ !$0.isASCII && CharacterSet.letters.contains($0) }) {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

/// Merges per-index observations into one result per info hash.
///
/// Deterministic regardless of the order sources finish in, so results don't
/// shuffle while a search is still streaming in.
public enum TorrentResultMerger {
    public static func merge(_ observations: [TorrentObservation], queries: [String]) -> [TorrentSearchResult] {
        let order = Dictionary(uniqueKeysWithValues: TorrentSourceID.allCases.enumerated().map { ($1, $0) })
        let groups = Dictionary(grouping: observations, by: \.infoHash)
        let results = groups.map { hash, items -> TorrentSearchResult in
            let rows = items.sorted { lhs, rhs in
                let left = completeness(lhs), right = completeness(rhs)
                if left != right { return left > right }
                if order[lhs.source]! != order[rhs.source]! { return order[lhs.source]! < order[rhs.source]! }
                return (lhs.title, lhs.query) < (rhs.title, rhs.query)
            }
            let best = rows[0]
            let size = rows.first(where: { $0.sizeIsExact && $0.size != nil })?.size ?? rows.compactMap(\.size).first
            let seeders = rows.compactMap(\.seeders).max()
            let leechers = rows.compactMap(\.leechers).max()
            let category: TorrentCategory = rows.contains { $0.category == .batch } ? .batch
                : rows.first { $0.category != .other }?.category ?? .other
            var trackers: [String] = []
            for tracker in rows.flatMap(\.trackers) + TorrentTrackers.common where !trackers.contains(tracker) {
                trackers.append(tracker)
            }
            var pages: [TorrentSourceID: URL] = [:]
            for row in rows { if let url = row.pageURL, pages[row.source] == nil { pages[row.source] = url } }
            var release = TorrentReleaseInfo.parse(title: best.title)
            if category == .batch { release.isBatch = true }
            let matched = Array(Set(rows.map(\.query)).subtracting([""])).sorted()
            return TorrentSearchResult(
                infoHash: hash,
                title: best.title,
                size: size,
                seeders: seeders,
                leechers: leechers,
                publishedAt: rows.compactMap(\.publishedAt).min(),
                category: category,
                // Aggregators that name the fansub outrank title guesses.
                team: rows.sorted { order[$0.source]! < order[$1.source]! }.lazy.compactMap(\.team).first,
                sources: Array(Set(rows.map(\.source))).sorted { order[$0]! < order[$1]! },
                matchedQueries: matched,
                torrentURLs: Array(Set(rows.compactMap(\.torrentURL))).sorted { $0.absoluteString < $1.absoluteString },
                pageURLs: pages,
                trackers: trackers,
                release: release,
                relevance: TorrentRelevance.score(title: best.title, queries: matched.isEmpty ? queries : matched)
            )
        }
        return sort(results, by: .relevance)
    }

    /// A title with more of the facts that make it recognisable wins.
    private static func completeness(_ observation: TorrentObservation) -> Int {
        (observation.title.isEmpty ? 0 : 4)
            + (observation.size != nil ? 1 : 0)
            + (observation.publishedAt != nil ? 1 : 0)
            + (observation.seeders != nil ? 1 : 0)
    }

    public enum SortOrder: String, CaseIterable, Identifiable, Sendable {
        case relevance
        case newest
        case seeders
        case size

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .relevance: "Best Match"
            case .newest: "Newest"
            case .seeders: "Most Seeders"
            case .size: "Largest"
            }
        }
    }

    public static func sort(_ results: [TorrentSearchResult], by order: SortOrder) -> [TorrentSearchResult] {
        results.sorted { lhs, rhs in
            func tail() -> Bool {
                let left = (lhs.seeders ?? -1, lhs.publishedAt ?? .distantPast, lhs.size ?? -1)
                let right = (rhs.seeders ?? -1, rhs.publishedAt ?? .distantPast, rhs.size ?? -1)
                if left != right { return left > right }
                return lhs.infoHash < rhs.infoHash
            }
            switch order {
            case .relevance:
                // Relevance is bucketed so near-identical scores fall back to
                // recency — fansub titles differ by a bracket or two.
                let left = (lhs.relevance * 4).rounded(), right = (rhs.relevance * 4).rounded()
                if left != right { return left > right }
                if lhs.publishedAt != rhs.publishedAt { return (lhs.publishedAt ?? .distantPast) > (rhs.publishedAt ?? .distantPast) }
                return tail()
            case .newest:
                if lhs.publishedAt != rhs.publishedAt { return (lhs.publishedAt ?? .distantPast) > (rhs.publishedAt ?? .distantPast) }
                return tail()
            case .seeders:
                if lhs.seeders != rhs.seeders { return (lhs.seeders ?? -1) > (rhs.seeders ?? -1) }
                return tail()
            case .size:
                if lhs.size != rhs.size { return (lhs.size ?? -1) > (rhs.size ?? -1) }
                return tail()
            }
        }
    }
}
