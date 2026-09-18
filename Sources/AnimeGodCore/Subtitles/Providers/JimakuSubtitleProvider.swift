import Foundation

/// Jimaku (https://jimaku.cc/api/docs) — a Japanese anime subtitle archive
/// indexed by AniList ID. It has no Chinese subtitles, so it only runs when
/// Japanese is among the preferred languages; it is also the natural source
/// for a future Japanese → Chinese translation fallback.
///
/// Requires an account API key sent as the raw `Authorization` header.
/// Rate limits are per IP and reported with `x-ratelimit-*` headers.
public struct JimakuSubtitleProvider: SubtitleProvider {
    public let id: SubtitleProviderID = .jimaku

    private let apiKey: String
    private let client: SubtitleHTTPClient
    private let baseURL: URL

    public init(apiKey: String, session: URLSession = .shared, baseURL: URL = URL(string: "https://jimaku.cc/api")!) {
        self.apiKey = apiKey
        self.client = SubtitleHTTPClient(session: session)
        self.baseURL = baseURL
    }

    public func search(_ query: SubtitleQuery) async throws -> [SubtitleResult] {
        guard !apiKey.isEmpty else { throw SubtitleProviderError.notConfigured }
        var entries: [JimakuEntry] = []
        var basis = SubtitleMatchBasis.title
        if query.customText == nil, let aniListID = query.identity.ids.aniListID {
            entries = try await get([JimakuEntry].self, "entries/search", ["anilist_id": String(aniListID), "anime": "true"])
            basis = .externalID
        }
        if entries.isEmpty, let title = query.searchTitles.first {
            entries = try await get([JimakuEntry].self, "entries/search", ["query": title, "anime": "true"])
            basis = .title
        }

        var results: [SubtitleResult] = []
        // The first entries are the relevant ones; each costs a request.
        for entry in entries.prefix(2) {
            var parameters: [String: String] = [:]
            if let episode = query.identity.episode, !(entry.flags?.movie ?? false) {
                parameters["episode"] = String(Int(episode))
            }
            let files = try await get([JimakuFile].self, "entries/\(entry.id)/files", parameters)
            for file in files {
                let format = SubtitleFormat.of(fileName: file.name)
                let isArchive = ["zip", "rar", "7z"].contains((file.name as NSString).pathExtension.lowercased())
                guard format != nil || isArchive else { continue }
                let parsed = TorrentReleaseInfo.parse(title: file.name)
                results.append(SubtitleResult(
                    provider: id,
                    providerSubtitleID: file.url,
                    title: entry.name,
                    alternativeTitles: [entry.english_name, entry.japanese_name].compactMap { $0 },
                    releaseName: file.name,
                    fileName: file.name,
                    languages: [SubtitleReleaseParsing.language(inFileName: file.name) ?? .japanese],
                    format: format,
                    episode: parsed.isBatch ? parsed.firstEpisode : (SubtitleReleaseParsing.episode(inFileName: file.name) ?? parsed.firstEpisode),
                    episodeRangeEnd: parsed.isBatch ? parsed.lastEpisode : nil,
                    isPack: isArchive || parsed.isBatch,
                    basis: basis,
                    uploadedAt: file.last_modified.flatMap { ISO8601DateFormatter().date(from: $0) },
                    pageURL: URL(string: "https://jimaku.cc/entry/\(entry.id)"),
                    downloadContext: file.url
                ))
            }
        }
        return results
    }

    public func download(_ result: SubtitleResult, for video: SubtitleVideoIdentity) async throws -> [SubtitleDownloadedFile] {
        guard let url = URL(string: result.downloadContext) else { throw SubtitleProviderError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        let (data, _) = try await client.data(for: request)
        return [SubtitleDownloadedFile(name: result.fileName ?? url.lastPathComponent, data: data)]
    }

    private func get<Value: Decodable>(_ type: Value.Type, _ path: String, _ parameters: [String: String]) async throws -> Value {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !parameters.isEmpty {
            components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await client.json(Value.self, for: request).0
    }
}

struct JimakuEntry: Decodable {
    struct Flags: Decodable {
        let movie: Bool?
        let anime: Bool?
    }

    let id: Int
    let name: String
    let english_name: String?
    let japanese_name: String?
    let anilist_id: Int?
    let flags: Flags?
}

struct JimakuFile: Decodable {
    let url: String
    let name: String
    let size: Int?
    let last_modified: String?
}
