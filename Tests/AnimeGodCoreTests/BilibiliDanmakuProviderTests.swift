import Foundation
import Testing
@testable import AnimeGodCore

/// Intercepts Bilibili traffic. A dedicated protocol class, not the shared
/// dandanplay one: suites run in parallel with each other, so two suites
/// sharing one static handler would answer each other's requests.
final class BilibiliMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequestHeaders: [String: String]?
    /// Every URL requested, in order — the bootstrap, search, episode lookup
    /// and segment sweep only make sense as a sequence.
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    static func reset() {
        handler = nil
        lastRequestHeaders = nil
        requestedURLs = []
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BilibiliMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestHeaders = request.allHTTPHeaderFields
        if let url = request.url { Self.requestedURLs.append(url) }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// End-to-end provider behavior against a scripted Bilibili, so the whole
/// path — bootstrap, WBI-signed search, episode resolution, the segment
/// sweep and conversion — is exercised without touching the live API.
@Suite(.serialized)
struct BilibiliDanmakuProviderTests {
    // MARK: - Scripted server

    /// Answers the endpoints the provider uses. `segments` maps a cid to its
    /// per-segment comment texts.
    private struct FakeBilibili {
        var searchHits: [[String: Any]] = []
        var seasons: [Int64: [String: Any]] = [:]
        var videos: [String: [String: Any]] = [:]
        var segments: [Int64: [[String]]] = [:]
        var segmentStatus: [String: Any]?

        func respond(to request: URLRequest) throws -> (HTTPURLResponse, Data) {
            let url = try #require(request.url)
            let path = url.path
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

            switch path {
            case "/x/frontend/finger/spi":
                return (httpResponse(url), json(["code": 0, "data": ["b_3": "FAKE-BUVID3", "b_4": "FAKE-BUVID4"]]))
            case "/x/web-interface/nav":
                return (httpResponse(url), json([
                    "code": -101,
                    "data": ["wbi_img": [
                        "img_url": "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
                        "sub_url": "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"
                    ]]
                ]))
            case "/x/web-interface/wbi/search/all/v2":
                return (httpResponse(url), json([
                    "code": 0,
                    "data": ["result": [["result_type": "media_bangumi", "data": searchHits]]]
                ]))
            case "/pgc/view/web/season":
                let id = Int64(value("season_id") ?? "") ?? 0
                guard let season = seasons[id] else { return (httpResponse(url), json(["code": -404, "message": "没有找到"])) }
                return (httpResponse(url), json(["code": 0, "result": season]))
            case "/x/web-interface/view":
                let key = value("bvid") ?? value("aid") ?? ""
                guard let video = videos[key] else { return (httpResponse(url), json(["code": -404, "message": "没有找到"])) }
                return (httpResponse(url), json(["code": 0, "data": video]))
            case "/x/v2/dm/web/seg.so", "/x/v2/dm/wbi/web/seg.so":
                if let segmentStatus { return (httpResponse(url), json(segmentStatus)) }
                let cid = Int64(value("oid") ?? "") ?? 0
                let index = Int(value("segment_index") ?? "1") ?? 1
                guard let pools = segments[cid], index <= pools.count else {
                    // Past the end of the pool Bilibili answers with an
                    // error envelope, not an empty protobuf message.
                    return (httpResponse(url), json(["code": -352, "message": "no such segment"]))
                }
                let elements = pools[index - 1].enumerated().map { offset, text in
                    ProtobufWireWriter.element(
                        progress: Int64((index - 1) * 360_000 + offset * 1_000),
                        mode: 1,
                        content: text,
                        idStr: "\(cid)-\(index)-\(offset)"
                    )
                }
                return (httpResponse(url), ProtobufWireWriter.segment(elements))
            default:
                return (httpResponse(url, status: 404), Data())
            }
        }

        private func json(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
    }

    private func install(_ server: FakeBilibili) {
        BilibiliMockURLProtocol.reset()
        BilibiliMockURLProtocol.handler = { try server.respond(to: $0) }
    }

    private func makeProvider(
        endpoint: BilibiliSession.SegmentEndpoint = .automatic,
        configuration: BilibiliDanmakuProvider.Configuration = .init()
    ) -> BilibiliDanmakuProvider {
        var sessionConfiguration = BilibiliSession.Configuration()
        sessionConfiguration.segmentEndpoint = endpoint
        return BilibiliDanmakuProvider(
            session: BilibiliSession(
                configuration: sessionConfiguration,
                urlSession: BilibiliMockURLProtocol.makeSession()
            ),
            configuration: configuration
        )
    }

    /// A licensed season of `episodes` 24-minute episodes.
    private func season(id: Int64, title: String, episodes: Int) -> [String: Any] {
        [
            "season_id": id,
            "title": title,
            "type_name": "番剧",
            "episodes": (1...episodes).map { number in
                [
                    "id": 10_000 + id * 100 + Int64(number),
                    "aid": 900_000 + Int64(number),
                    "bvid": "BV1bangdream\(number)",
                    "cid": 500_000 + Int64(number),
                    "title": "\(number)",
                    "long_title": "第\(number)话",
                    "duration": 1_440_000
                ] as [String: Any]
            }
        ]
    }

    // MARK: - The headline scenario

    @Test func identifiesAndFetchesBilibiliDanmakuForALocalEpisode() async throws {
        // The exact case the feature exists for: dandanplay has nothing, so
        // "BanG Dream! YUME∞MITA - 01.mkv" has to reach Bilibili by title
        // and episode number alone.
        var server = FakeBilibili()
        server.searchHits = [
            ["season_id": 55, "media_id": 55, "title": "BanG Dream! Ave Mujica", "season_type_name": "番剧", "ep_size": 13],
            ["season_id": 42, "media_id": 42, "title": "BanG Dream! <em>YUME∞MITA</em>", "season_type_name": "番剧", "ep_size": 12]
        ]
        server.seasons = [
            42: season(id: 42, title: "BanG Dream! YUME∞MITA", episodes: 12),
            55: season(id: 55, title: "BanG Dream! Ave Mujica", episodes: 13)
        ]
        // Episode 1's own pool: four segments for a 24-minute episode.
        server.segments = [500_001: [["第一段"], ["第二段"], ["第三段"], ["第四段"]]]
        install(server)

        let provider = makeProvider()
        let result = try await provider.match(
            fileName: "BanG Dream! YUME∞MITA - 01.mkv",
            fileHash: nil,
            fileSize: 1_400_000_000,
            videoDuration: 1_440
        )

        #expect(result.isMatched)
        let best = try #require(result.best)
        #expect(best.animeTitle == "BanG Dream! YUME∞MITA")
        // The episode id handed to the player is the cid — the pool id.
        #expect(best.episodeID == 500_001)

        let context = try #require(BilibiliDanmakuContext.decode(best.providerContext))
        #expect(context.cid == 500_001)
        #expect(context.aid == 900_001)

        let comments = try await provider.fetchComments(
            episodeID: best.episodeID,
            context: DanmakuFetchContext(providerContext: best.providerContext, mediaDuration: 1_440)
        )
        #expect(comments.map(\.text) == ["第一段", "第二段", "第三段", "第四段"])
        #expect(comments.allSatisfy { $0.source == "bilibili" })
        // Segment n starts at minute 6n, so the times span the episode.
        #expect(comments.map(\.time) == [0, 360, 720, 1_080])
    }

    // MARK: - Transport behavior

    @Test func bootstrapsADeviceCookieAndSignsSearchOnce() async throws {
        var server = FakeBilibili()
        server.searchHits = [["season_id": 42, "media_id": 42, "title": "某番", "season_type_name": "番剧"]]
        server.seasons = [42: season(id: 42, title: "某番", episodes: 12)]
        install(server)

        _ = try await makeProvider().searchAnime(query: "某番")

        let paths = BilibiliMockURLProtocol.requestedURLs.map(\.path)
        // The device identity and the WBI keys are fetched before search.
        #expect(paths.prefix(3) == ["/x/frontend/finger/spi", "/x/web-interface/nav", "/x/web-interface/wbi/search/all/v2"])
        let search = try #require(BilibiliMockURLProtocol.requestedURLs.first { $0.path.hasSuffix("search/all/v2") })
        let query = try #require(search.query)
        #expect(query.contains("w_rid="))
        #expect(query.contains("wts="))
        // The anonymous cookie acquired during bootstrap is sent onwards.
        #expect(BilibiliMockURLProtocol.lastRequestHeaders?["Cookie"]?.contains("buvid3=FAKE-BUVID3") == true)
    }

    @Test func stopsTheSweepWhenThePoolEndsEarly() async throws {
        var server = FakeBilibili()
        // The local file claims 24 minutes but the pool only holds two
        // segments; the sweep must stop rather than ask for four.
        server.segments = [777: [["a"], ["b"]]]
        install(server)

        let comments = try await makeProvider().fetchComments(
            episodeID: 777,
            context: DanmakuFetchContext(providerContext: BilibiliDanmakuContext(cid: 777, aid: 5).encoded(), mediaDuration: 1_440)
        )
        #expect(comments.map(\.text) == ["a", "b"])

        let segmentRequests = BilibiliMockURLProtocol.requestedURLs.filter { $0.path.hasSuffix("seg.so") }
        #expect(segmentRequests.count == 3)
        // aid rides along as pid on every segment request.
        #expect(segmentRequests.allSatisfy { $0.query?.contains("pid=5") == true })
    }

    @Test func deduplicatesCommentsRepeatedAcrossSegmentBoundaries() async throws {
        var server = FakeBilibili()
        server.segments = [777: [["shared"], ["shared"]]]
        install(server)

        // Both segments emit the same idStr for offset 0 only if the cid and
        // index match, so craft the overlap through identical indices.
        let comments = try await makeProvider().fetchComments(
            episodeID: 777,
            context: DanmakuFetchContext(providerContext: BilibiliDanmakuContext(cid: 777).encoded(), mediaDuration: 720)
        )
        // Distinct ids, so both are kept — the dedup guards against the
        // server repeating one comment, not against equal text.
        #expect(comments.count == 2)
        #expect(Set(comments.map(\.id)).count == 2)
    }

    @Test func fallsBackToTheWBIEndpointWhenThePlainOneIsRejected() async throws {
        // Risk control on the plain path must not cost the viewer danmaku:
        // the web player's signed endpoint is the supported replacement.
        BilibiliMockURLProtocol.reset()
        var server = FakeBilibili()
        server.segments = [777: [["signed"]]]
        let scripted = server
        BilibiliMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/x/v2/dm/web/seg.so" {
                return (httpResponse(url, status: 412), Data())
            }
            return try scripted.respond(to: request)
        }

        let comments = try await makeProvider(endpoint: .automatic).fetchComments(
            episodeID: 777,
            context: DanmakuFetchContext(providerContext: BilibiliDanmakuContext(cid: 777).encoded(), mediaDuration: 300)
        )
        #expect(comments.map(\.text) == ["signed"])
        let paths = BilibiliMockURLProtocol.requestedURLs.map(\.path)
        #expect(paths.contains("/x/v2/dm/wbi/web/seg.so"))
    }

    @Test func honorsAnExplicitEndpointChoice() async throws {
        var server = FakeBilibili()
        server.segments = [777: [["only"]]]
        install(server)

        _ = try await makeProvider(endpoint: .wbi).fetchComments(
            episodeID: 777,
            context: DanmakuFetchContext(providerContext: BilibiliDanmakuContext(cid: 777).encoded(), mediaDuration: 300)
        )
        let paths = BilibiliMockURLProtocol.requestedURLs.map(\.path)
        #expect(paths.contains("/x/v2/dm/wbi/web/seg.so"))
        #expect(!paths.contains("/x/v2/dm/web/seg.so"))
    }

    // MARK: - Degraded states

    @Test func reportsRegionLockAndLoginWithoutBreakingThePipeline() async throws {
        var server = FakeBilibili()
        server.segmentStatus = ["code": -10403, "message": "抱歉您所在地区不可观看"]
        install(server)

        await #expect(throws: DanmakuProviderError.regionLocked("抱歉您所在地区不可观看")) {
            try await makeProvider().fetchComments(
                episodeID: 1,
                context: DanmakuFetchContext(providerContext: BilibiliDanmakuContext(cid: 1).encoded(), mediaDuration: 300)
            )
        }

        server.segmentStatus = ["code": -101, "message": "账号未登录"]
        install(server)
        await #expect(throws: DanmakuProviderError.requiresLogin("账号未登录")) {
            try await makeProvider().fetchComments(
                episodeID: 1,
                context: DanmakuFetchContext(providerContext: BilibiliDanmakuContext(cid: 1).encoded(), mediaDuration: 300)
            )
        }
    }

    @Test func anUnrelatedResultIsDiscardedRatherThanOffered() async throws {
        // Search returns noise for almost every query. A result with no
        // title relationship is dropped here; the match sheet's own search
        // is where the user goes when identification finds nothing.
        var server = FakeBilibili()
        server.searchHits = [["season_id": 9, "media_id": 9, "title": "完全不相干的作品", "season_type_name": "番剧"]]
        server.seasons = [9: season(id: 9, title: "完全不相干的作品", episodes: 12)]
        install(server)

        let result = try await makeProvider().match(
            fileName: "BanG Dream! YUME∞MITA - 01.mkv", fileHash: nil, fileSize: nil, videoDuration: 1_440
        )
        #expect(!result.isMatched)
        #expect(result.candidates.isEmpty)
    }

    @Test func aRelatedButDifferentSeasonIsOfferedNeverBound() async throws {
        // A sibling season shares most of its title, so it survives ranking
        // — but binding it would put another show's comments on the video.
        var server = FakeBilibili()
        server.searchHits = [["season_id": 55, "media_id": 55, "title": "BanG Dream! Ave Mujica", "season_type_name": "番剧", "ep_size": 13]]
        server.seasons = [55: season(id: 55, title: "BanG Dream! Ave Mujica", episodes: 13)]
        install(server)

        let result = try await makeProvider().match(
            fileName: "BanG Dream! YUME∞MITA - 01.mkv", fileHash: nil, fileSize: nil, videoDuration: 1_440
        )
        #expect(!result.isMatched)
        #expect(!result.candidates.isEmpty)
        // …and the session will not bind it, because Bilibili's ambiguity
        // means a different work rather than a second listing of one.
        #expect(!makeProvider().bindsAmbiguousMatches)
    }

    @Test func emptySearchResultsAreNotAnError() async throws {
        install(FakeBilibili())
        let result = try await makeProvider().match(
            fileName: "Something Unreleased - 01.mkv", fileHash: nil, fileSize: nil, videoDuration: 1_440
        )
        #expect(!result.isMatched)
        #expect(result.candidates.isEmpty)
    }

    @Test func searchResultsCarryTheProviderAndPerEpisodeContext() async throws {
        var server = FakeBilibili()
        server.searchHits = [["season_id": 42, "media_id": 42, "title": "某番", "season_type_name": "番剧"]]
        server.seasons = [42: season(id: 42, title: "某番", episodes: 3)]
        install(server)

        let results = try await makeProvider().searchAnime(query: "某番")
        let anime = try #require(results.first)
        #expect(anime.providerID == "bilibili")
        #expect(anime.episodes.count == 3)
        // Every episode carries its own cid and the state needed to fetch it.
        #expect(anime.episodes.map(\.episodeID) == [500_001, 500_002, 500_003])
        let context = try #require(BilibiliDanmakuContext.decode(anime.episodes[1].providerContext))
        #expect(context.cid == 500_002)
        #expect(context.seasonID == 42)
    }

    @Test func multiPartSubmissionsExposeEveryPartsOwnPool() async throws {
        var server = FakeBilibili()
        BilibiliMockURLProtocol.reset()
        server.videos = ["BV1multi": [
            "aid": 777, "bvid": "BV1multi", "title": "某番 合集", "tname": "动画", "duration": 4_320,
            "pages": [
                ["cid": 8_001, "page": 1, "part": "第1话", "duration": 1_440],
                ["cid": 8_002, "page": 2, "part": "第2话", "duration": 1_440],
                ["cid": 8_003, "page": 3, "part": "第3话", "duration": 1_440]
            ]
        ]]
        let scripted = server
        BilibiliMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/x/web-interface/wbi/search/all/v2" {
                return (httpResponse(url), try #require(try? JSONSerialization.data(withJSONObject: [
                    "code": 0,
                    "data": ["result": [["result_type": "video", "data": [
                        ["aid": 777, "bvid": "BV1multi", "title": "某番 合集", "typename": "动画", "duration": "1:12:00", "author": "up"]
                    ]]]]
                ])))
            }
            return try scripted.respond(to: request)
        }

        let results = try await makeProvider().searchAnime(query: "某番 合集")
        let anime = try #require(results.first)
        #expect(anime.episodes.map(\.episodeID) == [8_001, 8_002, 8_003])
    }
}
