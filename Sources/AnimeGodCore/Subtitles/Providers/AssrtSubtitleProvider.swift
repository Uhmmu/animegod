import Foundation

/// 射手网(伪) — assrt.net, the largest Chinese subtitle archive with an
/// official API (https://assrt.net/api/doc). Free for personal use with a
/// per-user token; the terms ask for a visible "字幕服务由assrt.net提供"
/// credit, which the player's search sheet and Settings show.
///
/// Quota is 20 requests a minute shared per token and per IP, so a search
/// sends at most three queries and the detail call happens only on download.
public struct AssrtSubtitleProvider: SubtitleProvider {
    public let id: SubtitleProviderID = .assrt
    public static let attribution = "字幕服务由assrt.net提供"

    private let token: String
    private let client: SubtitleHTTPClient
    /// The API host, then the alternate domain assrt documents for networks
    /// that cannot reach it.
    private let baseURLs: [URL]
    private let hosts: AssrtHostMemory
    /// Queries per search; each costs one request of the per-minute quota.
    private let maximumQueries = 3

    public static let defaultBaseURLs = [
        URL(string: "https://api.assrt.net/v1")!,
        URL(string: "https://api.makedie.me/v1")!
    ]

    public init(token: String, session: URLSession = .shared, baseURLs: [URL] = AssrtSubtitleProvider.defaultBaseURLs) {
        self.token = token
        self.client = SubtitleHTTPClient(session: session)
        self.baseURLs = baseURLs
        self.hosts = baseURLs == Self.defaultBaseURLs ? .shared : AssrtHostMemory()
    }

    public func search(_ query: SubtitleQuery) async throws -> [SubtitleResult] {
        guard !token.isEmpty else { throw SubtitleProviderError.notConfigured }
        var results: [SubtitleResult] = []
        var seen: Set<Int> = []
        var lastError: Error?
        for (text, isFile) in queries(for: query) {
            do {
                for sub in try await searchSubs(text, isFile: isFile) where seen.insert(sub.id).inserted {
                    if let result = makeResult(sub) { results.append(result) }
                }
            } catch let error as SubtitleProviderError {
                // Quota and credential errors will not improve with the next
                // query; anything else might.
                switch error {
                case .unauthorized, .notConfigured, .rateLimited, .quotaExceeded: throw error
                default: lastError = error
                }
            }
        }
        if results.isEmpty, let lastError { throw lastError }
        return results
    }

    /// The video's own filename first (finds uploads timed to that exact
    /// release), then "title episode" for each of the best titles.
    func queries(for query: SubtitleQuery) -> [(String, Bool)] {
        var queries: [(String, Bool)] = []
        if query.customText == nil {
            let stem = (query.identity.fileName as NSString).deletingPathExtension
            if stem.count >= 3 { queries.append((stem, true)) }
        }
        let episode = query.identity.episode.map { value in
            value.rounded() == value ? String(format: "%02d", Int(value)) : String(value)
        }
        for title in query.searchTitles {
            let text = [title, episode].compactMap { $0 }.joined(separator: " ")
            guard text.count >= 3, !queries.contains(where: { $0.0 == text }) else { continue }
            queries.append((text, false))
        }
        return Array(queries.prefix(maximumQueries))
    }

    public func download(_ result: SubtitleResult, for video: SubtitleVideoIdentity) async throws -> [SubtitleDownloadedFile] {
        guard !token.isEmpty else { throw SubtitleProviderError.notConfigured }
        // Download links are single-use and expire, so they are fetched now
        // rather than stored with the search result.
        let detail: AssrtEnvelope = try await request("sub/detail", ["id": result.providerSubtitleID])
        guard let sub = detail.sub?.subs?.first else { throw SubtitleProviderError.noSuitableFile }

        // The file list is served extracted on the fly, which also covers
        // RAR and 7z packs AnimeGod cannot open itself.
        let listed = (sub.filelist ?? []).filter { file in
            SubtitleFormat.of(fileName: file.f) != nil
        }
        if !listed.isEmpty {
            let wanted = video.episode ?? result.episode
            let chosen = listed.count > 1 && wanted != nil
                ? listed.filter { SubtitleReleaseParsing.episode(inFileName: $0.f) == wanted }.nilIfEmpty ?? listed
                : listed
            var files: [SubtitleDownloadedFile] = []
            for file in chosen.prefix(8) {
                guard let url = URL(string: file.url) else { continue }
                let (data, _) = try await client.data(for: URLRequest(url: url))
                files.append(SubtitleDownloadedFile(name: file.f, data: data))
            }
            if !files.isEmpty { return files }
        }
        guard let urlString = sub.url, let url = URL(string: urlString) else { throw SubtitleProviderError.noSuitableFile }
        let (data, _) = try await client.data(for: URLRequest(url: url))
        return [SubtitleDownloadedFile(name: sub.filename ?? url.lastPathComponent, data: data)]
    }

