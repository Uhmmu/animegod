import Foundation

/// One playable part of a Bilibili video.
///
/// Every part carries its **own** `cid`, and the danmaku pool is keyed by
/// `cid` — never by `aid`/`bvid`. A multi-part upload (a whole cour packed
/// into one submission, a batch of OP/ED clips) therefore has one danmaku
/// pool per part, and using the submission's top-level `cid` would show the
/// first part's comments over every episode.
public struct BilibiliVideoPart: Codable, Hashable, Sendable {
    public let cid: Int64
    /// 1-based part index as Bilibili numbers them.
    public let page: Int
    public let title: String
    /// Part duration in seconds.
    public let duration: Double

    public init(cid: Int64, page: Int, title: String, duration: Double) {
        self.cid = cid
        self.page = page
        self.title = title
        self.duration = duration
    }
}

/// A user-uploaded (UGC) submission.
public struct BilibiliVideo: Codable, Hashable, Sendable {
    public let aid: Int64
    public let bvid: String
    public let title: String
    /// Total duration in seconds.
    public let duration: Double
    public let parts: [BilibiliVideoPart]
    public let typeName: String
    public let publishedAt: Date?

    public init(
        aid: Int64,
        bvid: String,
        title: String,
        duration: Double,
        parts: [BilibiliVideoPart],
        typeName: String = "",
        publishedAt: Date? = nil
    ) {
        self.aid = aid
        self.bvid = bvid
        self.title = title
        self.duration = duration
        self.parts = parts
        self.typeName = typeName
        self.publishedAt = publishedAt
    }
}

/// One episode of a licensed bangumi season (Bilibili's PGC catalogue).
public struct BilibiliBangumiEpisode: Codable, Hashable, Sendable {
    public let episodeID: Int64
    public let aid: Int64
    public let bvid: String
    public let cid: Int64
    /// Bilibili's own episode label — usually just the number ("1", "12.5").
    public let title: String
    /// The episode's subtitle, when the season has one.
    public let longTitle: String
    /// Duration in seconds (the API reports milliseconds).
    public let duration: Double

    public init(
        episodeID: Int64,
        aid: Int64,
        bvid: String,
        cid: Int64,
        title: String,
        longTitle: String,
        duration: Double
    ) {
        self.episodeID = episodeID
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.title = title
        self.longTitle = longTitle
        self.duration = duration
    }

    /// Numeric episode number when the label is one, e.g. "12.5" → 12.5.
    public var episodeNumber: Double? { Double(title.trimmingCharacters(in: .whitespaces)) }

    public var displayTitle: String {
        longTitle.isEmpty ? title : "\(title) \(longTitle)"
    }
}

public struct BilibiliBangumiSeason: Codable, Hashable, Sendable {
    public let seasonID: Int64
    public let title: String
    public let seasonTypeName: String
    public let episodes: [BilibiliBangumiEpisode]

    public init(seasonID: Int64, title: String, seasonTypeName: String, episodes: [BilibiliBangumiEpisode]) {
        self.seasonID = seasonID
        self.title = title
        self.seasonTypeName = seasonTypeName
        self.episodes = episodes
    }
}

/// A search hit, before any episode has been resolved. Search results are
/// deliberately shallow: resolving every candidate's episode list would be
/// dozens of requests, so the matcher ranks on what search returns and only
/// the winners are expanded.
public enum BilibiliSearchHit: Hashable, Sendable {
    case bangumi(BilibiliSearchBangumi)
    case video(BilibiliSearchVideo)

    public var title: String {
        switch self {
        case let .bangumi(item): item.title
        case let .video(item): item.title
        }
    }
}

public struct BilibiliSearchBangumi: Hashable, Sendable {
    public let seasonID: Int64
    public let mediaID: Int64
    public let title: String
    /// Original-language title when Bilibili carries one (usually Japanese).
    public let originalTitle: String
    public let seasonTypeName: String
    /// Number of episodes the catalogue lists, when reported.
    public let episodeCount: Int?

    public init(
        seasonID: Int64,
        mediaID: Int64,
        title: String,
        originalTitle: String,
        seasonTypeName: String,
        episodeCount: Int?
    ) {
        self.seasonID = seasonID
        self.mediaID = mediaID
        self.title = title
        self.originalTitle = originalTitle
        self.seasonTypeName = seasonTypeName
        self.episodeCount = episodeCount
    }
}

public struct BilibiliSearchVideo: Hashable, Sendable {
    public let aid: Int64
    public let bvid: String
    public let title: String
    public let author: String
    public let typeName: String
    /// Duration in seconds, parsed from the "MM:SS" string search returns.
    public let duration: Double?

    public init(aid: Int64, bvid: String, title: String, author: String, typeName: String, duration: Double?) {
        self.aid = aid
        self.bvid = bvid
        self.title = title
        self.author = author
        self.typeName = typeName
        self.duration = duration
    }
}

/// The provider state stored on a match so a later fetch can reproduce it
/// without searching again. Serialized as JSON into
/// `DanmakuEpisodeRef.providerContext`.
public struct BilibiliDanmakuContext: Codable, Hashable, Sendable {
    /// The danmaku pool id — the part's own `cid`.
    public let cid: Int64
    /// Sent as `pid`; optional in the API but improves acceptance.
    public let aid: Int64?
    public let bvid: String?
    public let seasonID: Int64?
    public let episodeID: Int64?
    /// Bilibili's duration for this part in seconds, used to size the
    /// segment sweep when the local file's duration is unknown.
    public let duration: Double?

    public init(
        cid: Int64,
        aid: Int64? = nil,
        bvid: String? = nil,
        seasonID: Int64? = nil,
        episodeID: Int64? = nil,
        duration: Double? = nil
    ) {
        self.cid = cid
        self.aid = aid
        self.bvid = bvid
        self.seasonID = seasonID
        self.episodeID = episodeID
        self.duration = duration
    }

    public func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ raw: String?) -> BilibiliDanmakuContext? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BilibiliDanmakuContext.self, from: data)
    }
}
