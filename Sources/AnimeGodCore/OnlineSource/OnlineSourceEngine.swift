import Foundation

/// A request a rule says to make, with everything already substituted in.
///
/// Building it is kept apart from sending it so a rule can be checked
/// against a captured page in a test: every parse below takes bytes, and
/// nothing in this file needs a network to be exercised.
public struct OnlineSourceRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// Runs a source rule: builds its requests, reads its responses.
///
/// The two halves a rule describes are a search and an episode list. What it
/// cannot describe is where the stream is — that is behind the site's own
/// player JavaScript, and resolving it needs a browser. See the resolver in
/// the app layer; everything up to the episode's page URL is here.
public struct OnlineSourceEngine: Sendable {
    public init() {}

    // MARK: - Search

    public func searchRequest(_ rule: OnlineSourceRule, keyword: String) throws -> OnlineSourceRequest {
        guard !rule.requiresNewerClient else { throw OnlineSourceError.requiresNewerClient(api: rule.api) }
        switch rule.searchMode {
        case .api:
            return try apiRequest(rule.searchAPI.request, substituting: ["keyword": keyword])
        case .xpath:
            guard !rule.searchURL.isEmpty else { throw OnlineSourceError.ruleIncomplete(field: "searchURL") }
            // A keyword goes in as a query component, so a space, an `&` or
            // a `!` in a title cannot end the parameter early.
            let filled = rule.searchURL.replacingOccurrences(
                of: "@keyword",
                with: keyword.addingPercentEncoding(withAllowedCharacters: .onlineSourceQueryValue) ?? keyword
            )
            guard let url = URL(string: filled), url.scheme != nil, url.host != nil else {
                throw OnlineSourceError.invalidURL(filled)
            }
            guard rule.usePost else {
                return OnlineSourceRequest(method: "GET", url: url, headers: browsingHeaders(rule))
            }
            // A POST rule writes its parameters into `searchURL` anyway, so
            // the query is where the form body comes from.
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let form = (components?.percentEncodedQuery ?? "").data(using: .utf8)
            var stripped = components
            stripped?.query = nil
            guard let postURL = stripped?.url else { throw OnlineSourceError.invalidURL(filled) }
            var headers = browsingHeaders(rule)
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            return OnlineSourceRequest(method: "POST", url: postURL, headers: headers, body: form)
        }
    }

    public func parseSearch(_ data: Data, rule: OnlineSourceRule) throws -> OnlineSearchResult {
        switch rule.searchMode {
        case .api: return try parseAPISearch(data, rule: rule)
        case .xpath: return try parseXPathSearch(data, rule: rule)
        }
    }

    private func parseXPathSearch(_ data: Data, rule: OnlineSourceRule) throws -> OnlineSearchResult {
        guard !rule.searchList.isEmpty else { throw OnlineSourceError.ruleIncomplete(field: "searchList") }
        guard !rule.searchName.isEmpty else { throw OnlineSourceError.ruleIncomplete(field: "searchName") }
        guard !rule.searchResult.isEmpty else { throw OnlineSourceError.ruleIncomplete(field: "searchResult") }
        guard let page = HTMLSelector(data: data) else { throw OnlineSourceError.unreadableResponse }

        var items: [OnlineSearchItem] = []
        var skipped: [String] = []
        for (index, row) in page.nodes(forXPath: rule.searchList).enumerated() {
            let name = row.node(forXPath: rule.searchName)?.text ?? ""
            // The link node may be the anchor itself or carry the href on a
            // child; a rule points at whichever its site has.
            let href = row.node(forXPath: rule.searchResult).flatMap(Self.href) ?? ""
            guard !name.isEmpty, !href.isEmpty else {
                skipped.append(Self.skippedRow(index, missingName: name.isEmpty))
                continue
            }
            items.append(
                OnlineSearchItem(
                    ruleName: rule.name,
                    name: name,
                    pageURL: OnlineEpisodeURL.absolute(href, base: rule.baseURL)
                )
            )
        }
        guard !items.isEmpty else { throw OnlineSourceError.noResults }
        return OnlineSearchResult(ruleName: rule.name, items: items, skipped: skipped)
    }

