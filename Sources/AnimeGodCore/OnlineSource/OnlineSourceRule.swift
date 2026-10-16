import Foundation

/// A streaming source, described by selectors rather than code.
///
/// This is deliberately Kazumi's rule schema, field for field, so the rules
/// people already write and share load here unchanged — a rule is at most
/// five XPath expressions plus the URL to run them against, which is the
/// whole reason that project can follow sites that move, rename and break
/// every few weeks without shipping an app update.
///
/// Fields AnimeGod has no use for are still read and written back
/// (`useWebview`, `useNativePlayer`, `adBlocker`, `muliSources` —
/// misspelled upstream and kept that way): a rule round-trips through this
/// app and out again, and silently dropping half of it would make the copy
/// useless to the editor it came from.
public struct OnlineSourceRule: Codable, Sendable, Identifiable, Hashable {
    /// How a rule reads a response: selectors over HTML, or paths into JSON.
    public enum Mode: String, Codable, Sendable {
        case xpath
        case api

        /// Anything unrecognized is XPath, which is what a rule without the
        /// field at all means.
        public init(_ raw: String?) {
            self = raw == Mode.api.rawValue ? .api : .xpath
        }
    }

    /// The rule schema level this rule needs. A rule from a newer editor can
    /// describe things this app cannot run, and the honest answer is to say
    /// so rather than half-run it.
    public static let supportedAPILevel = 9

    public var id: String { OnlineSourceRule.identityKey(name) }

    /// Rules are identified by name, case-insensitively — the catalog's own
    /// spelling is kept for display.
    public static func identityKey(_ name: String) -> String { name.lowercased() }

    public var api: String
    public var type: String
    public var name: String
    public var version: String
    public var muliSources: Bool
    public var useWebview: Bool
    public var useNativePlayer: Bool
    public var usePost: Bool
    /// Whether the page hides its stream behind an iframe rather than a
    /// `<video>` tag. It decides which script the resolver injects.
    public var useLegacyParser: Bool
    public var adBlocker: Bool
    public var userAgent: String
    public var baseURL: String
    public var searchURL: String
    public var searchList: String
    public var searchName: String
    public var searchResult: String
    public var chapterRoads: String
    public var chapterResult: String
    public var referer: String
    public var searchMode: Mode
    public var chapterMode: Mode
    public var searchAPI: OnlineSourceAPISearch
    public var chapterAPI: OnlineSourceAPIChapter

    public init(
        api: String = "\(OnlineSourceRule.supportedAPILevel)",
        type: String = "anime",
        name: String = "",
        version: String = "",
        muliSources: Bool = true,
        useWebview: Bool = true,
        useNativePlayer: Bool = true,
        usePost: Bool = false,
        useLegacyParser: Bool = false,
        adBlocker: Bool = false,
        userAgent: String = "",
        baseURL: String = "",
        searchURL: String = "",
        searchList: String = "",
        searchName: String = "",
        searchResult: String = "",
        chapterRoads: String = "",
        chapterResult: String = "",
        referer: String = "",
        searchMode: Mode = .xpath,
        chapterMode: Mode = .xpath,
        searchAPI: OnlineSourceAPISearch = OnlineSourceAPISearch(),
        chapterAPI: OnlineSourceAPIChapter = OnlineSourceAPIChapter()
    ) {
        self.api = api
        self.type = type
        self.name = name
        self.version = version
        self.muliSources = muliSources
        self.useWebview = useWebview
        self.useNativePlayer = useNativePlayer
        self.usePost = usePost
        self.useLegacyParser = useLegacyParser
        self.adBlocker = adBlocker
        self.userAgent = userAgent
        self.baseURL = baseURL
        self.searchURL = searchURL
        self.searchList = searchList
        self.searchName = searchName
        self.searchResult = searchResult
        self.chapterRoads = chapterRoads
        self.chapterResult = chapterResult
        self.referer = referer
        self.searchMode = searchMode
        self.chapterMode = chapterMode
        self.searchAPI = searchAPI
        self.chapterAPI = chapterAPI
    }

