import Foundation

/// The user's ranking preferences. Kept out of the scorer's logic so the
/// order "简体 ASS → 繁體 ASS → … → 繁體 SRT" is a setting, not code.
public struct SubtitleRankingPreferences: Codable, Hashable, Sendable {
    /// Preferred languages, best first. Languages not listed still appear
    /// in manual results but are never loaded automatically.
    public var languages: [SubtitleLanguage]
    /// Preferred formats, best first.
    public var formats: [SubtitleFormat]
    /// Minimum score (0...1) for a result to load without asking.
    public var autoLoadThreshold: Double

    public init(
        languages: [SubtitleLanguage] = [.simplifiedChinese, .traditionalChinese],
        formats: [SubtitleFormat] = [.ass, .ssa, .srt, .vtt],
        autoLoadThreshold: Double = 0.7
    ) {
        self.languages = languages
        self.formats = formats
        self.autoLoadThreshold = autoLoadThreshold
    }

    public static let `default` = SubtitleRankingPreferences()
}

/// Why a score is lower than it looks, or why it must not load on its own.
public enum SubtitleMatchWarning: String, Codable, Hashable, Sendable, CaseIterable {
    /// The subtitle is explicitly for another episode.
    case wrongEpisode
    /// The subtitle is explicitly for another season.
    case wrongSeason
    /// The subtitle's work title does not resemble the video's.
    case titleMismatch
    /// BD vs WEB (or similar): cuts and timing usually differ.
    case sourceMismatch
    /// A different release group; timing may be shifted.
    case groupMismatch
    /// The subtitle does not say which episode it is for.
    case unknownEpisode
    /// A season pack; the right file is chosen after download.
    case seasonPack
    case unpreferredLanguage
    case machineTranslated

    /// Warnings that forbid automatic loading however high the score is.
    public var blocksAutoLoad: Bool {
        switch self {
        case .wrongEpisode, .wrongSeason, .titleMismatch, .sourceMismatch, .unpreferredLanguage, .machineTranslated, .unknownEpisode:
            true
        case .groupMismatch, .seasonPack:
            false
        }
    }

    public var displayName: String {
        switch self {
        case .wrongEpisode: "Different episode"
        case .wrongSeason: "Different season"
        case .titleMismatch: "Title differs"
        case .sourceMismatch: "Different source (BD/WEB timing)"
        case .groupMismatch: "Different release group"
        case .unknownEpisode: "Episode not stated"
        case .seasonPack: "Season pack"
        case .unpreferredLanguage: "Not a preferred language"
        case .machineTranslated: "Machine translated"
        }
    }
}

/// How well one subtitle fits the playing video. Components are points
/// out of 100 so the breakdown reads naturally in diagnostics.
public struct SubtitleMatchScore: Codable, Hashable, Sendable {
    public var identity: Double
    public var episode: Double
    public var release: Double
    public var language: Double
    public var format: Double
    public var quality: Double
    /// A ceiling applied after summing, for disqualifying mismatches.
    public var cap: Double
    public var warnings: [SubtitleMatchWarning]

    /// 0...1.
    public var total: Double {
        let sum = identity + episode + release + language + format + quality
        return min(max(sum / 100, 0), cap)
    }

    public var percent: Int { Int((total * 100).rounded()) }

    public func isAutoLoadable(threshold: Double) -> Bool {
        total >= threshold && !warnings.contains(where: \.blocksAutoLoad)
    }
}

public struct ScoredSubtitle: Identifiable, Hashable, Sendable {
    public var result: SubtitleResult
    public var score: SubtitleMatchScore
    public var id: String { result.id }

    public init(result: SubtitleResult, score: SubtitleMatchScore) {
        self.result = result
        self.score = score
    }
}

