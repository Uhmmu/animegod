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
