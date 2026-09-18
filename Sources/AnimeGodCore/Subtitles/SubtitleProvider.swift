import Foundation

/// A subtitle source. Providers only translate between their API and the
/// shared models: ranking, unpacking, decoding and caching are done once,
/// by `SubtitleManager`, for all of them.
public protocol SubtitleProvider: Sendable {
    var id: SubtitleProviderID { get }
    /// Results for the query. Throwing is fine — one provider failing never
    /// fails the search as a whole.
    func search(_ query: SubtitleQuery) async throws -> [SubtitleResult]
    /// The raw bytes behind a result: a subtitle, or an archive of them.
    /// `video` lets a provider fetch only the right episode from a pack.
    ///
    /// Returning bytes rather than a file URL keeps validation, decoding
    /// and cache layout in one place instead of four.
    func download(_ result: SubtitleResult, for video: SubtitleVideoIdentity) async throws -> [SubtitleDownloadedFile]
}

/// Machine translation of a subtitle into another language — the planned
/// fallback when no Chinese subtitle exists but a Japanese or English one
/// does. Deliberately separate from `SubtitleProvider`: translation turns
/// one prepared subtitle into another and never searches.
public protocol SubtitleTranslationProvider: Sendable {
    var id: String { get }
    func canTranslate(from source: SubtitleLanguage, to target: SubtitleLanguage) -> Bool
    /// Returns the translated subtitle in the same format, timing untouched.
    func translate(_ subtitle: PreparedSubtitle, from source: SubtitleLanguage, to target: SubtitleLanguage) async throws -> PreparedSubtitle
}

/// Shared request plumbing: one place maps HTTP status codes and rate-limit
/// headers onto `SubtitleProviderError`.
struct SubtitleHTTPClient: Sendable {
    let session: URLSession
    let userAgent: String

    init(session: URLSession, userAgent: String = SubtitleHTTPClient.defaultUserAgent) {
        self.session = session
        self.userAgent = userAgent
    }

    static var defaultUserAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "AnimeGod v\(version)"
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        // URLRequest defaults to 60 s; a stalled source should not hold up the rest.
        if request.timeoutInterval >= 60 { request.timeoutInterval = 20 }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubtitleProviderError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401, 403:
            throw SubtitleProviderError.unauthorized
        case 429:
            throw SubtitleProviderError.rateLimited(retryAfter: Self.retryAfter(http))
        default:
            throw SubtitleProviderError.httpStatus(http.statusCode)
        }
    }

    func json<Value: Decodable>(_ type: Value.Type, for request: URLRequest) async throws -> (Value, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        do {
            return (try JSONDecoder().decode(Value.self, from: data), response)
        } catch {
            throw SubtitleProviderError.invalidResponse
        }
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        for header in ["Retry-After", "x-ratelimit-reset-after", "ratelimit-reset"] {
            if let value = response.value(forHTTPHeaderField: header).flatMap(TimeInterval.init) { return value }
        }
        return nil
    }
}

/// OpenSubtitles' moviehash: the file size plus the 64-bit little-endian
/// word sums of the first and last 64 KiB. Cheap to compute even on an
/// external drive, and it identifies the exact release.
public enum OpenSubtitlesHash {
    public static func compute(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 131_072 else { return nil }
        let chunk = 65_536
        guard (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: chunk), head.count == chunk,
              (try? handle.seek(toOffset: size - UInt64(chunk))) != nil,
              let tail = try? handle.read(upToCount: chunk), tail.count == chunk else { return nil }
        return compute(size: size, head: head, tail: tail)
    }

    public static func compute(size: UInt64, head: Data, tail: Data) -> String {
        var hash = size
        for data in [head, tail] {
            data.withUnsafeBytes { raw in
                for offset in stride(from: 0, to: raw.count - 7, by: 8) {
                    hash &+= UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                }
            }
        }
        return String(format: "%016llx", hash)
    }
}
