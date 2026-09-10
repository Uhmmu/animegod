import Foundation
import Testing
@testable import AnimeGodCore

@Suite(.serialized)
struct TranslationServiceTests {
    @Test func batchesTextsIntoASingleDeepLRequest() async throws {
        DeepLURLProtocol.lastRequestBody = nil
        DeepLURLProtocol.sendCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepLURLProtocol.self]
        let service = DeepLTranslationService(apiKey: "test-key:fx", session: URLSession(configuration: configuration))

        let results = try await service.translate(["Hello", "A patient fantasy"], to: "zh-Hans")

        #expect(results == ["你好", "一场耐心的幻想"])
        #expect(DeepLURLProtocol.sendCount == 1)
        let body = try #require(DeepLURLProtocol.lastRequestBody)
        #expect(body.text.count == 2)
        #expect(body.targetLang == "ZH")
        // Free keys must reach the free endpoint.
        #expect(DeepLURLProtocol.lastRequestURL?.host == "api-free.deepl.com")
        #expect(DeepLURLProtocol.lastAuthorization == "DeepL-Auth-Key test-key:fx")
    }

    @Test func rejectsMismatchedResultCounts() async {
        DeepLMismatchURLProtocol.lastRequestURL = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepLMismatchURLProtocol.self]
        let service = DeepLTranslationService(apiKey: "pro-key", session: URLSession(configuration: configuration))

        await #expect(throws: TranslationError.self) {
            _ = try await service.translate(["a", "b"], to: "zh-Hans")
        }
        // Pro keys (no ":fx") must reach the pro endpoint.
        #expect(DeepLMismatchURLProtocol.lastRequestURL?.host == "api.deepl.com")
    }

    @Test func cachesAndReusesTranslationsPerProviderAndLanguage() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let texts = ["Original review body", "Another review body"]
        #expect(try await database.cachedTranslations(provider: "deepl", targetLanguage: "zh-Hans", texts: texts).isEmpty)

        try await database.saveTranslations(provider: "deepl", targetLanguage: "zh-Hans", pairs: [
            (texts[0], "原始评论正文")
        ])

        let cached = try await database.cachedTranslations(provider: "deepl", targetLanguage: "zh-Hans", texts: texts)
        #expect(cached[0] == "原始评论正文")
        #expect(cached[1] == nil)
        // A different target language must not leak between caches.
        let other = try await database.cachedTranslations(provider: "deepl", targetLanguage: "en", texts: texts)
        #expect(other.isEmpty)
    }

    @Test func persistsPostTranslationsBesideOriginalText() async throws {
        let context = try await makeTranslatedPostLibrary()
        try await context.database.saveCommunityPostTranslations(
            animeID: context.animeID,
            provider: .anilist,
            translationsByPostID: ["review-1": (title: "译文标题", body: "译文正文")]
        )

        let posts = try await context.database.communityPosts(animeID: context.animeID, provider: .anilist)
        let post = try #require(posts.first { $0.postID == "review-1" })
        // Original content stays intact; translation sits beside it.
        #expect(post.title == "Original Title")
        #expect(post.body == "Full original body")
        #expect(post.translatedTitle == "译文标题")
        #expect(post.translatedBody == "译文正文")
    }
}

private extension TranslationServiceTests {
    struct Context {
        let database: LibraryDatabase
        let animeID: UUID
    }

    func makeTranslatedPostLibrary() async throws -> Context {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Anime", lastKnownPath: "/Anime")
        try await database.save(root: root)
        let animeID = UUID()
        // The anime must exist before metadata can reference it.
        let file = ScannedMediaFile(
            relativePath: "Show/01.mkv",
            fileSize: 1,
            modifiedAt: .now,
            parsed: ParsedAnimeFilename(title: "Show", episode: 1, episodeText: "01", confidence: 0.9)
        )
        try await database.importScan(.init(root: root, files: [file], skippedUnreadableCount: 0))
        let anime = try #require(await database.library().first?.anime)
        let metadata = AnimeMetadata(
            animeID: anime.id, provider: .anilist, externalID: "500",
            title: "Show", originalTitle: "Show", summary: "", posterURL: nil,
            airDate: nil, platform: nil, score: nil, rank: nil, ratingCount: nil
        )
        let post = CommunityPost(
            provider: .anilist, externalID: "500", postID: "review-1", kind: .review,
            title: "Original Title", summary: "Original", url: URL(string: "https://anilist.co/review/1")!,
            author: "User", replyCount: 0, publishedAt: .now, body: "Full original body", originalLanguage: "en"
        )
        try await database.save(metadata: metadata, communityPosts: [post], matchConfidence: 1, isManualMatch: true)
        return Context(database: database, animeID: anime.id)
    }
}

private final class DeepLURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequestBody: Body?
    nonisolated(unsafe) static var lastRequestURL: URL?
    nonisolated(unsafe) static var lastAuthorization: String?
    nonisolated(unsafe) static var sendCount = 0

    struct Body: Decodable {
        let text: [String]
        let targetLang: String

        enum CodingKeys: String, CodingKey {
            case text
            case targetLang = "target_lang"
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.sendCount += 1
        Self.lastRequestURL = request.url
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.lastRequestBody = try? JSONDecoder().decode(Body.self, from: data)
        }
        let json = #"{"translations":[{"detected_source_language":"EN","text":"你好"},{"detected_source_language":"EN","text":"一场耐心的幻想"}]}"#
        let data = Data(json.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class DeepLMismatchURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequestURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastRequestURL = request.url
        let json = #"{"translations":[{"detected_source_language":"EN","text":"only one"}]}"#
        let data = Data(json.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
