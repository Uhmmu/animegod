import Foundation

/// OpenSubtitles.com REST API (https://opensubtitles.stoplight.io).
///
/// Its terms matter for how it is configured:
/// - The `Api-Key` identifies the *application* (a "consumer"); OpenSubtitles
///   bans apps that make each user create a key. AnimeGod therefore takes it
///   from the developer's Keychain entry or the `ANIMEGOD_OPENSUBTITLES_API_KEY`
///   environment variable, never from the repository.
/// - Searching is unlimited, but downloads without a user login are capped
///   at 5 per IP per day. A user's own login (Keychain) raises that to the
///   account's allowance.
/// - Downloads are served as UTF-8 SRT; original ASS styling is not kept, so
///   results are labelled SRT and rank below styled subtitles.
/// - The moviehash identifies the exact release; hash matches score highest.
public struct OpenSubtitlesProvider: SubtitleProvider {
    public let id: SubtitleProviderID = .openSubtitles

    public struct Credentials: Sendable {
        public var username: String
        public var password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    private let apiKey: String
    private let credentials: Credentials?
    private let tokens: OpenSubtitlesTokenStore
    private let client: SubtitleHTTPClient
    private let baseURL: URL

    public init(
        apiKey: String,
        credentials: Credentials? = nil,
        tokens: OpenSubtitlesTokenStore = OpenSubtitlesTokenStore(),
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.opensubtitles.com/api/v1")!
    ) {
        self.apiKey = apiKey
        self.credentials = credentials.flatMap { $0.username.isEmpty || $0.password.isEmpty ? nil : $0 }
        self.tokens = tokens
        self.client = SubtitleHTTPClient(session: session)
        self.baseURL = baseURL
    }

    static func codes(for language: SubtitleLanguage) -> [String] {
        switch language {
        case .simplifiedChinese: ["zh-cn", "ze"]
        case .traditionalChinese: ["zh-tw", "ze"]
        case .chinese: ["zh-cn", "zh-tw", "ze"]
        case .japanese: ["ja"]
        case .english: ["en"]
        }
    }

    static func languages(code: String?) -> [SubtitleLanguage] {
        switch code?.lowercased() {
        case "zh-cn": [.simplifiedChinese]
        case "zh-tw": [.traditionalChinese]
        // "ze" is OpenSubtitles' Chinese–English bilingual code.
        case "ze": [.chinese, .english]
        case "ja": [.japanese]
        case "en": [.english]
        default: []
        }
    }

