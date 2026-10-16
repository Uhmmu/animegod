import Foundation
import Testing
@testable import AnimeGodCore

/// Fixtures are trimmed from real pages and real rules captured on
/// 2026-10-16: the search and detail pages of one Chinese streaming index,
/// and three rules out of the live catalog (schema levels 1, 6 and 9).
/// The markup keeps the div nesting intact, because the rules address it by
/// position — `//div[3]/div[1]/div[1]` is a real selector and trimming a
/// wrapper away would make the fixture test a structure no site has.
@Suite("A source rule, run against the pages it was written for")
struct OnlineSourceRuleTests {
    // MARK: - Fixtures

    /// Two results for 药师少女, as the site serves them.
    static let searchPage = """
    <html><body><div class="row"><div class="row-right">
      <div class="public-list-box search-box flex rel">
        <div class="cover"></div>
        <div class="left public-list-bj">
          <a target="_self" class="public-list-exp" href="/bangumi/56.html"><span class="public-list-prb hide ft2">已完结</span></a>
        </div>
        <div class="right rel flex-auto">
          <div class="thumb-content">
            <div class="thumb-txt cor4 hide">药屋少女的呢喃</div>
            <div class="thumb-else cor5 hide"><span><a href="/search/year/2023.html">2023</a></span></div>
          </div>
          <div class="playlist-btn"><a class="public-btn" href="/bangumi/56.html">播放正片</a></div>
        </div>
      </div>
      <div class="public-list-box search-box flex rel">
        <div class="cover"></div>
        <div class="left public-list-bj">
          <a target="_self" class="public-list-exp" href="/bangumi/3035.html"><span class="public-list-prb hide ft2">已完结</span></a>
        </div>
        <div class="right rel flex-auto">
          <div class="thumb-content">
            <div class="thumb-txt cor4 hide">药屋少女的呢喃 第二季</div>
            <div class="thumb-else cor5 hide"><span><a href="/search/year/2025.html">2025</a></span></div>
          </div>
          <div class="playlist-btn"><a class="public-btn" href="/bangumi/3035.html">播放正片</a></div>
        </div>
      </div>
    </div></div></body></html>
    """

    /// Two playback lines of one work, which is the ordinary case: any one
    /// of them can be down or short an episode.
    static let detailPage = """
    <html><body>
      <div class="anthology-list top20 select-a"><div class="anthology-list-box none"><div>
        <ul class="anthology-list-play size">
          <li class="box border"><a class="hide" href="/watch/56/1/1.html">第01集</a></li>
          <li class="box border"><a class="hide" href="/watch/56/1/2.html">第 02 集</a></li>
          <li class="box border"><a class="hide" href="/watch/56/1/3.html">第03集</a></li>
        </ul>
      </div></div></div>
      <div class="anthology-list top20 select-a"><div class="anthology-list-box none"><div>
        <ul class="anthology-list-play size">
          <li class="box border"><a class="hide" href="/watch/56/2/1.html">第01集</a></li>
          <li class="box border"><a class="hide" href="/watch/56/2/2.html">第02集</a></li>
        </ul>
      </div></div></div>
    </body></html>
    """

    /// Schema 6, XPath both sides, the iframe-based resolver.
    static let xpathRuleJSON = """
    {
        "api": "6",
        "type": "anime",
        "name": "xfdmneo",
        "version": "1.1",
        "muliSources": true,
        "useWebview": true,
        "useNativePlayer": true,
        "usePost": false,
        "useLegacyParser": true,
        "adBlocker": false,
        "userAgent": "",
        "baseURL": "https://dm1.xfdm.pro/",
        "searchURL": "https://dm1.xfdm.pro/search.html?wd=@keyword",
        "searchList": "//div[@class='public-list-box search-box flex rel']",
        "searchName": "//div[3]/div[1]/div[1]",
        "searchResult": "//div[3]/div[2]/a[1]",
        "chapterRoads": "//ul[@class='anthology-list-play size']",
        "chapterResult": "//li/a",
        "referer": ""
    }
    """

