import Foundation

// The wire types. Deliberately flat and self-describing: the phone renders
// straight from these, so anything the UI needs has to be here rather than
// derived from a second request.

public struct LinkHealth: Codable, Sendable {
    public let name: String
    public let appVersion: String
    public let protocolVersion: Int
    /// Whether this Mac will currently accept a pairing code.
    public let isPairing: Bool

    public init(name: String, appVersion: String, protocolVersion: Int = LinkProtocol.version, isPairing: Bool) {
        self.name = name
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.isPairing = isPairing
    }
}

public struct LinkPairRequest: Codable, Sendable {
    public let code: String
    public let deviceName: String

    public init(code: String, deviceName: String) {
        self.code = code
        self.deviceName = deviceName
    }
}

public struct LinkPairResponse: Codable, Sendable {
    public let token: String
    public let macName: String

    public init(token: String, macName: String) {
        self.token = token
        self.macName = macName
    }
}

/// One row of the grid.
///
/// `displayTitle` and `sortKey` are sent rather than derived, because the Mac
/// sorts over the title the metadata gave the work while `anime.sortTitle`
/// holds the folder's romaji name. A phone that sorted on the stored column
/// would show the same works in a different order.
public struct LinkWork: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let displayTitle: String
    public let originalTitle: String?
    public let sortKey: String
    public let kind: AnimeKind
    public let posterPath: String?
    public let score: Double?
    public let episodeCount: Int
    public let watchedCount: Int
    public let unwatchedCount: Int
    public let lastWatchedAt: Date?
    public let lastPlayedAt: Date?
    public let createdAt: Date

    public var isFinished: Bool { episodeCount > 0 && watchedCount >= episodeCount }
    public var isInProgress: Bool { !isFinished && lastPlayedAt != nil }

    public init(
        id: UUID,
        displayTitle: String,
        originalTitle: String?,
        sortKey: String,
        kind: AnimeKind,
        posterPath: String?,
        score: Double?,
        episodeCount: Int,
        watchedCount: Int,
        unwatchedCount: Int,
        lastWatchedAt: Date?,
        lastPlayedAt: Date?,
        createdAt: Date
    ) {
        self.id = id
        self.displayTitle = displayTitle
        self.originalTitle = originalTitle
        self.sortKey = sortKey
        self.kind = kind
        self.posterPath = posterPath
        self.score = score
        self.episodeCount = episodeCount
        self.watchedCount = watchedCount
        self.unwatchedCount = unwatchedCount
        self.lastWatchedAt = lastWatchedAt
        self.lastPlayedAt = lastPlayedAt
        self.createdAt = createdAt
    }
}

public struct LinkLibrary: Codable, Sendable {
    public let works: [LinkWork]
    public let generatedAt: Date

    public init(works: [LinkWork], generatedAt: Date = .now) {
        self.works = works
        self.generatedAt = generatedAt
    }
}

public struct LinkEpisode: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let animeID: UUID
    /// The canonical English label (`Episode 3`, `Creditless Opening`). Stored
    /// labels stay canonical; the phone localizes with `Episode.localizedLabel`.
    public let label: String
    public let title: String?
    public let kind: EpisodeKind
    public let sortIndex: Double
    public let mediaFileID: UUID
    public let fileSize: Int64
    public let position: Double
    public let duration: Double
    public let isWatched: Bool
    public let updatedAt: Date?

    public var completion: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    public init(
        id: UUID,
        animeID: UUID,
        label: String,
        title: String?,
        kind: EpisodeKind,
        sortIndex: Double,
        mediaFileID: UUID,
        fileSize: Int64,
        position: Double,
        duration: Double,
        isWatched: Bool,
        updatedAt: Date?
    ) {
        self.id = id
        self.animeID = animeID
        self.label = label
        self.title = title
        self.kind = kind
        self.sortIndex = sortIndex
        self.mediaFileID = mediaFileID
        self.fileSize = fileSize
        self.position = position
        self.duration = duration
        self.isWatched = isWatched
        self.updatedAt = updatedAt
    }
}

public struct LinkAnimeDetail: Codable, Sendable {
    public let work: LinkWork
    public let summary: String
    public let episodes: [LinkEpisode]
    /// One entry per matched provider, for the ratings row.
    public let sources: [LinkMetadataSource]

