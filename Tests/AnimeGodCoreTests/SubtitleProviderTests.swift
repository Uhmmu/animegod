import Foundation
import Testing
@testable import AnimeGodCore

/// Intercepts subtitle provider traffic; routes by URL substring so one
/// test can serve search, detail and download endpoints.
final class SubtitleMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [(match: String, status: Int, body: Data, headers: [String: String])] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        routes = []
        requests = []
    }

    static func route(_ match: String, status: Int = 200, json: String, headers: [String: String] = [:]) {
        routes.append((match, status, Data(json.utf8), headers))
    }

    static func route(_ match: String, status: Int = 200, data: Data) {
        routes.append((match, status, data, [:]))
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            stream.close()
            recorded.httpBody = data
        }
        Self.requests.append(recorded)
        let url = request.url?.absoluteString ?? ""
        guard let route = Self.routes.first(where: { url.contains($0.match) }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: route.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Always fails — to prove one provider's failure stays contained.
struct FailingSubtitleProvider: SubtitleProvider {
    let id: SubtitleProviderID
    func search(_ query: SubtitleQuery) async throws -> [SubtitleResult] { throw SubtitleProviderError.rateLimited(retryAfter: 30) }
    func download(_ result: SubtitleResult, for video: SubtitleVideoIdentity) async throws -> [SubtitleDownloadedFile] { throw SubtitleProviderError.invalidResponse }
}

struct StaticSubtitleProvider: SubtitleProvider {
    let id: SubtitleProviderID
    let results: [SubtitleResult]
    var files: [SubtitleDownloadedFile] = []
    func search(_ query: SubtitleQuery) async throws -> [SubtitleResult] { results }
    func download(_ result: SubtitleResult, for video: SubtitleVideoIdentity) async throws -> [SubtitleDownloadedFile] { files }
}

@Suite(.serialized)
struct SubtitleProviderTests {
    let video: SubtitleVideoIdentity = {
        var identity = SubtitleVideoIdentity.fromFileName(
            "[LoliHouse] Sousou no Frieren - 14 [WebRip 1080p HEVC-10bit AAC SRTx2].mkv",
            titles: ["葬送的芙莉莲"]
        )
        identity.ids = SubtitleAnimeIDs(aniListID: 154587, tmdbID: 209867, tmdbKind: .tv, tmdbSeason: 1)
        return identity
    }()

    var query: SubtitleQuery { SubtitleQuery(identity: video, languages: [.simplifiedChinese, .traditionalChinese]) }

    // MARK: assrt

    @Test func assrtMapsLanguagesFormatsAndEpisodes() async throws {
        SubtitleMockURLProtocol.reset()
        SubtitleMockURLProtocol.route("sub/search", json: """
        {"status":0,"sub":{"subs":[
          {"id":700001,"native_name":"葬送的芙莉莲 第14集/Sousou no Frieren","videoname":"[LoliHouse] Sousou no Frieren - 14 [WebRip 1080p HEVC-10bit AAC SRTx2]",
           "subtype":"ASS","upload_time":"2024-01-01 10:00:00","release_site":"喵萌奶茶屋","lang":{"langlist":{"langchs":true,"langcht":true},"desc":"简 繁"}},
          {"id":700002,"native_name":"葬送的芙莉莲","videoname":"Sousou no Frieren 01-28","subtype":"Subrip(srt)","lang":{"langlist":{"langdou":true},"desc":"双语"}},
          {"id":700003,"native_name":"葬送的芙莉莲","subtype":"VobSub","lang":{"langlist":{"langchs":true}}}
        ],"result":"succeed"}}
        """)
        let provider = AssrtSubtitleProvider(token: "t", session: SubtitleMockURLProtocol.makeSession())
        let results = try await provider.search(query)
        #expect(results.map(\.providerSubtitleID) == ["700001", "700002"])
        let first = try #require(results.first)
        #expect(first.languages == [.simplifiedChinese, .traditionalChinese])
        #expect(first.format == .ass)
        #expect(first.episode == 14)
        #expect(first.title == "葬送的芙莉莲")
        #expect(first.author == "喵萌奶茶屋")
        #expect(first.displayGroup == "LoliHouse")
        #expect(results[1].languages == [.chinese])
        #expect(results[1].isPack)
        #expect(SubtitleMockURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(SubtitleMockURLProtocol.requests.first?.url?.query?.contains("is_file=1") == true)
    }

    @Test func assrtReportsBadTokensAndQuota() async {
        SubtitleMockURLProtocol.reset()
        SubtitleMockURLProtocol.route("sub/search", json: #"{"status":20001,"errmsg":"invalid token"}"#)
        let provider = AssrtSubtitleProvider(token: "bad", session: SubtitleMockURLProtocol.makeSession())
        await #expect(throws: SubtitleProviderError.unauthorized) { try await provider.search(query) }

        SubtitleMockURLProtocol.reset()
        SubtitleMockURLProtocol.route("sub/search", json: #"{"status":30900}"#)
        await #expect(throws: SubtitleProviderError.rateLimited(retryAfter: 60)) { try await provider.search(query) }
    }

    @Test func assrtFallsBackToTheAlternateDomainWhenTheAPIHostIsUnreachable() async throws {
        SubtitleMockURLProtocol.reset()
        // No route for the primary host: the mock answers "cannot find host".
        SubtitleMockURLProtocol.route("alternate.example/v1/sub/search", json: #"{"status":0,"sub":{"subs":[{"id":1,"native_name":"葬送的芙莉莲 第14集","subtype":"ASS"}]}}"#)
        let provider = AssrtSubtitleProvider(
            token: "t", session: SubtitleMockURLProtocol.makeSession(),
            baseURLs: [URL(string: "https://primary.example/v1")!, URL(string: "https://alternate.example/v1")!]
        )
        let results = try await provider.search(query)
        #expect(results.map(\.providerSubtitleID) == ["1"])
        // Once the alternate answered, later requests go straight to it.
        let hosts = SubtitleMockURLProtocol.requests.compactMap { $0.url?.host() }
        #expect(hosts.first == "primary.example")
        #expect(hosts.dropFirst(2).allSatisfy { $0 == "alternate.example" })
    }

    @Test func assrtDownloadsTheEpisodeFileFromTheListedArchive() async throws {
        SubtitleMockURLProtocol.reset()
        SubtitleMockURLProtocol.route("sub/detail", json: """
        {"status":0,"sub":{"subs":[{"id":700002,"filename":"pack.rar","url":"https://file0.assrt.net/download/700002/pack.rar",
          "filelist":[{"url":"https://file0.assrt.net/onthefly/700002/-/1/Frieren - 13.chs.ass","f":"Frieren - 13.chs.ass","s":"40KB"},
                      {"url":"https://file0.assrt.net/onthefly/700002/-/2/Frieren - 14.chs.ass","f":"Frieren - 14.chs.ass","s":"40KB"}]}]}}
        """)
        SubtitleMockURLProtocol.route("onthefly/700002/-/2", data: Data("[Script Info]\nDialogue: x".utf8))
        let provider = AssrtSubtitleProvider(token: "t", session: SubtitleMockURLProtocol.makeSession())
        let result = SubtitleResult(provider: .assrt, providerSubtitleID: "700002", title: "", languages: [.chinese], isPack: true, basis: .title, downloadContext: "700002")
        let files = try await provider.download(result, for: video)
        #expect(files.map(\.name) == ["Frieren - 14.chs.ass"])
    }

    // MARK: SubDL

    @Test func subDLSearchesByTMDBAndMapsChineseCodes() async throws {
        SubtitleMockURLProtocol.reset()
        SubtitleMockURLProtocol.route("api.subdl.com", json: """
        {"status":true,"results":[{"name":"Frieren: Beyond Journey's End","tmdb_id":209867,"type":"tv"}],
         "subtitles":[
          {"release_name":"[SubsPlease] Sousou no Frieren - 14 (1080p)","name":"SUBDL.com::frieren.zip","lang":"Chinese BG code","language":"ZH",
           "author":"someone","url":"/subtitle/100-200.zip","season":1,"episode":14,"releases":["[LoliHouse] Sousou no Frieren - 14 [WebRip 1080p HEVC-10bit AAC SRTx2]"]},
          {"release_name":"Frieren S01 Complete","name":"pack.zip","lang":"Big 5 code","language":"ZH_BG","url":"/subtitle/300-400.zip",
           "season":1,"full_season":true,"episode_from":1,"episode_end":28,
           "unpack_files":[{"name":"Frieren.S01E13.srt","episode":13,"language":"ZH_BG","format":"srt","url":"/subtitle/300/f13"},
                           {"name":"Frieren.S01E14.srt","episode":14,"language":"ZH_BG","format":"srt","url":"/subtitle/300/f14"}]}
         ]}
        """)
        let provider = SubDLSubtitleProvider(apiKey: "k", session: SubtitleMockURLProtocol.makeSession())
        let results = try await provider.search(query)
        #expect(results.count == 2)
        #expect(results[0].languages == [.simplifiedChinese])
        #expect(results[0].basis == .externalID)
        #expect(results[0].episode == 14)
        // The listed release closest to the playing file is the one shown.
        #expect(results[0].releaseName == "[LoliHouse] Sousou no Frieren - 14 [WebRip 1080p HEVC-10bit AAC SRTx2]")
        #expect(results[1].languages == [.traditionalChinese])
        #expect(results[1].downloadContext == "/subtitle/300/f14")
        #expect(results[1].format == .srt)
        let url = try #require(SubtitleMockURLProtocol.requests.first?.url?.absoluteString)
        #expect(url.contains("tmdb_id=209867"))
        #expect(url.contains("episode_number=14"))
        #expect(url.contains("languages=ZH,ZH_BG"))
        #expect(url.contains("type=tv"))
    }

    @Test func subDLTreatsNotFoundAsEmpty() async throws {
        SubtitleMockURLProtocol.reset()
        SubtitleMockURLProtocol.route("api.subdl.com", json: #"{"status":false,"error":"can't find movie or tv"}"#)
        let provider = SubDLSubtitleProvider(apiKey: "k", session: SubtitleMockURLProtocol.makeSession())
        #expect(try await provider.search(query).isEmpty)
    }

    // MARK: OpenSubtitles

    @Test func openSubtitlesSendsSortedParametersAndRecognizesHashMatches() async throws {
        SubtitleMockURLProtocol.reset()
        SubtitleMockURLProtocol.route("/subtitles", json: """
        {"total_count":1,"data":[{"id":"1","type":"subtitle","attributes":{"language":"zh-cn","download_count":900,"release":"Sousou no Frieren S01E14 1080p WEB",
          "moviehash_match":true,"ai_translated":false,"machine_translated":false,
          "feature_details":{"parent_title":"Frieren: Beyond Journey's End","season_number":1,"episode_number":14},
          "files":[{"file_id":555,"file_name":"frieren.s01e14.zh-cn.srt"}]}}]}
        """)
        var hashed = video
        hashed.openSubtitlesHash = "8e245d9679d31e12"
        let provider = OpenSubtitlesProvider(apiKey: "key", session: SubtitleMockURLProtocol.makeSession())
        let results = try await provider.search(SubtitleQuery(identity: hashed, languages: [.simplifiedChinese, .traditionalChinese]))
        let result = try #require(results.first)
        #expect(result.isHashMatch)
        #expect(result.basis == .fileHash)
        #expect(result.languages == [.simplifiedChinese])
        #expect(result.downloadContext == "555")
        let request = try #require(SubtitleMockURLProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "Api-Key") == "key")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("AnimeGod v") == true)
        let query = try #require(request.url?.query)
        #expect(query == "episode_number=14&languages=ze,zh-cn,zh-tw&moviehash=8e245d9679d31e12&parent_tmdb_id=209867&season_number=1")
    }

    @Test func openSubtitlesExplainsTheAnonymousDownloadLimit() async {
        SubtitleMockURLProtocol.reset()
        SubtitleMockURLProtocol.route("/download", status: 406, json: #"{"message":"You have downloaded your allowed 5 subtitles for 24h"}"#)
        let provider = OpenSubtitlesProvider(apiKey: "key", session: SubtitleMockURLProtocol.makeSession())
        let result = SubtitleResult(provider: .openSubtitles, providerSubtitleID: "555", title: "", languages: [.simplifiedChinese], basis: .title, downloadContext: "555")
        do {
            _ = try await provider.download(result, for: video)
            Issue.record("expected a quota error")
        } catch let error as SubtitleProviderError {
            guard case .quotaExceeded = error else { Issue.record("unexpected \(error)"); return }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func openSubtitlesLogsInOnceAndDownloadsWithTheToken() async throws {
        SubtitleMockURLProtocol.reset()
        SubtitleMockURLProtocol.route("/login", json: #"{"token":"jwt","base_url":"api.opensubtitles.com","status":200,"user":{}}"#)
        SubtitleMockURLProtocol.route("/download", json: #"{"link":"https://www.opensubtitles.com/download/abc/frieren.srt","file_name":"frieren.srt","remaining":19}"#)
        SubtitleMockURLProtocol.route("download/abc", data: Data("1\n00:00:01,000 --> 00:00:02,000\n你好\n".utf8))
        let tokens = OpenSubtitlesTokenStore()
        let provider = OpenSubtitlesProvider(
            apiKey: "key", credentials: .init(username: "u", password: "p"), tokens: tokens,
            session: SubtitleMockURLProtocol.makeSession()
        )
        let result = SubtitleResult(provider: .openSubtitles, providerSubtitleID: "555", title: "", languages: [.simplifiedChinese], basis: .title, downloadContext: "555")
        let files = try await provider.download(result, for: video)
        _ = try await provider.download(result, for: video)
        #expect(files.first?.name == "frieren.srt")
        #expect(SubtitleMockURLProtocol.requests.filter { $0.url?.path.hasSuffix("/login") == true }.count == 1)
        let download = try #require(SubtitleMockURLProtocol.requests.first { $0.url?.path.hasSuffix("/download") == true })
        #expect(download.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
        #expect(String(data: download.httpBody ?? Data(), encoding: .utf8) == #"{"file_id":555}"#)
    }

    // MARK: Jimaku

    @Test func jimakuSearchesByAniListIDAndEpisode() async throws {
        SubtitleMockURLProtocol.reset()
        SubtitleMockURLProtocol.route("entries/search", json: #"[{"id":42,"name":"Sousou no Frieren","anilist_id":154587,"flags":{"anime":true}}]"#)
        SubtitleMockURLProtocol.route("entries/42/files", json: #"[{"url":"https://jimaku.cc/entry/42/download/Frieren.14.ja.ass","name":"Frieren.14.ja.ass","size":1000,"last_modified":"2024-01-01T00:00:00Z"}]"#)
        let provider = JimakuSubtitleProvider(apiKey: "jk", session: SubtitleMockURLProtocol.makeSession())
        let results = try await provider.search(SubtitleQuery(identity: video, languages: [.japanese]))
        #expect(results.count == 1)
        #expect(results.first?.languages == [.japanese])
        #expect(results.first?.episode == 14)
        #expect(results.first?.basis == .externalID)
        #expect(SubtitleMockURLProtocol.requests.first?.url?.query?.contains("anilist_id=154587") == true)
        #expect(SubtitleMockURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "jk")
    }

    // MARK: Manager

    @Test func oneFailingProviderDoesNotFailTheSearch() async {
        let good = SubtitleResult(
            provider: .subdl, providerSubtitleID: "1", title: "葬送的芙莉莲",
            releaseName: "[LoliHouse] Sousou no Frieren - 14 [WebRip 1080p HEVC-10bit AAC SRTx2]",
            languages: [.simplifiedChinese], format: .ass, episode: 14, basis: .externalID, downloadContext: "1"
        )
        let manager = SubtitleManager(providers: [
            FailingSubtitleProvider(id: .assrt),
            StaticSubtitleProvider(id: .subdl, results: [good]),
            StaticSubtitleProvider(id: .jimaku, results: [good])
        ])
        let report = await manager.search(query)
        #expect(report.ranked.map(\.result.provider) == [.subdl])
        #expect(report.automaticChoice?.result.id == good.id)
        guard case .failed = report.outcomes[.assrt] else { Issue.record("assrt should have failed"); return }
        guard case .skipped = report.outcomes[.jimaku] else { Issue.record("jimaku should be skipped for Chinese"); return }
        #expect(report.outcomes[.subdl] == .succeeded(count: 1))
    }

    @Test func mirroredFilesAreDeduplicatedAcrossProviders() async {
        func make(_ provider: SubtitleProviderID, _ id: String) -> SubtitleResult {
            SubtitleResult(provider: provider, providerSubtitleID: id, title: "葬送的芙莉莲", fileName: "Frieren - 14.chs.ass",
                           languages: [.simplifiedChinese], format: .ass, episode: 14, basis: .title, downloadContext: id)
        }
        let manager = SubtitleManager(providers: [
            StaticSubtitleProvider(id: .assrt, results: [make(.assrt, "a"), make(.assrt, "b")]),
            StaticSubtitleProvider(id: .subdl, results: [make(.subdl, "c")])
        ])
        let report = await manager.search(query)
        // Two uploads on one site stay; the other site's mirror is dropped.
        #expect(report.ranked.count == 2)
        #expect(Set(report.ranked.map(\.result.provider)) == [.assrt])
    }

    @Test func downloadPreparesAndCachesAsUTF8() async throws {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let text = "[Script Info]\nScriptType: v4.00+\n\n[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,这个时间我们还没有说过，你来对了。这个时间我们还没有说过。\n"
        let result = SubtitleResult(provider: .assrt, providerSubtitleID: "9", title: "葬送的芙莉莲", releaseName: "[LoliHouse] Sousou no Frieren - 14 [WebRip 1080p]",
                                    languages: [.chinese], format: .ass, episode: 14, basis: .title, downloadContext: "9")
        let manager = SubtitleManager(providers: [
            StaticSubtitleProvider(id: .assrt, results: [result], files: [
                SubtitleDownloadedFile(name: "sub.zip", data: TestZip.make([("Frieren - 14.ass", text.data(using: gb18030)!), ("font.otf", Data([1, 2]))]))
            ])
        ])
        let prepared = try await manager.download(result, for: video)
        #expect(prepared.sourceEncoding == .gb18030)
        #expect(prepared.language == .simplifiedChinese)

        let root = FileManager.default.temporaryDirectory.appending(path: "subtitle-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SubtitleCacheStore(root: root)
        let animeID = UUID()
        let scored = ScoredSubtitle(result: result, score: SubtitleMatchScorer().score(result, for: video))
        let record = try store.store(prepared, for: scored, video: video, videoKey: "media:x", animeID: animeID, isAutomatic: true)
        #expect(record.relativePath == "\(animeID.uuidString)/S01E14/assrt-9.ass")
        #expect(try String(contentsOf: store.url(for: record), encoding: .utf8) == text)
        #expect(FileManager.default.fileExists(atPath: store.fontsDirectory.appending(path: "font.otf").path))
        #expect(record.language == .simplifiedChinese)
        #expect(record.releaseGroup == "LoliHouse")
        #expect(store.diskUsage() > 0)

        try Data("{}".utf8).write(to: store.idMappingURL)
        store.removeAll()
        #expect(!FileManager.default.fileExists(atPath: store.url(for: record).path))
        #expect(FileManager.default.fileExists(atPath: store.idMappingURL.path))
    }
}

struct SubtitleDownloadDatabaseTests {
    func record(_ id: String, key: String = "media:A", active: Bool = true) -> SubtitleDownloadRecord {
        SubtitleDownloadRecord(
            videoKey: key, animeID: nil, provider: .assrt, providerSubtitleID: id,
            language: .simplifiedChinese, format: .ass, releaseGroup: "LoliHouse", source: "WEB",
            releaseName: "x", fileName: "x.ass", relativePath: "unlinked/S01E14/assrt-\(id).ass",
            matchScore: 0.9, isAutomatic: true, isActive: active, videoFileName: "v.mkv"
        )
    }

    @Test func keepsOneActiveSubtitlePerVideo() async throws {
        let database = try LibraryDatabase(inMemory: true)
        try await database.saveSubtitleDownload(record("1"))
        try await database.saveSubtitleDownload(record("2"))
        try await database.saveSubtitleDownload(record("3", key: "media:B"))
        var saved = try await database.subtitleDownloads(videoKey: "media:A")
        #expect(saved.count == 2)
        #expect(saved.filter(\.isActive).map(\.providerSubtitleID) == ["2"])
        #expect(saved.first?.providerSubtitleID == "2")

        try await database.setActiveSubtitleDownload(id: saved.last?.id, videoKey: "media:A")
        saved = try await database.subtitleDownloads(videoKey: "media:A")
        #expect(saved.first?.providerSubtitleID == "1")
        #expect(saved.first?.isActive == true)

        try await database.setActiveSubtitleDownload(id: nil, videoKey: "media:A")
        #expect(try await database.subtitleDownloads(videoKey: "media:A").allSatisfy { !$0.isActive })
        // B is untouched throughout.
        #expect(try await database.subtitleDownloads(videoKey: "media:B").first?.isActive == true)

        try await database.removeSubtitleDownloads(videoKey: "media:A")
        #expect(try await database.subtitleDownloads(videoKey: "media:A").isEmpty)
        #expect(try await database.allSubtitleDownloads().count == 1)
    }

    @Test func redownloadingUpdatesInsteadOfDuplicating() async throws {
        let database = try LibraryDatabase(inMemory: true)
        try await database.saveSubtitleDownload(record("1"))
        var again = record("1")
        again.matchScore = 0.5
        try await database.saveSubtitleDownload(again)
        let saved = try await database.subtitleDownloads(videoKey: "media:A")
        #expect(saved.count == 1)
        #expect(saved.first?.matchScore == 0.5)
    }
}