/// Scores subtitles against the video. The weights encode one principle:
/// a subtitle is only as good as its timing, and timing follows the
/// release — so episode identity and release compatibility dominate, and
/// preferences (language, format) order what is left.
///
/// Budget (points of 100):
/// - identity 25 — is it the same work (hash / external ID / title)?
/// - episode 25 — the same episode, not a neighbour?
/// - release 25 — same group and source (BD vs WEB) as the video?
/// - language 15 — how high in the user's language list?
/// - format 7 — ASS/SSA keep fansub typesetting; SRT does not.
/// - quality 3 — popularity; machine translation is penalized.
///
/// Mismatches that make a subtitle *wrong* rather than merely worse
/// (another episode, another season, another title) cap the total so no
/// amount of preference points can lift it back up.
public struct SubtitleMatchScorer: Sendable {
    public var preferences: SubtitleRankingPreferences

    public init(preferences: SubtitleRankingPreferences = .default) {
        self.preferences = preferences
    }

    public func score(_ result: SubtitleResult, for video: SubtitleVideoIdentity) -> SubtitleMatchScore {
        var score = SubtitleMatchScore(
            identity: 0, episode: 0, release: 0, language: 0, format: 0, quality: 0, cap: 1, warnings: []
        )
        scoreIdentity(result, video, into: &score)
        scoreEpisode(result, video, into: &score)
        scoreRelease(result, video, into: &score)
        scoreLanguage(result, into: &score)
        scoreFormat(result, into: &score)
        scoreQuality(result, into: &score)
        return score
    }

    public func rank(_ results: [SubtitleResult], for video: SubtitleVideoIdentity) -> [ScoredSubtitle] {
        results
            .map { ScoredSubtitle(result: $0, score: score($0, for: video)) }
            .sorted { lhs, rhs in
                if lhs.score.total != rhs.score.total { return lhs.score.total > rhs.score.total }
                // Ties go to the more popular file, then to a stable order.
                let left = lhs.result.downloadCount ?? 0
                let right = rhs.result.downloadCount ?? 0
                if left != right { return left > right }
                return lhs.id < rhs.id
            }
    }

    /// The result to load without asking, or nil when nothing is confident
    /// enough. Only the top-ranked result is considered: loading a lower
    /// one automatically would override the ranking the user sees.
    public func automaticChoice(from ranked: [ScoredSubtitle]) -> ScoredSubtitle? {
        guard let best = ranked.first,
              best.score.isAutoLoadable(threshold: preferences.autoLoadThreshold) else { return nil }
        return best
    }

    // MARK: - Components

    private func scoreIdentity(_ result: SubtitleResult, _ video: SubtitleVideoIdentity, into score: inout SubtitleMatchScore) {
        let resultTitles = [result.title] + result.alternativeTitles
            + [result.releaseName, result.fileName].compactMap { $0 }.map { SubtitleReleaseParsing.parseFileName($0).title }
        let similarity = video.titles.flatMap { videoTitle in
            resultTitles.map { DanmakuTitleSimilarity.similarityOfRawTitles(videoTitle, $0) }
        }.max() ?? 0

        switch result.basis {
        case .fileHash:
            score.identity = 25
        case .externalID:
            score.identity = 22 + 3 * similarity
        case .title:
            score.identity = 22 * similarity
            if similarity < 0.45 {
                score.warnings.append(.titleMismatch)
                score.cap = min(score.cap, 0.35)
            }
        }

        // Season: an explicit, different season is a different work.
        let resultSeason = result.season
            ?? resultTitles.lazy.compactMap(DanmakuTitleSimilarity.seasonNumber(in:)).first
        if let resultSeason, result.basis != .fileHash {
            let expected = result.basis == .externalID ? (video.ids.tmdbSeason ?? video.effectiveSeason) : video.effectiveSeason
            if resultSeason != expected, !(resultSeason == 0 && result.isPack) {
                score.warnings.append(.wrongSeason)
                score.cap = min(score.cap, 0.3)
            }
        }
    }

