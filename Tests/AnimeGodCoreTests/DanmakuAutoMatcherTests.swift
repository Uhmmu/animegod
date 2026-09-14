import Foundation
import Testing
@testable import AnimeGodCore

@Suite struct DanmakuAutoMatcherTests {
    @Test func buildsDistinctCleanQueriesWithoutPastingReleaseNoise() {
        let context = DanmakuSearchContext(
            titleCandidates: [
                "孤独摇滚！",
                "Bocchi the Rock!",
                "[SubsPlease] Bocchi the Rock! 1080p HEVC",
                "bocchi the rock"
            ],
            episodeNumber: 8,
            episodeKind: .regular
        )

        let queries = DanmakuAutoMatcher.searchQueries(for: context)

        #expect(queries == ["孤独摇滚！", "Bocchi the Rock!"])
        #expect(queries.allSatisfy { !$0.localizedCaseInsensitiveContains("1080p") })
        #expect(queries.allSatisfy { !$0.localizedCaseInsensitiveContains("HEVC") })
    }

    @Test func ranksTheRequestedEpisodeAboveAdjacentEpisodes() throws {
        let anime = DanmakuSearchedAnime(
            animeID: 8001,
            animeTitle: "孤独摇滚！",
            typeDescription: "TV动画",
            episodes: [
                DanmakuSearchedEpisode(episodeID: 101, episodeTitle: "第7话 君之家"),
                DanmakuSearchedEpisode(episodeID: 102, episodeTitle: "第8话 孤独摇滚"),
                DanmakuSearchedEpisode(episodeID: 103, episodeTitle: "第9话 江之岛电梯")
            ]
        )
        let context = DanmakuSearchContext(
            titleCandidates: ["孤独摇滚！", "Bocchi the Rock!"],
            episodeNumber: 8,
            episodeKind: .regular
        )

        let ranked = DanmakuAutoMatcher.rank(
            responses: [DanmakuSearchResponse(query: "孤独摇滚！", queryIndex: 0, anime: [anime])],
            context: context
        )

        #expect(try #require(ranked.first).episode.episodeID == 102)
        #expect(ranked.map(\.episode.episodeID).prefix(3) == [102, 101, 103])
    }

    @Test func metadataAliasBeatsAProviderResultThatOnlySharesEpisodeNumber() throws {
        let expected = DanmakuSearchedAnime(
            animeID: 1,
            animeTitle: "葬送的芙莉莲",
            typeDescription: "TV动画",
            episodes: [DanmakuSearchedEpisode(episodeID: 11, episodeTitle: "第12话 真正的勇者")]
        )
        let unrelated = DanmakuSearchedAnime(
            animeID: 2,
            animeTitle: "勇者斗恶龙",
            typeDescription: "TV动画",
            episodes: [DanmakuSearchedEpisode(episodeID: 22, episodeTitle: "第12话")]
        )
        let context = DanmakuSearchContext(
            titleCandidates: ["葬送的芙莉莲"],
            episodeNumber: 12,
            episodeKind: .regular
        )

        let ranked = DanmakuAutoMatcher.rank(
            responses: [DanmakuSearchResponse(
                query: "葬送的芙莉莲",
                queryIndex: 0,
                anime: [unrelated, expected]
            )],
            context: context
        )

        #expect(try #require(ranked.first).anime.animeID == expected.animeID)
    }

    @Test func specialRequestPrefersSpecialOverRegularEpisodeWithSameNumber() throws {
        let anime = DanmakuSearchedAnime(
            animeID: 9,
            animeTitle: "Example",
            typeDescription: "TV动画",
            episodes: [
                DanmakuSearchedEpisode(episodeID: 91, episodeTitle: "第1话"),
                DanmakuSearchedEpisode(episodeID: 92, episodeTitle: "SP 1 特别篇")
            ]
        )
        let context = DanmakuSearchContext(
            titleCandidates: ["Example"],
            episodeNumber: 1,
            episodeKind: .special
        )

        let ranked = DanmakuAutoMatcher.rank(
            responses: [DanmakuSearchResponse(query: "Example", queryIndex: 0, anime: [anime])],
            context: context
        )

        #expect(try #require(ranked.first).episode.episodeID == 92)
    }
}
