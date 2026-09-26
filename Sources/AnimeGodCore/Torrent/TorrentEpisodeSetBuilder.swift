import Foundation

/// The identity of one fansub's release line: everything that has to stay
/// the same from episode to episode for a season to feel like one set.
///
/// A group alone is too coarse — most teams publish 1080p and 720p, HEVC and
/// AVC, 简 and 繁 of the same episode, and a "season" mixing those is not
/// what anyone wants on disk. Matching on the whole tuple instead is the
/// orthogonal part: the episode number is the only axis allowed to vary.
public struct TorrentReleaseVariant: Hashable, Sendable, Identifiable {
    /// The fansub as it should be shown. Grouping folds case and width, so
    /// this is the first spelling seen for the folded name.
    public var group: String?
    public var season: Int?
    public var resolution: String?
    public var videoCodec: String?
    public var videoSource: String?
    public var subtitleLanguages: Set<TorrentSubtitleLanguage>

    public init(
        group: String? = nil,
        season: Int? = nil,
        resolution: String? = nil,
        videoCodec: String? = nil,
        videoSource: String? = nil,
        subtitleLanguages: Set<TorrentSubtitleLanguage> = []
    ) {
        self.group = group
        self.season = season
        self.resolution = resolution
        self.videoCodec = videoCodec
        self.videoSource = videoSource
        self.subtitleLanguages = subtitleLanguages
    }

    public init(_ result: TorrentSearchResult) {
        self.init(
            group: result.group,
            season: result.release.season,
            resolution: result.release.resolution,
            videoCodec: result.release.videoCodec,
            videoSource: result.release.videoSource,
            subtitleLanguages: result.release.subtitleLanguages
        )
    }

    /// Stable across runs — the UI keeps expansion state keyed on it.
    public var id: String {
        [
            group.map(TorrentRelevance.fold) ?? "",
            season.map(String.init) ?? "",
            resolution ?? "",
            videoCodec ?? "",
            videoSource ?? "",
            TorrentSubtitleLanguage.allCases.filter(subtitleLanguages.contains).map(\.rawValue).joined(separator: "+")
        ].joined(separator: "|")
    }

    /// Everything but the fansub name, in the order a viewer reads it.
    public var attributeTags: [String] {
        var tags: [String] = []
        if let season { tags.append("S\(season)") }
        if let resolution { tags.append(resolution) }
        if !subtitleLanguages.isEmpty {
            tags.append(TorrentSubtitleLanguage.allCases.filter(subtitleLanguages.contains).map(\.displayName).joined())
        }
        if let videoCodec { tags.append(videoCodec) }
        if let videoSource { tags.append(videoSource) }
        return tags
    }
}

