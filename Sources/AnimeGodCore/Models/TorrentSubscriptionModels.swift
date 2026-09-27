import Foundation

/// A standing rule: keep watching the indexes for new episodes of one anime
/// and download the ones that fit.
///
/// Two ways in. Filling the form by hand is the expert path — fansub,
/// resolution, subtitle language, keywords — and is still there. The normal
/// path is one click on an unfinished season in Find Releases: everything
/// below is then learned from the set that was downloaded, including the
/// folder its episodes live in and the shape of their filenames, so episode
/// 11 lands beside the ten already on disk and looks like them.
public struct TorrentSubscription: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The library title this follows, when it was created from one.
    public var animeID: UUID?
    public var title: String
    /// Names to search, as a release search would (Chinese, original, romaji).
    public var queries: [String]
    /// Empty means "whichever sources are enabled".
    public var sources: Set<TorrentSourceID>
    public var group: String?
    public var resolution: String?
    public var subtitleLanguages: Set<TorrentSubtitleLanguage>
    /// The rest of the release line's identity, so a rule made from a set
    /// keeps following that exact line rather than the team's other encodes.
    public var videoCodec: String?
    public var videoSource: String?
    public var season: Int?
    /// Every one of these must appear in the title.
    public var includeKeywords: [String]
    /// Any one of these rejects a release.
    public var excludeKeywords: [String]
    /// Ignore episodes at or below this number (episodes already watched
    /// elsewhere, or a season starting mid-count).
    public var minimumEpisode: Double?
    /// Batches are off by default: a subscription is for new episodes, and a
    /// season pack would re-download everything.
    public var includesBatches: Bool
    /// Off by default: a subscription follows what appears from now on. With
    /// it on, the first check also fetches everything already published —
    /// which for a running season is dozens of episodes at once.
    public var includesExistingReleases: Bool
    public var isEnabled: Bool

    // MARK: - Learned from the set this was created from

    /// The folder the work's episodes already live in, relative to the
    /// download folder. An automatic download joins it instead of starting a
    /// folder of its own — a season is one folder, whoever started it.
    public var folderName: String?
    /// What this line's filenames look like with the numbers taken out (see
    /// `TorrentEpisodeSetBuilder.titleSignature`). A release that matches it
    /// is the same team's next episode; one that does not is a re-encode, a
    /// fix, or another team, and needs confirming.
    public var titleSignature: String?
    /// How long the season is, when the metadata said. Once the last episode
    /// has arrived the rule has nothing left to wait for.
    public var expectedEpisodeCount: Int?
    /// The rhythm observed when the rule was made, so the page can say when
    /// the next episode is due without searching first.
    public var averageIntervalSeconds: Double?
    /// When the newest episode known to the rule was published.
    public var lastReleaseAt: Date?
    /// The highest episode the rule has seen published anywhere — what the
    /// next-episode estimate counts from.
    public var latestEpisode: Double?

    /// Settable so tests can normalise the millisecond rounding SQLite does.
    public var createdAt: Date
    public var lastCheckedAt: Date?
    public var lastMatchedAt: Date?

    public init(
        id: UUID = UUID(),
        animeID: UUID? = nil,
        title: String,
        queries: [String],
        sources: Set<TorrentSourceID> = [],
        group: String? = nil,
        resolution: String? = nil,
        subtitleLanguages: Set<TorrentSubtitleLanguage> = [],
        videoCodec: String? = nil,
        videoSource: String? = nil,
        season: Int? = nil,
        includeKeywords: [String] = [],
        excludeKeywords: [String] = [],
        minimumEpisode: Double? = nil,
        includesBatches: Bool = false,
        includesExistingReleases: Bool = false,
        isEnabled: Bool = true,
        folderName: String? = nil,
        titleSignature: String? = nil,
        expectedEpisodeCount: Int? = nil,
        averageIntervalSeconds: Double? = nil,
        lastReleaseAt: Date? = nil,
        latestEpisode: Double? = nil,
        createdAt: Date = .now,
        lastCheckedAt: Date? = nil,
        lastMatchedAt: Date? = nil
    ) {
        self.id = id
        self.animeID = animeID
        self.title = title
        self.queries = queries
        self.sources = sources
        self.group = group
        self.resolution = resolution
        self.subtitleLanguages = subtitleLanguages
        self.videoCodec = videoCodec
        self.videoSource = videoSource
        self.season = season
        self.includeKeywords = includeKeywords
        self.excludeKeywords = excludeKeywords
        self.minimumEpisode = minimumEpisode
        self.includesBatches = includesBatches
        self.includesExistingReleases = includesExistingReleases
        self.isEnabled = isEnabled
        self.folderName = folderName
        self.titleSignature = titleSignature
        self.expectedEpisodeCount = expectedEpisodeCount
        self.averageIntervalSeconds = averageIntervalSeconds
        self.lastReleaseAt = lastReleaseAt
        self.latestEpisode = latestEpisode
        self.createdAt = createdAt
        self.lastCheckedAt = lastCheckedAt
        self.lastMatchedAt = lastMatchedAt
    }

    /// The episode the rule is waiting for.
    public var nextEpisode: Double? {
        if let latestEpisode { return latestEpisode + 1 }
        return minimumEpisode.map { $0 + 1 }
    }

    /// When the next episode is due at the rhythm observed so far. Stepped
    /// forward past slots that have already gone by, so a late episode reads
    /// as "due now" rather than as a date last week.
    public func estimatedNextEpisodeAt(now: Date = .now) -> Date? {
        guard let lastReleaseAt, let interval = averageIntervalSeconds, interval > 0 else { return nil }
        guard interval <= TorrentReleaseSchedule.maximumBroadcastInterval else { return nil }
        var next = lastReleaseAt.addingTimeInterval(interval)
        var steps = 0
        while next < now, steps < 64 {
            next = next.addingTimeInterval(interval)
            steps += 1
        }
        return next
    }

    /// Every episode of the season has been published, so there is nothing
    /// left to follow. The rule stays in the list — it is the record of what
    /// the library is following — but it stops searching.
    public var isSeasonComplete: Bool {
        guard let expectedEpisodeCount, expectedEpisodeCount > 0, let latestEpisode else { return false }
        return Int(latestEpisode) >= expectedEpisodeCount
    }

    /// Searches to run for one check: the work's names, plus the same names
    /// with the awaited episode number appended.
    ///
    /// The episode-targeted query is what "look for episode 11 the way the
    /// first ten were named" comes down to on an index: every one of them
    /// ANDs the words of the query, so `Yani Neko 11` narrows to that
    /// episode. It is a *second* query rather than a replacement, because an
    /// index that pads differently ("E11", "第11话") would answer nothing.
    public func searchQueries(now: Date = .now) -> [String] {
        var all = queries
        if let next = nextEpisode, next > 0, next <= TorrentEpisodeSetBuilder.maximumEpisode,
           let primary = queries.first {
            let padded = String(format: "%02d", Int(next))
            all.append("\(primary) \(padded)")
        }
        // Order matters only for the progress display; duplicates would
        // double the work for nothing.
        var seen: Set<String> = []
        return all.filter { seen.insert($0.lowercased()).inserted }
    }

    /// A one-line description of what this rule accepts.
    public var ruleSummary: String {
        var parts: [String] = []
        if let group { parts.append(group) }
        if let resolution { parts.append(resolution) }
        if !subtitleLanguages.isEmpty {
            parts.append(TorrentSubtitleLanguage.allCases
                .filter(subtitleLanguages.contains)
                .map(\.displayName)
                .joined(separator: "/"))
        }
        if let videoCodec { parts.append(videoCodec) }
        if !includeKeywords.isEmpty { parts.append("+" + includeKeywords.joined(separator: " +")) }
        if !excludeKeywords.isEmpty { parts.append("−" + excludeKeywords.joined(separator: " −")) }
        if let minimumEpisode { parts.append(String(localized: "after EP \(Int(minimumEpisode))", bundle: .module)) }
        if includesBatches { parts.append(String(localized: "batches too", bundle: .module)) }
        // Only worth saying when nothing else bounds the rule: an episode
        // floor already says exactly where it starts, and printing both made
        // every rule made by subscribing to a set look permissive.
        if includesExistingReleases, minimumEpisode == nil {
            parts.append(String(localized: "including older releases", bundle: .module))
        }
        return parts.isEmpty ? String(localized: "Any release", bundle: .module) : parts.joined(separator: " · ")
    }
}

