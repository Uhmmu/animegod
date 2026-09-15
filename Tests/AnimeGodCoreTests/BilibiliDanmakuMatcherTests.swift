import Foundation
import Testing
@testable import AnimeGodCore

@Suite struct BilibiliDanmakuMatcherTests {
    private func context(
        titles: [String],
        episode: Double? = 1,
        duration: Double? = nil,
        season: Int? = nil,
        kind: EpisodeKind = .regular
    ) -> BilibiliDanmakuMatcher.Context {
        BilibiliDanmakuMatcher.Context(
            titleCandidates: titles, episodeNumber: episode,
            episodeKind: kind, duration: duration, seasonNumber: season
        )
    }

    private func bangumi(_ title: String, seasonID: Int64 = 1, original: String = "", episodes: Int? = 12) -> BilibiliSearchHit {
        .bangumi(BilibiliSearchBangumi(
            seasonID: seasonID, mediaID: seasonID, title: title,
            originalTitle: original, seasonTypeName: "番剧", episodeCount: episodes
        ))
    }

    private func video(_ title: String, aid: Int64 = 100, duration: Double? = nil) -> BilibiliSearchHit {
        .video(BilibiliSearchVideo(
            aid: aid, bvid: "BV1\(aid)", title: title, author: "uploader",
            typeName: "动画", duration: duration
        ))
    }

    @Test func prefersTheLicensedSeasonOverReuploadsAndClips() {
        let hits = [
            video("【混剪】BanG Dream! YUME∞MITA 高燃AMV", aid: 7),
            bangumi("BanG Dream! Ave Mujica", seasonID: 55),
            bangumi("BanG Dream! YUME∞MITA", seasonID: 42),
            video("BanG Dream! YUME∞MITA 第1集 反应视频", aid: 8)
        ]
        let ranked = BilibiliDanmakuMatcher.rankHits(hits, context: context(titles: ["BanG Dream! YUME∞MITA"]))

        guard case let .bangumi(best) = ranked.first?.hit else {
            Issue.record("expected a licensed season to rank first")
            return
        }
        #expect(best.seasonID == 42)
    }

    @Test func matchesTheJapaneseTitleWhenTheLibraryOnlyKnowsThat() {
        let hits = [bangumi("孤独摇滚！", seasonID: 3, original: "ぼっち・ざ・ろっく！")]
        let ranked = BilibiliDanmakuMatcher.rankHits(hits, context: context(titles: ["ぼっち・ざ・ろっく！"]))
        #expect(ranked.first != nil)
        #expect((ranked.first?.score ?? 0) > 0.6)
    }

    @Test func penalizesTheWrongSeasonOfTheSameWork() {
        let first = BilibiliDanmakuMatcher.hitScore(
            bangumi("某科学的超电磁炮", seasonID: 1),
            context: context(titles: ["某科学的超电磁炮"], season: 3)
        )
        let third = BilibiliDanmakuMatcher.hitScore(
            bangumi("某科学的超电磁炮 第三季", seasonID: 3),
            context: context(titles: ["某科学的超电磁炮"], season: 3)
        )
        #expect(third > first)
    }

    @Test func picksTheRequestedEpisodeAndCarriesItsOwnCID() {
        let season = BilibiliBangumiSeason(
            seasonID: 42, title: "BanG Dream! YUME∞MITA", seasonTypeName: "番剧",
            episodes: (1...12).map { number in
                BilibiliBangumiEpisode(
                    episodeID: 1_000 + Int64(number), aid: 900 + Int64(number), bvid: "BV1x\(number)",
                    cid: 5_000 + Int64(number), title: "\(number)", longTitle: "第\(number)话",
                    duration: 1_440
                )
            }
        )
        let candidates = BilibiliDanmakuMatcher.rankSeasonEpisodes(
            season, seasonScore: 1, context: context(titles: ["BanG Dream! YUME∞MITA"], episode: 7)
        )
        let best = try? #require(BilibiliDanmakuMatcher.rank(candidates).first)
        #expect(best?.cid == 5_007)
        #expect(best?.aid == 907)
        #expect(best?.seasonID == 42)
        #expect(best?.episodeNumber == 7)
        #expect((best?.score ?? 0) >= BilibiliDanmakuMatcher.automaticSelectionThreshold)
    }

    @Test func multiPartUploadsResolveToThePartsOwnCIDNotTheTopLevelOne() {
        // The whole point of expanding pages[]: every part has its own
        // danmaku pool, and the submission's first cid is not episode 5's.
        let video = BilibiliVideo(
            aid: 777, bvid: "BV1multi", title: "某番 合集 01-12", duration: 17_280,
            parts: (1...12).map { page in
                BilibiliVideoPart(cid: 8_000 + Int64(page), page: page, title: "第\(page)话", duration: 1_440)
            },
            typeName: "动画"
        )
        let candidates = BilibiliDanmakuMatcher.rankVideoParts(
            video, videoScore: 0.9, context: context(titles: ["某番"], episode: 5, duration: 1_440)
        )
        let best = try? #require(BilibiliDanmakuMatcher.rank(candidates).first)
        #expect(best?.cid == 8_005)
        #expect(best?.aid == 777)
        #expect(best?.episodeTitle == "第5话")
    }

