import Foundation

/// What a search says about a show's release rhythm: how far the fansubs have
/// got, how often a new episode appears, and therefore whether the season is
/// still running.
///
/// This is what tells "a finished 12-episode season" apart from "a season
/// that is ten episodes in" — the question a Subscribe button has to answer,
/// because subscribing to a show nobody will publish another episode of is
/// a rule that never fires. Neither answer is available from a single
/// release: it takes the whole result set (the highest episode *anyone*
/// published) plus the dates those episodes appeared.
public struct TorrentReleaseSchedule: Hashable, Sendable {
    /// The highest episode number any source in the search published.
    public var latestEpisode: Double?
    /// Distinct episode numbers seen, for "10 episodes out".
    public var episodeCount: Int
    /// When the newest episode first appeared on any index.
    public var lastPublishedAt: Date?
    /// The typical gap between one episode's first appearance and the next's.
    /// A median rather than a mean: one mid-season break would otherwise
    /// stretch the estimate by weeks.
    public var averageInterval: TimeInterval?
    /// What the metadata says the season is, when the caller knows.
    public var expectedEpisodeCount: Int?
    /// A fansub said this was the last one — `[END]`, `[完]`, `[最終回]` on the
    /// newest episode, or a full-season pack reaching it.
    public var isMarkedFinished: Bool = false
    /// The season is still being published, so new episodes are worth
    /// waiting for.
    public var isOngoing: Bool
    /// When the next episode is due, at the observed cadence. Nil when the
    /// cadence is unknown or the season looks finished.
    public var estimatedNextEpisodeAt: Date?

    /// Every episode the fansubs still owe, when the metadata says how long
    /// the season is.
    public var remainingEpisodeCount: Int? {
        guard let expectedEpisodeCount, let latestEpisode else { return nil }
        return max(0, expectedEpisodeCount - Int(latestEpisode))
    }

    /// The episode a subscription is waiting for.
    public var nextEpisode: Double? {
        latestEpisode.map { $0 + 1 }
    }

    // MARK: - Tuning

    /// A season nobody has added to in this long has stopped, whatever its
    /// cadence says — the floor for shows that published two episodes a week
    /// apart and then ended.
    static let silenceBeforeFinished: TimeInterval = 16 * 24 * 3600
    /// How many cadences of silence still counts as "between episodes".
    static let silenceIntervalMultiple: Double = 2.5
    /// How close two runs' newest episodes have to be for both to count as
    /// "being published now" — one broadcast slot, give or take.
    static let concurrentRunWindow: TimeInterval = 10 * 24 * 3600
    /// A gap longer than this is not a broadcast schedule — it is two
    /// unrelated releases of an old show, and no next episode is coming.
    static let maximumBroadcastInterval: TimeInterval = 45 * 24 * 3600

