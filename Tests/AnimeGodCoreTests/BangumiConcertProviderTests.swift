import Foundation
import Testing
@testable import AnimeGodCore

/// Bangumi files a concert twice — as a performance and as a disc — and the
/// two carry different halves of the answer. Both fixtures are real responses,
/// trimmed: subject 540469 is the 演出 entry for BanG Dream!'s 10th
/// anniversary live, and 512098 is the 音乐 entry for 結束バンドLIVE-恒星-.
@Suite(.serialized)
struct BangumiConcertProviderTests {
    static let musicSubjectJSON = #"""
    {"id":512098,"type":3,"platform":"","name":"結束バンドLIVE-恒星","name_cn":"","summary":"Zepp Haneda（TOKYO）で開催された、結束バンド初のワンマンライブを全曲収録！\r\n音声特典として臨場感のある立体音響を体感できる5.1chサラウンドのほか、出演キャスト４人、\r\n音楽スタッフによるオーディオコメンタリーを2種収録。特典映像にはヒューリックホール東京で開催した『ぼっち・ざ・ろっく！です。』や\r\n『結束バンドLIVE-恒星-』のメイキング映像、『ギターヒーローへの道 番外編』も収録。さらに全24Pに及ぶオフィシャルフォトブック、\r\n「光の中へ」リリックビデオのイラストを使用したポストカード2種も封入した豪華仕様！\r\n\r\n日程：2023年5月21日(日)\r\n時間：17:00開場／18：00開演\r\n出演：青山吉能、鈴代紗弓、水野朔、長谷川育美\r\nバンドメンバー：生本直毅(Gt)、五十嵐勝人(Gt)、山崎英明(Ba)、石井悠也(Dr)\r\n会場：Zepp Haneda（TOKYO）\r\n\r\n\r\n【収録内容】\r\n\r\n◆本編\r\n☆Disc 1\r\n結束バンドLIVE-恒星-\r\nZepp Haneda（TOKYO）で開催されたワンマンライブ\r\n音声特典：\r\n・5.1chサラウンド\r\n・オーディオコメンタリー\r\n①青山吉能×鈴代紗弓×水野朔×長谷川育美\r\n②三井律郎（サウンドプロデューサー）×岡村弦（音楽ディレクター)× 高山幹弘（アソシエイトプロデューサー）\r\n〈収録楽曲〉\r\n　　　01．ひとりぼっち東京\r\n　　　02．ギターと孤独と蒼い惑星\r\n　　　03．ラブソングが歌えない\r\n　　　04．Distortion!!\r\n　　　05．ひみつ基地\r\n　　　06．カラカラ\r\n　　　07．あのバンド\r\n　　　08．小さな海\r\n　　　09．なにが悪い\r\n　　　10．青い春と西の空\r\n　　　11．忘れてやらない\r\n　　　12．星座になれたら\r\n　　　13．フラッシュバッカー\r\n　　アンコール\r\n　　　01．転がる岩、君に朝が降る\r\n　　　02．光の中へ\r\n　　　03．青春コンプレックス\r\n◆特典映像\r\n　☆DISC 2\r\n・ぼっち・ざ・ろっく！です。（2023年4月23日開催イベント）\r\n　☆DISC 3\r\n・Making of -恒星-\r\n・ギターヒーローへの道 番外編\r\n\r\n【特典】\r\n\r\n◆オフィシャルフォトブック（全24P）\r\n◆「光の中へ」リリックビデオ　ポストカード2種\r\n※仕様・特典は変更となる可能性がございます。\r\n\r\n(C)はまじあき／芳文社・アニプレックス\r\n\r\n","date":"2023-11-22","infobox":[{"key":"别名","value":[{"v":"Kessoku Band Live -Kosei- [Limited Edition]"}]},{"key":"版本特性","value":"Live Event"},{"key":"发售日期","value":"2023年11月22日"},{"key":"价格","value":"JP¥8,800"},{"key":"碟片数量","value":"3"}],"rating":{"rank":0,"total":18,"count":{"1":0,"2":0,"3":0,"4":0,"5":0,"6":0,"7":3,"8":11,"9":1,"10":3},"score":8.2},"images":{"large":"https://lain.bgm.tv/pic/cover/l/39/a3/512098_y8Aq1.jpg"}}
    """#

    static let performanceSubjectJSON = #"""
    {"id":540469,"type":6,"platform":"演出","name":"BanG Dream! 10th Anniversary LIVE「In the name of BanG Dream!」","name_cn":"","summary":"","date":"2026-02-28","infobox":[{"key":"集数","value":"1"},{"key":"开始","value":"2026年2月28日"},{"key":"类型","value":"Live"},{"key":"国家/地区","value":"日本"},{"key":"官方网站","value":"https://bang-dream.com/events/bangdream-10th-anniversary-live"},{"key":"演出地点","value":"Kアリーナ横浜"}],"rating":{"rank":19,"total":38,"count":{"1":0,"2":0,"3":0,"4":0,"5":0,"6":0,"7":1,"8":2,"9":6,"10":29},"score":9.7},"images":{"large":"https://lain.bgm.tv/pic/cover/l/c5/66/540469_MhD5o.jpg"}}
    """#

    private func provider() -> BangumiConcertProvider {
        BangumiConcertProvider(
            session: BangumiConcertStubURLProtocol.makeSession(),
            baseURL: URL(string: "https://bgm.example.test")!
        )
    }

    /// The 演出 entry is the only place any of the three sources says which
    /// hall the concert was in.
    @Test func readsThePerformanceAndItsVenue() async throws {
        BangumiConcertStubURLProtocol.reset(responses: ["/v0/subjects/540469": Self.performanceSubjectJSON])
        let release = try await provider().release(subjectID: "540469")

        #expect(release.isPerformanceRecord)
        #expect(release.venue == "Kアリーナ横浜")
        #expect(release.performedOn == "2026年2月28日")
        #expect(release.officialSiteURL?.host() == "bang-dream.com")
        #expect(release.country == "日本")
        #expect(release.score == 9.7)
        #expect(release.coverImageURLs.first?.scheme == "https")
        // A performance has no track list, and reading one out of an event
        // description would pick numbers out of prose.
        #expect(release.discs.isEmpty)
    }

    /// The 音乐 entry has no track-list field at all: the setlist is prose in
    /// the summary, and reading it is the fallback for a disc MusicBrainz has
    /// never heard of.
    @Test func readsTheSetlistOutOfTheSummary() async throws {
        BangumiConcertStubURLProtocol.reset(responses: ["/v0/subjects/512098": Self.musicSubjectJSON])
        let release = try await provider().release(subjectID: "512098")

        #expect(!release.isPerformanceRecord)
        #expect(release.score == 8.2)
        #expect(release.ratingCount == 18)
        #expect(release.releaseDate == "2023-11-22")

        let disc = try #require(release.discs.first)
        // Thirteen in the main set and three in the encore: sixteen songs,
        // which is exactly what MusicBrainz lists for the same disc.
        #expect(disc.tracks.count == 16)
        #expect(disc.tracks.first?.title == "ひとりぼっち東京")
        #expect(disc.tracks.map(\.position) == Array(1...16))
        #expect(disc.tracks.last?.title == "青春コンプレックス")
        // The encore restarts its own numbering at 01, which is what would
        // have quietly dropped the last three songs.
        #expect(disc.tracks.filter(\.isEncore).map(\.title)
            == ["転がる岩、君に朝が降る", "光の中へ", "青春コンプレックス"])
        // The same summary holds `17:00開場`, `・5.1chサラウンド` and a bulleted
        // bonus-disc list, and none of it may become a song.
        #expect(!disc.tracks.contains { $0.title.contains("開場") })
        #expect(!disc.tracks.contains { $0.title.contains("ch") && $0.title.contains("サラウンド") })
        #expect(!disc.tracks.contains { $0.title.contains("Making") })
    }

    @Test func sortsPerformancesAheadOfDiscs() async throws {
        let body = #"{"data":[DISC,EVENT]}"#
            .replacingOccurrences(of: "DISC", with: Self.musicSubjectJSON)
            .replacingOccurrences(of: "EVENT", with: Self.performanceSubjectJSON)
        BangumiConcertStubURLProtocol.reset(responses: ["/v0/search/subjects": body])
        let results = try await provider().search("結束バンドLIVE")
        #expect(results.first?.isPerformanceRecord == true)
        #expect(results.count == 2)
    }

    // MARK: - The prose reader on its own

    @Test func refusesProseThatMerelyHasNumbersInIt() {
        let notASetlist = """
        日程：2023年5月21日(日)
        時間：17:00開場／18：00開演
        会場：Zepp Haneda（TOKYO）
        ・5.1chサラウンド
        """
        #expect(ConcertSetlistTextParser.songs(in: notASetlist).isEmpty)
    }

    @Test func readsAPlainlyNumberedListWithNoHeading() {
        let text = """
        1. ひとりぼっち東京
        2. ギターと孤独と蒼い惑星
        3. ラブソングが歌えない
        """
        let songs = ConcertSetlistTextParser.songs(in: text)
        #expect(songs.map(\.title) == ["ひとりぼっち東京", "ギターと孤独と蒼い惑星", "ラブソングが歌えない"])
    }

    /// Two numbered lines are a coincidence, not a list.
    @Test func needsMoreThanTwoLinesToCallItASetlist() {
        #expect(ConcertSetlistTextParser.songs(in: "1. A\n2. B").isEmpty)
    }

    @Test func stopsAtTheBonusDisc() {
        let text = """
        〈収録楽曲〉
        01．A
        02．B
        03．C
        ◆特典映像
        　☆DISC 2
        01．これは本編ではない
        """
        let songs = ConcertSetlistTextParser.songs(in: text)
        #expect(songs.map(\.title) == ["A", "B", "C"])
    }

    @Test func nilAndEmptyTextAreNotSetlists() {
        #expect(ConcertSetlistTextParser.songs(in: nil).isEmpty)
        #expect(ConcertSetlistTextParser.songs(in: "").isEmpty)
    }
}

/// Its own stub rather than the one the Discogs and MusicBrainz tests use.
/// A `URLProtocol`'s registry is static, so two suites sharing one class clear
/// each other's responses the moment they run side by side — which is exactly
/// what happened: both suites are `.serialized`, but that orders the tests
/// *within* a suite and says nothing about two suites running at once.
final class BangumiConcertStubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var responses: [String: String] = [:]
    private static let lock = NSLock()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BangumiConcertStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset(responses: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        Self.responses = responses
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        let body = Self.responses[path]
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
