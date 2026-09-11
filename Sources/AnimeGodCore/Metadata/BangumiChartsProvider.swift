import Foundation

/// A subject category on Bangumi whose ranking chart can be browsed.
public enum BangumiChartChannel: String, CaseIterable, Identifiable, Sendable {
    case anime
    case book
    case music
    case game
    case real

    public var id: String { rawValue }

    /// Subject type ID used by the API ("没有 5").
    var typeID: Int {
        switch self {
        case .book: 1
        case .anime: 2
        case .music: 3
        case .game: 4
        case .real: 6
        }
    }

    public var title: String {
        switch self {
        case .anime: "Anime"
        case .book: "Books"
        case .music: "Music"
        case .game: "Games"
        case .real: "Live Action"
        }
    }
}

/// One filter option from a channel's chart sidebar (分类 / 来源 / 平台 …).
/// Each option narrows the ranking chart; exactly one may be active.
public struct BangumiChartFilter: Hashable, Identifiable, Sendable {
    public let group: String
    public let title: String
    /// `cat` query parameter for subject platform categories.
    let categoryID: Int?
    /// `series` query parameter (books only: 系列 / 单行本).
    let series: Bool?
    /// `tags` query parameter with a wiki meta tag (decoded).
    let tag: String?

    public var id: String { "\(group)/\(title)" }

    public static func == (lhs: BangumiChartFilter, rhs: BangumiChartFilter) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public struct BangumiChartEntry: Hashable, Identifiable, Sendable {
    public let subjectID: String
    /// The subject's site-wide rank; entries arrive sorted by it.
    public let rank: Int
    public let title: String
    public let originalTitle: String?
    public let score: Double?
    public let ratingCount: Int?
    public let info: String?
    public let coverURL: URL?
    public let sourceURL: URL

    public var id: String { subjectID }
}

public struct BangumiChartPage: Sendable {
    public let channel: BangumiChartChannel
    public let filter: BangumiChartFilter?
    public let page: Int
    public let totalPages: Int
    public let entries: [BangumiChartEntry]

    public var hasNextPage: Bool { page < totalPages }
}

/// Bangumi's site-wide ranking charts.
///
/// Entries come from the private `next.bgm.tv/p1/subjects` JSON endpoint
/// (`type` + `sort=rank` + `cat`/`series`/`tags` filters) which needs no
/// authentication. That API has no way to enumerate a channel's filter
/// taxonomy, so the available filters are read from the server-rendered
/// `bgm.tv/{channel}/browser?sort=rank` sidebar — a page that, unlike its
/// filtered subpaths, is not behind a Cloudflare challenge.
public struct BangumiChartsProvider: Sendable {
    private let session: URLSession
    private let apiBaseURL: URL
    private let webBaseURL: URL
    private let userAgent: String

    public init(
        session: URLSession = .shared,
        apiBaseURL: URL = URL(string: "https://next.bgm.tv")!,
        webBaseURL: URL = URL(string: "https://bgm.tv")!,
        userAgent: String = "AnimeGod/0.2 (https://github.com/Uhmmu/animegod)"
    ) {
        self.session = session
        self.apiBaseURL = apiBaseURL
        self.webBaseURL = webBaseURL
        self.userAgent = userAgent
    }

    // MARK: - Entries

    public func chart(
        channel: BangumiChartChannel,
        filter: BangumiChartFilter? = nil,
        page: Int
    ) async throws -> BangumiChartPage {
        let page = max(page, 1)
        var components = URLComponents(url: apiBaseURL.appending(path: "p1/subjects"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "type", value: String(channel.typeID)),
            URLQueryItem(name: "sort", value: "rank"),
            URLQueryItem(name: "page", value: String(page))
        ]
        if let categoryID = filter?.categoryID {
            items.append(URLQueryItem(name: "cat", value: String(categoryID)))
        }
        if let series = filter?.series {
            items.append(URLQueryItem(name: "series", value: series ? "true" : "false"))
        }
        if let tag = filter?.tag {
            items.append(URLQueryItem(name: "tags", value: tag))
        }
        components.queryItems = items

        let response: ChartResponse = try await loadJSON(request(url: components.url!))
        var seen = Set<String>()
        let entries: [BangumiChartEntry] = response.data.compactMap { subject -> BangumiChartEntry? in
            guard seen.insert(String(subject.id)).inserted else { return nil }
            return subject.entry
        }
        return BangumiChartPage(
            channel: channel,
            filter: filter,
            page: page,
            totalPages: max(response.total, 1),
            entries: entries
        )
    }