/// One fansub's line, assembled from the single-episode releases a search
/// returned: which episodes it covers, which had to be borrowed from another
/// team, and which nobody published.
public struct TorrentEpisodeSet: Identifiable, Hashable, Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public var episode: Double
        public var result: TorrentSearchResult
        /// The set's own variant had no release for this episode, so it was
        /// borrowed from the closest other line.
        public var isSubstitute: Bool
        /// The library already has this episode; downloading it again is
        /// opt-in.
        public var isOwned: Bool
        /// Outside the season's episode range — a 12.5 recap, an OVA. Shown,
        /// but never counted as coverage and never missing.
        public var isExtra: Bool

        public var id: Double { episode }

        /// The fansub that actually published this file.
        public var group: String? { result.group }
    }

    public var variant: TorrentReleaseVariant
    /// Built across fansubs rather than from one line: the whole season,
    /// best release per episode, anchored on the team that published most
    /// of it. Offered alongside the per-fansub sets, never instead of them.
    public var isMixed: Bool = false
    /// Sorted by episode; extras last.
    public var entries: [Entry]
    /// The season as the search sees it, e.g. 1…12.
    public var expectedEpisodes: [Double]
    /// Episodes of `expectedEpisodes` that are neither in the library nor
    /// published by any source the search reached.
    public var missingEpisodes: [Double]
    /// The part of the season the library already has.
    public var ownedEpisodes: Set<Double>

    public var id: String { variant.id }

    public var group: String? { variant.group }

    /// Episodes worth downloading: expected, not already in the library.
    public var neededEpisodes: [Double] {
        expectedEpisodes.filter { !ownedEpisodes.contains($0) }
    }

    /// What "Download Set" acts on: one release per needed episode.
    public var downloadableEntries: [Entry] {
        entries.filter { !$0.isOwned && !$0.isExtra }
    }

    public var coveredCount: Int { entries.filter { !$0.isExtra }.count }
    public var substituteCount: Int { entries.filter { $0.isSubstitute && !$0.isExtra }.count }
    /// Episodes on disk a release was also found for — what "download the
    /// whole season anyway" would add. Smaller than `ownedEpisodes` when an
    /// episode the library has is no longer listed anywhere.
    public var ownedCount: Int { entries.filter { $0.isOwned && !$0.isExtra }.count }
    public var extras: [Entry] { entries.filter(\.isExtra) }

    /// Nothing the season still needs is unavailable — borrowed episodes
    /// count, episodes already on disk are not the set's problem.
    public var isComplete: Bool { missingEpisodes.isEmpty && !expectedEpisodes.isEmpty }

    /// Sum over the releases that would actually be fetched; nil when no
    /// index reported a size for any of them.
    public var downloadSize: Int64? {
        let sizes = downloadableEntries.compactMap(\.result.size)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    /// The weakest swarm in the set — one dead episode stalls the season.
    /// Only counts episodes an index reported seeders for: treating "not
    /// reported" as zero made every set with one quiet index look dead.
    public var minimumSeeders: Int? {
        downloadableEntries.compactMap(\.result.seeders).min()
    }

    public var newestPublishedAt: Date? {
        entries.compactMap(\.result.publishedAt).max()
    }
}

public struct TorrentEpisodeSetOptions: Hashable, Sendable {
    /// Episodes already in the library: kept in the set for context, never
    /// downloaded, and never counted as missing.
    public var ownedEpisodes: Set<Double>
    /// Fill an episode the line never published from another fansub.
    public var allowsSubstitutes: Bool
    /// A borrowed episode must share a subtitle language with the line, so
    /// a 简体 season is never patched with a raw.
    public var requiresMatchingSubtitles: Bool
    /// A line with fewer episodes than this is a loose release, not a set.
    public var minimumEpisodes: Int
    public var maximumSets: Int

    public init(
        ownedEpisodes: Set<Double> = [],
        allowsSubstitutes: Bool = true,
        requiresMatchingSubtitles: Bool = true,
        minimumEpisodes: Int = 2,
        maximumSets: Int = 40
    ) {
        self.ownedEpisodes = ownedEpisodes
        self.allowsSubstitutes = allowsSubstitutes
        self.requiresMatchingSubtitles = requiresMatchingSubtitles
        self.minimumEpisodes = minimumEpisodes
        self.maximumSets = maximumSets
    }
}

/// Turns a flat list of search results into per-fansub seasons.
///
/// The problem this solves: a viewer who does not want a 40 GB batch has to
/// find and start twelve downloads by hand, and the indexes interleave every
/// team, resolution and subtitle language in one list. Grouping by the whole
/// release tuple (`TorrentReleaseVariant`) puts one team's season back
/// together, and episodes that team never published are borrowed from the
/// nearest other line rather than leaving a hole.
public enum TorrentEpisodeSetBuilder {
    /// Numbers above this are years, resolutions or CRCs that slipped
    /// through parsing, not episodes.
    static let maximumEpisode: Double = 1500
    /// How far the numbering may jump before the episodes on the far side
    /// are a different run rather than a gap in this one — roughly two
    /// months of weekly releases. Sequels are the reason this is not
    /// generous: a season tagged S2 and numbered 1–10 sits in the same
    /// search as teams still counting 29–38, and treating both as one
    /// season reports every line as almost entirely missing.
    static let maximumEpisodeGap: Double = 8