    public init(work: LinkWork, summary: String, episodes: [LinkEpisode], sources: [LinkMetadataSource]) {
        self.work = work
        self.summary = summary
        self.episodes = episodes
        self.sources = sources
    }
}

public struct LinkMetadataSource: Codable, Sendable, Hashable {
    public let provider: String
    public let displayName: String
    public let score: Double?
    public let ratingCount: Int?
    public let sourceURL: URL?

    public init(provider: String, displayName: String, score: Double?, ratingCount: Int?, sourceURL: URL?) {
        self.provider = provider
        self.displayName = displayName
        self.score = score
        self.ratingCount = ratingCount
        self.sourceURL = sourceURL
    }
}

public struct LinkProgressUpdate: Codable, Sendable {
    public let position: Double
    public let duration: Double
    /// nil lets the Mac's tail rule decide, exactly as the Mac player does.
    public let isWatched: Bool?
    public let overridesWatched: Bool

    public init(position: Double, duration: Double, isWatched: Bool? = nil, overridesWatched: Bool = false) {
        self.position = position
        self.duration = duration
        self.isWatched = isWatched
        self.overridesWatched = overridesWatched
    }
}

// MARK: - Handoff

public struct LinkHandoffClaim: Codable, Sendable {
    public let episodeID: UUID
    public let deviceName: String
    /// Take it from whoever holds it. Offered only after a 409 has already
    /// told the viewer who that is — silently stealing an episode someone is
    /// watching in another room is worse than asking.
    public let force: Bool

    public init(episodeID: UUID, deviceName: String, force: Bool = false) {
        self.episodeID = episodeID
        self.deviceName = deviceName
        self.force = force
    }
}

/// Who is watching this episode right now, when it is not you.
///
/// An `Error` so it can be the failure side of a `Result`: it travels as one
/// of two ordinary outcomes of a claim, not as something that went wrong.
public struct LinkHandoffConflict: Codable, Sendable, Error {
    public let holder: String

    public init(holder: String) {
        self.holder = holder
    }
}

/// The session, not just the timestamp.
///
/// The phone resumes what the viewer had set up — track choices, speed, where
/// the subtitles were nudged to — because arriving at the right second with
/// the wrong audio track is still an interruption.
public struct LinkHandoffState: Codable, Sendable {
    public let position: Double
    public let duration: Double
    public let isWatched: Bool
    public let keepsUnwatched: Bool
    public let speed: Double
    public let audioTrackID: Int64?
    public let subtitleTrackID: Int64?
    public let subtitleDelay: Double
    /// False when the Mac was not playing this episode: the position is then
    /// the stored one, which may be up to ten seconds stale.
    public let wasPlayingHere: Bool

    public init(
        position: Double,
        duration: Double,
        isWatched: Bool,
        keepsUnwatched: Bool,
        speed: Double = 1,
        audioTrackID: Int64? = nil,
        subtitleTrackID: Int64? = nil,
        subtitleDelay: Double = 0,
        wasPlayingHere: Bool
    ) {
        self.position = position
        self.duration = duration
        self.isWatched = isWatched
        self.keepsUnwatched = keepsUnwatched
        self.speed = speed
        self.audioTrackID = audioTrackID
        self.subtitleTrackID = subtitleTrackID
        self.subtitleDelay = subtitleDelay
        self.wasPlayingHere = wasPlayingHere
    }
}

public struct LinkHandoffRelease: Codable, Sendable {
    public let episodeID: UUID
    public let position: Double
    public let duration: Double
    /// Whether the Mac should reopen the player where the phone stopped.
    public let resumeOnMac: Bool

    public init(episodeID: UUID, position: Double, duration: Double, resumeOnMac: Bool) {
        self.episodeID = episodeID
        self.position = position
        self.duration = duration
        self.resumeOnMac = resumeOnMac
    }
}