    /// Reads the rhythm out of a search's results.
    ///
    /// Only single episodes of the season being searched count: batches
    /// publish on their own schedule (and all at once), and a 12.5 recap
    /// would report a half-episode cadence.
    public static func analyse(
        results: [TorrentSearchResult],
        expectedEpisodeCount: Int? = nil,
        ownedEpisodes: Set<Double> = [],
        now: Date = .now
    ) -> TorrentReleaseSchedule {
        /// The first time each episode number showed up anywhere.
        var firstSeen: [Double: Date] = [:]
        var episodes: Set<Double> = []
        /// Episodes a fansub tagged as the finale, and the highest episode any
        /// full-season pack covers. Both are the teams themselves saying the
        /// season is over, which is worth more than any inference from dates.
        var finaleEpisodes: Set<Double> = []
        var batchReach: Double = 0
        for result in results {
            if result.release.isBatch,
               let first = result.release.firstEpisode, first <= 2,
               let last = result.release.lastEpisode, last > batchReach {
                batchReach = last
            }
            guard !result.release.isBatch,
                  result.category == .episode || result.category == .raw,
                  result.relevance >= TorrentResultFilter.relatedThreshold,
                  let episode = result.release.firstEpisode,
                  episode == episode.rounded(),
                  episode >= 0,
                  episode <= TorrentEpisodeSetBuilder.maximumEpisode,
                  (result.release.lastEpisode ?? episode) == episode
            else { continue }
            episodes.insert(episode)
            if marksFinale(result.title) { finaleEpisodes.insert(episode) }
            guard let published = result.publishedAt else { continue }
            if let existing = firstSeen[episode], existing <= published { continue }
            firstSeen[episode] = published
        }
        // An episode only the library has still counts towards how far the
        // season has got — the indexes drop old listings.
        episodes.formUnion(ownedEpisodes.filter { $0 == $0.rounded() && $0 >= 0 })
        guard !episodes.isEmpty else {
            return TorrentReleaseSchedule(
                latestEpisode: nil,
                episodeCount: 0,
                lastPublishedAt: nil,
                averageInterval: nil,
                expectedEpisodeCount: expectedEpisodeCount,
                isMarkedFinished: false,
                isOngoing: false,
                estimatedNextEpisodeAt: nil
            )
        }

        // Everything is measured over one run of episode numbers — the one
        // being published now. A search for a long-running show returns the
        // sequel that restarted at 1 alongside the line still counting 29–38,
        // and averaging across both would report a cadence of months and an
        // episode number from the wrong season. The run is chosen by date
        // rather than by number, because either of the two can be the
        // higher-numbered one.
        let runs = TorrentEpisodeSetBuilder.runs(in: episodes)
        // Recency picks the season, but not on its own: a long-running show is
        // published under two numbering schemes at once — One Piece is both
        // `1179` and `S23E25`, both current, both weekly — and the shorter of
        // the two would otherwise be reported as the whole season. Among the
        // runs that are all equally current, the one with the most episodes is
        // the one the search is really about.
        let newestOverall = runs.map { newest(of: $0, in: firstSeen) }.max() ?? .distantPast
        let current = runs
            .filter { newest(of: $0, in: firstSeen) >= newestOverall.addingTimeInterval(-concurrentRunWindow) }
            .max { lhs, rhs in
                (lhs.count, newest(of: lhs, in: firstSeen)) < (rhs.count, newest(of: rhs, in: firstSeen))
            } ?? []
        let dated = current.compactMap { episode in firstSeen[episode].map { (episode, $0) } }
            .sorted { $0.0 < $1.0 }
        let interval = medianInterval(of: dated.map(\.1))
        let latest = current.max() ?? episodes.max()
        let lastPublished = dated.last?.1 ?? firstSeen.values.max()
        let countInRun = current.isEmpty ? episodes.count : current.count

        // The teams' own word for it, about the episode that is actually the
        // newest: a finale tag on episode 12 of a season now up to 13 is a
        // split cour that carried on.
        let finished = latest.map { finaleEpisodes.contains($0) || batchReach >= $0 } ?? false
        // A season length the caller looked up by title is evidence, not
        // authority: searching "Sousou no Frieren" confidently matches a
        // 12-episode spin-off, and a show numbered continuously across seasons
        // is at episode 38 of a 28-episode wiki entry. Episode 20 cannot exist
        // in a twelve-episode season, so when the count contradicts what the
        // indexes plainly hold, the indexes win and the count is dropped.
        let expected = expectedEpisodeCount.flatMap { count -> Int? in
            guard count > 0 else { return nil }
            guard let latest, Int(latest) > count else { return count }
            return nil
        }
        let ongoing = !finished && isOngoing(
            latestEpisode: latest,
            expectedEpisodeCount: expected,
            lastPublishedAt: lastPublished,
            interval: interval,
            now: now
        )
        return TorrentReleaseSchedule(
            latestEpisode: latest,
            episodeCount: countInRun,
            lastPublishedAt: lastPublished,
            averageInterval: interval,
            expectedEpisodeCount: expected,
            isMarkedFinished: finished,
            isOngoing: ongoing,
            estimatedNextEpisodeAt: ongoing
                ? nextAirDate(after: lastPublished, interval: interval, now: now)
                : nil
        )
    }

