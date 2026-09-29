import Foundation

/// The contract between AnimeGod on the Mac and AnimeGod on the phone.
///
/// Design: `docs/IOS_COMPANION_PLAN.md`. Both apps link this file, so a field
/// cannot drift between the two sides — that is the whole reason it lives in
/// the core rather than being written twice.
public enum LinkProtocol {
    /// Bumped whenever a payload changes shape. The phone refuses to talk to
    /// a Mac whose major differs, rather than decoding half a response and
    /// showing a library with holes in it.
    public static let version = 1

    /// Default port. Chosen in the dynamic/private range, away from anything
    /// the BitTorrent engine might pick.
    public static let defaultPort: UInt16 = 47380

    /// What the Mac advertises over Bonjour.
    public static let bonjourType = "_animegod._tcp"

    public enum Route {
        public static let health = "/health"
        public static let pair = "/pair"
        public static let library = "/library"
        public static let continueWatching = "/continue-watching"
        public static let events = "/events"
        /// `/anime/{id}`
        public static let animePrefix = "/anime/"
        /// `/media/{mediaFileID}`
        public static let mediaPrefix = "/media/"
        /// `/poster/{animeID}`
        public static let posterPrefix = "/poster/"
        /// `/danmaku/{mediaFileID}`
        public static let danmakuPrefix = "/danmaku/"
        /// `/progress/{episodeID}`
        public static let progressPrefix = "/progress/"
        /// `/episodes/{episodeID}/watched`
        public static let episodesPrefix = "/episodes/"
        public static let handoffClaim = "/handoff/claim"
        public static let handoffRelease = "/handoff/release"
    }

    public static let authorizationHeader = "Authorization"
    public static let bearerPrefix = "Bearer "
}

/// Why a request was refused. The phone shows different things for "pair
/// again" and "your Mac is a different version", so these cannot collapse
/// into one generic failure.
public enum LinkErrorCode: String, Codable, Sendable {
    case unauthorized
    case protocolMismatch
    case notFound
    case badRequest
    case pairingClosed
    case pairingRejected
    case claimHeldElsewhere
    case unavailable
}

public struct LinkError: Codable, Error, Sendable {
    public let code: LinkErrorCode
    public let message: String

    public init(code: LinkErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}
