import Foundation

/// The cookie jar every Bilibili request shares.
///
/// Bilibili's web endpoints expect a browser-shaped client. Even fully
/// anonymous access needs a `buvid3` device cookie — without it the search
/// and WBI endpoints answer `-412` (risk control). A signed-in user can
/// additionally supply `SESSDATA`, which unlocks region/membership-limited
/// titles; it is strictly optional and the provider degrades to anonymous
/// access when it is absent.
///
/// Cookies are held in memory only. `SESSDATA` is a credential: it is never
/// logged and never written to disk by this type — persistence (Keychain)
/// is the app layer's decision.
public actor BilibiliCookieStore {
    /// Optional cookies from a signed-in browser session.
    public struct UserCredentials: Sendable, Hashable {
        public var sessData: String?
        public var biliJct: String?
        public var dedeUserID: String?

        public init(sessData: String? = nil, biliJct: String? = nil, dedeUserID: String? = nil) {
            self.sessData = sessData.flatMap(Self.normalized)
            self.biliJct = biliJct.flatMap(Self.normalized)
            self.dedeUserID = dedeUserID.flatMap(Self.normalized)
        }

        public var isEmpty: Bool { sessData == nil }

        private static func normalized(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private var cookies: [String: String] = [:]

    public init(user: UserCredentials = UserCredentials()) {
        // The actor's own initializer runs before isolation is established,
        // so the jar is seeded directly rather than through `apply`.
        if let value = user.sessData { cookies["SESSDATA"] = value }
        if let value = user.biliJct { cookies["bili_jct"] = value }
        if let value = user.dedeUserID { cookies["DedeUserID"] = value }
    }

    /// Replaces the user cookies, keeping anonymous device cookies intact.
    public func apply(user: UserCredentials) {
        for name in ["SESSDATA", "bili_jct", "DedeUserID"] { cookies[name] = nil }
        if let value = user.sessData { cookies["SESSDATA"] = value }
        if let value = user.biliJct { cookies["bili_jct"] = value }
        if let value = user.dedeUserID { cookies["DedeUserID"] = value }
    }

    public func set(_ value: String, for name: String) {
        cookies[name] = value
    }

    public func value(for name: String) -> String? { cookies[name] }

    /// True once a device identity exists — the precondition for search and
    /// other WBI endpoints.
    public var hasDeviceIdentity: Bool { cookies["buvid3"]?.isEmpty == false }

    public var isSignedIn: Bool { cookies["SESSDATA"]?.isEmpty == false }

    /// The `Cookie` header value, or nil when the jar is empty.
    public var header: String? {
        guard !cookies.isEmpty else { return nil }
        return cookies
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// Absorbs `Set-Cookie` headers from a response. Only the name/value
    /// pair matters here; attributes (Path, Domain, Expires) are ignored
    /// because the jar is scoped to Bilibili for the lifetime of a session.
    public func ingest(response: HTTPURLResponse) {
        guard let url = response.url else { return }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders(response), for: url)
        for cookie in parsed where !cookie.value.isEmpty {
            cookies[cookie.name] = cookie.value
        }
    }

    private func stringHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            result[key] = value
        }
        return result
    }
}