    /// Whether this rule asks for a schema level this app does not implement.
    public var requiresNewerClient: Bool {
        (Int(api) ?? 1) > OnlineSourceRule.supportedAPILevel
    }

    /// The headers the final stream is fetched with. A hotlink-protected CDN
    /// serves nothing without the referer the page would have sent, and a
    /// rule that pins a user agent pins it because the site checks.
    public var playbackHeaders: [String: String] {
        var headers: [String: String] = [:]
        if !userAgent.isEmpty { headers["User-Agent"] = userAgent }
        if !referer.isEmpty {
            headers["Referer"] = referer
        } else if let origin = URL(string: baseURL), origin.host != nil {
            // Most rules leave `referer` blank and the site still wants one;
            // its own base URL is what a browser on that page would send.
            headers["Referer"] = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        }
        return headers
    }

    // Kazumi's JSON spells a few keys differently from the Swift names, and
    // every field is optional in the wild — a rule written against schema 1
    // has none of the API fields at all.
    private enum CodingKeys: String, CodingKey {
        case api, type, name, version, muliSources, useWebview, useNativePlayer
        case usePost, useLegacyParser, adBlocker, userAgent
        case baseURL = "baseURL"
        case searchURL, searchList, searchName, searchResult
        case chapterRoads, chapterResult, referer, searchMode, chapterMode
        case searchAPI = "searchApiConfig"
        case chapterAPI = "chapterApiConfig"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `api` and `version` are a string in some rules and a number in
        // others, and both spellings are in the live catalog.
        api = container.looseString(.api) ?? "1"
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "anime"
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        version = container.looseString(.version) ?? ""
        muliSources = try container.decodeIfPresent(Bool.self, forKey: .muliSources) ?? true
        useWebview = try container.decodeIfPresent(Bool.self, forKey: .useWebview) ?? true
        useNativePlayer = try container.decodeIfPresent(Bool.self, forKey: .useNativePlayer) ?? true
        usePost = try container.decodeIfPresent(Bool.self, forKey: .usePost) ?? false
        useLegacyParser = try container.decodeIfPresent(Bool.self, forKey: .useLegacyParser) ?? false
        adBlocker = try container.decodeIfPresent(Bool.self, forKey: .adBlocker) ?? false
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent) ?? ""
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        searchURL = try container.decodeIfPresent(String.self, forKey: .searchURL) ?? ""
        searchList = try container.decodeIfPresent(String.self, forKey: .searchList) ?? ""
        searchName = try container.decodeIfPresent(String.self, forKey: .searchName) ?? ""
        searchResult = try container.decodeIfPresent(String.self, forKey: .searchResult) ?? ""
        chapterRoads = try container.decodeIfPresent(String.self, forKey: .chapterRoads) ?? ""
        chapterResult = try container.decodeIfPresent(String.self, forKey: .chapterResult) ?? ""
        referer = try container.decodeIfPresent(String.self, forKey: .referer) ?? ""
        searchMode = Mode(try container.decodeIfPresent(String.self, forKey: .searchMode))
        chapterMode = Mode(try container.decodeIfPresent(String.self, forKey: .chapterMode))
        searchAPI = try container.decodeIfPresent(OnlineSourceAPISearch.self, forKey: .searchAPI)
            ?? OnlineSourceAPISearch()
        chapterAPI = try container.decodeIfPresent(OnlineSourceAPIChapter.self, forKey: .chapterAPI)
            ?? OnlineSourceAPIChapter()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(api, forKey: .api)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(muliSources, forKey: .muliSources)
        try container.encode(useWebview, forKey: .useWebview)
        try container.encode(useNativePlayer, forKey: .useNativePlayer)
        try container.encode(usePost, forKey: .usePost)
        try container.encode(useLegacyParser, forKey: .useLegacyParser)
        try container.encode(adBlocker, forKey: .adBlocker)
        try container.encode(userAgent, forKey: .userAgent)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(searchURL, forKey: .searchURL)
        try container.encode(searchList, forKey: .searchList)
        try container.encode(searchName, forKey: .searchName)
        try container.encode(searchResult, forKey: .searchResult)
        try container.encode(chapterRoads, forKey: .chapterRoads)
        try container.encode(chapterResult, forKey: .chapterResult)
        try container.encode(referer, forKey: .referer)
        try container.encode(searchMode.rawValue, forKey: .searchMode)
        try container.encode(chapterMode.rawValue, forKey: .chapterMode)
        // A configured API side survives even while the mode points at
        // XPath: saving the rule list re-serializes every rule, so dropping
        // the inactive half would quietly delete someone's work.
        if searchMode == .api || !searchAPI.request.url.isEmpty {
            try container.encode(searchAPI, forKey: .searchAPI)
        }
        if chapterMode == .api || !chapterAPI.request.url.isEmpty {
            try container.encode(chapterAPI, forKey: .chapterAPI)
        }
    }
}

