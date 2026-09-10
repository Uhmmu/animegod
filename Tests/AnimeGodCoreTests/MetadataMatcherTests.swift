import Foundation
import Testing
@testable import AnimeGodCore

struct MetadataMatcherTests {
    private let matcher = MetadataMatcher()

    @Test func linksTheStrongestCandidateAutomatically() {
        let candidates = [
            candidate(id: "1", title: "言叶之庭", original: "言の葉の庭"),
            candidate(id: "2", title: "言叶之庭 电影原声", original: "言の葉の庭 OST")
        ]
        guard case let .automatic(best) = matcher.decide(localTitle: "言叶之庭", candidates: candidates) else {
            Issue.record("expected an automatic link for a clear best candidate")
            return
        }
        #expect(best.candidate.externalID == "1")
        #expect(best.score == 1)
    }

    @Test func partialOverlapsStillLinkByDefault() {
        let candidates = [candidate(id: "1", title: "Made in Abyss", original: "メイドインアビス")]
        guard case let .automatic(best) = matcher.decide(localTitle: "Made in Abyss Movie", candidates: candidates) else {
            Issue.record("expected a best-effort automatic link for a partial overlap")
            return
        }
        #expect(best.candidate.externalID == "1")
        #expect(best.score == 0.86)
    }

    @Test func equallyStrongDuplicatesLinkTheFirst() {
        let candidates = [
            candidate(id: "2", title: "Fruits Basket", original: "フルーツバスケット 2019"),
            candidate(id: "1", title: "Fruits Basket", original: "フルーツバスケット")
        ]
        guard case let .automatic(best) = matcher.decide(localTitle: "Fruits Basket", candidates: candidates) else {
            Issue.record("expected the strongest candidate to link by default")
            return
        }
        #expect(best.candidate.externalID == "1")
    }

    @Test func weakButPlausibleHitsWaitForReview() {
        let candidates = [candidate(id: "1", title: "Alpha Beta Gamma Zeta Eta", original: "αβγ")]
        // Token overlap 3/7 → ~0.34: plausible enough to review, too weak to auto-link.
        guard case let .review(ranked) = matcher.decide(localTitle: "Alpha Beta Gamma Chi Omega", candidates: candidates) else {
            Issue.record("expected a review tier for a weak best candidate")
            return
        }
        #expect(ranked.first?.candidate.externalID == "1")
    }

    @Test func rejectsUnrelatedCandidatesEntirely() {
        let candidates = [candidate(id: "1", title: "Made in Abyss", original: "メイドインアビス")]
        if case .review = matcher.decide(localTitle: "K-On! Movie", candidates: candidates) {
            Issue.record("unrelated candidates must not queue for review")
        }
        if case .automatic = matcher.decide(localTitle: "K-On! Movie", candidates: candidates) {
            Issue.record("unrelated candidates must not auto-link")
        }
    }

    @Test func ranksExactTitleFirst() {
        let candidates = [
            candidate(id: "2", title: "Bocchi the Rock! Special", original: "ぼっち・ざ・ろっく！特別編"),
            candidate(id: "1", title: "Bocchi the Rock!", original: "ぼっち・ざ・ろっく！")
        ]
        let ranked = matcher.rank(localTitle: "Bocchi the Rock!", candidates: candidates)
        #expect(ranked.first?.candidate.externalID == "1")
        #expect(ranked.first!.score > ranked.last!.score)
    }

    private func candidate(id: String, title: String, original: String) -> AnimeMetadataCandidate {
        AnimeMetadataCandidate(
            provider: .bangumi,
            externalID: id,
            title: title,
            originalTitle: original,
            summary: "",
            posterURL: nil,
            airDate: nil,
            score: nil,
            rank: nil,
            ratingCount: nil
        )
    }
}
