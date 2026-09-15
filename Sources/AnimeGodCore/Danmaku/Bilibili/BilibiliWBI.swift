import CryptoKit
import Foundation

/// Bilibili's WBI request signature.
///
/// Newer web endpoints (`/x/web-interface/wbi/...`, and increasingly the
/// danmaku segment endpoint) reject unsigned queries. The scheme is public
/// and unauthenticated — it identifies the *client*, not a user:
///
/// 1. `GET /x/web-interface/nav` returns two rotating asset URLs; the file
///    names (without extension) are `img_key` and `sub_key`.
/// 2. `mixin_key` = the first 32 characters of `img_key + sub_key` reordered
///    by a fixed 64-entry permutation table.
/// 3. The request's parameters plus `wts` (Unix seconds) are sorted by key,
///    their values stripped of `!'()*`, then percent-encoded into a query
///    string.
/// 4. `w_rid = md5(query + mixin_key)`, sent alongside `wts`.
///
/// The keys rotate daily, so `BilibiliSession` caches them per calendar day.
public enum BilibiliWBI {
    /// The permutation Bilibili's web player applies to `img_key + sub_key`.
    /// These indices are part of the protocol; they are not a secret and
    /// not derivable.
    static let mixinKeyTable: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
    ]

    /// The daily signing keys, with the day they were fetched so a stale set
    /// is refreshed rather than silently producing rejected signatures.
    public struct Keys: Hashable, Sendable {
        public let imgKey: String
        public let subKey: String
        public let fetchedAt: Date

        public init(imgKey: String, subKey: String, fetchedAt: Date = .now) {
            self.imgKey = imgKey
            self.subKey = subKey
            self.fetchedAt = fetchedAt
        }

        /// Keys roll over at midnight in Bilibili's own timezone (UTC+8).
        public func isFresh(at date: Date = .now) -> Bool {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt
            return calendar.isDate(fetchedAt, inSameDayAs: date) && date >= fetchedAt
        }
    }

    /// Extracts a key from an asset URL such as
    /// `https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png`.
    public static func key(fromAssetURL url: String) -> String? {
        guard let name = url.split(separator: "/").last else { return nil }
        let stem = name.split(separator: ".").first.map(String.init) ?? String(name)
        return stem.isEmpty ? nil : stem
    }

    public static func mixinKey(imgKey: String, subKey: String) -> String {
        let raw = Array(imgKey + subKey)
        guard !raw.isEmpty else { return "" }
        var mixed = ""
        mixed.reserveCapacity(32)
        for index in mixinKeyTable where index < raw.count {
            mixed.append(raw[index])
            if mixed.count == 32 { break }
        }
        return mixed
    }

    /// Signs `parameters`, returning them with `wts` and `w_rid` added.
    /// Sorting and encoding here must match what the caller actually sends,
    /// so callers build their query from the returned pairs.
    public static func sign(
        parameters: [String: String],
        keys: Keys,
        timestamp: Date = .now
    ) -> [URLQueryItem] {
        let mixin = mixinKey(imgKey: keys.imgKey, subKey: keys.subKey)
        var signed = parameters
        let wts = String(Int(timestamp.timeIntervalSince1970))
        signed["wts"] = wts

        let canonical = signed
            .map { (key: $0.key, value: sanitize($0.value)) }
            .sorted { $0.key < $1.key }
        let query = canonical
            .map { "\(encode($0.key))=\(encode($0.value))" }
            .joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + mixin).utf8))
        let wrid = digest.map { String(format: "%02x", $0) }.joined()

        return canonical.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "w_rid", value: wrid)]
    }

    /// Builds the exact percent-encoded query string for `items`.
    ///
    /// `URLComponents.queryItems` must not be used for signed requests: it
    /// leaves characters such as `+`, `/` and `:` unescaped, so the string
    /// on the wire would differ from the one that was hashed. Callers assign
    /// this to `percentEncodedQuery` instead.
    public static func queryString(for items: [URLQueryItem]) -> String {
        items
            .map { "\(encode($0.name))=\(encode($0.value ?? ""))" }
            .joined(separator: "&")
    }

    /// Bilibili strips these characters from values before signing; leaving
    /// them in produces a signature the server will not reproduce.
    static func sanitize(_ value: String) -> String {
        value.filter { !"!'()*".contains($0) }
    }

    /// RFC 3986 percent-encoding of everything outside the unreserved set.
    /// `URLComponents` uses the same rule when the query items above are
    /// turned back into a URL, so the signed string and the sent string
    /// agree.
    static func encode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