/// One release a subscription already acted on, so it is never downloaded
/// twice — even if the download was removed from the list afterwards.
public struct TorrentSubscriptionMatch: Identifiable, Hashable, Sendable {
    public let subscriptionID: UUID
    public let infoHash: String
    public let title: String
    public let episode: Double?
    public let matchedAt: Date

    public var id: String { "\(subscriptionID.uuidString):\(infoHash)" }

    public init(subscriptionID: UUID, infoHash: String, title: String, episode: Double?, matchedAt: Date = .now) {
        self.subscriptionID = subscriptionID
        self.infoHash = infoHash.lowercased()
        self.title = title
        self.episode = episode
        self.matchedAt = matchedAt
    }
}

/// A new episode that fits the work but not the line — another fansub, a
/// different resolution, a re-encode.
///
/// It is not downloaded on its own: the whole point of following one line is
/// that a season stays consistent, and a season half in 简体 1080p and half
/// in raw 720p is worse than a season that waits. So it is offered instead,
/// on the Subscriptions page, where one click takes it.
public struct TorrentSubscriptionCandidate: Identifiable, Hashable, Sendable {
    public let subscriptionID: UUID
    public let infoHash: String
    public var title: String
    public var magnet: String
    public var trackers: [String]
    public var episode: Double?
    public var group: String?
    public var resolution: String?
    public var size: Int64?
    public var seeders: Int?
    public var publishedAt: Date?
    public var foundAt: Date
    /// Why it needs a look rather than a download.
    public var reason: Reason

