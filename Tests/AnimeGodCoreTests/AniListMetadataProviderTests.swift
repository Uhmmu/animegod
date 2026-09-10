import Foundation
import Testing
@testable import AnimeGodCore

@Suite(.serialized)
struct AniListMetadataProviderTests {
    @Test func mapsSearchMetadataCrossIDsAndReviews() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AniListURLProtocol.self]
        let provider = AniListMetadataProvider(
            session: URLSession(configuration: configuration),
            endpoint: URL(string: "https://example.test/graphql")!
        )

        let candidates = try await provider.search("Frieren", limit: 3)
        let candidate = try #require(candidates.first)
        #expect(candidate.provider == .anilist)
        #expect(candidate.externalID == "154587")
        #expect(candidate.title == "Frieren: Beyond Journey's End")
        #expect(candidate.score == 9.1)

        let animeID = UUID()
        let metadata = try await provider.metadata(externalID: candidate.externalID, animeID: animeID)
        #expect(metadata.animeID == animeID)
        #expect(metadata.externalReferences == [.init(provider: .myAnimeList, externalID: "52991")])
        #expect(metadata.summary == "A ten-year adventure ends.")
        #expect(metadata.sourceURL?.host == "anilist.co")

        let reviews = try await provider.communityPosts(externalID: candidate.externalID)
        let review = try #require(reviews.first)
        #expect(review.provider == .anilist)
        #expect(review.author == "fern")
        #expect(review.body == "Thoughtful and beautiful.")
        #expect(review.originalLanguage == "en")
    }

    @Test func exposesGraphQLErrorsAsServiceMessages() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AniListErrorURLProtocol.self]
        let provider = AniListMetadataProvider(session: URLSession(configuration: configuration))

        await #expect(throws: MetadataProviderError.self) {
            _ = try await provider.search("Unavailable", limit: 1)
        }
    }
}

private final class AniListURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var callCount = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let call = Self.callCount
        Self.callCount += 1
        let json: String
        if call == 2 {
            json = #"{"data":{"Page":{"reviews":[{"id":7,"summary":"A patient fantasy","body":"Thoughtful and <b>beautiful</b>.","ratingAmount":42,"createdAt":1700000000,"siteUrl":"https://anilist.co/review/7","user":{"name":"fern"}}]}}}"#
        } else if call == 1 {
            json = #"{"data":{"Media":{"id":154587,"idMal":52991,"title":{"romaji":"Sousou no Frieren","english":"Frieren: Beyond Journey's End","native":"葬送のフリーレン"},"description":"A ten-year <i>adventure</i> ends.","coverImage":{"extraLarge":"https://s4.anilist.co/file.jpg"},"startDate":{"year":2023,"month":9,"day":29},"format":"TV","averageScore":91,"popularity":500000,"siteUrl":"https://anilist.co/anime/154587","rankings":[{"rank":1,"type":"RATED","allTime":true}]}}}"#
        } else {
            json = #"{"data":{"Page":{"media":[{"id":154587,"idMal":52991,"title":{"romaji":"Sousou no Frieren","english":"Frieren: Beyond Journey's End","native":"葬送のフリーレン"},"description":"A fantasy.","coverImage":{"extraLarge":"https://s4.anilist.co/file.jpg"},"startDate":{"year":2023,"month":9,"day":29},"format":"TV","averageScore":91,"popularity":500000,"siteUrl":"https://anilist.co/anime/154587","rankings":[{"rank":1,"type":"RATED","allTime":true}] }]}}}"#
        }
        let data = Data(json.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class AniListErrorURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let data = Data(#"{"data":null,"errors":[{"message":"Service temporarily unavailable"}]}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