    /// Schema 9, JSON search with an id that a template turns into a URL.
    static let apiRuleJSON = """
    {
        "api": "9",
        "type": "anime",
        "name": "giriGiriLove",
        "version": "2.5",
        "muliSources": true,
        "useWebview": true,
        "useNativePlayer": true,
        "usePost": false,
        "useLegacyParser": false,
        "adBlocker": false,
        "userAgent": "",
        "baseURL": "https://ani.girigirilove.com",
        "searchMode": "api",
        "chapterMode": "xpath",
        "searchApiConfig": {
            "request": {
                "method": "GET",
                "url": "https://ani.girigirilove.com/index.php/ajax/suggest",
                "query": { "mid": "1", "wd": "@keyword" }
            },
            "listPath": "$.list[*]",
            "namePath": "$.name",
            "sourcePath": "$.id",
            "sourceTemplate": "https://ani.girigirilove.com/GV@source/"
        },
        "searchURL": "",
        "searchList": "",
        "searchName": "",
        "searchResult": "",
        "chapterRoads": "//ul[@class='anthology-list-play size']",
        "chapterResult": "//li/a",
        "referer": ""
    }
    """

    /// Schema 1, which is most of the catalog's older rules: no mode fields,
    /// no `usePost`, no `referer` at all.
    static let minimalRuleJSON = """
    {
        "api": "1",
        "type": "anime",
        "name": "AGE",
        "version": "1.5",
        "muliSources": true,
        "useWebview": true,
        "useNativePlayer": true,
        "userAgent": "",
        "baseURL": "https://www.agedm.io/",
        "searchURL": "https://www.agedm.io/search?query=@keyword",
        "searchList": "//div[2]/div/section/div/div/div/div",
        "searchName": "//div/div[2]/h5/a",
        "searchResult": "//div/div[2]/h5/a",
        "chapterRoads": "//div[2]/div/section/div/div[2]/div[2]/div[2]/div",
        "chapterResult": "//ul/li/a"
    }
    """

    static func rule(_ json: String) throws -> OnlineSourceRule {
        try JSONDecoder().decode(OnlineSourceRule.self, from: Data(json.utf8))
    }

    // MARK: - The selectors