    public enum Reason: String, Codable, Sendable {
        /// Another fansub published the episode this rule's team has not.
        case otherGroup
        /// The same team, but a different resolution / codec / subtitles.
        case otherVariant
        /// The filename does not look like the ten already on disk.
        case otherNaming
    }

    public var id: String { "\(subscriptionID.uuidString):\(infoHash)" }

    public init(
        subscriptionID: UUID,
        infoHash: String,
        title: String,
        magnet: String,
        trackers: [String] = [],
        episode: Double? = nil,
        group: String? = nil,
        resolution: String? = nil,
        size: Int64? = nil,
        seeders: Int? = nil,
        publishedAt: Date? = nil,
        foundAt: Date = .now,
        reason: Reason
    ) {
        self.subscriptionID = subscriptionID
        self.infoHash = infoHash.lowercased()
        self.title = title
        self.magnet = magnet
        self.trackers = trackers
        self.episode = episode
        self.group = group
        self.resolution = resolution
        self.size = size
        self.seeders = seeders
        self.publishedAt = publishedAt
        self.foundAt = foundAt
        self.reason = reason
    }

    public var reasonText: String {
        switch reason {
        case .otherGroup: String(localized: "Another fansub", bundle: .module)
        case .otherVariant: String(localized: "Different encode", bundle: .module)
        case .otherNaming: String(localized: "Named differently", bundle: .module)
        }
    }
}

/// Decides which search results a subscription should download.
public enum TorrentSubscriptionMatcher {
    /// What one check found: what to start now, and what to ask about.
    public struct Selection: Sendable {
        public var automatic: [TorrentSearchResult] = []
        public var needsConfirmation: [(result: TorrentSearchResult, reason: TorrentSubscriptionCandidate.Reason)] = []

        public var isEmpty: Bool { automatic.isEmpty && needsConfirmation.isEmpty }
    }

    /// Whether one release is of the work at all: right title, right kind,
    /// past the episode floor, and not excluded by hand-written keywords.
    ///
    /// Deliberately *not* the line's identity — that is
    /// `followsSameLine(_:rule:)`, so a release that is the right episode of
    /// the right show but the wrong encode can be offered rather than
    /// silently dropped.
    public static func acceptsWork(_ result: TorrentSearchResult, rule: TorrentSubscription) -> Bool {
        // The same guard the search UI uses: a title that barely resembles
        // the query is never downloaded unattended.
        guard result.relevance >= TorrentResultFilter.relatedThreshold else { return false }
        guard result.category == .episode || result.category == .batch || result.category == .raw else { return false }
        if result.release.isBatch && !rule.includesBatches { return false }
        if let season = rule.season, let found = result.release.season, found != season { return false }

        let folded = TorrentRelevance.fold(result.title)
        for keyword in rule.includeKeywords {
            let needle = TorrentRelevance.fold(keyword)
            guard !needle.isEmpty, folded.contains(needle) else { return false }
        }
        for keyword in rule.excludeKeywords {
            let needle = TorrentRelevance.fold(keyword)
            if !needle.isEmpty, folded.contains(needle) { return false }
        }
        if let minimum = rule.minimumEpisode {
            guard let episode = result.release.lastEpisode ?? result.release.firstEpisode, episode > minimum else { return false }
        }
        // Following a show means taking what appears from now on. Without
        // this, the first check of a mid-season subscription downloads every
        // episode released so far.
        if !rule.includesExistingReleases {
            guard let published = result.publishedAt, published >= rule.createdAt else { return false }
        }
        return true
    }

    /// Whether one release satisfies the rule outright, so it can be
    /// downloaded unattended.
    public static func accepts(_ result: TorrentSearchResult, rule: TorrentSubscription) -> Bool {
        acceptsWork(result, rule: rule) && mismatch(result, rule: rule) == nil
    }