    // MARK: - Filters

    /// The chart filter groups a channel offers, as linked by its browser
    /// page sidebar. Best-effort by design: a page outage must never make
    /// the charts themselves unusable.
    public func filters(channel: BangumiChartChannel) async throws -> [BangumiChartFilter] {
        // The filter path arrives percent-encoded from the page's own links;
        // URL(string:) preserves those escapes where appending(path:) would
        // encode them a second time.
        guard let url = URL(string: "\(webBaseURL.absoluteString)/\(channel.rawValue)/browser?sort=rank") else {
            throw MetadataProviderError.invalidResponse
        }
        let html = try await fetchHTML(request(url: url))
        return Self.parseFilters(html: html, channel: channel)
    }

    static func parseFilters(html: String, channel: BangumiChartChannel) -> [BangumiChartFilter] {
        var filters: [BangumiChartFilter] = []
        for groupMatch in html.matches(of: #/(?s)<h2 class="subtitle">([^<]+)</h2>\s*<ul class="grouped[^"]*">(.*?)</ul>/#) {
            let group = decodeHTMLEntities(String(groupMatch.output.1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !excludedFilterGroups.contains(group) else { continue }
            for linkMatch in String(groupMatch.output.2).matches(of: #/href="/([a-z]+)/browser/([^"?]*)(?:\?[^"]*)?"[^>]*>([^<]*)</a>/#) {
                let linkChannel = String(linkMatch.output.1)
                let path = String(linkMatch.output.2)
                let title = decodeHTMLEntities(String(linkMatch.output.3)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Empty paths are the group's "全部" reset links; the default
                // chart (filter == nil) already covers them.
                guard linkChannel == channel.rawValue, !path.isEmpty, !title.isEmpty,
                      let filter = Self.filter(group: group, title: title, path: path, channel: channel)
                else { continue }
                if !filters.contains(filter) { filters.append(filter) }
            }
        }
        return filters
    }

    /// Sidebar paths are either platform aliases (`cat`), the book series
    /// selectors (`series`), or wiki meta tags applied verbatim (`tags`).
    private static func filter(
        group: String,
        title: String,
        path: String,
        channel: BangumiChartChannel
    ) -> BangumiChartFilter? {
        let decodedPath = path.removingPercentEncoding ?? path
        if let categoryID = categoryAliases[channel]?[decodedPath] {
            return BangumiChartFilter(group: group, title: title, categoryID: categoryID, series: nil, tag: nil)
        }
        switch decodedPath {
        case "series":
            return BangumiChartFilter(group: group, title: title, categoryID: nil, series: true, tag: nil)
        case "offprint":
            return BangumiChartFilter(group: group, title: title, categoryID: nil, series: false, tag: nil)
        default:
            return BangumiChartFilter(group: group, title: title, categoryID: nil, series: nil, tag: decodedPath)
        }
    }

    /// Platform aliases per channel, from bangumi/common's
    /// `subject_platforms.yml`. `misc` (cat 0) is omitted: the API treats it
    /// as "no category filter" rather than "everything else".
    private static let categoryAliases: [BangumiChartChannel: [String: Int]] = [
        .anime: ["tv": 1, "ova": 2, "movie": 3, "short_film": 4, "web": 5, "anime_comic": 2006],
        .book: ["comic": 1001, "novel": 1002, "illustration": 1003, "picture": 1004, "photo": 1005, "official": 1006],
        .game: ["games": 4001, "software": 4002, "dlc": 4003, "tabletop": 4005],
        .real: ["jp": 1, "en": 2, "cn": 3, "tv": 6001, "movie": 6002, "live": 6003, "show": 6004]
    ]

    /// Groups that are site navigation (pinyin index, empty tag cloud) or
    /// have no equivalent in the subjects API (serialization progress).
    private static let excludedFilterGroups: Set<String> = ["拼音筛选", "标签", "进度"]

    // MARK: - Requests

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func loadJSON<Value: Decodable>(_ request: URLRequest) async throws -> Value {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MetadataProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw MetadataProviderError.httpStatus(http.statusCode) }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func fetchHTML(_ request: URLRequest) async throws -> String {
        var htmlRequest = request
        htmlRequest.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            return try await loadHTML(htmlRequest)
        } catch MetadataProviderError.httpStatus(403) {
            // bgm.tv's edge occasionally answers with a transient 403
            // challenge; one polite retry has consistently been enough.
            try await Task.sleep(for: .seconds(1.2))
            return try await loadHTML(htmlRequest)
        }
    }

    private func loadHTML(_ request: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MetadataProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw MetadataProviderError.httpStatus(http.statusCode) }
        guard let html = String(data: data, encoding: .utf8) else { throw MetadataProviderError.invalidResponse }
        return html
    }

    // MARK: - Entities

    static func decodeHTMLEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = decodeNumericEntities(in: string)
        let named: [String: String] = [
            "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
            "&#39;": "'", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—", "&middot;": "·"
        ]
        for (entity, character) in named where result.contains(entity) {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        // &amp; last so pre-escaped text ("&amp;lt;") is not double-decoded.
        if result.contains("&amp;") { result = result.replacingOccurrences(of: "&amp;", with: "&") }
        return result
    }

    private static func decodeNumericEntities(in string: String) -> String {
        var result = string
        for match in result.matches(of: #/&#(\d+);/#).reversed() {
            if let code = UInt32(match.output.1), let scalar = UnicodeScalar(code) {
                result.replaceSubrange(match.range, with: String(scalar))
            }
        }
        for match in result.matches(of: #/(?i)&#x([0-9a-f]+);/#).reversed() {
            if let code = UInt32(match.output.1, radix: 16), let scalar = UnicodeScalar(code) {
                result.replaceSubrange(match.range, with: String(scalar))
            }
        }
        return result
    }
}

private struct ChartResponse: Decodable {
    let data: [ChartSubject]
    let total: Int
}

private struct ChartSubject: Decodable {
    let id: Int
    let name: String
    let nameCN: String?
    let info: String?
    let images: ChartImages?
    let rating: ChartRating?

    enum CodingKeys: String, CodingKey {
        case id, name, info, images, rating
        case nameCN = "nameCN"
    }

    var entry: BangumiChartEntry? {
        let chineseTitle = nameCN?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayTitle = chineseTitle.isEmpty ? name : chineseTitle
        let original = (displayTitle == name || name.isEmpty) ? nil : name
        // Unrated subjects report score 0; keep the chart honest instead of
        // showing a wall of 0.0 badges.
        let score = rating?.score.flatMap { $0 > 0 ? $0 : nil }
        return BangumiChartEntry(
            subjectID: String(id),
            rank: rating?.rank ?? 0,
            title: displayTitle,
            originalTitle: original,
            score: score,
            ratingCount: rating?.total,
            info: info?.trimmingCharacters(in: .whitespacesAndNewlines),
            coverURL: (images?.large ?? images?.common).flatMap { URL(string: $0) },
            sourceURL: URL(string: "https://bgm.tv/subject/\(id)")!
        )
    }
}

private struct ChartImages: Decodable {
    let large: String?
    let common: String?
}

private struct ChartRating: Decodable {
    let rank: Int?
    let score: Double?
    let total: Int?
}