    public static func build(
        from results: [TorrentSearchResult],
        options: TorrentEpisodeSetOptions = TorrentEpisodeSetOptions()
    ) -> [TorrentEpisodeSet] {
        let singles = results.filter(isSingleEpisode)
        guard !singles.isEmpty else { return [] }

        // Seasons are counted separately. A show whose second season is
        // tagged "S2" and numbered 1–10 while other teams keep counting
        // 29–38 has two numbering universes in one search, and measuring
        // the S2 line against 1–38 would report it as almost entirely
        // missing.
        let bySeason = Dictionary(grouping: singles) { $0.release.season }
        let mainSeason = bySeason.max { lhs, rhs in
            lhs.value.count != rhs.value.count ? lhs.value.count < rhs.value.count : (lhs.key ?? 0) > (rhs.key ?? 0)
        }?.key
        var runsBySeason: [Int?: [[Double]]] = [:]
        for (season, group) in bySeason {
            var observed = Set(group.compactMap(\.release.firstEpisode))
            // What the library holds belongs to the season being searched.
            if season == mainSeason { observed.formUnion(options.ownedEpisodes) }
            runsBySeason[season] = runs(in: observed)
        }

        // Best release per (variant, episode) — a team publishing v2 of an
        // episode still contributes one entry.
        var lines: [String: Line] = [:]
        for result in singles {
            let variant = TorrentReleaseVariant(result)
            lines[variant.id, default: Line(variant: variant)].add(result)
        }
        for key in lines.keys { lines[key]?.resolveSignature() }

        let pool = SubstitutePool(lines: Array(lines.values))
        var sets = lines.values.compactMap { line -> TorrentEpisodeSet? in
            let expected = expectedEpisodes(
                for: line,
                in: runsBySeason[line.variant.season] ?? [],
                owned: options.ownedEpisodes
            )
            return assemble(line, expected: expected, expectedSet: Set(expected), pool: pool, options: options)
        }
        if let mixed = mixedSet(
            over: runsBySeason[mainSeason] ?? [],
            season: mainSeason,
            lines: lines,
            pool: pool,
            options: options
        ) {
            sets.append(mixed)
        }
        return Array(rank(sets).prefix(options.maximumSets))
    }

    /// The episode numbers in a search, split into the runs that hang
    /// together. A misparsed "2018" lands in its own run, and so does a
    /// sequel that restarted its numbering.
    static func runs(in episodes: Set<Double>) -> [[Double]] {
        let integral = episodes
            .filter { $0 == $0.rounded() && $0 >= 0 && $0 <= maximumEpisode }
            .sorted()
        guard let first = integral.first else { return [] }
        var runs: [[Double]] = [[first]]
        for episode in integral.dropFirst() {
            if episode - runs[runs.count - 1].last! <= maximumEpisodeGap {
                runs[runs.count - 1].append(episode)
            } else {
                runs.append([episode])
            }
        }
        return runs
    }

    /// The season the search describes: its longest run of episodes. Ties
    /// go to the earlier one, which is the season being searched rather
    /// than a trailing OVA.
    static func expectedEpisodes(in episodes: Set<Double>) -> [Double] {
        let candidates = runs(in: episodes)
        guard let best = candidates.max(by: { lhs, rhs in
            lhs.count != rhs.count ? lhs.count < rhs.count : lhs[0] > rhs[0]
        }) else { return [] }
        return span(of: best)
    }

    /// How far past its own first and last episode a line is stretched to
    /// meet the rest of the season. A team that stopped one or two short of
    /// the finale is missing a tail; a team that only ever covered 25–48 of
    /// a continuously numbered show is a second-season line, not a
    /// first-season line missing twenty-four episodes.
    static let maximumEdgeStretch: Double = 3

