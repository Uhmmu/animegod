import Foundation
import Testing

@testable import AnimeGodCore

/// The general indexes, ported from magnet-crawler. Every fixture below is a
/// real response to a real query, trimmed to the fields that are read — which
/// is how two of the five turned out to need different parsing from the
/// engines they came from.
struct AggregatorTorrentProviderTests {
    static let knabenJSON = #"""
    {"hits":[{"hash":"351bb9d718c7bdc1ea96ee3a8e95688ae7caa6af","title":"BanG Dream! MyGO!!!!! LIVE ZEPP TOUR 2024 (Zepp Nagoya) 「Wandering Desire」 (BD 1080p x264 8bit FLAC).mkv","magnetUrl":"magnet:?xt=urn:btih:351bb9d718c7bdc1ea96ee3a8e95688ae7caa6af&dn=BanG%20Dream%21%20MyGO%21%21%21%21%21%20LIVE%20ZEPP%20TOUR%202024%20%28Zepp%20Nagoya%29%20%E3%80%8CWandering%20Desire%E3%80%8D%20%28BD%201080p%20x264%208bit%20FLAC%29.mkv&tr=http%3A%2F%2Fnyaa.tracker.wf%3A7777%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fexodus.desync.com%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce","seeders":3,"peers":0,"bytes":4724464025,"date":"2024-12-23T09:57:00+00:00","category":"TV","cachedOrigin":"Nyaa.si","details":"https://nyaa.iss.ink/view/1914663"}]}
    """#

    static let torrentsCsvJSON = #"""
    {"torrents":[{"infohash":"083aa81a2030c8a1062b0fc28e23cef093c6ad48","name":"[Okay-Subs] BanG Dream! It's MyGO!!!!! (BD 1080p)","size_bytes":16224892063,"seeders":134,"leechers":9,"created_unix":1743519657},{"infohash":"55118aa1dbf75eebad500ec2ddd6a6de06e8f4d0","name":"[Nekomoe kissaten&VCB-Studio] BanG Dream! It’s MyGO!!!!! [Ma10p_1080p]","size_bytes":15114958357,"seeders":50,"leechers":14,"created_unix":1748758404}]}
    """#

    static let theRarbgJSON = #"""
    {"results":[{"h":"ABB2765402EA93A5074F87DF6A1D753A2DBC65B5","n":"[260718~19] MyGO!!!!! 9th LIVE「Tsunagime no Mukouni」[WEB-DL]","s":10844792422,"se":62,"le":161,"a":1784527589,"c":"TV"}]}
    """#

    static let apiBayJSON = #"""
    [{"id":"69913753","name":"BanG Dream Its MyGO S01E01 720p WEB H264-SKYANiME","info_hash":"7908E07F20C4D850811E5714F6EF298847AD20E2","seeders":"1","leechers":"1","size":"738092646","added":"1688064610","category":"208"}]
    """#

    /// One card of the real search page, from its swarm stats through the
    /// magnet link. Note `xt&#x3D;` and `&amp;dn&#x3D;`: the page escapes its
    /// own magnets, which is why a scan for the literal `magnet:?xt=urn:btih:`
    /// came back empty from a page holding forty of them.
    static let bitSearchHTML = #"""
    xt-gray-600 mb-3">
    <span class="inline-flex items-center space-x-1">
    <i class="fas fa-video text-blue-500"></i>
    <span>Other/Video</span>
    </span>
    <span class="inline-flex items-center space-x-1">
    <i class="fas fa-download"></i>
    <span>327.55 MB</span>
    </span>
    <span class="inline-flex items-center space-x-1">
    <i class="fas fa-calendar"></i>
    <span>8/24/2023</span>
    </span>
    </div>
    <!-- Swarm Stats -->
    <div class="flex flex-wrap items-center gap-4 text-sm">
    <span class="inline-flex items-center space-x-1 text-green-600">
    <i class="fas fa-arrow-up"></i>
    <span class="font-medium">405</span>
    <span>seeders</span>
    </span>
    <span class="inline-flex items-center space-x-1 text-red-600">
    <i class="fas fa-arrow-down"></i>
    <span class="font-medium">288</span>
    <span>leechers</span>
    </span>
    <span class="inline-flex items-center space-x-1 text-blue-600">
    <i class="fas fa-download"></i>
    <span class="font-medium">6867</span>
    <span>downloads</span>
    </span>
    </div>
    </div>
    <!-- Download Links -->
    <div class="hidden sm:flex flex-col space-y-2 ml-6">
    <a href="/download/torrent/1C5D1D2DA93CD2400406F4CB1D79980BDD4B0748?title=[ANi] BanG Dream! It&#x27;s MyGO!!!!! - 11 [1080P][Baha][WEB-DL][AAC AVC][CHT].mp4" 
    class="inline-flex items-center justify-center px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-md hover:bg-blue-700 transition duration-150 ease-in-out">
    <i class="fas fa-download mr-2"></i>
    Torrent
    </a>
    <a href="magnet:?xt&#x3D;urn:btih:1C5D1D2DA93CD2400406F4CB1D79980BDD4B0748&amp;dn&#x3D;%5BBitsearch.to%5D%20%5BANi%5D%20BanG%20Dream!%20It&#x27;s%20MyGO!!!!!%20-%2011%20%5B1080P%5D%5BBaha%5D%5BWEB-DL%5D%5BAAC%20AVC%5D%5BCHT%5D.mp4&amp;tr&#x3D;udp%3A%2F%2Ftracker2.dler.com%3A80%2Fannounce&amp;tr&#x3D;udp%3A%2F%2Ftracker.moeking.me%3A6969%2Fannounce&amp;tr&#x3D;udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce&amp;tr&#x3D;udp%3A%2F%2Ftracker.leech.ie%3A1337%2Fannounce&amp;tr&#x3D;udp%3A%2F%2Fwww.torrent.eu.org%3A451%2Fannounce&amp;tr&#x3D;udp%3A%2F%2Ftracker.bitsearch.to%3A1337%2Fannounce
    """#

    @Test func readsKnaben() throws {
        let found = try KnabenTorrentProvider.parse(Data(Self.knabenJSON.utf8))
        let first = try #require(found.first)
        #expect(first.source == .knaben)
        #expect(first.title.contains("ZEPP TOUR"))
        #expect(first.infoHash.hex == "351bb9d718c7bdc1ea96ee3a8e95688ae7caa6af")
        #expect(first.size == 4_724_464_025)
        #expect(first.seeders == 3)
        // `peers` is the leecher count, not the swarm size.
        #expect(first.leechers == 0)
        // Which tracker the aggregator cached it from — one hit can stand for
        // several of them.
        #expect(first.team == "Nyaa.si")
        #expect(first.pageURL?.host() == "nyaa.iss.ink")
        // A `TV` category is not `.other`: `.other` is hidden by the default
        // filter, and a result nobody can see is a source nobody added.
        #expect(first.category == .raw)
        let published = try #require(first.publishedAt)
        #expect(abs(published.timeIntervalSince1970 - 1_734_947_820) < 120)
    }

    @Test func readsTorrentsCsv() throws {
        let found = try TorrentsCsvTorrentProvider.parse(Data(Self.torrentsCsvJSON.utf8))
        #expect(found.count == 2)
        let first = try #require(found.first)
        #expect(first.source == .torrentsCsv)
        #expect(first.infoHash.hex == "083aa81a2030c8a1062b0fc28e23cef093c6ad48")
        #expect(first.size == 16_224_892_063)
        #expect(first.sizeIsExact)
        #expect(first.seeders == 134)
        #expect(first.leechers == 9)
    }

    /// The row that proves the point: a MyGO live none of the anime indexes in
    /// this app had, with 62 seeders.
    @Test func readsTheRarbg() throws {
        let found = try TheRarbgTorrentProvider.parse(Data(Self.theRarbgJSON.utf8))
        let first = try #require(found.first)
        #expect(first.source == .theRarbg)
        #expect(first.title.contains("9th LIVE"))
        // The index abbreviates every field: `h`, `n`, `s`, `se`, `le`, `a`.
        #expect(first.infoHash.hex == "abb2765402ea93a5074f87df6a1d753a2dbc65b5")
        #expect(first.size == 10_844_792_422)
        #expect(first.seeders == 62)
        #expect(first.leechers == 161)
    }

    @Test func readsApiBay() throws {
        let found = try ApiBayTorrentProvider.parse(Data(Self.apiBayJSON.utf8))
        let first = try #require(found.first)
        #expect(first.source == .apiBay)
        #expect(first.infoHash.hex == "7908e07f20c4d850811e5714f6ef298847ad20e2")
        // Every count arrives as a string.
        #expect(first.seeders == 1)
        #expect(first.size == 738_092_646)
        #expect(first.torrentURL?.absoluteString.contains("t.php?id=69913753") == true)
    }

    /// "No results" is a single row with id `0`, and reading it as a listing
    /// gives every empty search one torrent called *No results returned*.
    @Test func apiBayEmptyIsEmpty() throws {
        let sentinel = #"[{"id":"0","name":"No results returned","info_hash":"0000000000000000000000000000000000000000","leechers":"0","seeders":"0","size":"0","added":"0","category":"0"}]"#
        #expect(try ApiBayTorrentProvider.parse(Data(sentinel.utf8)).isEmpty)
    }

    @Test func readsBitSearchThroughItsOwnEscaping() throws {
        let found = try BitSearchTorrentProvider.parse(Data(Self.bitSearchHTML.utf8))
        let first = try #require(found.first)
        #expect(first.source == .bitSearch)
        #expect(first.infoHash.hex == "1c5d1d2da93cd2400406f4cb1d79980bdd4b0748")
        // The title comes out of the magnet's own `dn`, which cannot rot —
        // and the site's own stamp is taken off the front of it.
        #expect(first.title == "[ANi] BanG Dream! It's MyGO!!!!! - 11 [1080P][Baha][WEB-DL][AAC AVC][CHT].mp4")
        // The counts come off the markup around it and are best-effort.
        #expect(first.seeders == 405)
        #expect(first.leechers == 288)
        // The magnet rarely carries `xl`, so the card's own rounded size
        // stands in — and says that it is not exact.
        #expect(first.size == 327_550_000)
        #expect(!first.sizeIsExact)
    }

    /// A page with no magnets at all is the layout having moved or a challenge
    /// in the way — not an empty result, and not something to report as one.
    @Test func bitSearchTellsAnEmptyPageFromABrokenOne() {
        #expect(throws: TorrentSearchError.self) {
            try BitSearchTorrentProvider.parse(Data("<html><body>hello</body></html>".utf8))
        }
        #expect(try! BitSearchTorrentProvider.parse(Data("<html>No results found</html>".utf8)).isEmpty)
    }

    @Test func decodesTheEntitiesAPageTitleCarries() {
        let decoded = BitSearchTorrentProvider.decodingHTMLEntities(
            "a&amp;b &#x3D; c &#39;d&#39; &lt;e&gt; &#x60;f&#x60; &unknown;"
        )
        #expect(decoded == "a&b = c 'd' <e> `f` &unknown;")
    }

    /// The general indexes answer about everything, and the app says which is
    /// which so Settings can group them and a search can be honest about it.
    @Test func generalIndexesSayWhatTheyAre() {
        #expect(TorrentSourceID.knaben.isAnimeIndex == false)
        #expect(TorrentSourceID.theRarbg.isAnimeIndex == false)
        #expect(TorrentSourceID.nyaa.isAnimeIndex)
        #expect(TorrentSourceID.allCases.filter { !$0.isAnimeIndex }.count == 5)
    }

    /// Against the real services, opt-in with `ANIMEGOD_LIVE_TESTS=1`. This is
    /// the test that catches an index changing its shape under us, which two
    /// of these five had already done by the time they were ported.
    @Test func liveContractSmokeTest() async throws {
        guard ProcessInfo.processInfo.environment["ANIMEGOD_LIVE_TESTS"] == "1" else { return }
        let http = TorrentHTTPClient()
        let providers: [any TorrentSearchProvider] = [
            KnabenTorrentProvider(http: http),
            TorrentsCsvTorrentProvider(http: http),
            BitSearchTorrentProvider(http: http),
            TheRarbgTorrentProvider(http: http),
            ApiBayTorrentProvider(http: http)
        ]
        var answered = 0
        for provider in providers {
            guard let found = try? await provider.search(query: "MyGO LIVE", limit: 20) else { continue }
            guard !found.isEmpty else { continue }
            answered += 1
            // Whatever the shape, these three have to come out of it or the
            // listing cannot be downloaded or judged.
            #expect(found.allSatisfy { !$0.title.isEmpty })
            #expect(found.allSatisfy { $0.infoHash.hex.count == 40 })
            #expect(found.contains { $0.size != nil })
        }
        #expect(answered >= 3, "at least three of the five should answer from any network")
    }
}
