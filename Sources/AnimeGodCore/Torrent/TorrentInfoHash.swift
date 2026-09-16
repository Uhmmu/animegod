import Foundation

/// A BitTorrent v1 info hash (BTIH), always stored as 40 lowercase hex digits.
///
/// Sources disagree on encoding: Nyaa and bangumi.moe publish hex, while
/// dmhy, AnimeTosho and SubsPlease put 32-character base32 into their
/// magnets. Normalizing both is what lets one release found on several sites
/// merge into a single result.
public struct TorrentInfoHash: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let hex: String

    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 40, trimmed.allSatisfy(\.isHexDigit) {
            hex = trimmed.lowercased()
        } else if trimmed.count == 32, let decoded = Self.base32Decode(trimmed.uppercased()), decoded.count == 20 {
            hex = decoded.map { String(format: "%02x", $0) }.joined()
        } else {
            return nil
        }
    }

    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 20 else { return nil }
        hex = bytes.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { hex }

    public static func < (lhs: TorrentInfoHash, rhs: TorrentInfoHash) -> Bool { lhs.hex < rhs.hex }

    private static func base32Decode(_ value: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer = 0
        var bits = 0
        var output: [UInt8] = []
        for character in value {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return output
    }
}

/// The parts of a magnet link AnimeGod cares about.
public struct MagnetLink: Hashable, Sendable {
    public var infoHash: TorrentInfoHash
    public var displayName: String?
    public var trackers: [String]
    /// `xl` — exact length in bytes, when the publisher included it.
    public var exactLength: Int64?

    public init(infoHash: TorrentInfoHash, displayName: String? = nil, trackers: [String] = [], exactLength: Int64? = nil) {
        self.infoHash = infoHash
        self.displayName = displayName
        self.trackers = trackers
        self.exactLength = exactLength
    }

    /// Parses a `magnet:?xt=urn:btih:…` URI. A magnet carrying several
    /// conflicting BTIH values is rejected rather than guessed at.
    public init?(_ uri: String) {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("magnet:?") else { return nil }
        let query = trimmed.dropFirst("magnet:?".count)
        var hashes: Set<TorrentInfoHash> = []
        var name: String?
        var trackers: [String] = []
        var length: Int64?
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            // Magnets in the wild use "+" for spaces in dn.
            let raw = String(parts[1]).replacingOccurrences(of: "+", with: " ")
            let value = raw.removingPercentEncoding ?? raw
            switch key {
            case "xt":
                guard value.lowercased().hasPrefix("urn:btih:") else { continue }
                guard let hash = TorrentInfoHash(String(value.dropFirst("urn:btih:".count))) else { return nil }
                hashes.insert(hash)
            case "dn":
                if !value.isEmpty { name = value }
            case "tr":
                if !value.isEmpty, !trackers.contains(value) { trackers.append(value) }
            case "xl":
                length = Int64(value)
            default:
                continue
            }
        }
        guard hashes.count == 1, let hash = hashes.first else { return nil }
        self.init(infoHash: hash, displayName: name, trackers: trackers, exactLength: length)
    }

    /// Serializes with hex BTIH, which every client accepts.
    public var uri: String {
        var parts = ["magnet:?xt=urn:btih:\(infoHash.hex)"]
        if let displayName, !displayName.isEmpty {
            parts.append("dn=\(Self.encode(displayName))")
        }
        if let exactLength, exactLength > 0 {
            parts.append("xl=\(exactLength)")
        }
        parts += trackers.map { "tr=\(Self.encode($0))" }
        return parts.joined(separator: "&")
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public enum TorrentTrackers {
    /// Public trackers appended to every magnet, as magnet-crawler did, so a
    /// link copied from a tracker-less feed still finds peers.
    public static let common: [String] = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://open.demonii.com:1337/announce",
        "http://nyaa.tracker.wf:7777/announce",
        "https://tracker.anibt.net/announce",
        "http://open.acgnxtracker.com:80/announce"
    ]
}