/// The danmaku the Mac resolved for one file.
///
/// The phone is handed a finished pool. Everything hard about getting one
/// happened on the Mac already: dandanplay's 16 MB file hash, Bilibili's
/// `buvid3` bootstrap and daily WBI key signing, the per-part `cid`, the
/// cross-source merge with each provider's shift baked in, and the cache. The
/// phone needs no credentials and cannot disagree with the Mac about which
/// pool belongs to which file.
public struct LinkDanmakuPool: Codable, Sendable {
    public let mediaFileID: UUID
    public let comments: [DanmakuComment]
    /// One line per provider that contributed, for the "where did these come
    /// from" row.
    public let sources: [String]
    /// Set when no provider matched the file, so the phone can say so rather
    /// than showing an empty screen that looks like a failure.
    public let unmatched: Bool

    public init(mediaFileID: UUID, comments: [DanmakuComment], sources: [String], unmatched: Bool) {
        self.mediaFileID = mediaFileID
        self.comments = comments
        self.sources = sources
        self.unmatched = unmatched
    }
}

// MARK: - The More tab

/// The diary: what was watched, and the totals under it.
public struct LinkDiary: Codable, Sendable {
    public let events: [WatchEvent]
    public let summary: DiarySummary

    public init(events: [WatchEvent], summary: DiarySummary) {
        self.events = events
        self.summary = summary
    }
}

/// A work in the viewer's own ordering, with what the card needs to draw it.
public struct LinkRankedWork: Codable, Sendable, Identifiable {
    public let animeID: UUID
    public let displayTitle: String
    public let ranking: Int?
    public let score: Double?
    public let status: WatchStatus
    public let isFavorite: Bool
    public let review: String

    public var id: UUID { animeID }

    public init(
        animeID: UUID, displayTitle: String, ranking: Int?, score: Double?,
        status: WatchStatus, isFavorite: Bool, review: String
    ) {
        self.animeID = animeID
        self.displayTitle = displayTitle
        self.ranking = ranking
        self.score = score
        self.status = status
        self.isFavorite = isFavorite
        self.review = review
    }
}

public struct LinkCharts: Codable, Sendable {
    public let channel: String
    public let page: Int
    public let totalPages: Int
    public let entries: [BangumiChartEntry]

    public init(channel: String, page: Int, totalPages: Int, entries: [BangumiChartEntry]) {
        self.channel = channel
        self.page = page
        self.totalPages = totalPages
        self.entries = entries
    }
}

/// A running download, flattened.
///
/// The phone is a remote control here, not a second engine: it gets what a row
/// needs to draw and the three things it may ask for, not the torrent record.
public struct LinkDownload: Codable, Sendable, Identifiable {
    public let infoHash: String
    public let title: String
    public let animeTitle: String?
    public let progress: Double
    public let totalBytes: Int64
    public let downloadRate: Int64
    public let uploadRate: Int64
    public let peers: Int
    public let state: String
    public let isPaused: Bool
    public let isComplete: Bool
    public let isAutomatic: Bool

    public var id: String { infoHash }

    public init(
        infoHash: String, title: String, animeTitle: String?, progress: Double,
        totalBytes: Int64, downloadRate: Int64, uploadRate: Int64, peers: Int,
        state: String, isPaused: Bool, isComplete: Bool, isAutomatic: Bool
    ) {
        self.infoHash = infoHash
        self.title = title
        self.animeTitle = animeTitle
        self.progress = progress
        self.totalBytes = totalBytes
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.peers = peers
        self.state = state
        self.isPaused = isPaused
        self.isComplete = isComplete
        self.isAutomatic = isAutomatic
    }
}

/// A standing rule, flattened the same way.
public struct LinkSubscription: Codable, Sendable, Identifiable {
    public let id: UUID
    public let animeID: UUID?
    public let title: String
    public let summary: String
    public let isEnabled: Bool
    public let isSeasonComplete: Bool
    public let nextEpisode: Double?
    public let estimatedNextAt: Date?
    public let waitingCount: Int

    public init(
        id: UUID, animeID: UUID?, title: String, summary: String, isEnabled: Bool,
        isSeasonComplete: Bool, nextEpisode: Double?, estimatedNextAt: Date?, waitingCount: Int
    ) {
        self.id = id
        self.animeID = animeID
        self.title = title
        self.summary = summary
        self.isEnabled = isEnabled
        self.isSeasonComplete = isSeasonComplete
        self.nextEpisode = nextEpisode
        self.estimatedNextAt = estimatedNextAt
        self.waitingCount = waitingCount
    }
}

public enum LinkCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
