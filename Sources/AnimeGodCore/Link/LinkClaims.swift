import Foundation

/// Who is playing what.
///
/// Two devices driving one episode is worse than either of them not having it:
/// both write progress, and the one that saves last wins whatever the viewer
/// actually watched. So an episode is claimed, and the claim is **leased**
/// rather than held outright — if the phone dies on the bus there is nothing
/// left to release it, and an episode nobody can play again is a worse failure
/// than a rare double-play.
///
/// The holder renews by writing progress, which it does every ten seconds
/// anyway, so there is no heartbeat of its own to get wrong.
public struct LinkClaimRegistry: Sendable {
    public struct Claim: Sendable, Equatable {
        public let deviceID: UUID
        public let deviceName: String
        public var expiresAt: Date

        public init(deviceID: UUID, deviceName: String, expiresAt: Date) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.expiresAt = expiresAt
        }
    }

    public enum Outcome: Sendable, Equatable {
        case granted
        /// Someone else has it and did not ask to take over.
        case heldBy(String)
    }

    public static let defaultLease: TimeInterval = 60

    private var claims: [UUID: Claim] = [:]
    private let lease: TimeInterval

    public init(lease: TimeInterval = LinkClaimRegistry.defaultLease) {
        self.lease = lease
    }

    /// The live holder of an episode, if there is one. An expired claim is not
    /// a holder, and is dropped on the way past.
    public mutating func holder(of episodeID: UUID, now: Date = .now) -> Claim? {
        guard let claim = claims[episodeID] else { return nil }
        guard claim.expiresAt > now else {
            claims.removeValue(forKey: episodeID)
            return nil
        }
        return claim
    }

    public mutating func claim(
        episodeID: UUID,
        deviceID: UUID,
        deviceName: String,
        force: Bool,
        now: Date = .now
    ) -> Outcome {
        if let existing = holder(of: episodeID, now: now), existing.deviceID != deviceID, !force {
            return .heldBy(existing.deviceName)
        }
        claims[episodeID] = Claim(
            deviceID: deviceID,
            deviceName: deviceName,
            expiresAt: now.addingTimeInterval(lease)
        )
        return .granted
    }

    /// Pushes the holder's lease out. A device that does not hold the episode
    /// renews nothing — a stale phone must not keep someone else's claim alive.
    public mutating func renew(episodeID: UUID, deviceID: UUID, now: Date = .now) {
        guard var claim = holder(of: episodeID, now: now), claim.deviceID == deviceID else { return }
        claim.expiresAt = now.addingTimeInterval(lease)
        claims[episodeID] = claim
    }

    /// Gives the episode up. Only the holder may; otherwise a phone coming
    /// back from the dead could hand an episode away from whoever has it now.
    public mutating func release(episodeID: UUID, deviceID: UUID, now: Date = .now) -> Bool {
        guard let existing = holder(of: episodeID, now: now) else {
            claims.removeValue(forKey: episodeID)
            return true
        }
        guard existing.deviceID == deviceID else { return false }
        claims.removeValue(forKey: episodeID)
        return true
    }
}
