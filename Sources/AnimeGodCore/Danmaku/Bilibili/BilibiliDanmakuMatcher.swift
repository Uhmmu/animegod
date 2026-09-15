import Foundation

/// A resolved Bilibili danmaku pool with the evidence that chose it.
public struct BilibiliMatchCandidate: Hashable, Sendable {
    /// The danmaku pool id — always the part's own `cid`.
    public let cid: Int64
    public let aid: Int64?
    public let bvid: String?
    public let seasonID: Int64?
    public let episodeID: Int64?
    public let animeTitle: String
    public let episodeTitle: String
    public let typeDescription: String
    /// Bilibili's duration for this part, in seconds.
    public let duration: Double?
    public let episodeNumber: Double?
    public let score: Double

    public init(
        cid: Int64,
        aid: Int64? = nil,
        bvid: String? = nil,
        seasonID: Int64? = nil,
        episodeID: Int64? = nil,
        animeTitle: String,
        episodeTitle: String,
        typeDescription: String,
        duration: Double? = nil,
        episodeNumber: Double? = nil,
        score: Double
    ) {
        self.cid = cid
        self.aid = aid
        self.bvid = bvid
        self.seasonID = seasonID
        self.episodeID = episodeID
        self.animeTitle = animeTitle
        self.episodeTitle = episodeTitle
        self.typeDescription = typeDescription
        self.duration = duration
        self.episodeNumber = episodeNumber
        self.score = score
    }

    public var context: BilibiliDanmakuContext {
        BilibiliDanmakuContext(
            cid: cid, aid: aid, bvid: bvid, seasonID: seasonID,
            episodeID: episodeID, duration: duration
        )
    }

    public var matchCandidate: DanmakuMatchCandidate {
        DanmakuMatchCandidate(
            // The season is the closest thing Bilibili has to an "anime id";
            // UGC submissions fall back to their aid.
            animeID: seasonID ?? aid ?? 0,
            animeTitle: animeTitle,
            episodeID: cid,
            episodeTitle: episodeTitle,
            shift: 0,
            typeDescription: typeDescription,
            providerContext: context.encoded()
        )
    }
}

/// Ranks Bilibili search results against what the local library knows.
///
/// Deliberately pure and synchronous: picking the right season out of a
/// noisy search page is the part most likely to be wrong, so it must be
/// testable without touching the network. Nothing here decides on its own —
/// the caller keeps the whole ranked list so the user can override it.
public enum BilibiliDanmakuMatcher {
    /// Everything known locally about the file being played.
    public struct Context: Hashable, Sendable {
        public let titleCandidates: [String]
        public let episodeNumber: Double?
        public let episodeKind: EpisodeKind
        /// The local file's duration in seconds, when known.
        public let duration: Double?
        /// Season number from the local library, when known.
        public let seasonNumber: Int?

        public init(
            titleCandidates: [String],
            episodeNumber: Double?,
            episodeKind: EpisodeKind = .regular,
            duration: Double? = nil,
            seasonNumber: Int? = nil
        ) {
            self.titleCandidates = titleCandidates
            self.episodeNumber = episodeNumber
            self.episodeKind = episodeKind
            self.duration = duration
            self.seasonNumber = seasonNumber
        }
    }

    /// Below this, a candidate is offered for manual confirmation but never
    /// auto-selected. A wrong auto-match is worse than no danmaku: it puts
    /// another show's comments over the video.
    public static let automaticSelectionThreshold = 0.72

    /// How far a single episode may out-score the work it belongs to.
    ///
    /// Matching an episode number is nearly free — every season has an
    /// episode 1 — so without this cap a mediocre title match plus a perfect
    /// episode match clears the auto-selection bar, and a sibling season
    /// ("BanG Dream! Ave Mujica" for "BanG Dream! YUME∞MITA") gets bound
    /// automatically. Confidence in an episode can never meaningfully exceed
    /// confidence in the work that contains it.
    static let episodeConfidenceHeadroom = 0.12

    /// Combines a work-level score with an episode-level one under that cap.
    static func combine(sourceScore: Double, episodeScore: Double) -> Double {
        min(sourceScore * 0.58 + episodeScore * 0.42, sourceScore + episodeConfidenceHeadroom)
    }

