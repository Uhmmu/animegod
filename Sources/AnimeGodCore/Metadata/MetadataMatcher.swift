import Foundation

/// The outcome of comparing a local title with provider candidates.
/// The default policy is best-effort: the strongest candidate links
/// automatically unless it is plainly unrelated, and clearly dubious hits
/// surface for a quick human pass instead of blocking enrichment.
public enum MatchTier: Sendable {
    case automatic(RankedMatch)
    case review([RankedMatch])
    case none
}

public struct RankedMatch: Identifiable, Hashable, Sendable {
    public let candidate: AnimeMetadataCandidate
    public let score: Double
    public var id: String { candidate.id }

    public init(candidate: AnimeMetadataCandidate, score: Double) {
        self.candidate = candidate
        self.score = score
    }
}

public struct MetadataMatcher: Sendable {
    /// Strong candidates link automatically (best-effort default).
    public static let automaticThreshold = 0.5
    /// Weak-but-nonzero candidates wait in the review queue.
    public static let reviewThreshold = 0.3

    public init() {}

    public func decide(localTitle: String, candidates: [AnimeMetadataCandidate]) -> MatchTier {
        let ranked = rank(localTitle: localTitle, candidates: candidates)
        guard let best = ranked.first, best.score >= Self.reviewThreshold else { return .none }
        if best.score >= Self.automaticThreshold {
            return .automatic(best)
        }
        return .review(Array(ranked.prefix(5)))
    }

    public func rank(localTitle: String, candidates: [AnimeMetadataCandidate]) -> [RankedMatch] {
        candidates
            .map { RankedMatch(candidate: $0, score: score(localTitle: localTitle, candidate: $0)) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                // Deterministic order when scores tie.
                return $0.id < $1.id
            }
    }

    public func score(localTitle: String, candidate: AnimeMetadataCandidate) -> Double {
        let local = normalize(localTitle)
        guard !local.isEmpty else { return 0 }
        let options = [normalize(candidate.title), normalize(candidate.originalTitle)]
        if options.contains(local) { return 1 }
        if options.contains(where: { $0.contains(local) || local.contains($0) }) { return 0.86 }

        let localTokens = tokenSet(localTitle)
        let candidateTokens = tokenSet(candidate.title + " " + candidate.originalTitle)
        guard !localTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }
        let intersection = localTokens.intersection(candidateTokens).count
        let union = localTokens.union(candidateTokens).count
        return Double(intersection) / Double(union) * 0.8
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }

    private func tokenSet(_ value: String) -> Set<String> {
        Set(value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty })
    }
}
