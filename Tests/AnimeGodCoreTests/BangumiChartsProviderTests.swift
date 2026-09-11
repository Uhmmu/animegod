import Foundation
import Testing
@testable import AnimeGodCore

@Suite(.serialized)
struct BangumiChartsProviderTests {
    @Test func parsesChartEntriesFromSubjectsEndpoint() async throws {
        let provider = Self.provider()

        let page = try await provider.chart(channel: .anime, page: 1)

        #expect(ChartsURLProtocol.requestedPaths == ["/p1/subjects?type=2&sort=rank&page=1"])
        #expect(page.totalPages == 372)
        #expect(page.hasNextPage)
        #expect(page.channel == .anime)
        #expect(page.filter == nil)

        let first = try #require(page.entries.first)
        #expect(first.subjectID == "326")
        #expect(first.rank == 1)
        #expect(first.title == "攻壳机动队 S.A.C. 2nd GIG")
        #expect(first.originalTitle == "攻殻機動隊 S.A.C. 2nd GIG")
        #expect(first.score == 9.16)
        #expect(first.ratingCount == 10128)
        #expect(first.info == "26话 / 2004年1月1日 / 神山健治 / 士郎正宗「攻殻機動隊」")
        #expect(first.coverURL?.absoluteString == "https://lain.bgm.tv/pic/cover/l/a6/66/326_D8wjw.jpg")
        #expect(first.sourceURL.absoluteString == "https://bgm.tv/subject/326")

        // A subject whose Chinese title is empty falls back to the original,
        // and zero scores mean "unrated", not "0.0".
        let fallback = try #require(page.entries.first { $0.subjectID == "876" })
        #expect(fallback.title == "CLANNAD 〜AFTER STORY〜")
        #expect(fallback.originalTitle == nil)
        #expect(fallback.score == nil)
        #expect(fallback.ratingCount == 0)
    }

    @Test func appliesCategorySeriesAndTagFilters() async throws {
        let provider = Self.provider()
        ChartsURLProtocol.requestedPaths.removeAll()

        let tv = BangumiChartFilter(group: "分类", title: "TV", categoryID: 1, series: nil, tag: nil)
        _ = try await provider.chart(channel: .anime, filter: tv, page: 2)
        #expect(ChartsURLProtocol.requestedPaths == ["/p1/subjects?type=2&sort=rank&page=2&cat=1"])

        ChartsURLProtocol.requestedPaths.removeAll()
        let scifi = BangumiChartFilter(group: "类型", title: "科幻", categoryID: nil, series: nil, tag: "科幻")
        _ = try await provider.chart(channel: .anime, filter: scifi, page: 1)
        #expect(ChartsURLProtocol.requestedPaths == ["/p1/subjects?type=2&sort=rank&page=1&tags=%E7%A7%91%E5%B9%BB"])

        ChartsURLProtocol.requestedPaths.removeAll()
        let series = BangumiChartFilter(group: "系列", title: "系列", categoryID: nil, series: true, tag: nil)
        _ = try await provider.chart(channel: .book, filter: series, page: 1)
        #expect(ChartsURLProtocol.requestedPaths == ["/p1/subjects?type=1&sort=rank&page=1&series=true"])
    }

    @Test func discoversFiltersFromSidebar() async throws {
        let provider = Self.provider()
        ChartsURLProtocol.requestedPaths.removeAll()

        let filters = try await provider.filters(channel: .anime)

        #expect(ChartsURLProtocol.requestedPaths.last == "/anime/browser?sort=rank")
        let tv = try #require(filters.first { $0.title == "TV" })
        #expect(tv.group == "分类")
        #expect(tv.categoryID == 1)
        #expect(tv.tag == nil)
        // Tag filters are decoded wiki meta tags.
        let scifi = try #require(filters.first { $0.title == "科幻" })
        #expect(scifi.group == "类型")
        #expect(scifi.categoryID == nil)
        #expect(scifi.tag == "科幻")
        // Navigation aids and API-inexpressible groups are not charts.
        #expect(!filters.contains { $0.group == "拼音筛选" || $0.group == "进度" })
        #expect(!filters.contains { $0.title == "全部" })
        // The same alias resolves per channel: real's TV drama is 6001, not
        // anime's 1.
        let html = Self.sidebarHTML(channel: "real", links: [("分类", "tv", "电视剧")])
        let realFilters = BangumiChartsProvider.parseFilters(html: html, channel: .real)
        #expect(realFilters.first?.categoryID == 6001)
    }

    @Test func decodesEntities() {
        #expect(BangumiChartsProvider.decodeHTMLEntities("A &amp; B") == "A & B")
        #expect(BangumiChartsProvider.decodeHTMLEntities("&#25915;&#x6BBB;") == "攻殻")
        #expect(BangumiChartsProvider.decodeHTMLEntities("&amp;lt;") == "&lt;")
        #expect(BangumiChartsProvider.decodeHTMLEntities("no entities") == "no entities")
    }