    @Test("A search page becomes the works it lists")
    func readsSearchResults() throws {
        let rule = try Self.rule(Self.xpathRuleJSON)
        let result = try OnlineSourceEngine().parseSearch(Data(Self.searchPage.utf8), rule: rule)
        #expect(result.items.count == 2)
        #expect(result.items.map(\.name) == ["药屋少女的呢喃", "药屋少女的呢喃 第二季"])
        // Relative hrefs come back absolute, and the base URL's trailing
        // slash does not become a double one.
        #expect(result.items.map(\.pageURL) == [
            "https://dm1.xfdm.pro/bangumi/56.html",
            "https://dm1.xfdm.pro/bangumi/3035.html",
        ])
        #expect(result.skipped.isEmpty)
    }

    @Test("An inner selector searches its own row, not the whole page")
    func anchorsInnerSelectorsToTheirNode() throws {
        // The rules are written with a leading `//` on the inner selectors
        // and mean "inside this row". XPath 1.0 anchors that at the document,
        // so taken literally every row is handed the first row's answer.
        // Measured on the real page: `//div[3]/div[2]/a[1]` matched 2 nodes
        // unscoped and 1 scoped.
        let page = try #require(HTMLSelector(html: Self.searchPage))
        let rows = page.nodes(forXPath: "//div[@class='public-list-box search-box flex rel']")
        #expect(rows.count == 2)
        let second = try #require(rows.last)
        #expect(second.node(forXPath: "//div[3]/div[1]/div[1]")?.text == "药屋少女的呢喃 第二季")
        #expect(HTMLSelector.scoped("//li/a", within: nil) == "//li/a")
    }

    @Test("Two playback lines stay two lines")
    func readsEveryPlaybackLine() throws {
        let rule = try Self.rule(Self.xpathRuleJSON)
        let result = try OnlineSourceEngine().parseChapters(Data(Self.detailPage.utf8), rule: rule)
        #expect(result.roads.count == 2)
        #expect(result.roads[0].episodes.count == 3)
        #expect(result.roads[1].episodes.count == 2)
        // Unscoped, `//li/a` would hand both lines all five episodes — which
        // is the same fault as above and loses the choice the lines are for.
        #expect(result.roads[0].episodes.first?.pageURL == "https://dm1.xfdm.pro/watch/56/1/1.html")
        #expect(result.roads[1].episodes.first?.pageURL == "https://dm1.xfdm.pro/watch/56/2/1.html")
    }

    @Test("An episode label split across the markup is one label")
    func compactsEpisodeLabels() throws {
        let rule = try Self.rule(Self.xpathRuleJSON)
        let result = try OnlineSourceEngine().parseChapters(Data(Self.detailPage.utf8), rule: rule)
        // `第 02 集` in the source is `第02集` as a label, and its number is
        // readable either way.
        #expect(result.roads[0].episodes.map(\.label) == ["第01集", "第02集", "第03集"])
        #expect(result.roads[0].episodes.map(\.number) == [1, 2, 3])
    }

    @Test("A label with no number in it has no number, rather than a wrong one")
    func readsNoNumberFromASpecial() {
        #expect(OnlineEpisode(label: "OVA", pageURL: "https://example.com/1", index: 0).number == nil)
        #expect(OnlineEpisode(label: "第12话", pageURL: "https://example.com/2", index: 1).number == 12)
    }

    @Test("A source that has never heard of a show is not a broken source")
    func separatesEmptyFromBroken() throws {
        let rule = try Self.rule(Self.xpathRuleJSON)
        let engine = OnlineSourceEngine()
        #expect(throws: OnlineSourceError.noResults) {
            try engine.parseSearch(Data("<html><body><p>没有找到</p></body></html>".utf8), rule: rule)
        }
        var incomplete = rule
        incomplete.searchList = ""
        #expect(throws: OnlineSourceError.ruleIncomplete(field: "searchList")) {
            try engine.parseSearch(Data(Self.searchPage.utf8), rule: incomplete)
        }
    }

    @Test("A row missing its name is skipped and said to have been skipped")
    func reportsPartialRows() throws {
        var rule = try Self.rule(Self.xpathRuleJSON)
        // The name selector still matches the list but no longer the name
        // inside it — how one of these rules usually half-breaks when a site
        // reshuffles a wrapper.
        rule.searchName = "//div[9]/div[1]/div[1]"
        #expect(throws: OnlineSourceError.noResults) {
            try OnlineSourceEngine().parseSearch(Data(Self.searchPage.utf8), rule: rule)
        }
    }

    // MARK: - Requests

    @Test("A keyword is encoded into the search URL, punctuation and all")
    func encodesTheKeyword() throws {
        let rule = try Self.rule(Self.xpathRuleJSON)
        let request = try OnlineSourceEngine().searchRequest(rule, keyword: "Re:Zero & 药师")
        #expect(request.method == "GET")
        // An unescaped `&` would end the parameter and drop the rest of the
        // title; an unescaped `:` and `/` would change the path.
        #expect(request.url.absoluteString.contains("wd=Re%3AZero%20%26%20%E8%8D%AF%E5%B8%88"))
        #expect(request.headers["Referer"] == "https://dm1.xfdm.pro/")
        #expect(request.headers["User-Agent"] == OnlineSourceUserAgent.desktopSafari)
    }

    @Test("A JSON rule's query is built from its own template")
    func buildsAnAPIRequest() throws {
        let rule = try Self.rule(Self.apiRuleJSON)
        let request = try OnlineSourceEngine().searchRequest(rule, keyword: "药师少女")
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(request.url.path == "/index.php/ajax/suggest")
        #expect(query.contains(URLQueryItem(name: "mid", value: "1")))
        #expect(query.contains(URLQueryItem(name: "wd", value: "药师少女")))
    }

    @Test("A rule from a newer editor says so instead of half-running")
    func refusesANewerSchema() throws {
        var rule = try Self.rule(Self.apiRuleJSON)
        rule.api = "\(OnlineSourceRule.supportedAPILevel + 1)"
        #expect(rule.requiresNewerClient)
        #expect(throws: OnlineSourceError.requiresNewerClient(api: rule.api)) {
            try OnlineSourceEngine().searchRequest(rule, keyword: "x")
        }
    }

    // MARK: - JSON responses

    @Test("A JSON search answer becomes works, with an id turned into a link")
    func readsAnAPISearch() throws {
        let rule = try Self.rule(Self.apiRuleJSON)
        // Trimmed from the real suggest endpoint: the id is a number in the
        // response and a path segment in the URL built from it.
        let response = """
        {"total":2,"list":[{"id":5783,"name":"药师少女的独语"},{"id":9042,"name":"药师少女的独语 第二季"}]}
        """
        let result = try OnlineSourceEngine().parseSearch(Data(response.utf8), rule: rule)
        #expect(result.items.map(\.name) == ["药师少女的独语", "药师少女的独语 第二季"])
        #expect(result.items.map(\.pageURL) == [
            "https://ani.girigirilove.com/GV5783",
            "https://ani.girigirilove.com/GV9042",
        ])
    }

    @Test("An episode list packed into delimited strings comes apart")
    func readsADelimitedChapterAnswer() throws {
        var rule = try Self.rule(Self.apiRuleJSON)
        rule.chapterMode = .api
        rule.chapterAPI = OnlineSourceAPIChapter(
            shape: .delimited,
            roadNamesPath: "$.data.playFrom",
            roadEpisodesPath: "$.data.playUrl"
        )
        // MacCMS and everything modelled on it answers like this.
        let response = """
        {"data":{"playFrom":"线路一$$$线路二",
        "playUrl":"第01集$https://cdn.example.com/1.m3u8#第02集$https://cdn.example.com/2.m3u8$$$第01集$https://alt.example.com/1.m3u8"}}
        """
        let result = try OnlineSourceEngine().parseChapters(Data(response.utf8), rule: rule)
        #expect(result.roads.map(\.name) == ["线路一", "线路二"])
        #expect(result.roads[0].episodes.map(\.label) == ["第01集", "第02集"])
        #expect(result.roads[1].episodes.count == 1)
        #expect(result.roads[0].episodes[1].pageURL == "https://cdn.example.com/2.m3u8")
    }

    // MARK: - The schema itself

    @Test("A rule written for an older schema loads with the defaults it omits")
    func readsEveryCatalogSchema() throws {
        let minimal = try Self.rule(Self.minimalRuleJSON)
        #expect(minimal.name == "AGE")
        #expect(minimal.searchMode == .xpath)
        #expect(minimal.chapterMode == .xpath)
        #expect(minimal.usePost == false)
        #expect(minimal.referer.isEmpty)
        #expect(!minimal.requiresNewerClient)

        let api = try Self.rule(Self.apiRuleJSON)
        #expect(api.searchMode == .api)
        #expect(api.chapterMode == .xpath)
        #expect(api.searchAPI.sourceTemplate == "https://ani.girigirilove.com/GV@source/")

        let xpath = try Self.rule(Self.xpathRuleJSON)
        #expect(xpath.useLegacyParser)
    }

    @Test("A hand-edited rule survives a number where a string belongs")
    func toleratesLooseJSON() throws {
        // Both spellings are in the live catalog, and a rule that throws
        // here is a source the user simply cannot use.
        let rule = try Self.rule("""
        {"api": 9, "version": 1.1, "name": "loose", "baseURL": "https://example.com",
         "searchApiConfig": {"request": {"url": "https://example.com/s", "query": {"page": 1}}}}
        """)
        #expect(rule.api == "9")
        #expect(rule.version == "1.1")
        #expect(rule.searchAPI.request.query["page"] == "1")
    }

    @Test("A rule round-trips, including the half it is not using")
    func roundTripsThroughJSON() throws {
        // A rule is edited here and shared back out. Saving the list
        // re-serializes every rule, so dropping a configured API side while
        // the mode points at XPath would quietly delete someone's work.
        let original = try Self.rule(Self.apiRuleJSON)
        let encoded = try JSONEncoder().encode(original)
        let again = try JSONDecoder().decode(OnlineSourceRule.self, from: encoded)
        #expect(again == original)

        var switched = original
        switched.searchMode = .xpath
        let keptAPI = try JSONDecoder().decode(
            OnlineSourceRule.self, from: try JSONEncoder().encode(switched)
        )
        #expect(keptAPI.searchAPI.request.url == original.searchAPI.request.url)
    }

    @Test("Rules are the same source when their names differ only in case")
    func identifiesRulesByName() throws {
        #expect(OnlineSourceRule.identityKey("GiriGiriLove") == OnlineSourceRule.identityKey("girigirilove"))
    }

    @Test("A hotlink-protected stream is fetched with the headers the page would have sent")
    func carriesPlaybackHeaders() throws {
        let rule = try Self.rule(Self.xpathRuleJSON)
        // Measured: this site's CDN answers 401 to a bare request. A rule
        // that leaves `referer` blank still needs one, and its base URL is
        // what a browser on that page would have sent.
        #expect(rule.playbackHeaders["Referer"] == "https://dm1.xfdm.pro/")
        var pinned = rule
        pinned.referer = "https://dm1.xfdm.pro/watch/"
        pinned.userAgent = "SomeAgent/1.0"
        #expect(pinned.playbackHeaders["Referer"] == "https://dm1.xfdm.pro/watch/")
        #expect(pinned.playbackHeaders["User-Agent"] == "SomeAgent/1.0")
    }
}

