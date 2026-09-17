import Foundation
import Testing
@testable import AnimeGodCore

private func result(
    _ title: String,
    hash: String,
    category: TorrentCategory = .episode,
    team: String? = nil,
    seeders: Int? = nil,
    publishedAt: Date = .now,
    queries: [String] = ["Ave Mujica"]
) -> TorrentSearchResult {
    // A single character stands in for a whole info hash, for readability.
    let hex = hash.count == 40 ? hash : String(repeating: hash, count: 40)
    var observation = TorrentObservation(
        source: .nyaa, title: title, infoHash: TorrentInfoHash(hex)!,
        seeders: seeders, publishedAt: publishedAt, category: category, team: team
    )
    observation.query = queries[0]
    return TorrentResultMerger.merge([observation], queries: queries)[0]
}

struct TorrentSubscriptionMatcherTests {
    private var rule: TorrentSubscription {
        TorrentSubscription(
            title: "Ave Mujica",
            queries: ["Ave Mujica"],
            group: "LoliHouse",
            resolution: "1080p",
            subtitleLanguages: [.simplifiedChinese],
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    @Test func acceptsOnlyReleasesFittingEveryPartOfTheRule() {
        let good = result("[LoliHouse] Ave Mujica - 05 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]", hash: "1", team: "LoliHouse")
        #expect(TorrentSubscriptionMatcher.accepts(good, rule: rule))

        let wrongGroup = result("[Other] Ave Mujica - 05 [1080p][简体内嵌]", hash: "2", team: "Other")
        #expect(!TorrentSubscriptionMatcher.accepts(wrongGroup, rule: rule))

        let wrongResolution = result("[LoliHouse] Ave Mujica - 05 [WebRip 720p][简繁内封]", hash: "3", team: "LoliHouse")
        #expect(!TorrentSubscriptionMatcher.accepts(wrongResolution, rule: rule))

        let wrongLanguage = result("[LoliHouse] Ave Mujica - 05 [WebRip 1080p][日语无字]", hash: "4", team: "LoliHouse")
        #expect(!TorrentSubscriptionMatcher.accepts(wrongLanguage, rule: rule))

        // The relevance guard applies unattended too: a sibling series must
        // never be downloaded automatically.
        let otherShow = result("[LoliHouse] Frieren - 05 [WebRip 1080p][简繁内封]", hash: "5", team: "LoliHouse")
        #expect(!TorrentSubscriptionMatcher.accepts(otherShow, rule: rule))
    }

    @Test func aCollaborationCountsAsTheNamedFansub() {
        // Real releases carry joint names, and indexes disagree about which
        // half they report as the team.
        let joint = result(
            "[喵萌奶茶屋&LoliHouse] Ave Mujica - 05 [WebRip 1080p HEVC-10bit AAC][简繁日内封字幕]",
            hash: "1", team: "喵萌奶茶屋&LoliHouse"
        )
        #expect(TorrentSubscriptionMatcher.accepts(joint, rule: rule))

        // Matching the title's bracket works even when the index reports a
        // different team name.
        let mislabelled = result(
            "[LoliHouse] Ave Mujica - 06 [WebRip 1080p][简繁内封]", hash: "2", team: "Some Uploader"
        )
        #expect(TorrentSubscriptionMatcher.accepts(mislabelled, rule: rule))

        let unrelatedGroup = result("[Nekomoe kissaten] Ave Mujica - 05 [1080p][简繁内封]", hash: "3", team: "Nekomoe kissaten")
        #expect(!TorrentSubscriptionMatcher.accepts(unrelatedGroup, rule: rule))
    }

    @Test func keywordsAndEpisodeFloorNarrowFurther() {
        var rule = self.rule
        rule.excludeKeywords = ["Reseed"]
        rule.includeKeywords = ["WebRip"]
        let reseed = result("[LoliHouse] Ave Mujica - 05 [WebRip 1080p][简繁内封][Reseed]", hash: "1", team: "LoliHouse")
        #expect(!TorrentSubscriptionMatcher.accepts(reseed, rule: rule))
        let bdrip = result("[LoliHouse] Ave Mujica - 05 [BDRip 1080p][简繁内封]", hash: "2", team: "LoliHouse")
        #expect(!TorrentSubscriptionMatcher.accepts(bdrip, rule: rule))

        rule = self.rule
        rule.minimumEpisode = 5
        let fifth = result("[LoliHouse] Ave Mujica - 05 [WebRip 1080p][简繁内封]", hash: "3", team: "LoliHouse")
        let sixth = result("[LoliHouse] Ave Mujica - 06 [WebRip 1080p][简繁内封]", hash: "4", team: "LoliHouse")
        #expect(!TorrentSubscriptionMatcher.accepts(fifth, rule: rule))
        #expect(TorrentSubscriptionMatcher.accepts(sixth, rule: rule))
    }

    @Test func followingMeansFromNowOnUnlessAskedOtherwise() {
        // The trap this avoids: subscribing mid-season and immediately
        // downloading every episode already out.
        let old = result(
            "[LoliHouse] Ave Mujica - 05 [WebRip 1080p][简繁内封]", hash: "1", team: "LoliHouse",
            publishedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        let new = result(
            "[LoliHouse] Ave Mujica - 06 [WebRip 1080p][简繁内封]", hash: "2", team: "LoliHouse",
            publishedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        #expect(!TorrentSubscriptionMatcher.accepts(old, rule: rule))
        #expect(TorrentSubscriptionMatcher.accepts(new, rule: rule))

        var backfilling = rule
        backfilling.includesExistingReleases = true
        #expect(TorrentSubscriptionMatcher.accepts(old, rule: backfilling))
    }

    @Test func aReleaseNobodySeedsLosesToOneWithPeers() {
        let dead = result("[LoliHouse] Ave Mujica - 05 [WebRip 1080p][简繁内封]", hash: "1", team: "LoliHouse", seeders: 0)
        let alive = result("[LoliHouse] Ave Mujica - 05v2 [WebRip 1080p][简繁内封]", hash: "2", team: "LoliHouse", seeders: 4)
        let picked = TorrentSubscriptionMatcher.select(from: [dead, alive], rule: rule, alreadyMatched: [], ownedEpisodes: [])
        #expect(picked.map(\.infoHash.hex) == [alive.infoHash.hex])
    }

    @Test func batchesAreExcludedUnlessAskedFor() {
        let batch = result("[LoliHouse] Ave Mujica [01-13][WebRip 1080p][简繁内封]", hash: "1", category: .batch, team: "LoliHouse")
        #expect(!TorrentSubscriptionMatcher.accepts(batch, rule: rule))
        var permissive = rule
        permissive.includesBatches = true
        #expect(TorrentSubscriptionMatcher.accepts(batch, rule: permissive))
    }

    @Test func picksOneReleasePerEpisodeAndSkipsWhatIsAlreadyHad() {
        let episode5 = result("[LoliHouse] Ave Mujica - 05 [WebRip 1080p][简繁内封]", hash: "1", team: "LoliHouse", seeders: 3)
        let episode5Again = result("[LoliHouse] Ave Mujica - 05v2 [WebRip 1080p][简繁内封]", hash: "2", team: "LoliHouse", seeders: 40)
        let episode6 = result("[LoliHouse] Ave Mujica - 06 [WebRip 1080p][简繁内封]", hash: "3", team: "LoliHouse", seeders: 5)
        let episode4 = result("[LoliHouse] Ave Mujica - 04 [WebRip 1080p][简繁内封]", hash: "4", team: "LoliHouse")
        let alreadyTaken = result("[LoliHouse] Ave Mujica - 07 [WebRip 1080p][简繁内封]", hash: "5", team: "LoliHouse")

        let picked = TorrentSubscriptionMatcher.select(
            from: [episode5, episode5Again, episode6, episode4, alreadyTaken],
            rule: rule,
            alreadyMatched: [alreadyTaken.infoHash.hex],
            ownedEpisodes: [4]
        )

        // One per episode (the better-seeded v2 wins), episode 4 is in the
        // library, episode 7 was downloaded by a previous check.
        #expect(picked.map(\.infoHash.hex) == [episode5Again.infoHash.hex, episode6.infoHash.hex])
    }

    @Test func releasesWithoutEpisodeNumbersNeedASpecificRule() {
        let movie = result("[LoliHouse] Ave Mujica Movie [WebRip 1080p][简繁内封]", hash: "1", team: "LoliHouse")
        var vague = TorrentSubscription(
            title: "Ave Mujica", queries: ["Ave Mujica"], resolution: "1080p",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        #expect(TorrentSubscriptionMatcher.select(from: [movie], rule: vague, alreadyMatched: [], ownedEpisodes: []).isEmpty)

        vague.group = "LoliHouse"
        #expect(TorrentSubscriptionMatcher.select(from: [movie], rule: vague, alreadyMatched: [], ownedEpisodes: []).count == 1)
    }
}

struct TorrentSubscriptionStoreTests {
    @Test func roundTripsEveryFieldOfARule() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let subscription = TorrentSubscription(
            title: "Ave Mujica",
            queries: ["BanG Dream! Ave Mujica", "颂乐人偶"],
            sources: [.mikan, .dmhy],
            group: "LoliHouse",
            resolution: "1080p",
            subtitleLanguages: [.simplifiedChinese, .japanese],
            includeKeywords: ["WebRip"],
            excludeKeywords: ["Reseed", "BDRip"],
            minimumEpisode: 3,
            includesBatches: true
        )
        try await database.saveTorrentSubscription(subscription)

        var stored = try #require(try await database.torrentSubscriptions().first)
        // SQLite stores timestamps to millisecond precision, so compare the
        // creation date with a tolerance and the rest exactly.
        #expect(abs(stored.createdAt.timeIntervalSince(subscription.createdAt)) < 0.01)
        stored.createdAt = subscription.createdAt
        #expect(stored == subscription)

        // Updating in place keeps one row.
        var updated = stored
        updated.isEnabled = false
        updated.lastCheckedAt = Date(timeIntervalSince1970: 1_786_600_000)
        try await database.saveTorrentSubscription(updated)
        let all = try await database.torrentSubscriptions()
        #expect(all.count == 1)
        #expect(all[0].isEnabled == false)
        #expect(all[0].lastCheckedAt == Date(timeIntervalSince1970: 1_786_600_000))

        try await database.removeTorrentSubscription(id: subscription.id)
        #expect(try await database.torrentSubscriptions().isEmpty)
    }

    @Test func matchesAreRecordedOnceAndSurviveDownloadRemoval() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let subscription = TorrentSubscription(title: "Ave Mujica", queries: ["Ave Mujica"])
        try await database.saveTorrentSubscription(subscription)

        let match = TorrentSubscriptionMatch(
            subscriptionID: subscription.id,
            infoHash: "6E54509DE959FBE569C135B4F46B35789D53AAA6",
            title: "Ave Mujica - 05",
            episode: 5
        )
        try await database.recordTorrentSubscriptionMatch(match)
        try await database.recordTorrentSubscriptionMatch(match)

        let stored = try await database.torrentSubscriptionMatches(subscriptionID: subscription.id)
        #expect(stored.count == 1)
        #expect(stored[0].infoHash == "6e54509de959fbe569c135b4f46b35789d53aaa6")
        #expect(stored[0].episode == 5)

        // Removing the rule takes its log with it.
        try await database.removeTorrentSubscription(id: subscription.id)
        #expect(try await database.torrentSubscriptionMatches(subscriptionID: subscription.id).isEmpty)
    }
}