    private func scoreEpisode(_ result: SubtitleResult, _ video: SubtitleVideoIdentity, into score: inout SubtitleMatchScore) {
        if result.isHashMatch {
            score.episode = 25
            return
        }
        guard let wanted = video.episode else {
            // A movie: subtitles that name no episode are for the film.
            score.episode = result.episode == nil || result.isPack ? 20 : 6
            return
        }
        if let first = result.episode {
            let last = result.episodeRangeEnd ?? first
            if result.isPack || last > first {
                if wanted >= first && wanted <= last {
                    score.episode = 17
                    score.warnings.append(.seasonPack)
                } else {
                    score.warnings.append(.wrongEpisode)
                    score.cap = min(score.cap, 0.15)
                }
            } else if first == wanted {
                score.episode = 25
            } else {
                score.warnings.append(.wrongEpisode)
                score.cap = min(score.cap, 0.15)
            }
        } else if result.isPack {
            score.episode = 14
            score.warnings.append(.seasonPack)
        } else {
            score.episode = 7
            score.warnings.append(.unknownEpisode)
        }
    }

    private func scoreRelease(_ result: SubtitleResult, _ video: SubtitleVideoIdentity, into score: inout SubtitleMatchScore) {
        if result.isHashMatch {
            score.release = 25
            return
        }
        let timed = result.timedRelease
        var points = 5.0

        let videoGroup = SubtitleReleaseParsing.normalizedGroup(video.releaseGroup)
        let subtitleGroup = SubtitleReleaseParsing.normalizedGroup(timed.group)
        if let videoGroup, let subtitleGroup {
            if videoGroup == subtitleGroup {
                points += 12
            } else {
                points -= 4
                score.warnings.append(.groupMismatch)
            }
        }

        if let videoSource = video.source, let subtitleSource = timed.videoSource {
            if videoSource == subtitleSource {
                points += 7
            } else {
                // BD releases drop broadcast cuts and re-time scenes; a WEB
                // subtitle on a BD encode drifts, and vice versa.
                points -= 12
                score.warnings.append(.sourceMismatch)
            }
        } else {
            points += 1
        }

        if let resolution = video.resolution, resolution == timed.resolution { points += 1 }

        let names = [result.releaseName, result.fileName].compactMap { $0 }
        let similarity = names.map { SubtitleReleaseParsing.releaseSimilarity(video.fileName, $0) }.max() ?? 0
        points += 5 * similarity

        score.release = min(max(points, 0), 25)
    }

    private func scoreLanguage(_ result: SubtitleResult, into score: inout SubtitleMatchScore) {
        let ranks = result.languages.compactMap(rank(of:))
        guard let best = ranks.max(by: { $0.points < $1.points }) else {
            score.language = 2
            score.warnings.append(.unpreferredLanguage)
            return
        }
        score.language = best.points
    }

    /// Points for one language: 15 for the first preference, then 12, 9,
    /// 7 … A script-less "Chinese" ranks just below the preferred script it
    /// could turn out to be.
    private func rank(of language: SubtitleLanguage) -> (index: Int, points: Double)? {
        func points(_ index: Int) -> Double { [15, 12, 9, 7, 5][min(index, 4)] }
        if let index = preferences.languages.firstIndex(of: language) {
            return (index, points(index))
        }
        if language == .chinese,
           let index = preferences.languages.firstIndex(where: { $0 == .simplifiedChinese || $0 == .traditionalChinese }) {
            return (index, points(index) - 3)
        }
        return nil
    }

    private func scoreFormat(_ result: SubtitleResult, into score: inout SubtitleMatchScore) {
        guard let format = result.format else {
            // Unknown until unpacked; archives usually hold ASS for anime.
            score.format = 4
            return
        }
        guard let index = preferences.formats.firstIndex(of: format) else {
            score.format = 1
            return
        }
        score.format = [7, 5.5, 3, 2][min(index, 3)]
    }

    private func scoreQuality(_ result: SubtitleResult, into score: inout SubtitleMatchScore) {
        let downloads = Double(max(result.downloadCount ?? 0, 0))
        score.quality = min(3, log10(downloads + 1))
        if result.isMachineTranslated {
            score.quality -= 10
            score.warnings.append(.machineTranslated)
        }
    }
}
