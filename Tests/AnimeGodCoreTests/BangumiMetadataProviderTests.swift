import Foundation
import Testing
@testable import AnimeGodCore

struct BangumiMetadataProviderTests {
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
        #expect(posts.contains { $0.kind == .review })
        #expect(posts.contains { $0.kind == .discussion })
        #expect(posts.allSatisfy { $0.url.scheme == "https" })
    }
}