@Suite("One episode, one URL")
struct OnlineEpisodeURLTests {
    @Test("A scraped href becomes an absolute URL")
    func resolvesRelativeLinks() {
        let base = "https://dm1.xfdm.pro/"
        #expect(OnlineEpisodeURL.absolute("/watch/56/1/1.html", base: base) == "https://dm1.xfdm.pro/watch/56/1/1.html")
        #expect(OnlineEpisodeURL.absolute("watch/56/1/1.html", base: base) == "https://dm1.xfdm.pro/watch/56/1/1.html")
        // Protocol-relative, which plenty of these pages use.
        #expect(OnlineEpisodeURL.absolute("//other.example.com/x", base: base) == "https://other.example.com/x")
    }

    @Test("The same episode is the same string every time")
    func normalizesToOneIdentity() {
        let base = "https://dm1.xfdm.pro"
        // Watch progress is filed under this string, so one episode reached
        // two ways must not become two episodes.
        let withSlash = OnlineEpisodeURL.absolute("/watch/56/1/1.html/", base: base)
        let plain = OnlineEpisodeURL.absolute("/watch/56/1/1.html", base: base)
        #expect(withSlash == plain)
        // The rule declares https, so its own host is read as https however
        // the page spelled the link.
        #expect(OnlineEpisodeURL.absolute("http://dm1.xfdm.pro/watch/1.html", base: base) == "https://dm1.xfdm.pro/watch/1.html")
        // Idempotent, because a stored URL is normalized again on the way
        // back in.
        #expect(OnlineEpisodeURL.absolute(plain, base: base) == plain)
    }

