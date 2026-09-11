import Foundation
import Testing
@testable import AnimeGodCore

@Suite(.serialized)
struct BangumiMetadataProviderTests {
    @Test func mapsShoutboxCommentsAlongsideLegacyCommunity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BangumiURLProtocol.self]
        let provider = BangumiMetadataProvider(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://api.example.test")!,
            commentsBaseURL: URL(string: "https://next.example.test")!
        )

        let posts = try await provider.communityPosts(externalID: "123")
        let shout = try #require(posts.first { $0.kind == .shoutbox })
        #expect(shout.postID == "99")
        #expect(shout.author == "测试用户")
        #expect(shout.body == "很喜欢这部电影。")
        #expect(shout.rating == 8)
        #expect(shout.url.absoluteString == "https://bgm.tv/subject/123/comments#likes_grid_99")
        #expect(posts.contains { $0.kind == .review })
        #expect(posts.contains { $0.kind == .discussion })
        #expect(BangumiURLProtocol.requestedPaths.contains("/p1/subjects/123/comments"))
    }

    /// Opt-in because package tests should remain deterministic when offline.
    @Test func liveBangumiContractSmokeTest() async throws {
        guard ProcessInfo.processInfo.environment["ANIMEGOD_LIVE_TESTS"] == "1" else { return }
        let provider = BangumiMetadataProvider()

        let candidates = try await provider.search("BanG Dream! It's MyGO!!!!!", limit: 3)
        let match = try #require(candidates.first { $0.externalID == "428735" })
        #expect(match.posterURL?.scheme == "https")

        let metadata = try await provider.metadata(externalID: match.externalID, animeID: UUID())
        #expect(metadata.score != nil)
        #expect(!metadata.summary.isEmpty)

        // Subjects edited without a studio field return none rather than
        // crediting the production committee ("製作") as the studio; entries
        // that do carry the field must surface it.
        #expect(metadata.studios == nil || metadata.studios!.allSatisfy { !$0.isEmpty })
        let juuni = try await provider.metadata(externalID: "12", animeID: UUID())
        #expect(juuni.studios == ["MADHOUSE"])
        #expect(juuni.kind == .tv)

        let posts = try await provider.communityPosts(externalID: match.externalID)
        #expect(posts.contains { $0.kind == .shoutbox })
        #expect(posts.contains { $0.kind == .review })
        #expect(posts.contains { $0.kind == .discussion })
        #expect(posts.allSatisfy { $0.url.scheme == "https" })
    }
}

private final class BangumiURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requestedPaths.append(request.url?.path ?? "")
        let json: String
        if request.url?.path == "/p1/subjects/123/comments" {
            json = #"{"data":[{"id":99,"user":{"username":"tester","nickname":"测试用户"},"rate":8,"comment":"很喜欢这部电影。","updatedAt":1700000000}],"total":1}"#
        } else {
            json = #"{"topic":[{"id":7,"url":"http://bgm.tv/subject/topic/7","title":"讨论","replies":2,"timestamp":1690000000,"user":{"username":"topic-user"}}],"blog":[{"id":8,"url":"http://bgm.tv/blog/8","title":"长评","summary":"摘要","replies":3,"timestamp":1680000000,"user":{"nickname":"作者"}}]}"#
        }
        let data = Data(json.utf8)
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