    /// Words a fansub puts on the last episode of a season.
    ///
    /// Two teams tagged episode 12 of スーパーの裏でヤニ吸うふたり `[END]` three
    /// days after it aired, while every date-based test still read the season
    /// as running — a weekly show is *supposed* to be three days since its
    /// last episode. The teams know when they are done, and they say so.
    private static let finaleMarkers: Set<String> = [
        "end", "fin", "完", "完结", "完結", "终", "終",
        "最終回", "最终回", "最終話", "最终话", "全剧终", "全劇終"
    ]

    /// Whether a release title carries one of those markers.
    ///
    /// Matched against whole tokens only, never as a substring: `終` is a
    /// token in `[終]` and a letter in `少女終末旅行`, and `end` is a word in
    /// `The End` and three letters in `Legend`.
    static func marksFinale(_ title: String) -> Bool {
        let separators = CharacterSet(charactersIn: " \t_-.·~/|+&")
            .union(CharacterSet(charactersIn: "[](){}【】（）〔〕"))
        return title.components(separatedBy: separators)
            .contains { finaleMarkers.contains($0.lowercased()) }
    }

    /// When a run of episodes was last added to; distantPast when no index
    /// dated any of them, so a dated run always wins.
    private static func newest(of run: [Double], in firstSeen: [Double: Date]) -> Date {
        run.compactMap { firstSeen[$0] }.max() ?? .distantPast
    }

    /// Still running when the metadata says episodes are outstanding, or —
    /// with no metadata — when the newest episode is recent enough that the
    /// next one is still plausibly on its way.
    private static func isOngoing(
        latestEpisode: Double?,
        expectedEpisodeCount: Int?,
        lastPublishedAt: Date?,
        interval: TimeInterval?,
        now: Date
    ) -> Bool {
        guard let lastPublishedAt, let latestEpisode, latestEpisode > 0 else { return false }
        let silence = now.timeIntervalSince(lastPublishedAt)
        // A date in the future is a bad index timestamp, not a broadcast.
        guard silence > -7 * 24 * 3600 else { return false }
        if let expectedEpisodeCount, expectedEpisodeCount > 0 {
            // The season is known to be longer than what is out: the only
            // reason to call that finished is that publishing plainly
            // stopped, which "a year ago" is and "last week" is not.
            guard Int(latestEpisode) < expectedEpisodeCount else { return false }
            return silence < max(silenceBeforeFinished, (interval ?? 0) * silenceIntervalMultiple)
        }
        guard let interval, interval > 0, interval <= maximumBroadcastInterval else {
            // One episode, or every episode published the same day: fall
            // back on recency alone.
            return silence < silenceBeforeFinished
        }
        return silence < max(silenceBeforeFinished, interval * silenceIntervalMultiple)
    }

    /// The next slot in the observed cadence that has not already passed.
    private static func nextAirDate(after last: Date?, interval: TimeInterval?, now: Date) -> Date? {
        guard let last, let interval, interval > 0 else { return nil }
        var next = last.addingTimeInterval(interval)
        // A late episode is still due: keep stepping until the estimate is
        // ahead of now rather than showing a date in the past.
        var steps = 0
        while next < now, steps < 64 {
            next = next.addingTimeInterval(interval)
            steps += 1
        }
        return next
    }

    /// The median gap between consecutive dates, ignoring gaps a broadcast
    /// schedule would never produce.
    static func medianInterval(of dates: [Date]) -> TimeInterval? {
        guard dates.count >= 2 else { return nil }
        let sorted = dates.sorted()
        var gaps: [TimeInterval] = []
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            let gap = next.timeIntervalSince(previous)
            // Two encodes of one episode hours apart, or a season dumped in
            // an afternoon, say nothing about the weekly rhythm.
            guard gap >= 6 * 3600, gap <= maximumBroadcastInterval else { continue }
            gaps.append(gap)
        }
        guard !gaps.isEmpty else { return nil }
        gaps.sort()
        let middle = gaps.count / 2
        return gaps.count.isMultiple(of: 2) ? (gaps[middle - 1] + gaps[middle]) / 2 : gaps[middle]
    }
}
