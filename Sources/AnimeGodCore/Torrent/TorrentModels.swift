import Foundation

/// Anime torrent indexes AnimeGod can search. General-purpose, adult and
/// game indexes from magnet-crawler are deliberately absent.
public enum TorrentSourceID: String, CaseIterable, Codable, Identifiable, Sendable {
    case dmhy
    case mikan
    case bangumiMoe
    case animeGarden
    case acgRip
    case acgnx
    case nyaa
    case animeTosho
    case subsPlease
    case tokyoTosho
    // General indexes. Every one above is an *anime* index, and a concert
    // Blu-ray is not filed as anime — the live discs in the real library come
    // from DBD-Raws, which these carry and several of the anime indexes do
    // not. Ported from the magnet-crawler project.
    case knaben
    case torrentsCsv
    case bitSearch
    case theRarbg
    case apiBay

    public var id: String { rawValue }

    /// Whether this index is about anime specifically. The general ones answer
    /// about everything, which is the point and also the cost: relevance
    /// scoring is what keeps a search for one concert from returning the rest
    /// of the internet.
    public var isAnimeIndex: Bool {
        switch self {
        case .knaben, .torrentsCsv, .bitSearch, .theRarbg, .apiBay: false
        default: true
        }
    }

    public var displayName: String {
        switch self {
        case .dmhy: "动漫花园"
        case .mikan: "蜜柑计划"
        case .bangumiMoe: "萌番组"
        case .animeGarden: "Anime Garden"
        case .acgRip: "ACG.RIP"
        case .acgnx: "末日动漫"
        case .nyaa: "Nyaa"
        case .animeTosho: "AnimeTosho"
        case .subsPlease: "SubsPlease"
        case .tokyoTosho: "TokyoTosho"
        case .knaben: "Knaben"
        case .torrentsCsv: "torrents-csv"
        case .bitSearch: "BitSearch"
        case .theRarbg: "TheRARBG"
        case .apiBay: "The Pirate Bay"
        }
    }

    public var homepage: URL {
        switch self {
        case .dmhy: URL(string: "https://share.dmhy.org")!
        case .mikan: URL(string: "https://mikanani.me")!
        case .bangumiMoe: URL(string: "https://bangumi.moe")!
        case .animeGarden: URL(string: "https://animes.garden")!
        case .acgRip: URL(string: "https://acg.rip")!
        case .acgnx: URL(string: "https://share.acgnx.se")!
        case .nyaa: URL(string: "https://nyaa.si")!
        case .animeTosho: URL(string: "https://animetosho.org")!
        case .subsPlease: URL(string: "https://subsplease.org")!
        case .tokyoTosho: URL(string: "https://www.tokyotosho.info")!
        case .knaben: URL(string: "https://knaben.org")!
        case .torrentsCsv: URL(string: "https://torrents-csv.com")!
        case .bitSearch: URL(string: "https://bitsearch.to")!
        case .theRarbg: URL(string: "https://therarbg.to")!
        case .apiBay: URL(string: "https://apibay.org")!
        }
    }
}

/// What a listing is, as far as its index says. Adult listings never reach
/// this type: providers drop them while parsing.
public enum TorrentCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case episode
    case batch
    case raw
    case music
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .episode: String(localized: "Anime", bundle: .module)
        case .batch: String(localized: "Batch", bundle: .module)
        case .raw: String(localized: "Raw", bundle: .module)
        case .music: String(localized: "Music", bundle: .module)
        case .other: String(localized: "Other", bundle: .module)
        }
    }

    /// Categories shown before the user widens the filter.
    public static let defaultVisible: Set<TorrentCategory> = [.episode, .batch, .raw]
}

/// One listing as a single index reported it.
public struct TorrentObservation: Hashable, Sendable {
    public var source: TorrentSourceID
    public var title: String
    public var infoHash: TorrentInfoHash
    public var trackers: [String]
    /// Bytes; nil when the index did not say.
    public var size: Int64?
    public var seeders: Int?
    public var leechers: Int?
    public var publishedAt: Date?
    public var category: TorrentCategory
    /// Fansub / uploader team as reported by the index (more reliable than
    /// parsing the leading bracket of the title).
    public var team: String?
    public var torrentURL: URL?
    public var pageURL: URL?
    /// Whether `size` is an exact byte count rather than a rounded "9.4 GiB".
    public var sizeIsExact: Bool
    /// The query that produced this observation; set by the coordinator.
    public var query: String = ""

    public init(
        source: TorrentSourceID,
        title: String,
        infoHash: TorrentInfoHash,
        trackers: [String] = [],
        size: Int64? = nil,
        seeders: Int? = nil,
        leechers: Int? = nil,
        publishedAt: Date? = nil,
        category: TorrentCategory = .episode,
        team: String? = nil,
        torrentURL: URL? = nil,
        pageURL: URL? = nil,
        sizeIsExact: Bool = false
    ) {
        self.source = source
        self.title = title
        self.infoHash = infoHash
        self.trackers = trackers
        self.size = size.flatMap { $0 > 0 ? $0 : nil }
        self.seeders = seeders.map { max(0, $0) }
        self.leechers = leechers.map { max(0, $0) }
        self.publishedAt = publishedAt
        self.category = category
        self.team = team?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.torrentURL = torrentURL.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
        self.pageURL = pageURL
        self.sizeIsExact = sizeIsExact
    }
}

/// One release after merging every index that listed the same info hash.
public struct TorrentSearchResult: Hashable, Identifiable, Sendable {
    public var infoHash: TorrentInfoHash
    public var title: String
    public var size: Int64?
    public var seeders: Int?
    public var leechers: Int?
    public var publishedAt: Date?
    public var category: TorrentCategory
    public var team: String?
    public var sources: [TorrentSourceID]
    public var matchedQueries: [String]
    public var torrentURLs: [URL]
    public var pageURLs: [TorrentSourceID: URL]
    public var trackers: [String]
    public var release: TorrentReleaseInfo
    public var relevance: Double

    public var id: TorrentInfoHash { infoHash }

    public var magnet: MagnetLink {
        MagnetLink(infoHash: infoHash, displayName: title, trackers: trackers, exactLength: size)
    }

    /// The team from the index, else the title's leading bracket.
    public var group: String? { team ?? release.group }
}

public enum TorrentSearchError: Error, Hashable, Sendable {
    case network(String)
    case http(Int)
    /// A Cloudflare / DDoS-Guard interstitial instead of results.
    case blocked
    case parse(String)
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