    private func parseAPISearch(_ data: Data, rule: OnlineSourceRule) throws -> OnlineSearchResult {
        let json = try Self.json(data)
        let config = rule.searchAPI
        var items: [OnlineSearchItem] = []
        var skipped: [String] = []
        for (index, entry) in OnlineSourceJSONPath.values(config.listPath, in: json).enumerated() {
            let name = OnlineSourceJSONPath.string(config.namePath, in: entry) ?? ""
            let source = OnlineSourceJSONPath.string(config.sourcePath, in: entry) ?? ""
            guard !name.isEmpty, !source.isEmpty else {
                skipped.append(Self.skippedRow(index, missingName: name.isEmpty))
                continue
            }
            // Several sites answer a search with an id, not a link; the
            // template is how a rule says what to build out of it.
            let href = config.sourceTemplate.isEmpty
                ? source
                : config.sourceTemplate.replacingOccurrences(of: "@source", with: source)
            items.append(
                OnlineSearchItem(
                    ruleName: rule.name,
                    name: name,
                    pageURL: OnlineEpisodeURL.absolute(href, base: rule.baseURL)
                )
            )
        }
        guard !items.isEmpty else { throw OnlineSourceError.noResults }
        return OnlineSearchResult(ruleName: rule.name, items: items, skipped: skipped)
    }

    // MARK: - Episode lists

    public func chapterRequest(_ rule: OnlineSourceRule, pageURL: String) throws -> OnlineSourceRequest {
        guard !rule.requiresNewerClient else { throw OnlineSourceError.requiresNewerClient(api: rule.api) }
        switch rule.chapterMode {
        case .api:
            return try apiRequest(rule.chapterAPI.request, substituting: ["source": pageURL])
        case .xpath:
            let absolute = OnlineEpisodeURL.absolute(pageURL, base: rule.baseURL)
            guard let url = URL(string: absolute), url.scheme != nil, url.host != nil else {
                throw OnlineSourceError.invalidURL(absolute)
            }
            return OnlineSourceRequest(method: "GET", url: url, headers: browsingHeaders(rule))
        }
    }

    public func parseChapters(_ data: Data, rule: OnlineSourceRule) throws -> OnlineChapterResult {
        switch rule.chapterMode {
        case .api: return try parseAPIChapters(data, rule: rule)
        case .xpath: return try parseXPathChapters(data, rule: rule)
        }
    }

    private func parseXPathChapters(_ data: Data, rule: OnlineSourceRule) throws -> OnlineChapterResult {
        guard !rule.chapterRoads.isEmpty else { throw OnlineSourceError.ruleIncomplete(field: "chapterRoads") }
        guard !rule.chapterResult.isEmpty else { throw OnlineSourceError.ruleIncomplete(field: "chapterResult") }
        guard let page = HTMLSelector(data: data) else { throw OnlineSourceError.unreadableResponse }

        var roads: [OnlineRoad] = []
        var skipped: [String] = []
        for (roadIndex, roadNode) in page.nodes(forXPath: rule.chapterRoads).enumerated() {
            var episodes: [OnlineEpisode] = []
            for node in roadNode.nodes(forXPath: rule.chapterResult) {
                guard let href = Self.href(node), !href.isEmpty else { continue }
                let label = node.compactText
                episodes.append(
                    OnlineEpisode(
                        label: label.isEmpty
                            ? String(localized: "Episode \(episodes.count + 1)", bundle: .module)
                            : label,
                        pageURL: OnlineEpisodeURL.absolute(href, base: rule.baseURL),
                        index: episodes.count
                    )
                )
            }
            guard !episodes.isEmpty else {
                skipped.append(String(localized: "Line \(roadIndex + 1) has no episodes", bundle: .module))
                continue
            }
            roads.append(
                OnlineRoad(
                    name: String(localized: "Line \(roads.count + 1)", bundle: .module),
                    episodes: episodes
                )
            )
        }
        guard !roads.isEmpty else { throw OnlineSourceError.noResults }
        return OnlineChapterResult(ruleName: rule.name, roads: roads, skipped: skipped)
    }

    private func parseAPIChapters(_ data: Data, rule: OnlineSourceRule) throws -> OnlineChapterResult {
        let json = try Self.json(data)
        let config = rule.chapterAPI
        // Named captures over the whole response, so a playback URL can be
        // built from ids that live outside the episode entry itself.
        var variables: [String: String] = [:]
        for (name, path) in config.variables {
            if let value = OnlineSourceJSONPath.string(path, in: json) { variables[name] = value }
        }

        let roads: [OnlineRoad]
        switch config.shape {
        case .nested: roads = nestedRoads(json, config: config, rule: rule, variables: variables)
        case .delimited: roads = delimitedRoads(json, config: config, rule: rule, variables: variables)
        }
        guard !roads.isEmpty else { throw OnlineSourceError.noResults }
        return OnlineChapterResult(ruleName: rule.name, roads: roads)
    }