    /// What a fansub's line is measured against: the run of episodes it
    /// belongs to — so a team counting 29–38 is never held against a sequel
    /// that restarted at 1 — trimmed to the part of that run the line
    /// actually reaches.
    private static func expectedEpisodes(
        for line: Line,
        in runs: [[Double]],
        owned: Set<Double>
    ) -> [Double] {
        let own = Set(line.byEpisode.keys)
        guard let best = runs.max(by: { lhs, rhs in
            let left = own.intersection(lhs).count, right = own.intersection(rhs).count
            return left != right ? left < right : lhs.count < rhs.count
        }) else { return [] }
        let season = span(of: best)
        guard let low = season.first, let high = season.last else { return [] }
        // Episodes already on disk count as reach: a line offering 9–12 of a
        // season whose first half is in the library still describes 1–12.
        let reach = own.union(owned).filter { $0 >= low && $0 <= high }
        guard let first = reach.min(), let last = reach.max() else { return [] }
        let from = first - low <= maximumEdgeStretch ? low : first
        let through = high - last <= maximumEdgeStretch ? high : last
        return Array(stride(from: from, through: through, by: 1))
    }

    /// A run filled in from end to end, snapped to episode 1 when it starts
    /// close enough that the first episodes simply fell off the indexes.
    private static func span(of run: [Double]) -> [Double] {
        guard var low = run.first, let high = run.last, high >= low else { return [] }
        if low <= 3 { low = min(1, high) }
        return Array(stride(from: low, through: high, by: 1))
    }

    private static func isSingleEpisode(_ result: TorrentSearchResult) -> Bool {
        guard !result.release.isBatch, result.category != .music, result.category != .other else { return false }
        guard let first = result.release.firstEpisode, first >= 0, first <= maximumEpisode else { return false }
        return (result.release.lastEpisode ?? first) == first
    }

    // MARK: - Assembly

    /// One variant's releases while the set is being put together.
    private struct Line {
        let variant: TorrentReleaseVariant
        var byEpisode: [Double: [TorrentSearchResult]] = [:]
        /// The spelling most of this line's titles share once the episode
        /// number and technical tags are removed. A release that does not
        /// match it is an oddity (a fix, a re-encode) and loses ties.
        var signature: String = ""

        mutating func add(_ result: TorrentSearchResult) {
            guard let episode = result.release.firstEpisode else { return }
            byEpisode[episode, default: []].append(result)
        }

        mutating func resolveSignature() {
            var counts: [String: Int] = [:]
            for result in byEpisode.values.flatMap({ $0 }) {
                counts[titleSignature(result.title), default: 0] += 1
            }
            signature = counts.max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            }?.key ?? ""
        }

        func best(for episode: Double) -> TorrentSearchResult? {
            byEpisode[episode]?.max { lhs, rhs in
                rank(lhs) < rank(rhs)
            }
        }

