import Foundation
import Testing
@testable import AnimeGodCore

/// Intercepts URLSession traffic so provider tests never touch the live
/// dandanplay API.
final class DanmakuMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequestHeaders: [String: String]?
    nonisolated(unsafe) static var lastRequestBody: Data?
    nonisolated(unsafe) static var lastRequestURL: URL?

    static func reset() {
        handler = nil
        lastRequestHeaders = nil
        lastRequestBody = nil
        lastRequestURL = nil
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DanmakuMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestHeaders = request.allHTTPHeaderFields
        Self.lastRequestBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }
        Self.lastRequestURL = request.url
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

func httpResponse(_ url: URL?, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url ?? URL(string: "https://api.dandanplay.net")!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

@Suite(.serialized)
struct DandanplayProviderTests {
    private func makeProvider() -> DandanplayDanmakuProvider {
        DandanplayDanmakuProvider(
            credentials: .signature(appID: "test-app", appSecret: "test-secret"),
            session: DanmakuMockURLProtocol.makeSession()
        )
    }

    // MARK: - Comment parsing

    @Test func parsesCommentsWithSubSecondPrecisionModesAndColors() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            let json = """
            {"success":true,"errorCode":0,"count":5,"comments":[
              {"cid":1,"p":"12.34,1,16777215,1001","m":"前方高能"},
              {"cid":2,"p":"445.6,4,255,1002,0","m":"底部弹幕"},
              {"cid":3,"p":"789.01,5,65535,1003","m":"顶部弹幕"},
              {"cid":4,"p":"0.5,1,16777215,1004","m":"  前后空白  "},
              {"cid":5,"p":"100.99,9,16711680,1005","m":"未知模式"}
            ]}
            """
            return (httpResponse(request.url), Data(json.utf8))
        }
        let comments = try await makeProvider().fetchComments(episodeID: 1001000001)

        // Unknown modes (mode 9) are dropped, not guessed.
        #expect(comments.count == 4)
        #expect(comments[0].time == 12.34)
        #expect(comments[0].mode == .scroll)
        #expect(comments[0].color == 0xFFFFFF)
        #expect(comments[0].senderID == "1001")
        #expect(comments[0].id == "1")
        #expect(comments[1].mode == .bottom)
        #expect(comments[1].color == 255)
        #expect(comments[2].mode == .top)
        #expect(comments[2].color == 65535)
        // Whitespace-only text is dropped; surrounding whitespace trimmed.
        #expect(comments[3].text == "前后空白")
        // The p field may carry a 5th source field; parsing ignores it.
    }

    @Test func dropsMalformedCommentEntriesButKeepsValidOnes() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            let json = """
            {"success":true,"errorCode":0,"count":3,"comments":[
              {"cid":10,"p":"not-a-time,1,16777215,1","m":"x"},
              {"cid":11,"p":"5,1,16777215","m":"too few fields"},
              {"cid":12,"p":"5.5,1,16777215,2","m":"ok"},
              {"cid":13,"p":"5.5,1,16777215,2","m":"   "}
            ]}
            """
            return (httpResponse(request.url), Data(json.utf8))
        }
        let comments = try await makeProvider().fetchComments(episodeID: 1)
        #expect(comments.map(\.id) == ["12"])
    }

    @Test func emptyCommentListIsNotAnError() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            (httpResponse(request.url), Data(#"{"success":true,"errorCode":0,"count":0,"comments":[]}"#.utf8))
        }
        let comments = try await makeProvider().fetchComments(episodeID: 1)
        #expect(comments.isEmpty)
    }

    @Test func parsesCurrentDirectCommentPayloadWithoutLegacyEnvelope() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            let json = #"{"count":1,"comments":[{"cid":1,"p":"8.5,1,16777215,user","m":"新版响应"}]}"#
            return (httpResponse(request.url), Data(json.utf8))
        }

        let comments = try await makeProvider().fetchComments(episodeID: 160630008)

        #expect(comments.count == 1)
        #expect(comments.first?.text == "新版响应")
    }

    @Test func commentsMissingCollectionsParseAsEmpty() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            (httpResponse(request.url), Data(#"{"success":true,"errorCode":0}"#.utf8))
        }
        let comments = try await makeProvider().fetchComments(episodeID: 1)
        #expect(comments.isEmpty)
    }

    @Test func malformedTopLevelJSONThrowsInvalidResponse() async {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            (httpResponse(request.url), Data("not json at all".utf8))
        }
        await #expect(throws: DanmakuProviderError.self) {
            _ = try await makeProvider().fetchComments(episodeID: 1)
        }
    }

    @Test func businessErrorsSurfaceAsServiceMessages() async {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            let json = #"{"success":false,"errorCode":1,"errorMessage":"服务器内部错误"}"#
            return (httpResponse(request.url), Data(json.utf8))
        }
        do {
            _ = try await makeProvider().fetchComments(episodeID: 1)
            Issue.record("Expected a service message error")
        } catch let error as DanmakuProviderError {
            guard case let .serviceMessage(message) = error else {
                Issue.record("Expected serviceMessage, got \(error)")
                return
            }
            #expect(message.contains("服务器内部错误"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func httpFailuresThrowHTTPStatus() async {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            (httpResponse(request.url, status: 403), Data())
        }
        await #expect(throws: DanmakuProviderError.self) {
            _ = try await makeProvider().fetchComments(episodeID: 1)
        }
    }

    @Test func networkFailuresPropagate() async {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = nil
        await #expect(throws: URLError.self) {
            _ = try await makeProvider().fetchComments(episodeID: 1)
        }
    }

    // MARK: - Match

    @Test func matchSendsFileIdentityAndParsesCandidates() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            let json = """
            {"success":true,"errorCode":0,"isMatched":true,"matches":[
              {"animeId":8001,"animeTitle":"孤独摇滚！","episodeId":10080010001,
               "episodeTitle":"転校生","shift":0.5,"type":"tvseries","typeDescription":"TV动画"}
            ]}
            """
            return (httpResponse(request.url), Data(json.utf8))
        }
        let result = try await makeProvider().match(
            fileName: "[SubsPlease] Bocchi the Rock - 01 (1080p).mkv",
            fileHash: "658d05841b9476ccc7420b3f0bb21c3b",
            fileSize: 1_433_106_953,
            videoDuration: 1_420.5
        )

        #expect(result.isMatched)
        let best = try #require(result.best)
        #expect(best.animeID == 8001)
        #expect(best.animeTitle == "孤独摇滚！")
        #expect(best.episodeID == 10080010001)
        #expect(best.shift == 0.5)

        // The request carries the documented file identity fields.
        let body = try #require(DanmakuMockURLProtocol.lastRequestBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["fileName"] as? String == "[SubsPlease] Bocchi the Rock - 01 (1080p).mkv")
        #expect(payload["fileHash"] as? String == "658d05841b9476ccc7420b3f0bb21c3b")
        #expect(payload["fileSize"] as? Int == 1_433_106_953)
        #expect(payload["videoDuration"] as? Int == 1421)
        #expect(payload["matchMode"] as? String == "hashAndFileName")
        #expect(DanmakuMockURLProtocol.lastRequestURL?.path == "/api/v2/match")
    }

    @Test func unmatchedFilesReportNoCandidates() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            let json = #"{"success":true,"errorCode":0,"isMatched":false,"matches":null}"#
            return (httpResponse(request.url), Data(json.utf8))
        }
        let result = try await makeProvider().match(fileName: "unknown.mkv", fileHash: "abc", fileSize: 1, videoDuration: 100)
        #expect(!result.isMatched)
        #expect(result.candidates.isEmpty)
    }

    @Test func fileNameOnlyMatchOmitsHashMode() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            let json = #"{"success":true,"errorCode":0,"isMatched":false,"matches":[]}"#
            return (httpResponse(request.url), Data(json.utf8))
        }
        _ = try await makeProvider().match(fileName: "x.mkv", fileHash: nil, fileSize: nil, videoDuration: nil)
        let body = try #require(DanmakuMockURLProtocol.lastRequestBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["matchMode"] as? String == "fileNameOnly")
        #expect(payload["fileHash"] == nil)
        #expect(payload["fileSize"] == nil)
    }

    // MARK: - Search

    @Test func searchParsesAnimeAndEpisodes() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            let json = """
            {"hasMore":false,"success":true,"errorCode":0,"animes":[
              {"animeId":8001,"animeTitle":"孤独摇滚！","type":"tvseries","typeDescription":"TV动画",
               "episodes":[{"episodeId":10080010001,"episodeTitle":"第01话 転校生"},
                            {"episodeId":10080010002,"episodeTitle":"第02话 見習いバンド"}]}
            ]}
            """
            return (httpResponse(request.url), Data(json.utf8))
        }
        let results = try await makeProvider().searchAnime(query: "孤独摇滚")
        #expect(results.count == 1)
        let anime = try #require(results.first)
        #expect(anime.animeTitle == "孤独摇滚！")
        #expect(anime.episodes.count == 2)
        #expect(anime.episodes[1].episodeID == 10080010002)
        let query = DanmakuMockURLProtocol.lastRequestURL?.query ?? ""
        #expect(query.contains("anime="))
    }

    @Test func parsesCurrentDirectSearchPayloadWithoutLegacyEnvelope() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            let json = """
            {"hasMore":false,"animes":[
              {"animeId":16063,"animeTitle":"孤独摇滚！","type":"tvseries","typeDescription":"TV动画",
               "episodes":[{"episodeId":160630008,"episodeTitle":"第8话 孤独摇滚"}]}
            ]}
            """
            return (httpResponse(request.url), Data(json.utf8))
        }

        let results = try await makeProvider().searchAnime(query: "孤独摇滚")

        #expect(results.first?.animeID == 16063)
        #expect(results.first?.episodes.first?.episodeID == 160630008)
    }

    @Test func emptySearchResultsParseAsEmpty() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            (httpResponse(request.url), Data(#"{"hasMore":false,"success":true,"errorCode":0,"animes":[]}"#.utf8))
        }
        let results = try await makeProvider().searchAnime(query: "不存在的东西")
        #expect(results.isEmpty)
    }

    @Test func incorrectEpisodeMatchFailsGracefully() async throws {
        // Match returns candidates for a different anime entirely — the
        // caller (session) decides; the provider reports what it got.
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            let json = """
            {"success":true,"errorCode":0,"isMatched":true,"matches":[
              {"animeId":9999,"animeTitle":"另一部动画","episodeId":10099990001,"episodeTitle":"第1话"}
            ]}
            """
            return (httpResponse(request.url), Data(json.utf8))
        }
        let result = try await makeProvider().match(fileName: "some file.mkv", fileHash: "ff", fileSize: 10, videoDuration: 10)
        #expect(result.isMatched)
        #expect(result.best?.animeTitle == "另一部动画")
    }

    // MARK: - Authentication

    @Test func signatureHeadersFollowTheDocumentedAlgorithm() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            (httpResponse(request.url), Data(#"{"success":true,"errorCode":0,"count":0,"comments":[]}"#.utf8))
        }
        _ = try await makeProvider().fetchComments(episodeID: 42)

        let headers = try #require(DanmakuMockURLProtocol.lastRequestHeaders)
        #expect(headers["X-AppId"] == "test-app")
        let timestamp = try #require(headers["X-Timestamp"])
        let signature = try #require(headers["X-Signature"])
        // Recompute the documented digest: sha256(AppId + Timestamp + Path + Secret)
        let expected = Data(
            CryptoKitSHA256.hash(data: Data("test-app\(timestamp)/api/v2/comment/42test-secret".utf8))
        ).base64EncodedString()
        #expect(signature == expected)
    }

    @Test func credentialModeSendsAppSecretHeader() async throws {
        DanmakuMockURLProtocol.reset()
        DanmakuMockURLProtocol.handler = { request in
            (httpResponse(request.url), Data(#"{"success":true,"errorCode":0,"count":0,"comments":[]}"#.utf8))
        }
        let provider = DandanplayDanmakuProvider(
            credentials: .credential(appID: "cred-app", appSecret: "cred-secret"),
            session: DanmakuMockURLProtocol.makeSession()
        )
        _ = try await provider.fetchComments(episodeID: 7)
        let headers = try #require(DanmakuMockURLProtocol.lastRequestHeaders)
        #expect(headers["X-AppId"] == "cred-app")
        #expect(headers["X-AppSecret"] == "cred-secret")
        #expect(headers["X-Signature"] == nil)
    }
}

import CryptoKit
typealias CryptoKitSHA256 = CryptoKit.SHA256