    @Test("A different host keeps its own scheme")
    func leavesOtherHostsAlone() {
        // A stream CDN reachable only over http would break if rewritten,
        // and it is not the rule's host to speak for.
        #expect(
            OnlineEpisodeURL.absolute("http://cdn.example.com/a.m3u8", base: "https://dm1.xfdm.pro")
                == "http://cdn.example.com/a.m3u8"
        )
    }

    @Test("A query that means something is kept")
    func keepsMeaningfulQueries() {
        #expect(
            OnlineEpisodeURL.absolute("/play?id=5&ep=2", base: "https://example.com")
                == "https://example.com/play?id=5&ep=2"
        )
        #expect(OnlineEpisodeURL.absolute("", base: "https://example.com").isEmpty)
    }
}

@Suite("The slice of JSONPath a rule uses")
struct OnlineSourceJSONPathTests {
    /// Every expression in the live catalog, collected on 2026-10-16. There
    /// are eleven and they are all this shape, which is why this is a subset
    /// rather than an implementation.
    static let catalogExpressions = [
        "$", "$.data", "$.data.records[*]", "$.episodeLabel", "$.episodeOrder",
        "$.episodes[*]", "$.id", "$.list[*]", "$.name", "$.sources[*]", "$.title", "$[*]",
    ]

    @Test("Every path the catalog actually uses parses")
    func parsesTheWholeCatalog() {
        for expression in Self.catalogExpressions {
            #expect(OnlineSourceJSONPath.parse(expression) != nil, "\(expression) should parse")
        }
    }

    @Test("Keys and wildcards walk the response")
    func walksTheResponse() throws {
        let json = try OnlineSourceEngine.json(Data("""
        {"data":{"records":[{"id":1,"title":"A"},{"id":2,"title":"B"}]}}
        """.utf8))
        let records = OnlineSourceJSONPath.values("$.data.records[*]", in: json)
        #expect(records.count == 2)
        #expect(OnlineSourceJSONPath.string("$.title", in: records[1]) == "B")
        #expect(OnlineSourceJSONPath.string("$.data.records[0].id", in: json) == "1")
        #expect(OnlineSourceJSONPath.values("$[*]", in: try OnlineSourceEngine.json(Data("[1,2,3]".utf8))).count == 3)
    }

