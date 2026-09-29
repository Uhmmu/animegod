import Foundation

/// Just enough HTTP to serve the link.
///
/// Written by hand rather than pulled in as a dependency: the surface is
/// fifteen routes and one of them needs byte ranges, which is exactly the part
/// a general-purpose server would hide behind an abstraction anyway. Parsing
/// lives here, in the core, because it is the part worth unit testing — the
/// socket plumbing on the app side is not.
public struct LinkHTTPRequest: Sendable, Equatable {
    public let method: String
    /// Path with the query stripped off.
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Header lookup is case-insensitive; `Authorization` and `authorization`
    /// are the same header, and clients disagree about which to send.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// The last path component, for `/media/{id}` and friends.
    public func identifier(after prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        let component = rest.split(separator: "/").first.map(String.init)
        return component?.removingPercentEncoding
    }

    public var rangeHeader: LinkByteRange? {
        LinkByteRange(header: header("Range"))
    }
}

/// A single `Range: bytes=…` request.
///
/// Multi-range requests are not supported and never need to be: mpv asks for
/// one span at a time. An unsatisfiable or malformed range is reported as nil
/// so the caller answers 200 with the whole file rather than guessing.
public struct LinkByteRange: Sendable, Equatable {
    public let start: Int64?
    public let end: Int64?

    public init?(header: String?) {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(trimmed.dropFirst("bytes=".count))
        guard !spec.contains(",") else { return nil }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let lhs = parts[0].trimmingCharacters(in: .whitespaces)
        let rhs = parts[1].trimmingCharacters(in: .whitespaces)
        if lhs.isEmpty {
            // `bytes=-500`: the last 500 bytes.
            guard let suffix = Int64(rhs), suffix > 0 else { return nil }
            start = nil
            end = suffix
        } else {
            guard let from = Int64(lhs), from >= 0 else { return nil }
            start = from
            end = rhs.isEmpty ? nil : Int64(rhs)
            if let end, end < from { return nil }
        }
    }

    init(start: Int64?, end: Int64?) {
        self.start = start
        self.end = end
    }

    /// Resolves against a known file size. Returns nil when the range falls
    /// entirely outside the file, which is a 416.
    public func resolve(totalSize: Int64) -> (offset: Int64, length: Int64)? {
        guard totalSize > 0 else { return nil }
        if let start {
            guard start < totalSize else { return nil }
            let last = min(end ?? totalSize - 1, totalSize - 1)
            guard last >= start else { return nil }
            return (start, last - start + 1)
        }
        guard let end else { return nil }
        let length = min(end, totalSize)
        return (totalSize - length, length)
    }
}

public struct LinkHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> LinkHTTPResponse {
        let data = (try? LinkCoding.encoder.encode(value)) ?? Data()
        return LinkHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    public static func error(_ code: LinkErrorCode, _ message: String, status: Int) -> LinkHTTPResponse {
        json(LinkError(code: code, message: message), status: status)
    }

    public static let reasons: [Int: String] = [
        200: "OK", 204: "No Content", 206: "Partial Content",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
        404: "Not Found", 409: "Conflict", 416: "Range Not Satisfiable",
        426: "Upgrade Required", 500: "Internal Server Error", 503: "Service Unavailable"
    ]

    /// The head only; the body is written separately so a large file can be
    /// streamed rather than held in memory.
    public func headData(contentLength: Int64) -> Data {
        var text = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        var all = headers
        all["Content-Length"] = String(contentLength)
        all["Connection"] = "keep-alive"
        for (key, value) in all.sorted(by: { $0.key < $1.key }) {
            text += "\(key): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }
}

/// Incremental request parser.
///
/// TCP gives no message boundaries, so a request can arrive in any number of
/// chunks and two requests can arrive in one. Feeding bytes in and pulling
/// whole requests out is the only shape that handles both.
public struct LinkHTTPParser: Sendable {
    private var buffer = Data()
    public private(set) var isOverflowed = false

    /// Requests here carry JSON at most; anything larger is a client error,
    /// not something to allocate for.
    public static let maxRequestBytes = 1 << 20

    public init() {}

    public mutating func append(_ data: Data) {
        guard !isOverflowed else { return }
        buffer.append(data)
        if buffer.count > Self.maxRequestBytes { isOverflowed = true; buffer.removeAll() }
    }

    /// Pulls the next complete request out of the buffer, or nil when more
    /// bytes are needed.
    public mutating func next() -> LinkHTTPRequest? {
        guard !isOverflowed else { return nil }
        let terminator = Data("\r\n\r\n".utf8)
        guard let headEnd = buffer.range(of: terminator) else { return nil }
        let headData = buffer[buffer.startIndex..<headEnd.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else {
            buffer.removeAll()
            return nil
        }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { buffer.removeAll(); return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        let target = String(requestLine[1])
        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<mark])
            let rest = String(target[target.index(after: mark)...])
            for pair in rest.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = kv.first?.removingPercentEncoding else { continue }
                let value = kv.count > 1 ? (kv[1].removingPercentEncoding ?? "") : ""
                query[key] = value
            }
        }

        return LinkHTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: path.removingPercentEncoding ?? path,
            query: query,
            headers: headers,
            body: body
        )
    }
}
