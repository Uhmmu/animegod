import Foundation
import Testing
@testable import AnimeGodCore

/// Fixtures are trimmed from real responses captured on 2026-09-16.
struct TorrentProviderParsingTests {
    private static let batchHash = "6e54509de959fbe569c135b4f46b35789d53aaa6"
    private static let batchTitle = "[Prejudice-Studio] 颂乐人偶 BanG Dream! Ave Mujica [01-13][Bilibili WEB-DL HDR10 2160P HEVC 10bit AAC MP4][简日内嵌][Reseed]"

    @Test func parsesDmhyAndDropsNonAnimeCategories() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?><rss version="2.0"><channel><title>動漫花園</title>
        <item>
        <title><![CDATA[\(Self.batchTitle)]]></title>
        <link>http://share.dmhy.org/topics/view/724795_Prejudice-Studio.html</link>
        <pubDate>Thu, 13 Aug 2026 13:56:12 +0800</pubDate>
        <description><![CDATA[<p>long html</p>]]></description>
        <enclosure url="magnet:?xt=urn:btih:NZKFBHPJLH56K2OBGW2PI2ZVPCOVHKVG&amp;dn=&amp;tr=https%3A%2F%2Ftracker.anibt.net%2Fannounce"  length="1"  type="application/x-bittorrent" >
        </enclosure>
        <author><![CDATA[MoYuanCN]]></author>
        <category domain="http://share.dmhy.org/topics/list/sort_id/31" ><![CDATA[季度全集]]></category>
        </item>
        <item>
        <title><![CDATA[[某汉化组] 某游戏 v1.0]]></title>
        <enclosure url="magnet:?xt=urn:btih:MRZPUJOUXYNQ2WPDU7EEL5RKQLURBQUV" length="1" type="application/x-bittorrent"></enclosure>
        <category domain="http://share.dmhy.org/topics/list/sort_id/9" ><![CDATA[遊戲]]></category>
        </item>
        </channel></rss>
        """
        let results = try DmhyTorrentProvider.parse(Data(xml.utf8))
        #expect(results.count == 1)
        let first = try #require(results.first)
        #expect(first.title == Self.batchTitle)
        #expect(first.infoHash.hex == Self.batchHash)
        #expect(first.category == .batch)
        #expect(first.trackers == ["https://tracker.anibt.net/announce"])
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_786_600_572))
        #expect(first.pageURL?.host == "share.dmhy.org")
    }

    @Test func parsesMikanHashFromEpisodeLink() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?><rss version="2.0"><channel><title>Mikan Project</title><item><guid isPermaLink="false">\(Self.batchTitle)</guid><link>https://mikanani.me/Home/Episode/\(Self.batchHash)</link><title>\(Self.batchTitle)</title><description>\(Self.batchTitle)[9.4 GB]</description><torrent xmlns="https://mikanani.me/0.1/"><link>https://mikanani.me/Home/Episode/\(Self.batchHash)</link><contentLength>10093172736</contentLength><pubDate>2026-08-13T13:56:15.11161</pubDate></torrent><enclosure type="application/x-bittorrent" length="10093172736" url="https://mikanani.me/Download/20260813/\(Self.batchHash).torrent" /></item></channel></rss>
        """
        let first = try #require(try MikanTorrentProvider.parse(Data(xml.utf8)).first)
        #expect(first.infoHash.hex == Self.batchHash)
        #expect(first.size == 10_093_172_736)
        #expect(first.sizeIsExact)
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_786_600_575))
        #expect(first.torrentURL?.lastPathComponent == "\(Self.batchHash).torrent")
    }

    @Test func parsesAcgnxSizeAndCategoryFromDescription() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>ACGNX</title>
        <item>
            <title><![CDATA[[JMAX] [2026.06.17] BanG Dream! Ave Mujica ベストアルバム「Ave Música」[FLAC 96kHz/24bit]]]></title>
            <link>https://share.acgnx.se/show-6472fa25d4be1b0d59e3a7c845f62a82e910c295.html</link>
            <description><![CDATA[<a href="https://share.acgnx.se/show-6472fa25d4be1b0d59e3a7c845f62a82e910c295.html">動漫花園鏡像 | [JMAX] BanG Dream! Ave Mujica [FLAC 96kHz/24bit]</a> | 1.3GB | 音樂 | 6472fa25d4be1b0d59e3a7c845f62a82e910c295]]></description>
            <author><![CDATA[動漫花園鏡像]]></author>
            <enclosure url="magnet:?xt=urn:btih:6472fa25d4be1b0d59e3a7c845f62a82e910c295&amp;tr=http%3A%2F%2Fopentracker.acgnx.se%2Fannounce" length="1" type="application/x-bittorrent" />
            <pubDate>Tue, 16 Jun 2026 20:14:00 +0800</pubDate>
            <category domain="https://share.acgnx.se/sort-6-1.html"><![CDATA[音樂]]></category>
        </item>
        </channel></rss>
        """
        let first = try #require(try AcgnxTorrentProvider.parse(Data(xml.utf8)).first)
        #expect(first.category == .music)
        #expect(first.size == Int64(1.3 * 1024 * 1024 * 1024))
        #expect(first.team == nil, "the uploader account is not a fansub")
        #expect(first.trackers == ["http://opentracker.acgnx.se/announce"])
    }

    @Test func parsesNyaaAnimeCategoriesOnly() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?><rss xmlns:atom="http://www.w3.org/2005/Atom" xmlns:nyaa="https://nyaa.si/xmlns/nyaa" version="2.0"><channel><title>Nyaa</title>
        <item>
            <title>\(Self.batchTitle)</title>
            <link>https://nyaa.si/download/2145552.torrent</link>
            <guid isPermaLink="true">https://nyaa.si/view/2145552</guid>
            <pubDate>Thu, 13 Aug 2026 05:56:19 -0000</pubDate>
            <nyaa:seeders>4</nyaa:seeders>
            <nyaa:leechers>1</nyaa:leechers>
            <nyaa:infoHash>\(Self.batchHash)</nyaa:infoHash>
            <nyaa:categoryId>1_3</nyaa:categoryId>
            <nyaa:size>9.4 GiB</nyaa:size>
        </item>
        <item>
            <title>Some Live Action</title>
            <nyaa:infoHash>938762a9ee0278dfcbd269badd8c064b5e18a90d</nyaa:infoHash>
            <nyaa:categoryId>4_1</nyaa:categoryId>
        </item>
        </channel></rss>
        """
        let results = try NyaaTorrentProvider.parse(Data(xml.utf8))
        #expect(results.count == 1)
        let first = try #require(results.first)
        #expect(first.seeders == 4)
        #expect(first.leechers == 1)
        #expect(first.size == Int64(9.4 * 1024 * 1024 * 1024))
        #expect(!first.sizeIsExact)
        #expect(first.torrentURL?.absoluteString == "https://nyaa.si/download/2145552.torrent")
        #expect(first.pageURL?.absoluteString == "https://nyaa.si/view/2145552")
    }

    @Test func tokyoToshoDropsAdultCategories() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>Tokyo Toshokan</title>
        <item>
        <category>Hentai (Manga)</category>
        <title>(C108) Some Doujin (BanG Dream! Ave Mujica) [English].zip</title>
        <link><![CDATA[https://ehtracker.org/get/4190413/cd075d8d5a8d35675dede8ddd9caafe161cf5ff8.torrent]]></link>
        <description><![CDATA[<a href="magnet:?xt=urn:btih:ZUDV3DK2RU2WOXPN5DO5TSVP4FQ46X7Y&tr=http://ehtracker.org/4190413/announce">Magnet Link</a><br />Size: 189.27MB<br />]]></description>
        </item>
        <item>
        <category>Anime</category>
        <title>[SubsPlease] BanG Dream! Ave Mujica - 13 (1080p) [3A1B2C3D].mkv</title>
        <link><![CDATA[https://nyaa.si/download/1950000.torrent]]></link>
        <description><![CDATA[<a href="https://nyaa.si/download/1950000.torrent">Torrent Link</a><br />
        <a href="magnet:?xt=urn:btih:I4ZZ5VLTYRJSQIHXJQ6U7C3U7YUZY4FY&tr=http://nyaa.tracker.wf:7777/announce">Magnet Link</a><br />
        Size: 1.32GB<br />]]></description>
        <guid><![CDATA[https://www.tokyotosho.info/details.php?id=1990000]]></guid>
        <pubDate>Thu, 27 Mar 2025 15:05:00 GMT</pubDate>
        </item>
        </channel></rss>
        """
        let results = try TokyoToshoTorrentProvider.parse(Data(xml.utf8))
        #expect(results.map(\.title) == ["[SubsPlease] BanG Dream! Ave Mujica - 13 (1080p) [3A1B2C3D].mkv"])
        #expect(results.first?.size == Int64(1.32 * 1024 * 1024 * 1024))
        #expect(results.first?.trackers == ["http://nyaa.tracker.wf:7777/announce"])
        #expect(results.first?.publishedAt != nil)
    }

    @Test func parsesAcgRipListings() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:torrent="http://xmlns.ezrss.it/0.1/" xmlns:media="http://search.yahoo.com/mrss/"><channel><title>ACG.RIP</title>
        <item>
          <title>\(Self.batchTitle)</title>
          <description>&lt;p&gt;html&lt;/p&gt;</description>
          <pubDate>Wed, 12 Aug 2026 22:56:11 -0700</pubDate>
          <link>https://acg.rip/t/360684</link>
          <enclosure url="https://acg.rip/t/360684.torrent" type="application/x-bittorrent"/>
          <torrent:contentLength>10072080384</torrent:contentLength>
        </item>
        </channel></rss>
        """
        let listing = try #require(try AcgRipTorrentProvider.parse(Data(xml.utf8)).first)
        #expect(listing.torrentURL.absoluteString == "https://acg.rip/t/360684.torrent")
        #expect(listing.size == 10_072_080_384)
        #expect(listing.publishedAt == Date(timeIntervalSince1970: 1_786_600_571))
    }

    @Test func nonRSSBodiesAreParseErrorsNotEmptyResults() {
        let html = Data("<html><head><title>502</title></head><body>Bad gateway</body></html>".utf8)
        #expect(throws: TorrentSearchError.self) { try DmhyTorrentProvider.parse(html) }
        #expect(throws: TorrentSearchError.self) { try AnimeToshoTorrentProvider.parse(html) }
        let empty = Data(#"<?xml version="1.0"?><rss version="2.0"><channel><title>none</title></channel></rss>"#.utf8)
        #expect((try? NyaaTorrentProvider.parse(empty))?.isEmpty == true)
    }

    @Test func parsesAnimeTosho() throws {
        let json = """
        [{"id": 742164, "title": "Ave Mujica - The Die is Cast S01 VOSTFR 1080p WEB x264 AAC -Tsundere-Raws (CR) (Multi-Subs, BanG Dream! Ave Mujica)", "torrent_name": "Ave Mujica - The Die is Cast S01 VOSTFR 1080p WEB x264 AAC -Tsundere-Raws (CR)", "link": "https://mirror.animetosho.org/view/ave-mujica.n2074946", "timestamp": 1770745061, "torrent_url": "https://storage.animetosho.org/torrent/938762a9ee0278dfcbd269badd8c064b5e18a90d/a.torrent", "info_hash": "938762a9ee0278dfcbd269badd8c064b5e18a90d", "magnet_uri": "magnet:?xt=urn:btih:SODWFKPOAJ4N7S6SNG5N3DAGJNPBRKIN&tr=http%3A%2F%2Fnyaa.tracker.wf%3A7777%2Fannounce", "seeders": 11, "leechers": 2, "total_size": 19108351539, "nzb_url": null}]
        """
        let first = try #require(try AnimeToshoTorrentProvider.parse(Data(json.utf8)).first)
        #expect(first.title == "Ave Mujica - The Die is Cast S01 VOSTFR 1080p WEB x264 AAC -Tsundere-Raws (CR)")
        #expect(first.infoHash.hex == "938762a9ee0278dfcbd269badd8c064b5e18a90d")
        #expect(first.seeders == 11)
        #expect(first.size == 19_108_351_539)
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_770_745_061))
    }

    @Test func parsesBangumiMoeAndMapsTags() throws {
        let json = """
        {"torrents":[
          {"_id":"6a7d5c7e9605d5c6901a2501","title":"\(Self.batchTitle)","seeders":3,"leechers":1,"publish_time":"2026-08-13T05:56:14.110Z","magnet":"magnet:?xt=urn:btih:\(Self.batchHash)","infoHash":"\(Self.batchHash)","size":"10.07 GB","team":{"name":"Prejudice-Studio"},"category_tag":{"name":"Collection"}},
          {"_id":"1","title":"Some Comic","infoHash":"938762a9ee0278dfcbd269badd8c064b5e18a90d","category_tag":{"name":"Comic"}}
        ],"count":2,"page_count":1,"success":true}
        """
        let results = try BangumiMoeTorrentProvider.parse(Data(json.utf8))
        #expect(results.count == 1)
        let first = try #require(results.first)
        #expect(first.category == .batch)
        #expect(first.team == "Prejudice-Studio")
        #expect(first.size == 10_070_000_000)
        #expect(first.pageURL?.absoluteString == "https://bangumi.moe/torrent/6a7d5c7e9605d5c6901a2501")
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_786_600_574.11))
    }

    @Test func parsesAnimeGarden() throws {
        let json = """
        {"status":"OK","resources":[
          {"id":2453228,"provider":"dmhy","title":"\(Self.batchTitle)","href":"https://share.dmhy.org/topics/view/724795.html","type":"合集","magnet":"magnet:?xt=urn:btih:NZKFBHPJLH56K2OBGW2PI2ZVPCOVHKVG","size":10093172736,"createdAt":"2026-08-13T05:56:00.000Z","publisher":{"name":"MoYuanCN"},"fansub":{"name":"Prejudice-Studio"}},
          {"id":1,"title":"某游戏","type":"游戏","magnet":"magnet:?xt=urn:btih:MRZPUJOUXYNQ2WPDU7EEL5RKQLURBQUV","size":1}
        ],"pagination":{"page":1,"pageSize":2,"complete":false}}
        """
        let results = try AnimeGardenTorrentProvider.parse(Data(json.utf8))
        #expect(results.count == 1)
        #expect(results.first?.infoHash.hex == Self.batchHash)
        #expect(results.first?.team == "Prejudice-Studio")
        #expect(results.first?.category == .batch)
        #expect(results.first?.sizeIsExact == true)
    }

    @Test func parsesSubsPleasePerResolution() throws {
        let json = """
        {"BanG Dream! Ave Mujica - 13": {"time": "03/27/25", "release_date": "Thu, 27 Mar 2025 15:02:44 +0000", "show": "BanG Dream! Ave Mujica", "episode": "13", "page": "bang-dream-ave-mujica", "downloads": [
          {"res": "480", "magnet": "magnet:?xt=urn:btih:BWFZXCNYAICX2F7UTYL5F2JMRGF63EEA&dn=%5BSubsPlease%5D%20BanG%20Dream%21%20Ave%20Mujica%20-%2013%20%28480p%29%20%5BE40B0C28%5D.mkv&xl=437041125"},
          {"res": "1080", "magnet": "magnet:?xt=urn:btih:I4ZZ5VLTYRJSQIHXJQ6U7C3U7YUZY4FY&dn=%5BSubsPlease%5D%20BanG%20Dream%21%20Ave%20Mujica%20-%2013%20%281080p%29.mkv&xl=1400000000"}
        ]}}
        """
        let results = try SubsPleaseTorrentProvider.parse(Data(json.utf8))
        #expect(results.count == 2)
        #expect(results.first?.title == "[SubsPlease] BanG Dream! Ave Mujica - 13 (480p) [E40B0C28].mkv")
        #expect(results.first?.size == 437_041_125)
        #expect(results.first?.team == "SubsPlease")
        #expect(results.first?.pageURL?.absoluteString == "https://subsplease.org/shows/bang-dream-ave-mujica/")
        #expect(try SubsPleaseTorrentProvider.parse(Data("[]".utf8)).isEmpty)
    }

    @Test func detectsChallengePages() {
        let url = URL(string: "https://share.dmhy.org/")!
        let challenge = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        #expect(TorrentHTTPClient.isChallenge(challenge, data: Data("<title>Just a moment...</title>".utf8)))
        let normal = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/xml"])!
        #expect(!TorrentHTTPClient.isChallenge(normal, data: Data("<rss>Just a moment...</rss>".utf8)))
    }

    /// Hits every real index. Run with `ANIMEGOD_LIVE_TESTS=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANIMEGOD_LIVE_TESTS"] == "1"))
    func liveProvidersReturnResults() async throws {
        let providers = TorrentProviders.all()
        for source in TorrentSourceID.allCases {
            let provider = try #require(providers[source])
            let results = try await provider.search(query: "Ave Mujica", limit: 10)
            #expect(!results.isEmpty, "\(source.rawValue) returned nothing")
            if let first = results.first {
                let release = TorrentReleaseInfo.parse(title: first.title)
                print("LIVE \(source.rawValue): \(results.count) · \(first.title) · size=\(first.size.map(String.init) ?? "-") seeders=\(first.seeders.map(String.init) ?? "-") date=\(first.publishedAt.map { "\($0)" } ?? "-") cat=\(first.category) ep=\(release.episodeLabel ?? "-") team=\(first.team ?? release.group ?? "-")")
            }
        }
    }
}