    // MARK: - Ranking search hits

    /// Scores search hits so only the plausible ones are expanded into full
    /// episode lists. Expanding every hit would be a request per result.
    public static func rankHits(_ hits: [BilibiliSearchHit], context: Context) -> [(hit: BilibiliSearchHit, score: Double)] {
        hits
            .map { (hit: $0, score: hitScore($0, context: context)) }
            .filter { $0.score > 0.3 }
            .sorted { $0.score > $1.score }
    }

    static func hitScore(_ hit: BilibiliSearchHit, context: Context) -> Double {
        switch hit {
        case let .bangumi(item):
            let title = max(
                titleScore(item.title, context: context),
                titleScore(item.originalTitle, context: context)
            )
            // A licensed season is a far better danmaku source than a
            // re-upload: the pool is the official one and the cut matches.
            let typeBonus = item.seasonTypeName.isEmpty ? 0 : 0.06
            let seasonBonus = seasonAgreement(
                candidate: DanmakuTitleSimilarity.seasonNumber(in: item.title),
                desired: context.seasonNumber
            )
            return min(1, title * 0.86 + typeBonus + seasonBonus)
        case let .video(item):
            let title = titleScore(item.title, context: context)
            // UGC results are mostly clips, reaction videos and AMVs.
            var score = title * 0.7
            if let wanted = context.duration, let actual = item.duration {
                score += durationAgreement(local: wanted, candidate: actual) * 0.18
            }
            if let number = context.episodeNumber, mentions(episode: number, in: item.title) {
                score += 0.1
            }
            return min(1, score)
        }
    }

    // MARK: - Ranking episodes within a season

    public static func rankSeasonEpisodes(
        _ season: BilibiliBangumiSeason,
        seasonScore: Double,
        context: Context
    ) -> [BilibiliMatchCandidate] {
        season.episodes.enumerated().compactMap { index, episode in
            guard episode.cid > 0 else { return nil }
            let episodeScore = episodeScore(
                number: episode.episodeNumber,
                index: index,
                title: episode.displayTitle,
                duration: episode.duration,
                context: context
            )
            return BilibiliMatchCandidate(
                cid: episode.cid,
                aid: episode.aid > 0 ? episode.aid : nil,
                bvid: episode.bvid.isEmpty ? nil : episode.bvid,
                seasonID: season.seasonID,
                episodeID: episode.episodeID > 0 ? episode.episodeID : nil,
                animeTitle: season.title,
                episodeTitle: episode.displayTitle,
                typeDescription: season.seasonTypeName,
                duration: episode.duration > 0 ? episode.duration : nil,
                episodeNumber: episode.episodeNumber,
                score: combine(sourceScore: seasonScore, episodeScore: episodeScore)
            )
        }
    }

    /// Ranks the parts of a UGC submission.
    ///
    /// The per-part `cid` is what makes this worth doing: a submission that
    /// packs a whole season into 12 parts has 12 separate danmaku pools, and
    /// the top-level `cid` only ever addresses the first one.
    public static func rankVideoParts(
        _ video: BilibiliVideo,
        videoScore: Double,
        context: Context
    ) -> [BilibiliMatchCandidate] {
        let parts = video.parts.isEmpty
            ? [BilibiliVideoPart(cid: 0, page: 1, title: video.title, duration: video.duration)]
            : video.parts
        return parts.compactMap { part in
            guard part.cid > 0 else { return nil }
            let number = episodeNumber(in: part.title) ?? (video.parts.count > 1 ? Double(part.page) : nil)
            let score = episodeScore(
                number: number,
                index: part.page - 1,
                title: part.title,
                duration: part.duration,
                context: context
            )
            return BilibiliMatchCandidate(
                cid: part.cid,
                aid: video.aid > 0 ? video.aid : nil,
                bvid: video.bvid.isEmpty ? nil : video.bvid,
                seasonID: nil,
                episodeID: nil,
                animeTitle: video.title,
                episodeTitle: part.title.isEmpty ? "P\(part.page)" : part.title,
                typeDescription: video.typeName,
                duration: part.duration > 0 ? part.duration : nil,
                episodeNumber: number,
                score: combine(sourceScore: videoScore, episodeScore: score)
            )
        }
    }