/// An HTTP request a rule describes, for the sites that answer with JSON
/// rather than a page.
public struct OnlineSourceAPIRequest: Codable, Sendable, Hashable {
    public enum BodyKind: String, Codable, Sendable {
        case none, json, form

        public init(_ raw: String?) {
            self = BodyKind(rawValue: raw ?? "") ?? .none
        }
    }

    public var method: String
    public var url: String
    public var headers: [String: String]
    public var query: [String: String]
    public var bodyType: BodyKind
    /// Kept as text: a rule's body is a template with `@keyword` in it, and
    /// re-encoding it as JSON would reorder and reformat what the site is
    /// matched against.
    public var body: String?

    public init(
        method: String = "GET",
        url: String = "",
        headers: [String: String] = [:],
        query: [String: String] = [:],
        bodyType: BodyKind = .none,
        body: String? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.query = query
        self.bodyType = bodyType
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case method, url, headers, query, bodyType, body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = (try container.decodeIfPresent(String.self, forKey: .method) ?? "GET").uppercased()
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = container.looseStringMap(.headers)
        query = container.looseStringMap(.query)
        bodyType = BodyKind(try container.decodeIfPresent(String.self, forKey: .bodyType))
        body = container.looseJSONText(.body)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method.uppercased(), forKey: .method)
        try container.encode(url, forKey: .url)
        if !headers.isEmpty { try container.encode(headers, forKey: .headers) }
        if !query.isEmpty { try container.encode(query, forKey: .query) }
        if bodyType != .none {
            try container.encode(bodyType.rawValue, forKey: .bodyType)
            if let body { try container.encode(body, forKey: .body) }
        }
    }
}

/// Where the names and links sit in a JSON search response.
public struct OnlineSourceAPISearch: Codable, Sendable, Hashable {
    public var request: OnlineSourceAPIRequest
    public var listPath: String
    public var namePath: String
    public var sourcePath: String
    /// The detail-page URL built by substituting `@source`. Several sites
    /// answer a search with an id rather than a link.
    public var sourceTemplate: String