    @Test func durationBreaksTiesBetweenOtherwiseEqualParts() {
        // Two parts claim to be episode 1; only one is a full episode.
        let video = BilibiliVideo(
            aid: 5, bvid: "BV1tie", title: "某番", duration: 1_600,
            parts: [
                BilibiliVideoPart(cid: 11, page: 1, title: "第1话 预告", duration: 90),
                BilibiliVideoPart(cid: 12, page: 2, title: "第1话", duration: 1_430)
            ],
            typeName: "动画"
        )
        let candidates = BilibiliDanmakuMatcher.rankVideoParts(
            video, videoScore: 0.9, context: context(titles: ["某番"], episode: 1, duration: 1_425)
        )
        #expect(BilibiliDanmakuMatcher.rank(candidates).first?.cid == 12)
    }

    @Test func aWeakTitleMatchStaysBelowTheAutomaticThreshold() {
        // Offered for manual confirmation, never bound on its own: another
        // show's comments over the video is worse than no danmaku.
        let season = BilibiliBangumiSeason(
            seasonID: 9, title: "完全不相干的作品", seasonTypeName: "番剧",
            episodes: [BilibiliBangumiEpisode(
                episodeID: 1, aid: 1, bvid: "BV1", cid: 99, title: "1", longTitle: "", duration: 1_400
            )]
        )
        let score = BilibiliDanmakuMatcher.hitScore(
            bangumi("完全不相干的作品", seasonID: 9),
            context: context(titles: ["BanG Dream! YUME∞MITA"])
        )
        let candidates = BilibiliDanmakuMatcher.rankSeasonEpisodes(season, seasonScore: score, context: context(titles: ["BanG Dream! YUME∞MITA"]))
        #expect((candidates.first?.score ?? 1) < BilibiliDanmakuMatcher.automaticSelectionThreshold)
    }

    @Test func aPerfectEpisodeNumberCannotRescueAMediocreTitle() {
        // Every season has an episode 1, so the episode match must not be
        // able to carry a sibling season over the auto-selection bar.
        let sibling = BilibiliDanmakuMatcher.hitScore(
            bangumi("BanG Dream! Ave Mujica", seasonID: 55),
            context: context(titles: ["BanG Dream! YUME∞MITA"], duration: 1_440)
        )
        let capped = BilibiliDanmakuMatcher.combine(sourceScore: sibling, episodeScore: 1)
        #expect(capped < BilibiliDanmakuMatcher.automaticSelectionThreshold)

        // The real season still clears it comfortably.
        let correct = BilibiliDanmakuMatcher.hitScore(
            bangumi("BanG Dream! YUME∞MITA", seasonID: 42),
            context: context(titles: ["BanG Dream! YUME∞MITA"], duration: 1_440)
        )
        #expect(BilibiliDanmakuMatcher.combine(sourceScore: correct, episodeScore: 1)
                >= BilibiliDanmakuMatcher.automaticSelectionThreshold)
    }

    @Test func segmentCountFollowsTheSixMinuteSegmentSize() {
        #expect(BilibiliAPIClient.segmentCount(forDuration: 0) == 1)
        #expect(BilibiliAPIClient.segmentCount(forDuration: 359) == 1)
        #expect(BilibiliAPIClient.segmentCount(forDuration: 360) == 1)
        #expect(BilibiliAPIClient.segmentCount(forDuration: 361) == 2)
        // A 24-minute episode: four segments.
        #expect(BilibiliAPIClient.segmentCount(forDuration: 1_440) == 4)
        // A two-hour film.
        #expect(BilibiliAPIClient.segmentCount(forDuration: 7_200) == 20)
        // Nonsense durations cannot turn into hundreds of requests.
        #expect(BilibiliAPIClient.segmentCount(forDuration: 9_999_999) == BilibiliAPIClient.maximumSegments)
    }

    @Test func parsesSearchDurationsAndStripsHighlightMarkup() {
        #expect(BilibiliSearchMarkup.strip("<em class=\"keyword\">孤独</em>摇滚！") == "孤独摇滚！")
        #expect(BilibiliSearchMarkup.strip("A &amp; B") == "A & B")
        #expect(BilibiliSearchMarkup.seconds(fromClock: "23:40") == 1_420)
        #expect(BilibiliSearchMarkup.seconds(fromClock: "1:02:03") == 3_723)
        #expect(BilibiliSearchMarkup.seconds(fromClock: "nonsense") == nil)
    }

    @Test func recognizesSeasonMarkersInEverySpelling() {
        #expect(DanmakuTitleSimilarity.seasonNumber(in: "Re:Zero Season 2") == 2)
        #expect(DanmakuTitleSimilarity.seasonNumber(in: "某番 第三季") == 3)
        #expect(DanmakuTitleSimilarity.seasonNumber(in: "Show S04") == 4)
        #expect(DanmakuTitleSimilarity.seasonNumber(in: "No marker here") == nil)
    }
}