    /// Why a release of the right work is not this line's next episode, or
    /// nil when it is.
    public static func mismatch(
        _ result: TorrentSearchResult,
        rule: TorrentSubscription
    ) -> TorrentSubscriptionCandidate.Reason? {
        if let group = rule.group, !matchesGroup(result, group: group) { return .otherGroup }
        if let resolution = rule.resolution, result.release.resolution != resolution { return .otherVariant }
        if !rule.subtitleLanguages.isEmpty,
           result.release.subtitleLanguages.isDisjoint(with: rule.subtitleLanguages) { return .otherVariant }
        if let codec = rule.videoCodec, let found = result.release.videoCodec, found != codec { return .otherVariant }
        if let source = rule.videoSource, let found = result.release.videoSource, found != source { return .otherVariant }
        // The naming check is last and is the weakest: a team that renames
        // its releases mid-season is common enough that this must not be
        // treated as "another fansub", only as "worth a look".
        if let signature = rule.titleSignature, !signature.isEmpty,
           TorrentEpisodeSetBuilder.titleSignature(result.title) != signature {
            return .otherNaming
        }
        return nil
    }

    /// Fansubs release together — "[喵萌奶茶屋&LoliHouse]" is one group's
    /// name inside another's — and different indexes report the team
    /// differently, so a rule naming one of them accepts the collaboration.
    private static func matchesGroup(_ result: TorrentSearchResult, group: String) -> Bool {
        let needle = TorrentRelevance.fold(group)
        guard !needle.isEmpty else { return true }
        if let team = result.team, TorrentRelevance.fold(team).contains(needle) { return true }
        if let parsed = result.release.group, TorrentRelevance.fold(parsed).contains(needle) { return true }
        return false
    }

    /// The releases to act on from one check.
    ///
    /// At most one per episode — an unattended rule must not fetch three
    /// encodes of the same episode — and nothing already downloaded, already
    /// matched before, or already in the library. Episodes only another team
    /// published come back as confirmations instead, one per episode.
    public static func select(
        from results: [TorrentSearchResult],
        rule: TorrentSubscription,
        alreadyMatched: Set<String>,
        ownedEpisodes: Set<Double>,
        alreadyOffered: Set<String> = []
    ) -> Selection {
        var onLine: [TorrentSearchResult] = []
        var offLine: [(TorrentSearchResult, TorrentSubscriptionCandidate.Reason)] = []
        for result in results {
            guard acceptsWork(result, rule: rule) else { continue }
            guard !alreadyMatched.contains(result.infoHash.hex) else { continue }
            if let episode = result.release.firstEpisode, !result.release.isBatch, ownedEpisodes.contains(episode) {
                continue
            }
            if result.release.isBatch, !TorrentResultFilter.hasMissingEpisode(result.release, owned: ownedEpisodes) {
                continue
            }
            if let reason = mismatch(result, rule: rule) {
                guard !alreadyOffered.contains(result.infoHash.hex) else { continue }
                offLine.append((result, reason))
            } else {
                onLine.append(result)
            }
        }

        var selection = Selection()
        selection.automatic = bestPerEpisode(onLine, rule: rule)
        // Only ask about an episode the line itself did not bring.
        let covered = Set(selection.automatic.compactMap(\.release.firstEpisode))
        var bestOffLine: [Double: (TorrentSearchResult, TorrentSubscriptionCandidate.Reason)] = [:]
        var unnumbered: [(TorrentSearchResult, TorrentSubscriptionCandidate.Reason)] = []
        for (result, reason) in offLine {
            guard let episode = result.release.firstEpisode, !result.release.isBatch else {
                unnumbered.append((result, reason))
                continue
            }
            guard !covered.contains(episode) else { continue }
            if let existing = bestOffLine[episode], isBetter(existing.0, than: result) { continue }
            bestOffLine[episode] = (result, reason)
        }
        selection.needsConfirmation = bestOffLine
            .sorted { ($0.value.0.release.firstEpisode ?? 0) < ($1.value.0.release.firstEpisode ?? 0) }
            .map { (result: $0.value.0, reason: $0.value.1) }
            + unnumbered.map { (result: $0.0, reason: $0.1) }
        return selection
    }