    private func nestedRoads(
        _ json: Any,
        config: OnlineSourceAPIChapter,
        rule: OnlineSourceRule,
        variables: [String: String]
    ) -> [OnlineRoad] {
        OnlineSourceJSONPath.values(config.roadsPath, in: json).enumerated().compactMap { roadIndex, road in
            let episodes = OnlineSourceJSONPath.values(config.episodesPath, in: road)
                .enumerated()
                .compactMap { index, entry -> OnlineEpisode? in
                    let label = OnlineSourceJSONPath.string(config.episodeNamePath, in: entry)
                        ?? String(localized: "Episode \(index + 1)", bundle: .module)
                    guard let href = episodePageURL(
                        config: config, rule: rule, entry: entry,
                        variables: variables, roadIndex: roadIndex, episodeIndex: index
                    ) else { return nil }
                    return OnlineEpisode(label: label, pageURL: href, index: index)
                }
            guard !episodes.isEmpty else { return nil }
            let name = OnlineSourceJSONPath.string(config.roadNamePath, in: road)
                ?? String(localized: "Line \(roadIndex + 1)", bundle: .module)
            return OnlineRoad(name: name, episodes: episodes)
        }
    }

    /// The shape where the whole episode list is one delimited string —
    /// `線路1$$$第01集$https://…#第02集$https://…`, which is how MacCMS and
    /// everything modelled on it answers.
    private func delimitedRoads(
        _ json: Any,
        config: OnlineSourceAPIChapter,
        rule: OnlineSourceRule,
        variables: [String: String]
    ) -> [OnlineRoad] {
        let names = (OnlineSourceJSONPath.string(config.roadNamesPath, in: json) ?? "")
            .components(separatedBy: config.roadSeparator)
        let lines = (OnlineSourceJSONPath.string(config.roadEpisodesPath, in: json) ?? "")
            .components(separatedBy: config.roadSeparator)
        return lines.enumerated().compactMap { roadIndex, line in
            let episodes = line.components(separatedBy: config.episodeSeparator)
                .enumerated()
                .compactMap { index, entry -> OnlineEpisode? in
                    let fields = entry.components(separatedBy: config.fieldSeparator)
                    // A field separator of `$` also appears inside a URL's
                    // query on some sites, so the link is the *last* field
                    // and the label is everything before it.
                    guard fields.count >= 2, let href = fields.last, !href.isEmpty else { return nil }
                    let label = fields.dropLast().joined(separator: config.fieldSeparator)
                    return OnlineEpisode(
                        label: label.isEmpty
                            ? String(localized: "Episode \(index + 1)", bundle: .module)
                            : label,
                        pageURL: OnlineEpisodeURL.absolute(href, base: rule.baseURL),
                        index: index
                    )
                }
            guard !episodes.isEmpty else { return nil }
            let name = names.indices.contains(roadIndex) && !names[roadIndex].isEmpty
                ? names[roadIndex]
                : String(localized: "Line \(roadIndex + 1)", bundle: .module)
            return OnlineRoad(name: name, episodes: episodes)
        }
    }

    /// Where an episode is played from: the response's own URL, or one the
    /// rule builds out of captured variables.
    private func episodePageURL(
        config: OnlineSourceAPIChapter,
        rule: OnlineSourceRule,
        entry: Any,
        variables: [String: String],
        roadIndex: Int,
        episodeIndex: Int
    ) -> String? {
        guard !config.episodePageURL.isEmpty else {
            guard let href = OnlineSourceJSONPath.string(config.episodeURLPath, in: entry), !href.isEmpty else {
                return nil
            }
            return OnlineEpisodeURL.absolute(href, base: rule.baseURL)
        }
        var substitutions = variables
        substitutions["roadIndex"] = String(roadIndex)
        substitutions["episodeIndex"] = String(episodeIndex)
        substitutions["episodeNumber"] = String(episodeIndex + 1)
        // Anything the rule names as a path into the episode entry resolves
        // against the entry, which is where a per-episode id lives.
        for (name, path) in config.variables {
            if let value = OnlineSourceJSONPath.string(path, in: entry) { substitutions[name] = value }
        }
        var filled = Self.substitute(config.episodePageURL, with: substitutions)
        if !config.episodePageQuery.isEmpty {
            var components = URLComponents(string: filled)
            var items = components?.queryItems ?? []
            for (name, template) in config.episodePageQuery.sorted(by: { $0.key < $1.key }) {
                items.append(URLQueryItem(name: name, value: Self.substitute(template, with: substitutions)))
            }
            components?.queryItems = items
            filled = components?.url?.absoluteString ?? filled
        }
        return OnlineEpisodeURL.absolute(filled, base: rule.baseURL)
    }

