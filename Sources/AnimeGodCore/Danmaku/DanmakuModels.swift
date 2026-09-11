import Foundation

/// How a comment is displayed. Derived from the provider's raw mode codes
/// but never exposing them: new providers translate their own codes into
/// these three presentation intents.
public enum DanmakuMode: String, Codable, Sendable, CaseIterable {
    /// Right-to-left scrolling comment.
    case scroll
    /// Fixed at the top of the display area.
    case top
    /// Fixed at the bottom of the display area.
    case bottom

    public var displayName: String {
        switch self {
        case .scroll: "Scrolling"
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }
}

/// Provider-independent danmaku comment. Timestamps keep sub-second
/// precision; color is a plain 24-bit RGB value with white as the default.
public struct DanmakuComment: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    /// Appearance time in media seconds (already includes any provider
    /// shift; the user's timing offset is applied by the engine, not here).
    public let time: Double
    public let text: String
    public let mode: DanmakuMode
    /// 0xRRGGBB. White (0xFFFFFF) comments render without a tint.
    public let color: Int
    /// Provider sender identifier when available (dandanplay's user ID).
    public let senderID: String?
    /// When the comment was posted, when the provider reports it.
    public let timestamp: Date?

    public init(
        id: String,
        time: Double,
        text: String,
        mode: DanmakuMode,
        color: Int = 0xFFFFFF,
        senderID: String? = nil,
        timestamp: Date? = nil
    ) {
        self.id = id
        self.time = time
        self.text = text
        self.mode = mode
        self.color = color
        self.senderID = senderID
        self.timestamp = timestamp
    }

    public var isColored: Bool { color != 0xFFFFFF }
}

/// One candidate from automatic file identification.
public struct DanmakuMatchCandidate: Codable, Hashable, Sendable {
    public let animeID: Int64
    public let animeTitle: String
    public let episodeID: Int64
    public let episodeTitle: String
    /// Provider-reported danmaku time shift in seconds (positive delays).
    public let shift: Double
    public let typeDescription: String

    public init(
        animeID: Int64,
        animeTitle: String,
        episodeID: Int64,
        episodeTitle: String,
        shift: Double = 0,
        typeDescription: String = ""
    ) {
        self.animeID = animeID
        self.animeTitle = animeTitle
        self.episodeID = episodeID
        self.episodeTitle = episodeTitle
        self.shift = shift
        self.typeDescription = typeDescription
    }
}

/// Outcome of automatic media identification.
public struct DanmakuMatchResult: Hashable, Sendable {
    public let isMatched: Bool
    public let candidates: [DanmakuMatchCandidate]

    public init(isMatched: Bool, candidates: [DanmakuMatchCandidate] = []) {
        self.isMatched = isMatched
        self.candidates = candidates
    }

    public var best: DanmakuMatchCandidate? { candidates.first }
}

/// An anime found by manual search, with the episodes the provider exposes.
public struct DanmakuSearchedAnime: Codable, Identifiable, Hashable, Sendable {
    public let animeID: Int64
    public let animeTitle: String
    public let typeDescription: String
    public let episodes: [DanmakuSearchedEpisode]

    public var id: Int64 { animeID }

    public init(animeID: Int64, animeTitle: String, typeDescription: String, episodes: [DanmakuSearchedEpisode]) {
        self.animeID = animeID
        self.animeTitle = animeTitle
        self.typeDescription = typeDescription
        self.episodes = episodes
    }
}

public struct DanmakuSearchedEpisode: Codable, Hashable, Sendable {
    public let episodeID: Int64
    public let episodeTitle: String

    public init(episodeID: Int64, episodeTitle: String) {
        self.episodeID = episodeID
        self.episodeTitle = episodeTitle
    }
}

/// The identity of the danmaku a provider serves for one episode. This is
/// the stable cache identity — never the local filename.
public struct DanmakuEpisodeRef: Codable, Hashable, Sendable {
    public let providerID: String
    public let episodeID: Int64
    public let animeTitle: String
    public let episodeTitle: String
    /// Provider-reported danmaku shift in seconds, applied on load.
    public let shift: Double

    public init(providerID: String, episodeID: Int64, animeTitle: String, episodeTitle: String, shift: Double = 0) {
        self.providerID = providerID
        self.episodeID = episodeID
        self.animeTitle = animeTitle
        self.episodeTitle = episodeTitle
        self.shift = shift
    }

    /// Cache key: provider + episode identity.
    public var cacheKey: String { "\(providerID):\(episodeID)" }
}

public struct DanmakuProviderMetadata: Hashable, Sendable {
    public let id: String
    public let displayName: String
    /// Credit line shown in the danmaku UI (API terms / good practice).
    public let attribution: String?

    public init(id: String, displayName: String, attribution: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.attribution = attribution
    }
}

public enum DanmakuProviderError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case invalidResponse
    case httpStatus(Int)
    case serviceMessage(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "The danmaku provider is not configured."
        case .invalidResponse: "The danmaku service returned an invalid response."
        case let .httpStatus(status): "The danmaku service returned HTTP \(status)."
        case let .serviceMessage(message): message
        }
    }

    public static func == (lhs: DanmakuProviderError, rhs: DanmakuProviderError) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }
}
