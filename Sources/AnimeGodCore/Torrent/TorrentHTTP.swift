import Foundation

public protocol TorrentSearchProvider: Sendable {
    var id: TorrentSourceID { get }
    func search(query: String, limit: Int) async throws -> [TorrentObservation]
}

/// Shared HTTP behavior for every index: one user agent, a response size cap,
/// and classifying anti-bot interstitials as `.blocked` instead of letting a
/// challenge page parse as "no results".
public struct TorrentHTTPClient: Sendable {
    public let session: URLSession
    public var userAgent: String
    public var timeout: TimeInterval
    public var maximumBytes: Int

    public init(
        session: URLSession = .shared,
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) AnimeGod/0.1",
        timeout: TimeInterval = 20,
        maximumBytes: Int = 10 * 1024 * 1024
    ) {
        self.session = session
        self.userAgent = userAgent
        self.timeout = timeout
        self.maximumBytes = maximumBytes
    }

    public func get(_ url: URL, accept: String = "*/*") async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    public func postJSON(_ url: URL, body: some Encodable) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,ja;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TorrentSearchError.network(error.localizedDescription)
        }
        guard data.count <= maximumBytes else { throw TorrentSearchError.parse("response larger than \(maximumBytes) bytes") }
        guard let http = response as? HTTPURLResponse else { return data }
        if Self.isChallenge(http, data: data) { throw TorrentSearchError.blocked }
        guard (200..<300).contains(http.statusCode) else { throw TorrentSearchError.http(http.statusCode) }
        return data
    }

    static func isChallenge(_ response: HTTPURLResponse, data: Data) -> Bool {
        if response.value(forHTTPHeaderField: "cf-mitigated") != nil { return true }
        let isHTML = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") ?? false
        guard isHTML || [403, 429, 503].contains(response.statusCode) else { return false }
        let head = String(decoding: data.prefix(16_000), as: UTF8.self).lowercased()
        return ["just a moment...", "challenge-platform", "cf-browser-verification", "ddos-guard", "attention required! | cloudflare"]
            .contains { head.contains($0) }
    }
}

// MARK: - RSS

/// One `<item>` of an RSS feed: element text keyed by qualified name (first
/// occurrence wins) plus attributes for elements such as `<enclosure>`.
struct RSSItem: Sendable {
    var text: [String: String] = [:]
    var attributes: [String: [String: String]] = [:]

    subscript(_ name: String) -> String? {
        text[name]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

enum RSSFeed {
    /// Parses an RSS 2.0 document. A document that isn't RSS at all (an HTML
    /// error page, a layout change) is a parse error, never an empty result.
    static func items(from data: Data) throws -> [RSSItem] {
        let delegate = RSSDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        let ok = parser.parse()
        guard delegate.sawChannel else {
            throw TorrentSearchError.parse(ok ? "not an RSS feed" : (parser.parserError?.localizedDescription ?? "invalid XML"))
        }
        // A truncated feed still yields the items read before the error.
        if !ok, delegate.items.isEmpty {
            throw TorrentSearchError.parse(parser.parserError?.localizedDescription ?? "invalid XML")
        }
        return delegate.items
    }

    private final class RSSDelegate: NSObject, XMLParserDelegate {
        var items: [RSSItem] = []
        var sawChannel = false
        private var current: RSSItem?
        private var element: String?
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "channel" { sawChannel = true }
            if name == "item" {
                current = RSSItem()
                return
            }
            guard current != nil else { return }
            element = name
            buffer = ""
            if !attributes.isEmpty, current?.attributes[name] == nil {
                current?.attributes[name] = attributes
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if element != nil { buffer += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if element != nil { buffer += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "item", let item = current {
                items.append(item)
                current = nil
                element = nil
                return
            }
            guard current != nil, element == name else { return }
            if current?.text[name] == nil { current?.text[name] = buffer }
            element = nil
            buffer = ""
        }
    }
}

// MARK: - Field parsing

enum TorrentFieldParser {
    /// "9.4 GiB", "9.4GB", "189.27MB" → bytes. Most anime indexes use binary
    /// units even when they write "GB"; bangumi.moe is decimal.
    static func size(_ text: String?, decimal: Bool = false) -> Int64? {
        guard let text,
              let regex = try? NSRegularExpression(pattern: #"(?i)(\d+(?:\.\d+)?)\s*([KMGT]?)i?B\b"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[numberRange]) else { return nil }
        let exponent = ["": 0, "K": 1, "M": 2, "G": 3, "T": 4][text[unitRange].uppercased()] ?? 0
        return Int64(value * pow(decimal ? 1000 : 1024, Double(exponent)))
    }

    static func rfc822Date(_ text: String?) -> Date? {
        guard let text else { return nil }
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// ISO 8601 with or without fractional seconds. A timestamp without a
    /// zone is interpreted in `defaultTimeZone` (Mikan omits it; it is UTC+8).
    static func isoDate(_ text: String?, defaultTimeZone: TimeZone = TimeZone(identifier: "UTC")!) -> Date? {
        guard let text else { return nil }
        let withZone = ISO8601DateFormatter()
        withZone.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withZone.date(from: text) { return date }
        withZone.formatOptions = [.withInternetDateTime]
        if let date = withZone.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = defaultTimeZone
        let trimmed = text.replacingOccurrences(of: #"\.\d+$"#, with: "", options: .regularExpression)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: trimmed)
    }

    static func hash(inText text: String?) -> TorrentInfoHash? {
        guard let text, let hex = TorrentReleaseInfo.firstCapture(#"(?i)(?<![0-9a-f])([0-9a-f]{40})(?![0-9a-f])"#, in: text) else {
            return nil
        }
        return TorrentInfoHash(hex)
    }

    static func url(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return URL(string: text)
    }
}