    public init(
        request: OnlineSourceAPIRequest = OnlineSourceAPIRequest(),
        listPath: String = "$.data[*]",
        namePath: String = "$.name",
        sourcePath: String = "$.url",
        sourceTemplate: String = ""
    ) {
        self.request = request
        self.listPath = listPath
        self.namePath = namePath
        self.sourcePath = sourcePath
        self.sourceTemplate = sourceTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case request, listPath, namePath, sourcePath, sourceTemplate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        request = try container.decodeIfPresent(OnlineSourceAPIRequest.self, forKey: .request)
            ?? OnlineSourceAPIRequest()
        listPath = try container.decodeIfPresent(String.self, forKey: .listPath) ?? "$.data[*]"
        namePath = try container.decodeIfPresent(String.self, forKey: .namePath) ?? "$.name"
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath) ?? "$.url"
        sourceTemplate = (try container.decodeIfPresent(String.self, forKey: .sourceTemplate) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where the playback lines and episodes sit in a JSON chapter response.
public struct OnlineSourceAPIChapter: Codable, Sendable, Hashable {
    /// Whether the response nests episodes under lines, or packs the whole
    /// lot into delimited strings — both shapes are in the live catalog.
    public enum Shape: String, Codable, Sendable {
        case nested, delimited

        public init(_ raw: String?) {
            self = raw == Shape.delimited.rawValue ? .delimited : .nested
        }
    }

    public var request: OnlineSourceAPIRequest
    public var shape: Shape

    public var roadsPath: String
    public var roadNamePath: String
    public var episodesPath: String
    public var episodeNamePath: String
    public var episodeURLPath: String

    public var roadNamesPath: String
    public var roadEpisodesPath: String
    public var roadSeparator: String
    public var episodeSeparator: String
    public var fieldSeparator: String

    /// Named captures over the response, usable as `@name` in
    /// `episodePageURL`. A site that builds its playback URL out of three
    /// ids rather than publishing one needs them.
    public var variables: [String: String]
    public var episodePageURL: String
    public var episodePageQuery: [String: String]

    public init(
        request: OnlineSourceAPIRequest = OnlineSourceAPIRequest(),
        shape: Shape = .nested,
        roadsPath: String = "$.data.roads[*]",
        roadNamePath: String = "$.name",
        episodesPath: String = "$.episodes[*]",
        episodeNamePath: String = "$.name",
        episodeURLPath: String = "$.url",
        roadNamesPath: String = "",
        roadEpisodesPath: String = "",
        roadSeparator: String = "$$$",
        episodeSeparator: String = "#",
        fieldSeparator: String = "$",
        variables: [String: String] = [:],
        episodePageURL: String = "",
        episodePageQuery: [String: String] = [:]
    ) {
        self.request = request
        self.shape = shape
        self.roadsPath = roadsPath
        self.roadNamePath = roadNamePath
        self.episodesPath = episodesPath
        self.episodeNamePath = episodeNamePath
        self.episodeURLPath = episodeURLPath
        self.roadNamesPath = roadNamesPath
        self.roadEpisodesPath = roadEpisodesPath
        self.roadSeparator = roadSeparator
        self.episodeSeparator = episodeSeparator
        self.fieldSeparator = fieldSeparator
        self.variables = variables
        self.episodePageURL = episodePageURL
        self.episodePageQuery = episodePageQuery
    }

    private enum CodingKeys: String, CodingKey {
        case request
        case shape = "format"
        case roadsPath, roadNamePath, episodesPath, episodeNamePath
        case episodeURLPath = "episodeUrlPath"
        case roadNamesPath, roadEpisodesPath, roadSeparator, episodeSeparator, fieldSeparator
        case variables, episodePage
    }

    private enum PageKeys: String, CodingKey {
        case url, query
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        request = try container.decodeIfPresent(OnlineSourceAPIRequest.self, forKey: .request)
            ?? OnlineSourceAPIRequest()
        shape = Shape(try container.decodeIfPresent(String.self, forKey: .shape))
        roadsPath = try container.decodeIfPresent(String.self, forKey: .roadsPath) ?? "$.data.roads[*]"
        roadNamePath = try container.decodeIfPresent(String.self, forKey: .roadNamePath) ?? "$.name"
        episodesPath = try container.decodeIfPresent(String.self, forKey: .episodesPath) ?? "$.episodes[*]"
        episodeNamePath = try container.decodeIfPresent(String.self, forKey: .episodeNamePath) ?? "$.name"
        episodeURLPath = try container.decodeIfPresent(String.self, forKey: .episodeURLPath) ?? "$.url"
        roadNamesPath = try container.decodeIfPresent(String.self, forKey: .roadNamesPath) ?? ""
        roadEpisodesPath = try container.decodeIfPresent(String.self, forKey: .roadEpisodesPath) ?? ""
        roadSeparator = try container.decodeIfPresent(String.self, forKey: .roadSeparator) ?? "$$$"
        episodeSeparator = try container.decodeIfPresent(String.self, forKey: .episodeSeparator) ?? "#"
        fieldSeparator = try container.decodeIfPresent(String.self, forKey: .fieldSeparator) ?? "$"
        variables = container.looseStringMap(.variables)
        if let page = try? container.nestedContainer(keyedBy: PageKeys.self, forKey: .episodePage) {
            episodePageURL = try page.decodeIfPresent(String.self, forKey: .url) ?? ""
            episodePageQuery = page.looseStringMap(.query)
        } else {
            episodePageURL = ""
            episodePageQuery = [:]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request, forKey: .request)
        try container.encode(shape.rawValue, forKey: .shape)
        if shape == .nested || hasNestedConfiguration {
            try container.encode(roadsPath, forKey: .roadsPath)
            try container.encode(roadNamePath, forKey: .roadNamePath)
            try container.encode(episodesPath, forKey: .episodesPath)
            try container.encode(episodeNamePath, forKey: .episodeNamePath)
            try container.encode(episodeURLPath, forKey: .episodeURLPath)
        }
        if shape == .delimited || hasDelimitedConfiguration {
            try container.encode(roadNamesPath, forKey: .roadNamesPath)
            try container.encode(roadEpisodesPath, forKey: .roadEpisodesPath)
            try container.encode(roadSeparator, forKey: .roadSeparator)
            try container.encode(episodeSeparator, forKey: .episodeSeparator)
            try container.encode(fieldSeparator, forKey: .fieldSeparator)
        }
        if !variables.isEmpty { try container.encode(variables, forKey: .variables) }
        if !episodePageURL.isEmpty || !episodePageQuery.isEmpty {
            var page = container.nestedContainer(keyedBy: PageKeys.self, forKey: .episodePage)
            try page.encode(episodePageURL, forKey: .url)
            try page.encode(episodePageQuery, forKey: .query)
        }
    }

    private var hasNestedConfiguration: Bool {
        roadsPath != "$.data.roads[*]" || roadNamePath != "$.name"
            || episodesPath != "$.episodes[*]" || episodeNamePath != "$.name"
            || episodeURLPath != "$.url"
    }

    private var hasDelimitedConfiguration: Bool {
        !roadNamesPath.isEmpty || !roadEpisodesPath.isEmpty
    }
}

// MARK: - Reading a schema nobody validates

/// A rule in the wild is hand-edited JSON: `"api": 9` and `"api": "9"` are
/// both in the live catalog, a header value may be a number, and a body may
/// be an object or the text of one. Decoding has to take what it is given,
/// because a rule that throws here is a source the user simply cannot use.
extension KeyedDecodingContainer {
    func looseString(_ key: Key) -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) { return text }
        if let number = try? decodeIfPresent(Int.self, forKey: key) { return String(number) }
        if let number = try? decodeIfPresent(Double.self, forKey: key) {
            return number == number.rounded() ? String(Int(number)) : String(number)
        }
        return nil
    }

