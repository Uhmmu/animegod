import Foundation
import Testing
@testable import AnimeGodCore

/// Both providers are parsed against responses captured from the real
/// services, trimmed but not reshaped. Hand-written JSON is what let the
/// AniList provider keep passing while the live schema moved underneath it.
@Suite(.serialized)
struct ConcertProviderTests {
    // MARK: - Captured responses

    /// `GET /database/search?catno=ANZX-10294&type=release`
    static let discogsSearchJSON = #"""
    {"results":[{"id":30770007,"title":"結束バンド* - 結束バンド LIVE-恒星-","year":"2023","country":"Japan","catno":"ANZX 10294","format":["Blu-ray","Blu-ray Audio","Limited Edition","Stereo","Multichannel"],"label":["Aniplex","Zepp Haneda","Hulic Hall Tokyo"],"genre":["Rock","Stage & Screen"],"style":["J-Rock","Anison"],"barcode":["4 534530 147127"],"cover_image":"https://i.discogs.com/IRG5P1lLD1AcTH0Q8zCZogGvVcI_WyLRuPFUj8UELI0/rs:fit/g:sm/q:90/h:808/w:600/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTMwNzcw/MDA3LTE3MTY1NjQ4/NDktNDY5NS5qcGVn.jpeg","uri":"/release/30770007-%E7%B5%90%E6%9D%9F%E3%83%90%E3%83%B3%E3%83%89-%E7%B5%90%E6%9D%9F%E3%83%90%E3%83%B3%E3%83%89-LIVE-%E6%81%92%E6%98%9F-"}]}
    """#

    /// `GET /releases/30770007`, tracks trimmed to the interesting ones.
    static let discogsReleaseJSON = #"""
    {"id":30770007,"title":"結束バンド LIVE-恒星-","artists":[{"name":"Kessoku Band","anv":"結束バンド","join":"","role":"","tracks":"","id":12283549,"resource_url":"https://api.discogs.com/artists/12283549","thumbnail_url":"https://i.discogs.com/BMjajOwTBf2TAm2Z-Oe_pSPqFjRvfpnK3AAEJf_rIdo/rs:fit/g:sm/q:90/h:337/w:600/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9BLTEyMjgz/NTQ5LTE2NzM1MzIx/MDMtNzM1OS5qcGVn.jpeg"}],"year":2023,"released":"2023-11-22","country":"Japan","labels":[{"name":"Aniplex","catno":"ANZX 10294","entity_type":"1","entity_type_name":"Label","id":51977,"resource_url":"https://api.discogs.com/labels/51977","thumbnail_url":"https://i.discogs.com/vsnLPoB0SLOLrdWTtxR2jV3Imc_LZZIJxZ5txhCW1jg/rs:fit/g:sm/q:90/h:175/w:600/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9MLTUxOTc3/LTEzOTYxOTcxMDkt/MTMyMi5qcGVn.jpeg"}],"formats":[{"name":"Blu-ray","qty":"3","descriptions":["Blu-ray Audio","Limited Edition","Stereo","Multichannel"]}],"genres":["Rock","Stage & Screen"],"styles":["J-Rock","Anison"],"identifiers":[{"type":"Barcode","value":"4 534530 147127"}],"notes":"DISC 1:\nKessoku Band LIVE-Fixed Star- 2023.05.21 [Sun] @Zepp Haneda (TOKYO)\n\nDISC 1 audio formats:\nLinear PCM STEREO (48kHz/24bit)\nDTS-HD Master Audio 5.1ch surround (48kHz/24bit)\nAudio commentary: Linear PCM STEREO (48kHz/24bit)\n\nDISC 2:\nThis is Bocchi The Rock! 2023.04.23 [Sun] @ Hulic Hall Tokyo\n\nDISC 3:\nMaking of -Fixed Star- / Road to Guitar Hero Extra Edition\n\nDISC 2-3 audio formats:\nLinear PCM STEREO (48KHz/24bit, some 16bit)\n\nEXTRA [Complete production limited edition bonus]:\n01 Official Photo Book [Total 24 pages]\n02 “Into the Light” lyric video illustrations on 2 types of postcards\n","uri":"https://www.discogs.com/release/30770007-結束バンド-結束バンド-LIVE-恒星-","images":[{"type":"secondary","uri":"https://i.discogs.com/KqmylG7lVP6HOL-g-M1CP9u_6PsM4CkV4KfRPkTZ7rI/rs:fit/g:sm/q:90/h:600/w:445/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTMwNzcw/MDA3LTE3MTY1NjQ4/NDktNDY5NS5qcGVn.jpeg","resource_url":"https://i.discogs.com/KqmylG7lVP6HOL-g-M1CP9u_6PsM4CkV4KfRPkTZ7rI/rs:fit/g:sm/q:90/h:600/w:445/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTMwNzcw/MDA3LTE3MTY1NjQ4/NDktNDY5NS5qcGVn.jpeg","uri150":"https://i.discogs.com/GDaGx1rDDBtpX6S0l72S5ti9572trYJ6wBHfO5fiOEc/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTMwNzcw/MDA3LTE3MTY1NjQ4/NDktNDY5NS5qcGVn.jpeg","width":445,"height":600}],"tracklist":[{"position":"1-01","type_":"track","title":"ひとりぼっち東京","duration":""},{"position":"1-02","type_":"track","title":"ギターと孤独と蒼い惑星","duration":""},{"position":"1-03","type_":"track","title":"Distortion!!","duration":""},{"position":"1-04","type_":"track","title":"ひみつ基地","duration":""},{"position":"1-05","type_":"track","title":"ひみつ基地","duration":""},{"position":"1-17","type_":"track","title":"オーディオコメンタリー","duration":""},{"position":"1-14","type_":"track","title":"[アンコール] 転がる岩、君に朝が降る","duration":""},{"position":"3-01","type_":"track","title":"Making of -恒星-","duration":""}]}
    """#

    /// `GET /release/295db787…?inc=recordings+artist-credits+labels+release-groups`
    static let musicBrainzReleaseJSON = #"""
    {"id":"295db787-13c3-4aae-8265-da1cfdd7a5dc","title":"結束バンドLIVE-恒星-","date":"2023-11-22","country":"JP","barcode":"4534530147127","artist-credit":[{"artist":{"disambiguation":"ぼっち・ざ・ろっく！","id":"c1b0fe0a-779d-43ed-b193-4370f0d0f88f","country":"JP","type-id":"e431f5f6-b5d2-343d-8b36-72607fffb74b","sort-name":"Kessoku Band","name":"結束バンド","type":"Group"},"name":"結束バンド","joinphrase":""}],"label-info":[{"catalog-number":"ANZX-10294","label":{"sort-name":"Aniplex","type-id":"b6285b2a-3514-3d43-80df-fcf528824ded","name":"Aniplex","type":"Imprint","id":"fa61217d-7501-4d3e-b7cd-04d9a3abe8fc","disambiguation":"","label-code":null}},{"catalog-number":"ANZX-10295","label":{"name":"Aniplex","type-id":"b6285b2a-3514-3d43-80df-fcf528824ded","sort-name":"Aniplex","type":"Imprint","label-code":null,"id":"fa61217d-7501-4d3e-b7cd-04d9a3abe8fc","disambiguation":""}},{"catalog-number":"ANZX-10296","label":{"type":"Imprint","type-id":"b6285b2a-3514-3d43-80df-fcf528824ded","sort-name":"Aniplex","name":"Aniplex","label-code":null,"id":"fa61217d-7501-4d3e-b7cd-04d9a3abe8fc","disambiguation":""}}],"release-group":{"primary-type":"Album","secondary-types":["Live"]},"media":[{"position":1,"format":"Blu-ray","title":"結束バンドLIVE-恒星-","track-count":16,"tracks":[{"position":1,"number":"1","title":"ひとりぼっち東京","length":233000},{"position":2,"number":"2","title":"ギターと孤独と蒼い惑星","length":239000},{"position":3,"number":"3","title":"ラブソングが歌えない","length":205000},{"position":4,"number":"4","title":"Distortion!!","length":215000}]},{"position":2,"format":"Blu-ray","title":"ぼっち・ざ・ろっく！です。","track-count":0,"tracks":[]},{"position":3,"format":"Blu-ray","title":"","track-count":2,"tracks":[{"position":1,"number":"","title":"Making of -恒星-","length":5886000},{"position":2,"number":"","title":"ギターヒーローへの道 番外編","length":3287000}]}]}
    """#

    /// `GET coverartarchive.org/release/295db787…`
    static let coverArtJSON = #"""
    {"images":[{"front":true,"image":"http://coverartarchive.org/release/295db787-13c3-4aae-8265-da1cfdd7a5dc/37826908346.jpg","thumbnails":{"1200":"http://coverartarchive.org/release/295db787-13c3-4aae-8265-da1cfdd7a5dc/37826908346-1200.jpg","250":"http://coverartarchive.org/release/295db787-13c3-4aae-8265-da1cfdd7a5dc/37826908346-250.jpg","500":"http://coverartarchive.org/release/295db787-13c3-4aae-8265-da1cfdd7a5dc/37826908346-500.jpg","large":"http://coverartarchive.org/release/295db787-13c3-4aae-8265-da1cfdd7a5dc/37826908346-500.jpg","small":"http://coverartarchive.org/release/295db787-13c3-4aae-8265-da1cfdd7a5dc/37826908346-250.jpg"}},{"front":false,"image":"http://coverartarchive.org/release/295db787-13c3-4aae-8265-da1cfdd7a5dc/37826909055.jpg","thumbnails":{"1200":"http://coverartarchive.org/release/295db787-13c3-4aae-8265-da1cfdd7a5dc/37826909055-1200.jpg","250":"http://coverartarchive.org/release/295db787-13c3-4aae-8265-da1cfdd7a5dc/37826909055-250.jpg","500":"http://coverartarchive.org/release/295db787-13c3-4aae-8265-da1cfdd7a5dc/37826909055-500.jpg","large":"http://coverartarchive.org/release/295db787-13c3-4aae-8265-da1cfdd7a5dc/37826909055-500.jpg","small":"http://coverartarchive.org/release/295db787-13c3-4aae-8265-da1cfdd7a5dc/37826909055-250.jpg"}}]}
    """#

    // MARK: - Discogs

    @Test func readsACatalogueNumberSearch() async throws {
        let provider = DiscogsConcertProvider(
            credentials: .init(consumerKey: "k", consumerSecret: "s"),
            session: ConcertStubURLProtocol.makeSession(),
            baseURL: URL(string: "https://discogs.example.test")!
        )
        ConcertStubURLProtocol.reset(responses: ["/database/search": Self.discogsSearchJSON])

        let number = try #require(ConcertCatalogNumber.first(in: "ANZX-10294"))
        let results = try await provider.releases(catalogNumber: number)
        let release = try #require(results.first)

        #expect(release.provider == .discogs)
        #expect(release.externalID == "30770007")
        // A search result's title is "artist* - release"; the two must not be
        // shown as one name.
        #expect(release.title == "結束バンド LIVE-恒星-")
        #expect(release.artistNames == ["結束バンド"])
        #expect(release.catalogNumbers == ["ANZX 10294"])
        #expect(release.coverImageURLs.first?.host() == "i.discogs.com")
        // The key has to reach the service; without it Discogs answers 200
        // with nothing at all.
        let sent = try #require(ConcertStubURLProtocol.lastHeaders?["Authorization"])
        #expect(sent == "Discogs key=k, secret=s")
    }

    @Test func readsAReleaseIntoDiscs() async throws {
        let provider = DiscogsConcertProvider(
            credentials: .init(consumerKey: "k", consumerSecret: "s"),
            session: ConcertStubURLProtocol.makeSession(),
            baseURL: URL(string: "https://discogs.example.test")!
        )
        ConcertStubURLProtocol.reset(responses: ["/releases/30770007": Self.discogsReleaseJSON])

        let release = try await provider.release(id: "30770007")

        #expect(release.title == "結束バンド LIVE-恒星-")
        // `anv` is how the disc credits the act; `name` is its romanisation,
        // and both are kept so either spelling matches.
        #expect(release.artistNames == ["結束バンド", "Kessoku Band"])
        #expect(release.releaseDate == "2023-11-22")
        #expect(release.labels == ["Aniplex"])
        #expect(release.barcode == "4 534530 147127")
        #expect(release.genres.contains("J-Rock"))

        // `1-01` and `3-01` are different discs, and the release is all
        // Blu-ray, so both inherit that format.
        #expect(release.discs.map(\.position) == [1, 3])
        #expect(release.discs.allSatisfy { $0.format == "Blu-ray" })
        #expect(release.videoDiscs.count == 2)

        let first = try #require(release.discs.first)
        #expect(first.tracks.first?.title == "ひとりぼっち東京")
        // The commentary is an alternative soundtrack and the making-of is
        // another programme: neither belongs on a timeline.
        #expect(first.tracks.first { $0.title == "オーディオコメンタリー" }?.kind == .commentary)
        #expect(release.discs.last?.tracks.first?.kind == .bonus)
        // `[アンコール]` comes off the title and comes back as a flag, so the
        // same song listed plainly elsewhere still matches.
        let encore = try #require(first.tracks.first { $0.isEncore })
        #expect(encore.title == "転がる岩、君に朝が降る")
    }

    /// Discogs publishes no track lengths for any concert Blu-ray measured,
    /// so the parser has to be fine with that rather than fail on it.
    @Test func survivesATrackListWithNoLengths() async throws {
        let provider = DiscogsConcertProvider(
            credentials: .init(consumerKey: "k", consumerSecret: "s"),
            session: ConcertStubURLProtocol.makeSession(),
            baseURL: URL(string: "https://discogs.example.test")!
        )
        ConcertStubURLProtocol.reset(responses: ["/releases/30770007": Self.discogsReleaseJSON])
        let release = try await provider.release(id: "30770007")
        #expect(release.discs.flatMap(\.tracks).allSatisfy { $0.duration == nil })
        #expect(release.totalSongDuration == nil)
    }

    @Test func refusesToLookAnythingUpWithoutAKey() async throws {
        let provider = DiscogsConcertProvider(
            credentials: .init(consumerKey: "", consumerSecret: ""),
            session: ConcertStubURLProtocol.makeSession(),
            baseURL: URL(string: "https://discogs.example.test")!
        )
        ConcertStubURLProtocol.reset(responses: [:])
        #expect(!provider.isConfigured)
        await #expect(throws: MetadataProviderError.self) {
            _ = try await provider.releases(barcode: "4534530147127")
        }
    }

    // MARK: - MusicBrainz

    @Test func readsTheSetlistAndItsLengths() async throws {
        let provider = MusicBrainzConcertProvider(
            session: ConcertStubURLProtocol.makeSession(),
            baseURL: URL(string: "https://mb.example.test/ws/2")!,
            coverArtBaseURL: URL(string: "https://caa.example.test")!
        )
        ConcertStubURLProtocol.reset(responses: [
            "/ws/2/release/295db787-13c3-4aae-8265-da1cfdd7a5dc": Self.musicBrainzReleaseJSON,
            "/release/295db787-13c3-4aae-8265-da1cfdd7a5dc": Self.coverArtJSON
        ])

        let release = try await provider.release(id: "295db787-13c3-4aae-8265-da1cfdd7a5dc")

        #expect(release.provider == .musicBrainz)
        // The two services file the same act under different names —
        // MusicBrainz under 結束バンド, Discogs under `Kessoku Band` with 結束バンド
        // as the credited variation — so neither spelling can be assumed.
        #expect(release.artistNames == ["結束バンド"])
        #expect(release.catalogNumbers.contains("ANZX-10294"))
        #expect(release.barcode == "4534530147127")

        // A medium's own title is what names the concert — this is where the
        // live, the bonus event and the making-of come apart.
        #expect(release.discs.map(\.title) == ["結束バンドLIVE-恒星-", "ぼっち・ざ・ろっく！です。", nil])
        let live = try #require(release.discs.first)
        #expect(live.format == "Blu-ray")
        #expect(live.tracks.map(\.title).prefix(2) == ["ひとりぼっち東京", "ギターと孤独と蒼い惑星"])
        // Lengths come in milliseconds and are the whole reason this provider
        // leads on the setlist.
        #expect(live.tracks.first?.duration == 233)
        #expect(live.tracks.map(\.duration) == [233, 239, 205, 215])
        #expect(release.discs.last?.tracks.first?.kind == .bonus)
    }

    /// The Cover Art Archive publishes `http://` links, which App Transport
    /// Security refuses outright, and prefers an original that runs to
    /// megabytes where a poster is drawn at 500px.
    @Test func takesTheFrontCoverOverTLS() async throws {
        let provider = MusicBrainzConcertProvider(
            session: ConcertStubURLProtocol.makeSession(),
            baseURL: URL(string: "https://mb.example.test/ws/2")!,
            coverArtBaseURL: URL(string: "https://caa.example.test")!
        )
        ConcertStubURLProtocol.reset(responses: [
            "/release/295db787-13c3-4aae-8265-da1cfdd7a5dc": Self.coverArtJSON
        ])
        let urls = try await provider.coverArtURLs(releaseID: "295db787-13c3-4aae-8265-da1cfdd7a5dc")
        let front = try #require(urls.first)
        #expect(front.scheme == "https")
        #expect(front.absoluteString.hasSuffix("-500.jpg"))
    }

    /// Two of six real concert Blu-rays had no cover art at all. Losing the
    /// cover must not lose the setlist, so a 404 is "no images".
    @Test func treatsMissingCoverArtAsNoImages() async throws {
        let provider = MusicBrainzConcertProvider(
            session: ConcertStubURLProtocol.makeSession(),
            baseURL: URL(string: "https://mb.example.test/ws/2")!,
            coverArtBaseURL: URL(string: "https://caa.example.test")!
        )
        ConcertStubURLProtocol.reset(responses: [:], statuses: ["/release/none": 404])
        #expect(try await provider.coverArtURLs(releaseID: "none").isEmpty)
    }

    /// A release whose cover is missing still has to come back whole.
    @Test func returnsAReleaseWhoseCoverIsMissing() async throws {
        let provider = MusicBrainzConcertProvider(
            session: ConcertStubURLProtocol.makeSession(),
            baseURL: URL(string: "https://mb.example.test/ws/2")!,
            coverArtBaseURL: URL(string: "https://caa.example.test")!
        )
        ConcertStubURLProtocol.reset(
            responses: ["/ws/2/release/295db787-13c3-4aae-8265-da1cfdd7a5dc": Self.musicBrainzReleaseJSON],
            statuses: ["/release/295db787-13c3-4aae-8265-da1cfdd7a5dc": 404]
        )
        let release = try await provider.release(id: "295db787-13c3-4aae-8265-da1cfdd7a5dc")
        #expect(release.coverImageURLs.isEmpty)
        #expect(release.discs.first?.tracks.count == 4)
    }

    /// 503 from MusicBrainz is the rate limiter, not an outage — it is what
    /// one request too soon looks like — so it is retried rather than
    /// reported as the service being down.
    @Test func retriesTheRateLimiter() async throws {
        let provider = MusicBrainzConcertProvider(
            session: ConcertStubURLProtocol.makeSession(),
            baseURL: URL(string: "https://mb.example.test/ws/2")!,
            coverArtBaseURL: URL(string: "https://caa.example.test")!
        )
        ConcertStubURLProtocol.reset(
            responses: ["/ws/2/release/295db787-13c3-4aae-8265-da1cfdd7a5dc": Self.musicBrainzReleaseJSON],
            statuses: [:],
            failFirst: ["/ws/2/release/295db787-13c3-4aae-8265-da1cfdd7a5dc": 503]
        )
        let release = try await provider.release(id: "295db787-13c3-4aae-8265-da1cfdd7a5dc")
        #expect(release.title == "結束バンドLIVE-恒星-")
        #expect(ConcertStubURLProtocol.requestCount(forPath: "/ws/2/release/295db787-13c3-4aae-8265-da1cfdd7a5dc") == 2)
    }

    // MARK: - The whole thing, against the real services

    /// Opt-in: package tests stay deterministic offline, and these are the
    /// ones that would have caught AniList's schema moving.
    @Test func liveContractSmokeTest() async throws {
        guard ProcessInfo.processInfo.environment["ANIMEGOD_LIVE_TESTS"] == "1" else { return }

        let musicBrainz = MusicBrainzConcertProvider()
        let number = try #require(ConcertCatalogNumber.first(in: "ANZX-10294"))
        let found = try await musicBrainz.releases(catalogNumber: number)
        #expect(found.count == 1, "a catalogue number is an exact key")
        let release = try await musicBrainz.release(id: try #require(found.first).externalID)
        let live = try #require(release.videoDiscs.first)
        #expect(live.songs.count == 16)
        #expect(live.songs.allSatisfy { $0.duration != nil })
        #expect(abs((release.totalSongDuration ?? 0) - 4239) < 2)

        guard let key = ProcessInfo.processInfo.environment["ANIMEGOD_DISCOGS_KEY"],
              let secret = ProcessInfo.processInfo.environment["ANIMEGOD_DISCOGS_SECRET"]
        else { return }
        let discogs = DiscogsConcertProvider(credentials: .init(consumerKey: key, consumerSecret: secret))
        let hits = try await discogs.releases(catalogNumber: number)
        #expect(hits.count == 1)
        let full = try await discogs.release(id: try #require(hits.first).externalID)
        #expect(!full.coverImageURLs.isEmpty)
        #expect(full.videoDiscs.count >= 1)
    }
}

/// Serves captured responses by path.
final class ConcertStubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var responses: [String: String] = [:]
    nonisolated(unsafe) private static var statuses: [String: Int] = [:]
    nonisolated(unsafe) private static var failFirst: [String: Int] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) static var lastHeaders: [String: String]?
    private static let lock = NSLock()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConcertStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset(
        responses: [String: String],
        statuses: [String: Int] = [:],
        failFirst: [String: Int] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        Self.responses = responses
        Self.statuses = statuses
        Self.failFirst = failFirst
        Self.counts = [:]
        Self.lastHeaders = nil
    }

    static func requestCount(forPath path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[path] ?? 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.lastHeaders = request.allHTTPHeaderFields
        Self.counts[path, default: 0] += 1
        let attempt = Self.counts[path] ?? 1
        let transient = attempt == 1 ? Self.failFirst[path] : nil
        let status = transient ?? Self.statuses[path] ?? (Self.responses[path] == nil ? 404 : 200)
        let body = status == 200 ? Self.responses[path] : nil
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