    /// Opt-in because package tests should remain deterministic when offline.
    @Test func liveChartsSmokeTest() async throws {
        guard ProcessInfo.processInfo.environment["ANIMEGOD_LIVE_TESTS"] == "1" else { return }
        let provider = BangumiChartsProvider()

        let page = try await provider.chart(channel: .anime, page: 1)
        #expect(!page.entries.isEmpty)
        #expect(page.entries.first?.rank == 1)
        #expect(page.entries.allSatisfy { !$0.title.isEmpty })

        let filters = try await provider.filters(channel: .anime)
        let tv = try #require(filters.first { $0.title == "TV" })
        let tvChart = try await provider.chart(channel: .anime, filter: tv, page: 1)
        #expect(!tvChart.entries.isEmpty)
        #expect(tvChart.entries.allSatisfy { !$0.title.isEmpty })

        let games = try await provider.chart(channel: .game, page: 1)
        #expect(!games.entries.isEmpty)
        let gameFilters = try await provider.filters(channel: .game)
        #expect(gameFilters.contains { $0.title == "PC" && $0.tag == "PC" })
        #expect(gameFilters.contains { $0.title == "游戏" && $0.categoryID == 4001 })
    }

    private static func provider() -> BangumiChartsProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChartsURLProtocol.self]
        ChartsURLProtocol.requestedPaths.removeAll()
        return BangumiChartsProvider(
            session: URLSession(configuration: configuration),
            apiBaseURL: URL(string: "https://api.example.test")!,
            webBaseURL: URL(string: "https://web.example.test")!
        )
    }

    private static func sidebarHTML(channel: String, links: [(group: String, path: String, title: String)]) -> String {
        let groups = links.map { group, path, title in
            """
            <h2 class="subtitle">\(group)</h2>
            <ul class="grouped clearit">
                <li><a href="/\(channel)/browser/" class="l focus">全部</a></li>
                <li><a href="/\(channel)/browser/\(path)?sort=rank" class="l ">\(title)</a></li>
            </ul>
            """
        }.joined(separator: "\n")
        return "<html><body>\(groups)</body></html>"
    }
}

private final class ChartsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if let url = request.url {
            // .path decodes percent-escapes; tag filters must stay encoded
            // exactly as sent, so record the encoded form.
            let query = url.query.map { "?\($0)" } ?? ""
            Self.requestedPaths.append(url.path(percentEncoded: true) + query)
        }
        let payload: String
        if request.url?.path.hasSuffix("/subjects") == true {
            payload = Self.subjectsJSON
        } else {
            payload = Self.sidebarHTML
        }
        let data = Data(payload.utf8)
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    static let subjectsJSON = """
    {
      "data": [
        {
          "id": 326,
          "name": "攻殻機動隊 S.A.C. 2nd GIG",
          "nameCN": "攻壳机动队 S.A.C. 2nd GIG",
          "type": 2,
          "info": " 26话 / 2004年1月1日 / 神山健治 / 士郎正宗「攻殻機動隊」 ",
          "metaTags": ["科幻", "TV"],
          "rating": {"rank": 1, "count": [47, 9], "score": 9.16, "total": 10128},
          "locked": false,
          "nsfw": false,
          "images": {
            "large": "https://lain.bgm.tv/pic/cover/l/a6/66/326_D8wjw.jpg",
            "common": "https://lain.bgm.tv/r/400/pic/cover/l/a6/66/326_D8wjw.jpg"
          }
        },
        {
          "id": 876,
          "name": "CLANNAD 〜AFTER STORY〜",
          "nameCN": "",
          "type": 2,
          "info": "24话 / 2008年10月2日",
          "metaTags": ["TV"],
          "rating": {"rank": 2, "count": [163, 54], "score": 0, "total": 0},
          "locked": false,
          "nsfw": false,
          "images": {
            "common": "https://lain.bgm.tv/r/400/pic/cover/l/67/d1/876_dCfrd.jpg"
          }
        }
      ],
      "total": 372
    }
    """

    static let sidebarHTML = """
    <!DOCTYPE html><html><body>
    <div id="columnSubjectBrowserB" class="column">
        <div class="sideInner">
            <h2 class="subtitle">分类</h2>
            <ul class="grouped clearit">
                <li><a href="/anime/browser/" class="l focus">全部</a></li>
                <li><a href="/anime/browser/tv?sort=rank" class="l ">TV</a></li>
                <li><a href="/anime/browser/web?sort=rank" class="l ">WEB</a></li>
                <li><a href="/anime/browser/movie?sort=rank" class="l ">剧场版</a></li>
            </ul>
            <h2 class="subtitle">类型</h2>
            <ul class="grouped clearit">
                <li><a href="/anime/browser/?sort=rank" class="l focus">全部</a></li>
                <li><a href="/anime/browser/%E7%A7%91%E5%B9%BB?sort=rank" class="l ">科幻</a></li>
                <li><a href="/anime/browser/%E5%96%9C%E5%89%A7?sort=rank" class="l ">喜剧</a></li>
            </ul>
            <h2 class="subtitle">拼音筛选</h2>
            <ul class="grouped clearit">
                <li><a href="/anime/browser/?sort=rank&amp;orderby=a" class="l ">A</a></li>
            </ul>
            <h2 class="subtitle">进度</h2>
            <ul class="grouped clearit">
                <li><a href="/anime/browser/%E5%B7%B2%E5%AE%8C%E7%BB%93?sort=rank" class="l ">已完结</a></li>
            </ul>
        </div>
    </div>
    <span class="p_edge">(&nbsp;1&nbsp;/&nbsp;1286&nbsp;)</span>
    </body></html>
    """
}