        private func rank(_ result: TorrentSearchResult) -> RankKey {
            RankKey(
                matchesSignature: titleSignature(result.title) == signature,
                seeders: result.seeders ?? 0,
                publishedAt: result.publishedAt ?? .distantPast,
                relevance: result.relevance,
                infoHash: result.infoHash.hex
            )
        }
    }

    private struct RankKey: Comparable {
        let matchesSignature: Bool
        let seeders: Int
        let publishedAt: Date
        let relevance: Double
        let infoHash: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.matchesSignature != rhs.matchesSignature { return rhs.matchesSignature }
            if lhs.seeders != rhs.seeders { return lhs.seeders < rhs.seeders }
            if lhs.publishedAt != rhs.publishedAt { return lhs.publishedAt < rhs.publishedAt }
            if lhs.relevance != rhs.relevance { return lhs.relevance < rhs.relevance }
            return lhs.infoHash > rhs.infoHash
        }
    }

    /// Every line indexed by episode, so a hole can be filled from whichever
    /// other team is closest to the one being assembled.
    private struct SubstitutePool {
        let lines: [Line]

        func candidate(
            for episode: Double,
            like variant: TorrentReleaseVariant,
            options: TorrentEpisodeSetOptions
        ) -> TorrentSearchResult? {
            var best: (score: Int, key: RankKey, result: TorrentSearchResult)?
            for line in lines where line.variant.id != variant.id {
                guard let result = line.best(for: episode) else { continue }
                guard let score = affinity(of: line.variant, to: variant, options: options) else { continue }
                let key = RankKey(
                    matchesSignature: true,
                    seeders: result.seeders ?? 0,
                    publishedAt: result.publishedAt ?? .distantPast,
                    relevance: result.relevance,
                    infoHash: result.infoHash.hex
                )
                if let current = best, (current.score, current.key) >= (score, key) { continue }
                best = (score, key, result)
            }
            return best?.result
        }

        /// How acceptable a borrowed line is, or nil when it must not be
        /// used at all.
        private func affinity(
            of candidate: TorrentReleaseVariant,
            to variant: TorrentReleaseVariant,
            options: TorrentEpisodeSetOptions
        ) -> Int? {
            if candidate.season != variant.season { return nil }
            if options.requiresMatchingSubtitles, !variant.subtitleLanguages.isEmpty,
               candidate.subtitleLanguages.isDisjoint(with: variant.subtitleLanguages) {
                return nil
            }
            var score = 0
            if candidate.resolution == variant.resolution { score += 8 }
            if candidate.subtitleLanguages == variant.subtitleLanguages { score += 4 }
            else if !candidate.subtitleLanguages.isDisjoint(with: variant.subtitleLanguages) { score += 2 }
            if candidate.videoSource == variant.videoSource { score += 2 }
            if candidate.videoCodec == variant.videoCodec { score += 1 }
            return score
        }
    }

    private static func assemble(
        _ line: Line,
        expected: [Double],
        expectedSet: Set<Double>,
        pool: SubstitutePool,
        options: TorrentEpisodeSetOptions
    ) -> TorrentEpisodeSet? {
        guard line.byEpisode.count >= options.minimumEpisodes else { return nil }

        var entries: [Entry] = []
        var missing: [Double] = []
        for episode in expected {
            if let own = line.best(for: episode) {
                entries.append(Entry(
                    episode: episode,
                    result: own,
                    isSubstitute: false,
                    isOwned: options.ownedEpisodes.contains(episode),
                    isExtra: false
                ))
            } else if options.allowsSubstitutes,
                      let borrowed = pool.candidate(for: episode, like: line.variant, options: options) {
                entries.append(Entry(
                    episode: episode,
                    result: borrowed,
                    isSubstitute: true,
                    isOwned: options.ownedEpisodes.contains(episode),
                    isExtra: false
                ))
            } else if !options.ownedEpisodes.contains(episode) {
                // An episode only the library has is not a hole in the set.
                missing.append(episode)
            }
        }
        // 12.5 recaps and OVAs the line published stay visible, outside the count.
        for episode in line.byEpisode.keys.sorted() where !expectedSet.contains(episode) {
            guard let result = line.best(for: episode) else { continue }
            entries.append(Entry(
                episode: episode,
                result: result,
                isSubstitute: false,
                isOwned: options.ownedEpisodes.contains(episode),
                isExtra: true
            ))
        }
        let own = entries.filter { !$0.isSubstitute && !$0.isExtra }.count
        let borrowed = entries.count - own - entries.filter(\.isExtra).count
        // A line held together mostly by other teams' files is not that
        // team's season, and offering it as one buries the real ones.
        guard own > 0, borrowed <= own else { return nil }
        return TorrentEpisodeSet(
            variant: line.variant,
            entries: entries,
            expectedEpisodes: expected,
            missingEpisodes: missing,
            ownedEpisodes: options.ownedEpisodes.intersection(expectedSet)
        )
    }

    /// The whole season, whoever published each episode: the best release
    /// for every number in the season's longest run, anchored on the line
    /// that covered most of it so the result stays as consistent as the
    /// indexes allow.
    ///
    /// The per-fansub sets are deliberately trimmed to what their team
    /// really covered; this is the row for someone who just wants all
    /// twelve episodes and does not mind where each one came from.
    private static func mixedSet(
        over runs: [[Double]],
        season: Int?,
        lines: [String: Line],
        pool: SubstitutePool,
        options: TorrentEpisodeSetOptions
    ) -> TorrentEpisodeSet? {
        guard options.allowsSubstitutes else { return nil }
        guard let longest = runs.max(by: { lhs, rhs in
            lhs.count != rhs.count ? lhs.count < rhs.count : lhs[0] > rhs[0]
        }) else { return nil }
        let expected = span(of: longest)
        guard expected.count > 1 else { return nil }
        let inSeason = lines.values.filter { $0.variant.season == season }
        // Anchored on whoever covered the most of the run, so the season is
        // as much one team's work as it can be.
        guard let anchor = inSeason.max(by: { lhs, rhs in
            let left = Set(lhs.byEpisode.keys).intersection(expected).count
            let right = Set(rhs.byEpisode.keys).intersection(expected).count
            return left != right ? left < right : lhs.variant.id > rhs.variant.id
        }) else { return nil }
        let native = Set(anchor.byEpisode.keys).intersection(expected).count
        // Nothing to add when the anchor already published the whole run.
        guard native < expected.count else { return nil }

        var entries: [Entry] = []
        var missing: [Double] = []
        for episode in expected {
            if let own = anchor.best(for: episode) {
                entries.append(Entry(episode: episode, result: own, isSubstitute: false,
                                     isOwned: options.ownedEpisodes.contains(episode), isExtra: false))
            } else if let borrowed = pool.candidate(for: episode, like: anchor.variant, options: options) {
                entries.append(Entry(episode: episode, result: borrowed, isSubstitute: true,
                                     isOwned: options.ownedEpisodes.contains(episode), isExtra: false))
            } else if !options.ownedEpisodes.contains(episode) {
                missing.append(episode)
            }
        }
        // Only worth a row of its own if it really beats its anchor.
        guard entries.count > native else { return nil }
        var variant = anchor.variant
        variant.group = nil
        return TorrentEpisodeSet(
            variant: variant,
            isMixed: true,
            entries: entries,
            expectedEpisodes: expected,
            missingEpisodes: missing,
            ownedEpisodes: options.ownedEpisodes.intersection(expected)
        )
    }

    private typealias Entry = TorrentEpisodeSet.Entry

    // MARK: - Ranking

    /// Best first: what covers the most of what the library still needs,
    /// with the fewest borrowed episodes and the healthiest swarms.
    static func rank(_ sets: [TorrentEpisodeSet]) -> [TorrentEpisodeSet] {
        sets.sorted { lhs, rhs in
            let left = key(lhs), right = key(rhs)
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
    }

    private static func key(_ set: TorrentEpisodeSet) -> (Int, Int, Int, Int, Double, Double) {
        let needed = Set(set.neededEpisodes)
        let coveredNatively = set.entries.filter { !$0.isExtra && !$0.isSubstitute && needed.contains($0.episode) }.count
        let covered = set.entries.filter { !$0.isExtra && needed.contains($0.episode) }.count
        return (
            // Complete first, and on equal footing a real fansub's own
            // season beats the cross-fansub mix. (Swift compares tuples of
            // at most six elements, so the two share one rank.)
            (set.isComplete ? 2 : 0) + (set.isMixed ? 0 : 1),
            // Native coverage outranks total coverage: a line that really
            // published twenty episodes is a better season than a line of
            // eight padded out with twelve borrowed from four other teams.
            coveredNatively,
            covered,
            // Above ~50 seeders the swarm is healthy either way; letting it
            // keep growing would outrank resolution.
            min(set.minimumSeeders ?? 0, 50),
            resolutionRank(set.variant.resolution),
            set.newestPublishedAt?.timeIntervalSince1970 ?? 0
        )
    }

    private static func resolutionRank(_ resolution: String?) -> Double {
        switch resolution {
        case "2160p": 4
        case "1080p": 3
        case "720p": 2
        case "480p": 1
        default: 0
        }
    }

    // MARK: - Titles

    /// A title stripped of everything that varies within one line: the
    /// episode number and every tag that carries a digit (resolution, codec,
    /// bit depth, CRC). What is left is the fansub's fixed naming.
    static func titleSignature(_ title: String) -> String {
        TorrentRelevance.fold(title)
            .split(separator: " ")
            .filter { token in !token.contains(where: \.isNumber) }
            .joined(separator: " ")
    }
}
