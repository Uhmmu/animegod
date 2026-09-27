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
        #expect(picked.automatic.map(\.infoHash.hex) == [alive.infoHash.hex])
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
        #expect(picked.automatic.map(\.infoHash.hex) == [episode5Again.infoHash.hex, episode6.infoHash.hex])
    }

    @Test func releasesWithoutEpisodeNumbersNeedASpecificRule() {
        let movie = result("[LoliHouse] Ave Mujica Movie [WebRip 1080p][简繁内封]", hash: "1", team: "LoliHouse")
        var vague = TorrentSubscription(
            title: "Ave Mujica", queries: ["Ave Mujica"], resolution: "1080p",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        #expect(TorrentSubscriptionMatcher.select(from: [movie], rule: vague, alreadyMatched: [], ownedEpisodes: []).automatic.isEmpty)

        vague.group = "LoliHouse"
        #expect(TorrentSubscriptionMatcher.select(from: [movie], rule: vague, alreadyMatched: [], ownedEpisodes: []).automatic.count == 1)
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
            videoCodec: "HEVC",
            videoSource: "WEB",
            season: 2,
            includeKeywords: ["WebRip"],
            excludeKeywords: ["Reseed", "BDRip"],
            minimumEpisode: 3,
            includesBatches: true,
            folderName: "Ave Mujica S2",
            titleSignature: "lolihouse ave mujica webrip",
            expectedEpisodeCount: 13,
            averageIntervalSeconds: 7 * 86_400,
            lastReleaseAt: Date(timeIntervalSince1970: 1_786_000_000),
            latestEpisode: 10
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

    @Test func offersAreKeptUntilTakenOrTurnedDown() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let subscription = TorrentSubscription(title: "Ave Mujica", queries: ["Ave Mujica"])
        try await database.saveTorrentSubscription(subscription)

        let candidate = TorrentSubscriptionCandidate(
            subscriptionID: subscription.id,
            infoHash: "6E54509DE959FBE569C135B4F46B35789D53AAA6",
            title: "[Nekomoe kissaten] Ave Mujica - 11 [1080p][JPSC]",
            magnet: "magnet:?xt=urn:btih:6e54509de959fbe569c135b4f46b35789d53aaa6",
            trackers: ["udp://tracker.opentrackr.org:1337/announce"],
            episode: 11,
            group: "Nekomoe kissaten",
            resolution: "1080p",
            size: 512_000_000,
            seeders: 30,
            publishedAt: Date(timeIntervalSince1970: 1_786_000_000),
            foundAt: Date(timeIntervalSince1970: 1_786_100_000),
            reason: .otherGroup
        )
        try await database.saveTorrentSubscriptionCandidate(candidate)
        // Offering it twice keeps one row, so a check every twelve hours does
        // not pile up copies of the same question.
        try await database.saveTorrentSubscriptionCandidate(candidate)

        var stored = try #require(try await database.torrentSubscriptionCandidates().first)
        #expect(try await database.torrentSubscriptionCandidates().count == 1)
        #expect(abs(stored.foundAt.timeIntervalSince(candidate.foundAt)) < 0.01)
        stored.foundAt = candidate.foundAt
        stored.publishedAt = candidate.publishedAt
        #expect(stored == candidate)

        try await database.removeTorrentSubscriptionCandidate(
            subscriptionID: subscription.id, infoHash: candidate.infoHash
        )
        #expect(try await database.torrentSubscriptionCandidates().isEmpty)

        // Removing the rule takes its offers with it.
        try await database.saveTorrentSubscriptionCandidate(candidate)
        try await database.removeTorrentSubscription(id: subscription.id)
        #expect(try await database.torrentSubscriptionCandidates().isEmpty)
    }

    @Test func aDownloadRemembersItsFolderAndWhoStartedIt() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let record = TorrentDownloadRecord(
            infoHash: "6E54509DE959FBE569C135B4F46B35789D53AAA6",
            title: "[LoliHouse] Ave Mujica - 11",
            magnet: "magnet:?xt=urn:btih:6e54509de959fbe569c135b4f46b35789d53aaa6",
            savePath: "/Volumes/T7/video",
            episodeLabel: "11",
            folderName: "Ave Mujica",
            isAutomatic: true,
            subscriptionID: UUID(),
            totalBytes: 512_000_000
        )
        try await database.saveTorrentDownload(record)
        let stored = try #require(try await database.torrentDownloads().first)
        #expect(stored.folderName == "Ave Mujica")
        #expect(stored.isAutomatic)
        #expect(stored.subscriptionID == record.subscriptionID)

        // The engine's later updates must not wipe what the folder is.
        try await database.updateTorrentDownload(
            infoHash: record.infoHash, title: "renamed", totalBytes: 600, completedAt: .now, isSequential: nil
        )
        let updated = try #require(try await database.torrentDownloads().first)
        #expect(updated.folderName == "Ave Mujica")
        #expect(updated.isAutomatic)
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

/// Episodes the right show but the wrong release line: offered, never taken.
struct TorrentSubscriptionConfirmationTests {
    private var rule: TorrentSubscription {
        TorrentSubscription(
            title: "Ave Mujica",
            queries: ["Ave Mujica"],
            group: "LoliHouse",
            resolution: "1080p",
            subtitleLanguages: [.simplifiedChinese],
            minimumEpisode: 10,
            includesExistingReleases: true,
            titleSignature: TorrentEpisodeSetBuilder.titleSignature(
                "[LoliHouse] Ave Mujica - 10 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]"
            ),
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    @Test func anotherFansubIsOfferedRatherThanDownloaded() {
        let own = result("[LoliHouse] Ave Mujica - 11 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]", hash: "1", team: "LoliHouse")
        let other = result("[Nekomoe kissaten] Ave Mujica - 12 [1080p][简繁内封]", hash: "2", team: "Nekomoe kissaten")
        let selection = TorrentSubscriptionMatcher.select(
            from: [own, other], rule: rule, alreadyMatched: [], ownedEpisodes: []
        )
        #expect(selection.automatic.map(\.infoHash.hex) == [own.infoHash.hex])
        #expect(selection.needsConfirmation.map(\.result.infoHash.hex) == [other.infoHash.hex])
        #expect(selection.needsConfirmation.map(\.reason) == [.otherGroup])
    }

    @Test func theLineOwnEpisodeWinsOverAnotherFansubOfTheSameNumber() {
        let own = result("[LoliHouse] Ave Mujica - 11 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]", hash: "1", team: "LoliHouse")
        let other = result("[Nekomoe kissaten] Ave Mujica - 11 [1080p][简繁内封]", hash: "2", team: "Nekomoe kissaten")
        let selection = TorrentSubscriptionMatcher.select(
            from: [other, own], rule: rule, alreadyMatched: [], ownedEpisodes: []
        )
        #expect(selection.automatic.count == 1)
        // Nothing to ask about: the episode already arrived on the line.
        #expect(selection.needsConfirmation.isEmpty)
    }

    @Test func aRenamedReleaseFromTheSameTeamIsWorthALookNotADownload() {
        let renamed = result("[LoliHouse] Ave Mujica Season Finale - 11 [WebRip 1080p][简繁内封]", hash: "3", team: "LoliHouse")
        let selection = TorrentSubscriptionMatcher.select(
            from: [renamed], rule: rule, alreadyMatched: [], ownedEpisodes: []
        )
        #expect(selection.automatic.isEmpty)
        #expect(selection.needsConfirmation.map(\.reason) == [.otherNaming])
    }

    @Test func anOfferAlreadyMadeIsNotMadeAgain() {
        let other = result("[Nekomoe kissaten] Ave Mujica - 11 [1080p][简繁内封]", hash: "2", team: "Nekomoe kissaten")
        let selection = TorrentSubscriptionMatcher.select(
            from: [other], rule: rule, alreadyMatched: [], ownedEpisodes: [],
            alreadyOffered: [other.infoHash.hex]
        )
        #expect(selection.isEmpty)
    }

    @Test func theEpisodeFloorStillAppliesToOffers() {
        // Episode 9 is behind what is on disk; nobody should be asked about it.
        let old = result("[Nekomoe kissaten] Ave Mujica - 09 [1080p][简繁内封]", hash: "4", team: "Nekomoe kissaten")
        #expect(TorrentSubscriptionMatcher.select(
            from: [old], rule: rule, alreadyMatched: [], ownedEpisodes: []
        ).isEmpty)
    }
}

/// The one-click rule built from a season that is still running.
struct TorrentSubscriptionFromSetTests {
    private func set(episodes: Range<Int>, group: String = "LoliHouse") -> TorrentEpisodeSet {
        let entries = episodes.map { episode in
            TorrentEpisodeSet.Entry(
                episode: Double(episode),
                result: result(
                    "[\(group)] Ave Mujica - \(String(format: "%02d", episode)) [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]",
                    hash: String(format: "%x", episode),
                    team: group,
                    publishedAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(episode) * 7 * 86_400)
                ),
                isSubstitute: false,
                isOwned: false,
                isExtra: false
            )
        }
        return TorrentEpisodeSet(
            variant: TorrentReleaseVariant(
                // The tags as the parser reports them: a set's variant is
                // always built from parsed releases, never spelled by hand.
                group: group, season: nil, resolution: "1080p", videoCodec: "HEVC",
                videoSource: "WEB", subtitleLanguages: [.simplifiedChinese, .traditionalChinese]
            ),
            entries: entries,
            expectedEpisodes: entries.map(\.episode),
            missingEpisodes: [],
            ownedEpisodes: []
        )
    }

    @Test func learnsTheLineTheFolderAndTheFloorFromWhatWasDownloaded() {
        let assembled = set(episodes: 1..<11)
        let schedule = TorrentReleaseSchedule.analyse(
            results: assembled.entries.map(\.result),
            expectedEpisodeCount: 13,
            now: Date(timeIntervalSince1970: 1_780_000_000 + 11 * 7 * 86_400)
        )
        let rule = TorrentSubscription.following(
            set: assembled,
            schedule: schedule,
            animeID: nil,
            title: "Ave Mujica",
            queries: ["Ave Mujica"],
            folderName: "Ave Mujica"
        )
        #expect(rule.group == "LoliHouse")
        #expect(rule.resolution == "1080p")
        #expect(rule.videoCodec == "HEVC")
        #expect(rule.subtitleLanguages == [.simplifiedChinese, .traditionalChinese])
        #expect(rule.minimumEpisode == 10)
        #expect(rule.folderName == "Ave Mujica")
        #expect(rule.expectedEpisodeCount == 13)
        #expect(rule.latestEpisode == 10)
        #expect(rule.nextEpisode == 11)
        // A rule made from a set must take the episode that is already out:
        // the floor is what keeps it from taking the ten on disk again.
        #expect(rule.includesExistingReleases)
        let signature = try? #require(rule.titleSignature)
        #expect(signature?.contains("ave mujica") == true)

        // Episode 11 from the same line is downloaded; episode 10 is not.
        let eleven = result("[LoliHouse] Ave Mujica - 11 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]", hash: "e", team: "LoliHouse")
        let ten = assembled.entries[9].result
        #expect(TorrentSubscriptionMatcher.accepts(eleven, rule: rule))
        #expect(!TorrentSubscriptionMatcher.accepts(ten, rule: rule))
    }

    @Test func theNextEpisodeIsSearchedForByNumberToo() {
        var rule = TorrentSubscription(title: "Ave Mujica", queries: ["Ave Mujica", "颂乐人偶"], minimumEpisode: 10)
        #expect(rule.searchQueries() == ["Ave Mujica", "颂乐人偶", "Ave Mujica 11"])
        rule.latestEpisode = 12
        #expect(rule.searchQueries().last == "Ave Mujica 13")
    }

    @Test func aFinishedSeasonStopsBeingFollowed() {
        var rule = TorrentSubscription(title: "Ave Mujica", queries: ["Ave Mujica"])
        rule.expectedEpisodeCount = 13
        rule.latestEpisode = 12
        #expect(!rule.isSeasonComplete)
        rule.latestEpisode = 13
        #expect(rule.isSeasonComplete)
    }

    @Test func theNextEpisodeIsEstimatedFromTheCadence() {
        var rule = TorrentSubscription(title: "Ave Mujica", queries: ["Ave Mujica"])
        rule.averageIntervalSeconds = 7 * 86_400
        rule.lastReleaseAt = Date(timeIntervalSince1970: 1_780_000_000)
        let soon = rule.estimatedNextEpisodeAt(now: Date(timeIntervalSince1970: 1_780_000_000 + 86_400))
        #expect(soon == Date(timeIntervalSince1970: 1_780_000_000 + 7 * 86_400))
        // Three weeks of silence: the estimate moves forward rather than
        // pointing at a date that has gone by.
        let late = rule.estimatedNextEpisodeAt(now: Date(timeIntervalSince1970: 1_780_000_000 + 20 * 86_400))
        #expect(late == Date(timeIntervalSince1970: 1_780_000_000 + 21 * 86_400))
    }
}
