import Foundation

/// Metadata available locally when dandanplay's file-hash match cannot
/// identify an encode. Titles are aliases for the same work, ordered from
/// most authoritative (provider metadata) to least authoritative (filename).
public struct DanmakuSearchContext: Hashable, Sendable {
    public let titleCandidates: [String]
    public let episodeNumber: Double?
    public let episodeKind: EpisodeKind

    public init(titleCandidates: [String], episodeNumber: Double?, episodeKind: EpisodeKind) {
        self.titleCandidates = titleCandidates
        self.episodeNumber = episodeNumber
        self.episodeKind = episodeKind
    }
}

/// A directly selectable episode produced by metadata-assisted search.
public struct DanmakuEpisodeSuggestion: Identifiable, Hashable, Sendable {
    public let anime: DanmakuSearchedAnime
    public let episode: DanmakuSearchedEpisode
    public let score: Double
    public let matchedQuery: String

    public var id: Int64 { episode.episodeID }

    public init(
        anime: DanmakuSearchedAnime,
        episode: DanmakuSearchedEpisode,
        score: Double,
        matchedQuery: String
    ) {
        self.anime = anime
        self.episode = episode
        self.score = score
        self.matchedQuery = matchedQuery
    }
}

public struct DanmakuSearchResponse: Hashable, Sendable {
    public let query: String
    public let queryIndex: Int
    public let anime: [DanmakuSearchedAnime]

    public init(query: String, queryIndex: Int, anime: [DanmakuSearchedAnime]) {
        self.query = query
        self.queryIndex = queryIndex
        self.anime = anime
    }
}