    private static func bestPerEpisode(
        _ candidates: [TorrentSearchResult],
        rule: TorrentSubscription
    ) -> [TorrentSearchResult] {
        var bestByEpisode: [Double: TorrentSearchResult] = [:]
        var withoutEpisode: [TorrentSearchResult] = []
        for candidate in candidates {
            guard let episode = candidate.release.firstEpisode, !candidate.release.isBatch else {
                withoutEpisode.append(candidate)
                continue
            }
            if let existing = bestByEpisode[episode], isBetter(existing, than: candidate) { continue }
            bestByEpisode[episode] = candidate
        }
        // A release with no recognisable episode number (a movie, a special)
        // is only taken when the rule is specific enough to trust it.
        let unnumbered = rule.group != nil || !rule.includeKeywords.isEmpty ? withoutEpisode : []
        return bestByEpisode.values.sorted { ($0.release.firstEpisode ?? 0) < ($1.release.firstEpisode ?? 0) } + unnumbered
    }

    /// Unattended, seeders matter more than anything else: a release nobody
    /// is seeding never finishes, however well it matches.
    private static func isBetter(_ lhs: TorrentSearchResult, than rhs: TorrentSearchResult) -> Bool {
        let left = lhs.seeders ?? 0, right = rhs.seeders ?? 0
        if (left == 0) != (right == 0) { return right == 0 }
        if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
        if left != right { return left > right }
        return (lhs.publishedAt ?? .distantPast) > (rhs.publishedAt ?? .distantPast)
    }
}

extension TorrentSubscription {
    /// The rule that follows the season just downloaded.
    ///
    /// This is the one-click path: everything the form would ask for is read
    /// off the set instead — the team and encode from its variant, the floor
    /// from the last episode it contains, the naming from the episodes
    /// themselves, and the folder they were saved into, so the next episode
    /// joins them rather than starting a folder of its own.
    public static func following(
        set: TorrentEpisodeSet,
        schedule: TorrentReleaseSchedule,
        animeID: UUID?,
        title: String,
        queries: [String],
        folderName: String?,
        now: Date = .now
    ) -> TorrentSubscription {
        let episodes = set.entries.filter { !$0.isExtra }.map(\.episode)
        // The floor is the last episode the set covers: everything up to it
        // is either on disk or downloading, so only what comes after is new.
        // `latestEpisode` is what the whole search reached, which may be
        // ahead of this line — that is what the estimate counts from.
        let covered = max(episodes.max() ?? 0, set.ownedEpisodes.max() ?? 0)
        return TorrentSubscription(
            animeID: animeID,
            title: title,
            queries: queries,
            group: set.isMixed ? nil : set.variant.group,
            resolution: set.variant.resolution,
            subtitleLanguages: set.variant.subtitleLanguages,
            videoCodec: set.variant.videoCodec,
            videoSource: set.variant.videoSource,
            season: set.variant.season,
            minimumEpisode: covered > 0 ? covered : nil,
            // A rule made from a set is created *after* those episodes were
            // published, so the "only what appears from now on" guard would
            // reject the episode that is already out but not yet downloaded.
            // The episode floor is the stricter guard here, and it is exact.
            includesExistingReleases: true,
            folderName: folderName,
            titleSignature: set.isMixed ? nil : Self.signature(of: set),
            expectedEpisodeCount: schedule.expectedEpisodeCount,
            averageIntervalSeconds: schedule.averageInterval,
            lastReleaseAt: schedule.lastPublishedAt,
            // Never behind the set itself: a show published under two
            // numbering schemes at once (`1179` and `S23E25`) can have a
            // schedule reading from the other one, and "waiting for EP 26"
            // when twelve hundred are on disk is nonsense.
            latestEpisode: [schedule.latestEpisode ?? 0, covered].max().flatMap { $0 > 0 ? $0 : nil },
            createdAt: now
        )
    }

    /// The naming most of a set's episodes share, so one oddly named episode
    /// in twelve does not become the pattern.
    private static func signature(of set: TorrentEpisodeSet) -> String? {
        var counts: [String: Int] = [:]
        for entry in set.entries where !entry.isSubstitute {
            let signature = TorrentEpisodeSetBuilder.titleSignature(entry.result.title)
            guard !signature.isEmpty else { continue }
            counts[signature, default: 0] += 1
        }
        guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        return best.value * 2 > set.entries.count ? best.key : nil
    }

    /// Brings the rule up to date with what a check saw, so the page can
    /// show when the next episode is due without searching again.
    public mutating func apply(schedule: TorrentReleaseSchedule) {
        if let interval = schedule.averageInterval { averageIntervalSeconds = interval }
        if let published = schedule.lastPublishedAt,
           published > (lastReleaseAt ?? .distantPast) { lastReleaseAt = published }
        if let latest = schedule.latestEpisode, latest > (latestEpisode ?? 0) { latestEpisode = latest }
        if let expected = schedule.expectedEpisodeCount { expectedEpisodeCount = expected }
    }
}