    public func search(_ query: SubtitleQuery) async throws -> [SubtitleResult] {
        guard !apiKey.isEmpty else { throw SubtitleProviderError.notConfigured }
        let video = query.identity
        // The API redirects unless parameters are lowercase and sorted.
        var parameters: [String: String] = [:]
        let codes = Set(query.languages.flatMap(Self.codes(for:)))
        if !codes.isEmpty { parameters["languages"] = codes.sorted().joined(separator: ",") }
        let isMovie = video.isMovie || video.ids.tmdbKind == .movie
        var basis = SubtitleMatchBasis.title

        if query.customText == nil, let tmdbID = video.ids.tmdbID {
            basis = .externalID
            if isMovie {
                parameters["tmdb_id"] = String(tmdbID)
            } else {
                parameters["parent_tmdb_id"] = String(tmdbID)
                parameters["season_number"] = String(video.ids.tmdbSeason ?? video.effectiveSeason)
                if let episode = video.episode { parameters["episode_number"] = String(Int(episode)) }
            }
        } else if let title = query.searchTitles.first(where: SubDLSubtitleProvider.isLatin) ?? query.searchTitles.first {
            parameters["query"] = title.lowercased()
            if !isMovie {
                parameters["season_number"] = String(video.effectiveSeason)
                if let episode = video.episode { parameters["episode_number"] = String(Int(episode)) }
            }
        } else {
            return []
        }
        if query.customText == nil, let hash = video.openSubtitlesHash {
            parameters["moviehash"] = hash
        }

        var components = URLComponents(url: baseURL.appending(path: "subtitles"), resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (response, _) = try await client.json(OpenSubtitlesSearchResponse.self, for: authorized(URLRequest(url: components.url!)))
        return response.data.compactMap { makeResult($0, basis: basis) }
    }

    func makeResult(_ item: OpenSubtitlesSearchResponse.Item, basis: SubtitleMatchBasis) -> SubtitleResult? {
        let attributes = item.attributes
        guard let file = attributes.files.first else { return nil }
        let details = attributes.feature_details
        let isHashMatch = attributes.moviehash_match == true
        return SubtitleResult(
            provider: id,
            providerSubtitleID: String(file.file_id),
            title: details?.parent_title ?? details?.title ?? details?.movie_name ?? "",
            alternativeTitles: [details?.movie_name, details?.title].compactMap { $0 },
            releaseName: attributes.release,
            fileName: file.file_name,
            languages: Self.languages(code: attributes.language),
            // Downloads are converted to SRT.
            format: .srt,
            season: details?.season_number,
            episode: details?.episode_number.map(Double.init),
            basis: isHashMatch ? .fileHash : basis,
            author: attributes.uploader?.name,
            downloadCount: attributes.download_count,
            isMachineTranslated: attributes.machine_translated == true || attributes.ai_translated == true,
            isHashMatch: isHashMatch,
            uploadedAt: attributes.upload_date.flatMap { ISO8601DateFormatter().date(from: $0) },
            pageURL: attributes.url.flatMap(URL.init(string:)),
            downloadContext: String(file.file_id)
        )
    }

    public func download(_ result: SubtitleResult, for video: SubtitleVideoIdentity) async throws -> [SubtitleDownloadedFile] {
        guard !apiKey.isEmpty else { throw SubtitleProviderError.notConfigured }
        guard let fileID = Int(result.downloadContext) else { throw SubtitleProviderError.invalidResponse }
        let session = try await loginIfPossible()
        var request = URLRequest(url: (session?.baseURL ?? baseURL).appending(path: "download"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["file_id": fileID])
        request = authorized(request, token: session?.token)
        let link: OpenSubtitlesDownloadResponse
        do {
            link = try await client.json(OpenSubtitlesDownloadResponse.self, for: request).0
        } catch SubtitleProviderError.httpStatus(let code) where code == 406 {
            // 406 is how the API reports an exhausted download allowance.
            throw SubtitleProviderError.quotaExceeded(credentials == nil
                ? "OpenSubtitles allows 5 downloads a day without a login — add your account in Settings."
                : "Your OpenSubtitles download allowance for today is used up.")
        }
        guard let url = link.link.flatMap(URL.init(string:)) else {
            throw SubtitleProviderError.serviceMessage(link.message ?? "OpenSubtitles returned no download link.")
        }
        let (data, _) = try await client.data(for: URLRequest(url: url))
        return [SubtitleDownloadedFile(name: link.file_name ?? result.fileName ?? "\(fileID).srt", data: data)]
    }

    // MARK: - Auth

    private func authorized(_ request: URLRequest, token: String? = nil) -> URLRequest {
        var request = request
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func loginIfPossible() async throws -> OpenSubtitlesTokenStore.Session? {
        guard let credentials else { return nil }
        if let cached = await tokens.session(for: credentials.username) { return cached }
        var request = URLRequest(url: baseURL.appending(path: "login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": credentials.username, "password": credentials.password])
        let (login, _) = try await client.json(OpenSubtitlesLoginResponse.self, for: authorized(request))
        let base = login.base_url.flatMap { URL(string: "https://\($0)/api/v1") } ?? baseURL
        let session = OpenSubtitlesTokenStore.Session(token: login.token, baseURL: base)
        await tokens.store(session, for: credentials.username)
        return session
    }
}

/// Keeps the OpenSubtitles login token (valid 24 h) across searches, so a
/// login happens at most once a day rather than per download.
public actor OpenSubtitlesTokenStore {
    public struct Session: Sendable {
        let token: String
        let baseURL: URL
    }

    private var sessions: [String: (session: Session, expires: Date)] = [:]

    public init() {}

    func session(for username: String) -> Session? {
        guard let entry = sessions[username], entry.expires > .now else { return nil }
        return entry.session
    }

    func store(_ session: Session, for username: String) {
        sessions[username] = (session, Date.now.addingTimeInterval(23 * 3600))
    }
}

// MARK: - Wire format

struct OpenSubtitlesSearchResponse: Decodable {
    struct Item: Decodable {
        let attributes: Attributes
    }

    struct Attributes: Decodable {
        struct File: Decodable {
            let file_id: Int
            let file_name: String?
        }

        struct Uploader: Decodable {
            let name: String?
        }

        struct Feature: Decodable {
            let title: String?
            let movie_name: String?
            let parent_title: String?
            let season_number: Int?
            let episode_number: Int?
        }

        let language: String?
        let download_count: Int?
        let release: String?
        let url: String?
        let upload_date: String?
        let ai_translated: Bool?
        let machine_translated: Bool?
        let moviehash_match: Bool?
        let uploader: Uploader?
        let feature_details: Feature?
        let files: [File]
    }

    let data: [Item]
}

struct OpenSubtitlesDownloadResponse: Decodable {
    let link: String?
    let file_name: String?
    let remaining: Int?
    let message: String?
}

struct OpenSubtitlesLoginResponse: Decodable {
    let token: String
    let base_url: String?
}