/// Turns local library metadata into a small set of real API searches, then
/// ranks the returned episodes. It intentionally does not stuff the raw file
/// name into a search field: release groups and codec tags are poor title
/// signals and produce noisy results.
public enum DanmakuAutoMatcher {
    public static func searchQueries(for context: DanmakuSearchContext, limit: Int = 3) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var queries: [String] = []
        for title in context.titleCandidates {
            let query = cleanedQuery(title)
            let key = normalized(query)
            guard !query.isEmpty, key.count >= 2, seen.insert(key).inserted else { continue }
            queries.append(query)
            if queries.count == limit { break }
        }
        return queries
    }

    public static func rank(
        responses: [DanmakuSearchResponse],
        context: DanmakuSearchContext,
        limit: Int = 12
    ) -> [DanmakuEpisodeSuggestion] {
        let aliases = context.titleCandidates.map(normalized).filter { !$0.isEmpty }
        var bestByEpisodeID: [Int64: DanmakuEpisodeSuggestion] = [:]

        for response in responses {
            for (animeIndex, anime) in response.anime.enumerated() {
                let candidateTitle = normalized(anime.animeTitle)
                let aliasScore = aliases.map { titleSimilarity($0, candidateTitle) }.max() ?? 0
                // A result returned for an authoritative alias remains useful
                // even when the provider localizes the displayed title.
                let queryTrust = max(0.68, 1 - Double(response.queryIndex) * 0.08)
                let resultOrder = max(0.55, 1 - Double(animeIndex) * 0.04)
                let titleScore = max(aliasScore, queryTrust * resultOrder * 0.82)

                for (episodeIndex, episode) in anime.episodes.enumerated() {
                    let episodeScore = episodeRelevance(
                        episode,
                        index: episodeIndex,
                        desiredNumber: context.episodeNumber,
                        desiredKind: context.episodeKind
                    )
                    let total = titleScore * 0.68 + episodeScore * 0.32
                    let suggestion = DanmakuEpisodeSuggestion(
                        anime: anime,
                        episode: episode,
                        score: total,
                        matchedQuery: response.query
                    )
                    if suggestion.score > (bestByEpisodeID[episode.episodeID]?.score ?? -.infinity) {
                        bestByEpisodeID[episode.episodeID] = suggestion
                    }
                }
            }
        }

        return bestByEpisodeID.values
            .sorted {
                if abs($0.score - $1.score) > 0.0001 { return $0.score > $1.score }
                if $0.anime.animeTitle != $1.anime.animeTitle {
                    return $0.anime.animeTitle.localizedStandardCompare($1.anime.animeTitle) == .orderedAscending
                }
                return $0.episode.episodeID < $1.episode.episodeID
            }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    private static func cleanedQuery(_ title: String) -> String {
        var value = title
        let noise = [
            #"^\s*[\[【][^\]】]+[\]】]\s*"#,
            #"(?i)\[[^\]]*(?:1080p|2160p|720p|x26[45]|hevc|av1|flac|aac|web-?dl|blu-?ray)[^\]]*\]"#,
            #"(?i)\b(?:1080p|2160p|720p|480p|4k|x26[45]|hevc|av1|web-?dl|blu-?ray|bdrip|remux|10bit|hdr)\b"#,
            #"\s+"#
        ]
        value = value.replacingOccurrences(of: noise[0], with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: noise[1], with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: noise[2], with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: noise[3], with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.[]【】")))
    }

    private static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"(?i)\b(?:season|part)\s*\d+\b|第\s*[一二三四五六七八九十百\d]+\s*季"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }

    private static func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
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

    private static func bigrams(_ value: String) -> Set<String> {
        let characters = Array(value)
        guard characters.count > 1 else { return Set(characters.map(String.init)) }
        return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
    }

    private static func episodeRelevance(
        _ episode: DanmakuSearchedEpisode,
        index: Int,
        desiredNumber: Double?,
        desiredKind: EpisodeKind
    ) -> Double {
        let title = episode.episodeTitle
        let kindMatches = episodeKind(in: title) == desiredKind
        guard let desiredNumber else { return kindMatches ? 0.8 : 0.48 }

        if let number = episodeNumber(in: title) {
            let difference = abs(number - desiredNumber)
            if difference < 0.001 { return kindMatches ? 1 : 0.92 }
            if difference <= 1 { return max(0.18, 0.55 - difference * 0.25) }
            return 0.08
        }

        // Some providers return episode names without a visible number. The
        // array order is a useful fallback only for ordinary integer episodes.
        if desiredKind == .regular,
           desiredNumber.rounded() == desiredNumber,
           index + 1 == Int(desiredNumber) {
            return 0.76
        }
        return kindMatches ? 0.42 : 0.18
    }

    private static func episodeNumber(in title: String) -> Double? {
        let patterns = [
            #"(?i)\bS\d{1,2}E(\d{1,4}(?:\.\d+)?)\b"#,
            #"第\s*(\d{1,4}(?:\.\d+)?)\s*[集话話回]"#,
            #"(?i)\b(?:EP?|Episode|SP|Special)\s*[-_. ]?\s*(\d{1,4}(?:\.\d+)?)\b"#,
            #"^\s*(\d{1,4}(?:\.\d+)?)\s*(?:[.、:\-]|$)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: title) else { continue }
            if let number = Double(title[range]) { return number }
        }
        return nil
    }

    private static func episodeKind(in title: String) -> EpisodeKind {
        if title.range(of: #"(?i)\b(?:SP|Special|OVA|OAD)\b|特别篇|特別篇"#, options: .regularExpression) != nil { return .special }
        if title.range(of: #"(?i)\b(?:PV|Trailer|Teaser)\b|预告|預告"#, options: .regularExpression) != nil { return .trailer }
        if title.range(of: #"(?i)\bNCOP\b"#, options: .regularExpression) != nil { return .opening }
        if title.range(of: #"(?i)\bNCED\b"#, options: .regularExpression) != nil { return .ending }
        if title.range(of: #"(?i)\bMV\b|Music Video"#, options: .regularExpression) != nil { return .music }
        return .regular
    }
}
