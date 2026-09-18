import Foundation

/// SubDL (https://subdl.com/api-doc). Free API key, 2,000 searches a day;
/// anonymous downloads are limited to 300 a day per IP. Indexed by TMDB and
/// IMDb, so it is searched by the TMDB ID and season/episode the anime ID
/// mapping provides, falling back to a title search.
///
/// Language codes are SubDL's own: `ZH` is Simplified ("Chinese BG code"
/// on the site — GB), `ZH_BG` is Traditional (Big5).
public struct SubDLSubtitleProvider: SubtitleProvider {
    public let id: SubtitleProviderID = .subdl

    private let apiKey: String
    private let client: SubtitleHTTPClient
    private let apiURL: URL
    private let downloadBaseURL: URL

    public init(
        apiKey: String,
        session: URLSession = .shared,
        apiURL: URL = URL(string: "https://api.subdl.com/api/v1/subtitles")!,
        downloadBaseURL: URL = URL(string: "https://dl.subdl.com")!
    ) {
        self.apiKey = apiKey
        self.client = SubtitleHTTPClient(session: session)
        self.apiURL = apiURL
        self.downloadBaseURL = downloadBaseURL
    }

    static func code(for language: SubtitleLanguage) -> [String] {
        switch language {
        case .simplifiedChinese: ["ZH"]
        case .traditionalChinese: ["ZH_BG"]
        case .chinese: ["ZH", "ZH_BG"]
        case .japanese: ["JA"]
        case .english: ["EN"]
        }
    }

    static func language(code: String?, name: String?) -> SubtitleLanguage? {
        switch code?.uppercased() {
        case "ZH": return .simplifiedChinese
        case "ZH_BG": return .traditionalChinese
        case "JA": return .japanese
        case "EN": return .english
        default: break
        }
        guard let name = name?.lowercased() else { return nil }
        if name.contains("big 5") || name.contains("big5") || name.contains("traditional") { return .traditionalChinese }
        if name.contains("chinese") { return .simplifiedChinese }
        if name.contains("japanese") { return .japanese }
        if name.contains("english") { return .english }
        return nil
    }

    public func search(_ query: SubtitleQuery) async throws -> [SubtitleResult] {
        guard !apiKey.isEmpty else { throw SubtitleProviderError.notConfigured }
        let video = query.identity
        let codes = SubtitleReleaseParsing.distinct(query.languages.flatMap(Self.code(for:)))
        var base: [String: String] = [
            "api_key": apiKey,
            "subs_per_page": "30",
            "unpack": "1",
            "releases": "1",
            "client": "custom_integration"
        ]
        if !codes.isEmpty { base["languages"] = codes.joined(separator: ",") }
        let isMovie = video.isMovie || video.ids.tmdbKind == .movie
        base["type"] = isMovie ? "movie" : "tv"

        if query.customText == nil, let tmdbID = video.ids.tmdbID {
            var parameters = base
            parameters["tmdb_id"] = String(tmdbID)
            if !isMovie {
                parameters["season_number"] = String(video.ids.tmdbSeason ?? video.effectiveSeason)
                if let episode = video.episode { parameters["episode_number"] = String(Int(episode)) }
            }
            let results = try await fetch(parameters, basis: .externalID, video: video)
            if !results.isEmpty { return results }
        }

        // Title fallback: the romanized or English title is what SubDL
        // indexes, so Latin-script titles are tried before CJK ones.
        let titles = query.searchTitles.sorted { Self.isLatin($0) && !Self.isLatin($1) }
        for title in titles.prefix(2) {
            var parameters = base
            parameters["film_name"] = Self.sanitize(title)
            if !isMovie {
                parameters["season_number"] = String(video.effectiveSeason)
                if let episode = video.episode { parameters["episode_number"] = String(Int(episode)) }
            }
            let results = try await fetch(parameters, basis: .title, video: video)
            if !results.isEmpty { return results }
        }
        return []
    }

    public func download(_ result: SubtitleResult, for video: SubtitleVideoIdentity) async throws -> [SubtitleDownloadedFile] {
        guard let url = URL(string: result.downloadContext, relativeTo: downloadBaseURL)?.absoluteURL else {
            throw SubtitleProviderError.invalidResponse
        }
        let (data, _) = try await client.data(for: URLRequest(url: url))
        return [SubtitleDownloadedFile(name: result.fileName ?? url.lastPathComponent, data: data)]
    }

    // MARK: - API

    private func fetch(_ parameters: [String: String], basis: SubtitleMatchBasis, video: SubtitleVideoIdentity) async throws -> [SubtitleResult] {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            data = try await client.data(for: request).0
        } catch SubtitleProviderError.httpStatus(let code) where code == 400 || code == 404 {
            // "Can't find movie or tv" is an empty result, not an outage.
            return []
        }
        guard let response = try? JSONDecoder().decode(SubDLResponse.self, from: data) else {
            throw SubtitleProviderError.invalidResponse
        }
        guard response.status != false else {
            let message = response.error ?? response.message ?? "SubDL returned an error."
            if message.range(of: #"(?i)can'?t find|not found|no .*found"#, options: .regularExpression) != nil { return [] }
            if message.range(of: #"(?i)api.?key|invalid key|unauthori"#, options: .regularExpression) != nil {
                throw SubtitleProviderError.unauthorized
            }
            if message.range(of: #"(?i)limit|quota"#, options: .regularExpression) != nil {
                throw SubtitleProviderError.quotaExceeded(message)
            }
            throw SubtitleProviderError.serviceMessage(message)
        }
        let workTitle = response.results?.first?.name ?? ""
        return (response.subtitles ?? []).flatMap { makeResults($0, workTitle: workTitle, basis: basis, video: video) }
    }