    func looseStringMap(_ key: Key) -> [String: String] {
        guard let raw = try? decodeIfPresent([String: OnlineSourceJSONScalar].self, forKey: key) else {
            return [:]
        }
        return raw.compactMapValues(\.text)
    }

    /// A field that may be written as JSON or as a string holding JSON.
    func looseJSONText(_ key: Key) -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) { return text }
        guard let value = try? decodeIfPresent(OnlineSourceJSONValue.self, forKey: key) else { return nil }
        return value.jsonText
    }
}

/// One JSON scalar, however it was written.
struct OnlineSourceJSONScalar: Decodable {
    let text: String?

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) {
            self.text = text
        } else if let number = try? value.decode(Int.self) {
            text = String(number)
        } else if let number = try? value.decode(Double.self) {
            text = number == number.rounded() ? String(Int(number)) : String(number)
        } else if let flag = try? value.decode(Bool.self) {
            text = flag ? "true" : "false"
        } else {
            text = nil
        }
    }
}

/// Any JSON, kept as its own text. Used for a rule's request body, which is
/// a template this app substitutes into and sends on rather than interprets.
struct OnlineSourceJSONValue: Decodable {
    let jsonText: String?

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) {
            jsonText = text
        } else if let object = try? value.decode([String: OnlineSourceJSONScalar].self) {
            let pairs = object.compactMapValues(\.text)
                .sorted { $0.key < $1.key }
                .map { "\"\($0.key)\":\"\($0.value)\"" }
            jsonText = "{\(pairs.joined(separator: ","))}"
        } else {
            jsonText = nil
        }
    }
}