    /// Final ordering across every expanded source.
    public static func rank(_ candidates: [BilibiliMatchCandidate], limit: Int = 20) -> [BilibiliMatchCandidate] {
        var bestByCID: [Int64: BilibiliMatchCandidate] = [:]
        for candidate in candidates where candidate.score > (bestByCID[candidate.cid]?.score ?? -.infinity) {
            bestByCID[candidate.cid] = candidate
        }
        return bestByCID.values
            .sorted {
                if abs($0.score - $1.score) > 0.0001 { return $0.score > $1.score }
                return $0.cid < $1.cid
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    // MARK: - Scoring pieces

    static func titleScore(_ candidate: String, context: Context) -> Double {
        let normalizedCandidate = DanmakuTitleSimilarity.normalize(candidate)
        guard !normalizedCandidate.isEmpty else { return 0 }
        return context.titleCandidates
            .map { DanmakuTitleSimilarity.similarity(DanmakuTitleSimilarity.normalize($0), normalizedCandidate) }
            .max() ?? 0
    }

    static func seasonAgreement(candidate: Int?, desired: Int?) -> Double {
        // An unstated season means "the first one" on both sides, so an
        // unmarked title and a desired season 1 still agree.
        let left = candidate ?? 1
        let right = desired ?? 1
        if desired == nil && candidate == nil { return 0 }
        return left == right ? 0.08 : -0.2
    }

    /// 1 for a duration within a few seconds, decaying to 0 by two minutes.
    /// Encodes differ by trimmed logos and credits, so this is a tiebreaker,
    /// never a gate.
    static func durationAgreement(local: Double, candidate: Double) -> Double {
        guard local > 0, candidate > 0 else { return 0 }
        let difference = abs(local - candidate)
        if difference <= 5 { return 1 }
        if difference >= 120 { return 0 }
        return max(0, 1 - (difference - 5) / 115)
    }

    static func episodeScore(
        number: Double?,
        index: Int,
        title: String,
        duration: Double,
        context: Context
    ) -> Double {
        var score: Double
        if let desired = context.episodeNumber {
            if let number {
                let difference = abs(number - desired)
                if difference < 0.001 {
                    score = 1
                } else if difference <= 1 {
                    score = max(0.18, 0.5 - difference * 0.25)
                } else {
                    score = 0.05
                }
            } else if mentions(episode: desired, in: title) {
                score = 0.85
            } else if desired.rounded() == desired, index + 1 == Int(desired) {
                // Positional fallback, only for plain integer episodes.
                score = 0.7
            } else {
                score = 0.2
            }
        } else {
            score = 0.55
        }
        if let local = context.duration, duration > 0 {
            // Duration confirms or contradicts, within a small band.
            score = min(1, score + (durationAgreement(local: local, candidate: duration) - 0.5) * 0.2)
        }
        if context.episodeKind != .regular, !mentionsSpecial(title) { score -= 0.15 }
        return max(0, score)
    }

    static func mentions(episode: Double, in title: String) -> Bool {
        guard episode.rounded() == episode else { return false }
        let number = Int(episode)
        let patterns = [
            #"第\s*0*\#(number)\s*[集话話回]"#,
            #"(?i)\bE(?:P)?\s*0*\#(number)\b"#,
            #"^\s*0*\#(number)\s*(?:[.、:\-]|$)"#
        ]
        return patterns.contains { title.range(of: $0, options: .regularExpression) != nil }
    }

    static func mentionsSpecial(_ title: String) -> Bool {
        title.range(of: #"(?i)\b(?:SP|Special|OVA|OAD|PV|NCOP|NCED)\b|特别篇|特別篇|番外"#, options: .regularExpression) != nil
    }

    static func episodeNumber(in title: String) -> Double? {
        let patterns = [
            #"第\s*(\d{1,4}(?:\.\d+)?)\s*[集话話回]"#,
            #"(?i)\bE(?:P|pisode)?\s*[-_. ]?\s*(\d{1,4}(?:\.\d+)?)\b"#,
            #"^\s*(\d{1,4}(?:\.\d+)?)\s*(?:[.、:\-]|$)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: title),
                  let value = Double(title[range]) else { continue }
            return value
        }
        return nil
    }
}
