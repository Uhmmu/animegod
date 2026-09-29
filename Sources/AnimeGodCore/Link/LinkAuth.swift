import CryptoKit
import Foundation

/// Pairing and token checks.
///
/// The threat this defends against is modest but real: the server binds to
/// every interface so the phone can find it, which means anything else on the
/// network can knock on it too. A token on every request — including from
/// localhost, because "it came from this machine" is not an identity — is the
/// whole of the access control, so the comparison must not leak.
public enum LinkAuth {
    /// A 6-digit code, shown on the Mac and typed on the phone. Short because
    /// someone has to read it off a screen; safe because it lives five minutes
    /// and dies after five wrong guesses.
    public static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    public static let pairingLifetime: TimeInterval = 5 * 60
    public static let pairingAttemptLimit = 5

    /// The long-lived device token: 32 random bytes, base64url, no padding.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time equality.
    ///
    /// A plain `==` on a secret returns as soon as two bytes differ, which
    /// tells an attacker how much of a guess was right. It costs one function
    /// to not do that.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        // The lengths themselves are not secret — tokens are fixed width —
        // but comparing different lengths must still take the same path.
        var difference = UInt8(x.count == y.count ? 0 : 1)
        let count = max(x.count, y.count)
        guard count > 0 else { return difference == 0 }
        for i in 0..<count {
            let lhs = i < x.count ? x[i] : 0
            let rhs = i < y.count ? y[i] : 0
            difference |= lhs ^ rhs
        }
        return difference == 0
    }

    /// Pulls the token out of `Authorization: Bearer <token>`.
    public static func bearerToken(from headerValue: String?) -> String? {
        guard let headerValue else { return nil }
        let trimmed = headerValue.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > LinkProtocol.bearerPrefix.count else { return nil }
        let prefix = String(trimmed.prefix(LinkProtocol.bearerPrefix.count))
        guard prefix.caseInsensitiveCompare(LinkProtocol.bearerPrefix) == .orderedSame else { return nil }
        let token = String(trimmed.dropFirst(LinkProtocol.bearerPrefix.count)).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

/// A phone that has been paired.
public struct LinkPairedDevice: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var token: String
    public var pairedAt: Date
    public var lastSeenAt: Date?

    public init(id: UUID = UUID(), name: String, token: String, pairedAt: Date = .now, lastSeenAt: Date? = nil) {
        self.id = id
        self.name = name
        self.token = token
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}