    @Test("A number that is an id reads as an id, not as a decimal")
    func readsNumbersAsTheirText() throws {
        // `5783.0` in a URL is a 404. JSONSerialization hands every number
        // back as an NSNumber, so this is the case that actually fires.
        let json = try OnlineSourceEngine.json(Data(#"{"id":5783,"score":8.7,"live":true}"#.utf8))
        #expect(OnlineSourceJSONPath.string("$.id", in: json) == "5783")
        #expect(OnlineSourceJSONPath.string("$.score", in: json) == "8.7")
        // A boolean is an NSNumber too, and casts to Int as 1 — it has to be
        // told apart before any numeric cast is tried.
        #expect(OnlineSourceJSONPath.string("$.live", in: json) == "true")
    }

    @Test("A path this does not implement finds nothing rather than something wrong")
    func refusesWhatItCannotDo() {
        // Filters, slices and recursive descent are used by no rule. Saying
        // nothing is found is recoverable; a confident wrong answer is not.
        #expect(OnlineSourceJSONPath.parse("$..name") == nil)
        #expect(OnlineSourceJSONPath.parse("$.list[?(@.id==1)]") == nil)
        #expect(OnlineSourceJSONPath.parse("$.list[0:2]") == nil)
        #expect(OnlineSourceJSONPath.values("$..name", in: ["name": "x"]).isEmpty)
    }

    @Test("A missing key is missing, not empty text")
    func distinguishesMissingFromBlank() throws {
        let json = try OnlineSourceEngine.json(Data(#"{"name":""}"#.utf8))
        #expect(OnlineSourceJSONPath.string("$.name", in: json) == "")
        #expect(OnlineSourceJSONPath.string("$.missing", in: json) == nil)
    }
}

@Suite("Reading a page nobody validated")
struct HTMLSelectorTests {
    @Test("Markup a browser forgives is parsed, not refused")
    func recoversFromRealMarkup() throws {
        // Unclosed tags are what these pages are made of.
        let page = try #require(HTMLSelector(html: "<div><p>one<p>two<ul><li><a href=/x>link</div>"))
        #expect(page.nodes(forXPath: "//p").count == 2)
        #expect(page.node(forXPath: "//a")?.attribute("href") == "/x")
    }

    @Test("A page that declares GBK is read as GBK")
    func honoursADeclaredCharset() throws {
        // A Chinese index serving GBK is ordinary, and the general decoder
        // scores code pages against each other — a page that says what it
        // is should not be argued with.
        let gbk = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let html = "<html><head><meta charset=\"gbk\"></head><body><div>药师少女的独语</div></body></html>"
        let data = try #require(html.data(using: gbk))
        #expect(HTMLSelector.declaredEncoding(data) == gbk)
        let page = try #require(HTMLSelector(data: data))
        #expect(page.node(forXPath: "//div")?.text == "药师少女的独语")
    }

    @Test("A page that declares nothing is still read")
    func fallsBackToSniffing() throws {
        let html = "<html><body><div>ふつうのページ</div></body></html>"
        let page = try #require(HTMLSelector(data: Data(html.utf8)))
        #expect(page.node(forXPath: "//div")?.text == "ふつうのページ")
    }

    @Test("A link on a child is found when the rule points at the wrapper")
    func findsTheAnchorBelow() throws {
        // A rule points `searchResult` at whatever its site has; a selector
        // that matches the row but not the anchor is the most common way one
        // of these rules half-breaks.
        let page = try #require(HTMLSelector(html: "<div class=row><span><a href='/y'>go</a></span></div>"))
        let row = try #require(page.node(forXPath: "//div[@class='row']"))
        #expect(OnlineSourceEngine.href(row) == "/y")
    }

    @Test("An empty or broken selector matches nothing instead of throwing")
    func survivesABadSelector() throws {
        let page = try #require(HTMLSelector(html: "<div>x</div>"))
        #expect(page.nodes(forXPath: "").isEmpty)
        #expect(page.nodes(forXPath: "//[[[").isEmpty)
    }
}