    // MARK: - Shared

    private func apiRequest(
        _ config: OnlineSourceAPIRequest,
        substituting values: [String: String]
    ) throws -> OnlineSourceRequest {
        guard !config.url.isEmpty else { throw OnlineSourceError.ruleIncomplete(field: "api url") }
        var components = URLComponents(string: Self.substitute(config.url, with: values))
        if !config.query.isEmpty {
            var items = components?.queryItems ?? []
            // Sorted so one rule produces one URL every time: a dictionary's
            // order is not stable, and the URL is an episode's identity.
            for (name, template) in config.query.sorted(by: { $0.key < $1.key }) {
                items.append(URLQueryItem(name: name, value: Self.substitute(template, with: values)))
            }
            components?.queryItems = items
        }
        guard let url = components?.url, url.scheme != nil, url.host != nil else {
            throw OnlineSourceError.invalidURL(config.url)
        }

        var headers = config.headers
        var body: Data?
        switch config.bodyType {
        case .none:
            break
        case .json:
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
            body = Self.substitute(config.body ?? "", with: values).data(using: .utf8)
        case .form:
            headers["Content-Type"] = headers["Content-Type"] ?? "application/x-www-form-urlencoded"
            body = Self.substitute(config.body ?? "", with: values).data(using: .utf8)
        }
        return OnlineSourceRequest(method: config.method, url: url, headers: headers, body: body)
    }

    /// Why a result row was passed over.
    ///
    /// Two whole sentences rather than one with the missing field dropped
    /// into it: a word substituted into a translated string stays English
    /// in every language, and these are read by whoever is fixing the rule.
    static func skippedRow(_ index: Int, missingName: Bool) -> String {
        missingName
            ? String(localized: "Result \(index + 1) has no name", bundle: .module)
            : String(localized: "Result \(index + 1) has no link", bundle: .module)
    }

    /// Replaces `@name` placeholders. A keyword reaching a query parameter
    /// is encoded by `URLComponents`, so it goes in raw here; one reaching
    /// the URL's own text is encoded on the way in.
    static func substitute(_ template: String, with values: [String: String]) -> String {
        var filled = template
        for (name, value) in values {
            filled = filled.replacingOccurrences(of: "@\(name)", with: value)
        }
        return filled
    }

    static func json(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw OnlineSourceError.unreadableResponse
        }
    }

    /// The link a matched node stands for.
    ///
    /// A rule points `searchResult` at whatever its site happens to have: an
    /// `<a>`, or a wrapper whose anchor is a child. Both are taken, because a
    /// selector that matches the row but not the anchor is the most common
    /// way one of these rules half-breaks.
    static func href(_ node: HTMLElement) -> String? {
        if let href = node.attribute("href"), !href.isEmpty { return href }
        if let href = node.attribute("data-href"), !href.isEmpty { return href }
        return node.nodes(forXPath: ".//a/@href").first.map(\.text).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Headers a browser on that site would send. Not cosmetic: several of
    /// these sites answer a request without a plausible user agent with a
    /// challenge page, and one without a referer with a redirect.
    private func browsingHeaders(_ rule: OnlineSourceRule) -> [String: String] {
        var headers = [
            "User-Agent": rule.userAgent.isEmpty ? OnlineSourceUserAgent.desktopSafari : rule.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,ja;q=0.8,en;q=0.7",
        ]
        if !rule.referer.isEmpty {
            headers["Referer"] = rule.referer
        } else if !rule.baseURL.isEmpty {
            headers["Referer"] = rule.baseURL.hasSuffix("/") ? rule.baseURL : rule.baseURL + "/"
        }
        return headers
    }
}

public enum OnlineSourceUserAgent {
    /// One fixed desktop Safari string rather than a random pick from a
    /// list. A clearance cookie is bound to the user agent it was issued to,
    /// so a rotating agent makes a site that has just let us in serve the
    /// challenge again on the next request.
    public static let desktopSafari =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

extension CharacterSet {
    /// What may stay unescaped in a search keyword. `&`, `=`, `+`, `/` and
    /// `?` are all legal in a title and all change the URL's meaning.
    static let onlineSourceQueryValue: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