    // MARK: - API

    private func searchSubs(_ text: String, isFile: Bool) async throws -> [AssrtSub] {
        var parameters = ["q": String(text.prefix(120)), "cnt": "15", "pos": "0"]
        if isFile { parameters["is_file"] = "1" }
        let envelope: AssrtEnvelope = try await request("sub/search", parameters)
        return envelope.sub?.subs ?? []
    }

    private func request<Value: Decodable & AssrtStatus>(_ endpoint: String, _ parameters: [String: String]) async throws -> Value {
        let preferred = await hosts.preferredIndex
        let order = [preferred] + baseURLs.indices.filter { $0 != preferred }
        var lastError: Error = SubtitleProviderError.invalidResponse
        for index in order where baseURLs.indices.contains(index) {
            do {
                let value: Value = try await request(endpoint, parameters, baseURL: baseURLs[index])
                await hosts.remember(index)
                return value
            } catch let error as URLError where Self.isUnreachable(error) {
                // Only an unreachable host moves on to the alternate domain;
                // an answer from the API (even an error) is final.
                lastError = error
            }
        }
        throw lastError
    }

    private static func isUnreachable(_ error: URLError) -> Bool {
        [.timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .secureConnectionFailed]
            .contains(error.code)
    }

    private func request<Value: Decodable & AssrtStatus>(_ endpoint: String, _ parameters: [String: String], baseURL: URL) async throws -> Value {
        var components = URLComponents(url: baseURL.appending(path: endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Short enough that both hosts fit in the search's time budget.
        request.timeoutInterval = 10
        let value: Value
        do {
            value = try await client.json(Value.self, for: request).0
        } catch SubtitleProviderError.httpStatus(let code) where code == 509 {
            throw SubtitleProviderError.rateLimited(retryAfter: 60)
        }
        switch value.status {
        case 0: return value
        case 101: return value // keyword too short: no results
        case 20001: throw SubtitleProviderError.unauthorized
        case 20900: throw SubtitleProviderError.noSuitableFile
        case 30900: throw SubtitleProviderError.rateLimited(retryAfter: 60)
        default: throw SubtitleProviderError.serviceMessage("assrt error \(value.status)")
        }
    }

    // MARK: - Mapping

    func makeResult(_ sub: AssrtSub) -> SubtitleResult? {
        let format = Self.format(subtype: sub.subtype)
        // Image-based subtitles (VobSub, PGS) cannot be rendered as text.
        if let subtype = sub.subtype?.lowercased(), subtype.contains("vobsub") || subtype.contains("sup") || subtype.contains("idx") {
            return nil
        }
        let names = (sub.native_name ?? "").split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let release = TorrentReleaseInfo.parse(title: [sub.videoname, sub.native_name].compactMap { $0 }.joined(separator: " "))
        let episodeSource = sub.videoname.map(TorrentReleaseInfo.parse(title:))
        let episode = episodeSource?.firstEpisode ?? release.firstEpisode
        let isPack = (episodeSource?.isBatch ?? false) || release.isBatch
            || (sub.native_name ?? "").range(of: #"全\d*[集话話]|合集|全季|BD\s*全|Season\s*Pack"#, options: [.regularExpression, .caseInsensitive]) != nil
        return SubtitleResult(
            provider: id,
            providerSubtitleID: String(sub.id),
            title: names.first.map(Self.stripEpisodeText) ?? (sub.videoname ?? ""),
            alternativeTitles: names.dropFirst().map(Self.stripEpisodeText),
            releaseName: sub.videoname,
            fileName: sub.filename,
            languages: Self.languages(sub.lang),
            format: format,
            season: episodeSource?.season ?? release.season,
            episode: episode,
            episodeRangeEnd: isPack ? (episodeSource?.lastEpisode ?? release.lastEpisode) : nil,
            isPack: isPack,
            basis: .title,
            author: sub.release_site?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            downloadCount: sub.down_count,
            isMachineTranslated: sub.vote_machine_translate.map { $0 > 0 } ?? false,
            uploadedAt: sub.upload_time.flatMap(Self.parseDate),
            downloadContext: String(sub.id)
        )
    }

    static func languages(_ lang: AssrtLang?) -> [SubtitleLanguage] {
        var languages: [SubtitleLanguage] = []
        let flags = lang?.langlist ?? [:]
        if flags["langchs"] == true { languages.append(.simplifiedChinese) }
        if flags["langcht"] == true { languages.append(.traditionalChinese) }
        // "双语" on assrt means Chinese paired with the original language.
        if flags["langdou"] == true, !languages.contains(where: \.isChinese) { languages.append(.chinese) }
        if flags["langeng"] == true { languages.append(.english) }
        if flags["langjap"] == true || flags["langjpn"] == true { languages.append(.japanese) }
        if languages.isEmpty, let described = lang?.desc.flatMap(SubtitleLanguage.fromLabel) {
            languages.append(described)
        }
        return languages
    }

    static func format(subtype: String?) -> SubtitleFormat? {
        guard let value = subtype?.lowercased() else { return nil }
        if value.contains("ass") { return .ass }
        if value.contains("ssa") { return .ssa }
        if value.contains("srt") || value.contains("subrip") { return .srt }
        if value.contains("vtt") { return .vtt }
        return nil
    }

    /// "葬送的芙莉莲 第14集" → "葬送的芙莉莲": the title half of a name.
    static func stripEpisodeText(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)\s*(?:第\s*[\d一二三四五六七八九十百]+\s*[集话話季]|S\d{1,2}E\d{1,4}|EP?\d{1,4}|全\d*[集话話]).*$"#,
            with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

/// Remembers which assrt host answered last, so later requests in this
/// run do not wait for an unreachable one again.
actor AssrtHostMemory {
    static let shared = AssrtHostMemory()
    private(set) var preferredIndex = 0

    func remember(_ index: Int) { preferredIndex = index }
}

// MARK: - Wire format

protocol AssrtStatus {
    var status: Int { get }
}

struct AssrtEnvelope: Decodable, AssrtStatus {
    struct Payload: Decodable {
        let subs: [AssrtSub]?
    }

    let status: Int
    let sub: Payload?
}

struct AssrtLang: Decodable {
    let langlist: [String: Bool]?
    let desc: String?
}

struct AssrtFile: Decodable {
    let url: String
    let f: String
    let s: String?
}

struct AssrtSub: Decodable {
    let id: Int
    let native_name: String?
    let videoname: String?
    let subtype: String?
    let upload_time: String?
    let release_site: String?
    let lang: AssrtLang?
    let vote_machine_translate: Int?
    let down_count: Int?
    let filename: String?
    let url: String?
    let filelist: [AssrtFile]?

    private enum CodingKeys: String, CodingKey {
        case id, native_name, videoname, subtype, upload_time, release_site, lang,
             vote_machine_translate, down_count, filename, url, filelist
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        native_name = try? container.decode(String.self, forKey: .native_name)
        videoname = try? container.decode(String.self, forKey: .videoname)
        subtype = try? container.decode(String.self, forKey: .subtype)
        upload_time = try? container.decode(String.self, forKey: .upload_time)
        release_site = try? container.decode(String.self, forKey: .release_site)
        lang = try? container.decode(AssrtLang.self, forKey: .lang)
        // The API reports some flags as numbers and some as booleans.
        vote_machine_translate = (try? container.decode(Int.self, forKey: .vote_machine_translate))
            ?? (try? container.decode(Bool.self, forKey: .vote_machine_translate)).map { $0 ? 1 : 0 }
        down_count = try? container.decode(Int.self, forKey: .down_count)
        filename = try? container.decode(String.self, forKey: .filename)
        url = try? container.decode(String.self, forKey: .url)
        filelist = try? container.decode([AssrtFile].self, forKey: .filelist)
    }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