    func makeResults(_ item: SubDLSubtitle, workTitle: String, basis: SubtitleMatchBasis, video: SubtitleVideoIdentity) -> [SubtitleResult] {
        guard let url = item.url else { return [] }
        let language = Self.language(code: item.language, name: item.lang)
        let releaseNames = SubtitleReleaseParsing.distinct([item.release_name].compactMap { $0 } + (item.releases ?? []))
        // SubDL lists every release an upload fits; show the one closest to
        // the playing file.
        let bestRelease = releaseNames.max {
            SubtitleReleaseParsing.releaseSimilarity(video.fileName, $0) < SubtitleReleaseParsing.releaseSimilarity(video.fileName, $1)
        }
        let isPack = item.full_season == true || (item.episode_end ?? 0) > (item.episode_from ?? 0)

        // Unpacked files are individually downloadable: prefer the one for
        // this episode over the whole archive.
        let unpacked = (item.unpack_files ?? []).filter { file in
            guard let wanted = video.episode else { return true }
            return (file.episode.map(Double.init) ?? file.name.flatMap(SubtitleReleaseParsing.episode(inFileName:))) == wanted
        }
        if isPack || (item.unpack_files?.count ?? 0) > 1, !unpacked.isEmpty {
            return unpacked.prefix(3).compactMap { file in
                guard let fileURL = file.url else { return nil }
                return SubtitleResult(
                    provider: id,
                    providerSubtitleID: fileURL,
                    title: workTitle,
                    releaseName: file.release_name ?? bestRelease,
                    fileName: file.name,
                    languages: [Self.language(code: file.language, name: nil) ?? language].compactMap { $0 },
                    format: file.format.flatMap(SubtitleFormat.init(fileExtension:)) ?? file.name.flatMap(SubtitleFormat.of(fileName:)),
                    season: file.season ?? item.season,
                    episode: (file.episode.map(Double.init)) ?? video.episode,
                    basis: basis,
                    author: item.author,
                    isMachineTranslated: item.ai_translated == true,
                    pageURL: item.subtitlePage.flatMap { URL(string: $0, relativeTo: URL(string: "https://subdl.com")) }?.absoluteURL,
                    downloadContext: fileURL
                )
            }
        }
        return [SubtitleResult(
            provider: id,
            providerSubtitleID: url,
            title: workTitle,
            releaseName: bestRelease,
            fileName: item.name,
            languages: [language].compactMap { $0 },
            format: item.name.flatMap(SubtitleFormat.of(fileName:)),
            season: item.season,
            episode: isPack ? item.episode_from.map(Double.init) : item.episode.map(Double.init),
            episodeRangeEnd: isPack ? item.episode_end.map(Double.init) : nil,
            isPack: isPack,
            basis: basis,
            author: item.author,
            isMachineTranslated: item.ai_translated == true,
            pageURL: item.subtitlePage.flatMap { URL(string: $0, relativeTo: URL(string: "https://subdl.com")) }?.absoluteURL,
            downloadContext: url
        )]
    }

    static func isLatin(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value < 0x2E80 }
    }

    /// SubDL rejects titles containing quotes, brackets and slashes; they
    /// become spaces (never nothing, which would merge words).
    static func sanitize(_ title: String) -> String {
        title.replacingOccurrences(of: #"[<>{}\[\]'"`´’;\\/]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
}

// MARK: - Wire format

struct SubDLResponse: Decodable {
    struct Work: Decodable {
        let name: String?
        let tmdb_id: Int?
        let type: String?
        let year: Int?
    }

    let status: Bool?
    let error: String?
    let message: String?
    let results: [Work]?
    let subtitles: [SubDLSubtitle]?
}

struct SubDLUnpackedFile: Decodable {
    let name: String?
    let release_name: String?
    let season: Int?
    let episode: Int?
    let language: String?
    let format: String?
    let url: String?
}

struct SubDLSubtitle: Decodable {
    let release_name: String?
    let name: String?
    let lang: String?
    let language: String?
    let author: String?
    let url: String?
    let subtitlePage: String?
    let season: Int?
    let episode: Int?
    let episode_from: Int?
    let episode_end: Int?
    let full_season: Bool?
    let releases: [String]?
    let ai_translated: Bool?
    let unpack_files: [SubDLUnpackedFile]?

    private enum CodingKeys: String, CodingKey {
        case release_name, name, lang, language, author, url, subtitlePage, season, episode,
             episode_from, episode_end, full_season, releases, ai_translated, unpack_files
    }

    // SubDL is loose with types (numbers as strings, flags as 0/1); a
    // field that does not decode is treated as absent rather than failing
    // the whole response.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? {
            (try? container.decode(String.self, forKey: key)) ?? (try? container.decode(Int.self, forKey: key)).map(String.init)
        }
        func int(_ key: CodingKeys) -> Int? {
            (try? container.decode(Int.self, forKey: key)) ?? (try? container.decode(String.self, forKey: key)).flatMap(Int.init)
        }
        func bool(_ key: CodingKeys) -> Bool? {
            (try? container.decode(Bool.self, forKey: key)) ?? (try? container.decode(Int.self, forKey: key)).map { $0 != 0 }
        }
        release_name = string(.release_name)
        name = string(.name)
        lang = string(.lang)
        language = string(.language)
        author = string(.author)
        url = string(.url)
        subtitlePage = string(.subtitlePage)
        season = int(.season)
        episode = int(.episode)
        episode_from = int(.episode_from)
        episode_end = int(.episode_end)
        full_season = bool(.full_season)
        releases = try? container.decode([String].self, forKey: .releases)
        ai_translated = bool(.ai_translated)
        unpack_files = try? container.decode([SubDLUnpackedFile].self, forKey: .unpack_files)
    }
}
