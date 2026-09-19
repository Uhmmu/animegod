import Foundation

/// A standing rule: keep watching the indexes for new episodes of one anime
/// and download the ones that fit.
///
/// The rule is deliberately explicit — fansub, resolution, subtitle language,
/// keywords — because an automatic download that picks the wrong release is
/// worse than none: it wastes bandwidth and clutters the library.
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
        includeKeywords: [String] = [],
        excludeKeywords: [String] = [],
        minimumEpisode: Double? = nil,
        includesBatches: Bool = false,
        includesExistingReleases: Bool = false,
        isEnabled: Bool = true,
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
        self.includeKeywords = includeKeywords
        self.excludeKeywords = excludeKeywords
        self.minimumEpisode = minimumEpisode
        self.includesBatches = includesBatches
        self.includesExistingReleases = includesExistingReleases
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastCheckedAt = lastCheckedAt
        self.lastMatchedAt = lastMatchedAt
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
        if !includeKeywords.isEmpty { parts.append("+" + includeKeywords.joined(separator: " +")) }
        if !excludeKeywords.isEmpty { parts.append("−" + excludeKeywords.joined(separator: " −")) }
        if let minimumEpisode { parts.append("after EP \(Int(minimumEpisode))") }
        if includesBatches { parts.append("batches too") }
        if includesExistingReleases { parts.append("including older releases") }
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

/// Decides which search results a subscription should download.
public enum TorrentSubscriptionMatcher {
    /// Whether one release satisfies the rule, ignoring what is already had.
    public static func accepts(_ result: TorrentSearchResult, rule: TorrentSubscription) -> Bool {
        // The same guard the search UI uses: a title that barely resembles
        // the query is never downloaded unattended.
        guard result.relevance >= TorrentResultFilter.relatedThreshold else { return false }
        guard result.category == .episode || result.category == .batch || result.category == .raw else { return false }
        if result.release.isBatch && !rule.includesBatches { return false }
        if let group = rule.group, !matchesGroup(result, group: group) { return false }
        if let resolution = rule.resolution, result.release.resolution != resolution { return false }
        if !rule.subtitleLanguages.isEmpty,
           result.release.subtitleLanguages.isDisjoint(with: rule.subtitleLanguages) { return false }

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

    /// The releases to download from one check.
    ///
    /// At most one per episode — an unattended rule must not fetch three
    /// encodes of the same episode — and nothing already downloaded, already
    /// matched before, or already in the library.
    public static func select(
        from results: [TorrentSearchResult],
        rule: TorrentSubscription,
        alreadyMatched: Set<String>,
        ownedEpisodes: Set<Double>
    ) -> [TorrentSearchResult] {
        let candidates = results.filter { result in
            guard accepts(result, rule: rule) else { return false }
            guard !alreadyMatched.contains(result.infoHash.hex) else { return false }
            if let episode = result.release.firstEpisode, !result.release.isBatch, ownedEpisodes.contains(episode) {
                return false
            }
            if result.release.isBatch, !TorrentResultFilter.hasMissingEpisode(result.release, owned: ownedEpisodes) {
                return false
            }
            return true
        }

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
        return (bestByEpisode.values.sorted { ($0.release.firstEpisode ?? 0) < ($1.release.firstEpisode ?? 0) } + unnumbered)
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
