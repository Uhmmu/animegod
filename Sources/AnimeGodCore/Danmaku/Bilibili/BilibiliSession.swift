import Foundation

/// Shared transport for every Bilibili request: browser-shaped headers, the
/// cookie jar, anonymous device bootstrap, and WBI signing.
///
/// Nothing in here knows about danmaku. `BilibiliAPIClient` layers the
/// endpoints on top, which keeps the risk-control workarounds in one place.
public actor BilibiliSession {
    /// Which danmaku segment endpoint to talk to. The plain endpoint still
    /// answers today; the WBI one is the web player's current path and is
    /// the safe landing spot if the plain one is locked down.
    public enum SegmentEndpoint: String, Sendable, CaseIterable {
        /// Try the plain endpoint, fall back to the WBI one on rejection.
        case automatic
        /// `/x/v2/dm/web/seg.so`
        case plain
        /// `/x/v2/dm/wbi/web/seg.so`
        case wbi

        public var displayName: String {
            switch self {
            case .automatic: String(localized: "Automatic", bundle: .module)
            case .plain: String(localized: "Plain (seg.so)", bundle: .module)
            case .wbi: String(localized: "WBI signed", bundle: .module)
            }
        }
    }

    public struct Configuration: Sendable {
        public var apiHost = URL(string: "https://api.bilibili.com")!
        public var webHost = URL(string: "https://www.bilibili.com")!
        /// A desktop Safari UA. Bilibili rejects obviously scripted agents.
        public var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        public var segmentEndpoint: SegmentEndpoint = .automatic
        public var timeout: TimeInterval = 25

        public init() {}
    }

    private let urlSession: URLSession
    private let cookies: BilibiliCookieStore
    private var configuration: Configuration
    private var wbiKeys: BilibiliWBI.Keys?
    private var didBootstrap = false

    public init(
        cookies: BilibiliCookieStore = BilibiliCookieStore(),
        configuration: Configuration = Configuration(),
        urlSession: URLSession = .shared
    ) {
        self.cookies = cookies
        self.configuration = configuration
        self.urlSession = urlSession
    }

    public var segmentEndpoint: SegmentEndpoint { configuration.segmentEndpoint }
    public var cookieStore: BilibiliCookieStore { cookies }

    public func update(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Bootstrap

    /// Acquires an anonymous device identity (`buvid3`) once per session.
    ///
    /// Two independent routes, because either can be unavailable: the
    /// `finger/spi` endpoint hands out `b_3`/`b_4` directly, and loading the
    /// home page sets `buvid3` through `Set-Cookie`. Failure is not fatal —
    /// some endpoints still answer without it — so this never throws.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        if await cookies.hasDeviceIdentity { return }

        if let data = try? await rawGet(url: configuration.apiHost.appending(path: "x/frontend/finger/spi"), referer: nil),
           let envelope = try? JSONDecoder().decode(SPIEnvelope.self, from: data),
           let b3 = envelope.data?.b_3, !b3.isEmpty {
            await cookies.set(b3, for: "buvid3")
            if let b4 = envelope.data?.b_4, !b4.isEmpty { await cookies.set(b4, for: "buvid4") }
        }
        if await cookies.hasDeviceIdentity { return }
        _ = try? await rawGet(url: configuration.webHost, referer: nil)
    }

    // MARK: - WBI keys

    /// Returns today's signing keys, fetching them from `/x/web-interface/nav`
    /// when the cached pair is missing or from a previous day.
    public func currentWBIKeys() async throws -> BilibiliWBI.Keys {
        if let wbiKeys, wbiKeys.isFresh() { return wbiKeys }
        await bootstrap()
        let data = try await rawGet(url: configuration.apiHost.appending(path: "x/web-interface/nav"), referer: configuration.webHost.absoluteString)
        // `nav` reports code -101 for anonymous callers but still includes
        // the wbi_img block, so the envelope code is deliberately ignored.
        guard let envelope = try? JSONDecoder().decode(NavEnvelope.self, from: data),
              let image = envelope.data?.wbi_img,
              let imgKey = image.img_url.flatMap(BilibiliWBI.key(fromAssetURL:)),
              let subKey = image.sub_url.flatMap(BilibiliWBI.key(fromAssetURL:))
        else { throw DanmakuProviderError.invalidResponse }
        let keys = BilibiliWBI.Keys(imgKey: imgKey, subKey: subKey)
        wbiKeys = keys
        return keys
    }

    // MARK: - Requests

    /// Performs a GET and returns the raw body, signing the query with WBI
    /// when asked. Business errors are surfaced by the caller, since the
    /// danmaku endpoint answers with protobuf rather than JSON.
    public func data(
        host: URL? = nil,
        path: String,
        parameters: [String: String] = [:],
        signed: Bool,
        referer: String? = nil
    ) async throws -> Data {
        await bootstrap()
        let base = host ?? configuration.apiHost
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)
        guard components != nil else { throw DanmakuProviderError.invalidResponse }

        if signed {
            let items = BilibiliWBI.sign(parameters: parameters, keys: try await currentWBIKeys())
            components?.percentEncodedQuery = BilibiliWBI.queryString(for: items)
        } else if !parameters.isEmpty {
            let items = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            components?.percentEncodedQuery = BilibiliWBI.queryString(for: items)
        }
        guard let url = components?.url else { throw DanmakuProviderError.invalidResponse }
        return try await rawGet(url: url, referer: referer ?? configuration.webHost.absoluteString)
    }

    /// GET returning a decoded Bilibili JSON envelope's `data` payload,
    /// translating the business code into a `DanmakuProviderError`.
    public func json<Payload: Decodable & Sendable>(
        _ type: Payload.Type,
        host: URL? = nil,
        path: String,
        parameters: [String: String] = [:],
        signed: Bool,
        referer: String? = nil
    ) async throws -> Payload {
        let body = try await data(host: host, path: path, parameters: parameters, signed: signed, referer: referer)
        return try Self.decodeEnvelope(type, from: body)
    }

    static func decodeEnvelope<Payload: Decodable>(_ type: Payload.Type, from body: Data) throws -> Payload {
        guard let envelope = try? JSONDecoder().decode(Envelope<Payload>.self, from: body) else {
            throw DanmakuProviderError.invalidResponse
        }
        if let error = BilibiliAPIError.make(code: envelope.code, message: envelope.message ?? "") {
            throw error
        }
        // Bangumi (pgc) endpoints put the payload in `result`, everything
        // else in `data`.
        guard let payload = envelope.data ?? envelope.result else {
            throw DanmakuProviderError.invalidResponse
        }
        return payload
    }

    private func rawGet(url: URL, referer: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.timeout
        // The jar is managed explicitly so tests are deterministic and the
        // user's system cookie storage is never touched.
        request.httpShouldHandleCookies = false
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(configuration.webHost.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(referer ?? configuration.webHost.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        if let header = await cookies.header {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }

        let (body, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DanmakuProviderError.invalidResponse }
        await cookies.ingest(response: http)
        if http.statusCode == 412 { throw DanmakuProviderError.rejectedByRiskControl }
        guard (200..<300).contains(http.statusCode) else {
            throw DanmakuProviderError.httpStatus(http.statusCode)
        }
        return body
    }

    // MARK: - Envelopes

    struct Envelope<Payload: Decodable>: Decodable {
        let code: Int
        let message: String?
        let data: Payload?
        let result: Payload?
    }

    private struct NavEnvelope: Decodable {
        let data: NavData?

        struct NavData: Decodable {
            let wbi_img: WBIImage?
        }

        struct WBIImage: Decodable {
            let img_url: String?
            let sub_url: String?
        }
    }

    private struct SPIEnvelope: Decodable {
        let data: SPIData?

        struct SPIData: Decodable {
            let b_3: String?
            let b_4: String?
        }
    }
}

/// Maps Bilibili's business codes onto the player's provider errors.
/// Anything that is "no danmaku here" must stay a recoverable status: the
/// danmaku pipeline reports it and playback continues untouched.
public enum BilibiliAPIError {
    public static func make(code: Int, message: String) -> DanmakuProviderError? {
        switch code {
        case 0:
            return nil
        case -412:
            return .rejectedByRiskControl
        case -101:
            return .requiresLogin(message)
        case -400 where message.contains("登录"):
            return .requiresLogin(message)
        case -403:
            // Used both for "members only" and for licence restrictions.
            return message.contains("地区") || message.contains("区域")
                ? .regionLocked(message)
                : .requiresLogin(message)
        case -10403, 6002003:
            return .regionLocked(message)
        case 62002, 62004:
            return .serviceMessage(message.isEmpty ? String(localized: "This video is not publicly visible.", bundle: .module) : message)
        default:
            return .serviceMessage(message.isEmpty ? String(localized: "Bilibili returned code \(String(code)).", bundle: .module) : message)
        }
    }
}
