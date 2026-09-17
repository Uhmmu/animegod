import Foundation

/// Narrows merged search results the way an anime viewer thinks about them:
/// release type, resolution, subtitle language, fansub, and — when searching
/// from a library title — only the episodes that aren't local yet.
public struct TorrentResultFilter: Hashable, Sendable {
    public enum BatchMode: String, CaseIterable, Identifiable, Sendable {
        case any
        case episodesOnly
        case batchesOnly

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .any: "Episodes & Batches"
            case .episodesOnly: "Single Episodes"
            case .batchesOnly: "Batches Only"
            }
        }
    }

    public var categories: Set<TorrentCategory>
    /// Empty means any resolution.
    public var resolutions: Set<String>
    /// Results must carry at least one of these; empty means any.
    public var subtitleLanguages: Set<TorrentSubtitleLanguage>
    /// Empty means any group.
    public var groups: Set<String>
    public var batchMode: BatchMode
    /// Hides releases whose titles barely resemble any query — fuzzy indexes
    /// return loosely related listings (doujinshi mentioning the title,
    /// unrelated shows sharing one word).
    public var hidesUnrelated: Bool
    /// Hides episodes already in the library (batches stay if they include
    /// at least one missing episode).
    public var ownedEpisodes: Set<Double>
    public var missingEpisodesOnly: Bool
    public var text: String

    /// Relevance below this is "unrelated": the full phrase scores ≥ 2, and
    /// without it at least half the query's words must appear. Half, not
    /// more: "Ave Mujica - The Die is Cast" is a legitimate match for
    /// "BanG Dream! Ave Mujica". Sibling series sharing a franchise prefix
    /// pass this bar too, but ranking puts full-phrase matches first.
    public static let relatedThreshold = 0.5

    public init(
        categories: Set<TorrentCategory> = TorrentCategory.defaultVisible,
        resolutions: Set<String> = [],
        subtitleLanguages: Set<TorrentSubtitleLanguage> = [],
        groups: Set<String> = [],
        batchMode: BatchMode = .any,
        hidesUnrelated: Bool = true,
        ownedEpisodes: Set<Double> = [],
        missingEpisodesOnly: Bool = false,
        text: String = ""
    ) {
        self.categories = categories
        self.resolutions = resolutions
        self.subtitleLanguages = subtitleLanguages
        self.groups = groups
        self.batchMode = batchMode
        self.hidesUnrelated = hidesUnrelated
        self.ownedEpisodes = ownedEpisodes
        self.missingEpisodesOnly = missingEpisodesOnly
        self.text = text
    }

    public func apply(_ results: [TorrentSearchResult]) -> [TorrentSearchResult] {
        // Every word must appear, in any order.
        let words = TorrentRelevance.fold(text).split(separator: " ")
        return results.filter { result in
            guard categories.contains(result.category) else { return false }
            if hidesUnrelated, result.relevance < Self.relatedThreshold { return false }
            if !resolutions.isEmpty, !resolutions.contains(result.release.resolution ?? "") { return false }
            if !subtitleLanguages.isEmpty, result.release.subtitleLanguages.isDisjoint(with: subtitleLanguages) { return false }
            if !groups.isEmpty, !groups.contains(result.group ?? "") { return false }
            switch batchMode {
            case .any: break
            case .episodesOnly: if result.release.isBatch { return false }
            case .batchesOnly: if !result.release.isBatch { return false }
            }
            if missingEpisodesOnly, !Self.hasMissingEpisode(result.release, owned: ownedEpisodes) { return false }
            if !words.isEmpty {
                let title = TorrentRelevance.fold(result.title)
                if !words.allSatisfy({ title.contains($0) }) { return false }
            }
            return true
        }
    }

    /// Whether a release brings at least one episode the library lacks.
    /// Releases without a recognisable episode number are kept: they may be
    /// movies or specials the filter can't reason about.
    public static func hasMissingEpisode(_ release: TorrentReleaseInfo, owned: Set<Double>) -> Bool {
        guard let first = release.firstEpisode else { return true }
        let last = release.lastEpisode ?? first
        guard last - first < 2000 else { return true }
        if first.rounded() != first || last.rounded() != last {
            return !owned.contains(first)
        }
        return stride(from: first, through: last, by: 1).contains { !owned.contains($0) }
    }

    public var isDefault: Bool { self == TorrentResultFilter(ownedEpisodes: ownedEpisodes) }
}

public struct TorrentResultFacets: Sendable {
    public let groups: [(name: String, count: Int)]
    public let resolutions: [String]

    public init(results: [TorrentSearchResult]) {
        var counts: [String: Int] = [:]
        for group in results.compactMap(\.group) { counts[group, default: 0] += 1 }
        groups = counts.map { (name: $0.key, count: $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let order = ["2160p", "1080p", "720p", "480p"]
        resolutions = order.filter { resolution in results.contains { $0.release.resolution == resolution } }
    }
}

/// Fetches a verified `.torrent` for a result: first the URLs the indexes
/// listed, then a public hash-addressed cache. A file whose info hash
/// doesn't match (an error page, a different release) is never returned.
public struct TorrentFileFetcher: Sendable {
    let http: TorrentHTTPClient
    let caches: [@Sendable (TorrentInfoHash) -> URL]

    public init(
        http: TorrentHTTPClient = TorrentHTTPClient(timeout: 15),
        caches: [@Sendable (TorrentInfoHash) -> URL] = [
            { URL(string: "https://itorrents.org/torrent/\($0.hex.uppercased()).torrent")! }
        ]
    ) {
        self.http = http
        self.caches = caches
    }

    public enum FetchError: Error, Equatable {
        case unavailable
    }

    public func fetch(_ result: TorrentSearchResult) async throws -> (data: Data, file: TorrentFile) {
        let candidates = result.torrentURLs + caches.map { $0(result.infoHash) }
        for url in candidates {
            try Task.checkCancellation()
            guard let data = try? await http.get(url, accept: "application/x-bittorrent"),
                  let file = try? TorrentFile(data: data),
                  file.infoHash == result.infoHash else { continue }
            return (data, file)
        }
        throw FetchError.unavailable
    }
}
