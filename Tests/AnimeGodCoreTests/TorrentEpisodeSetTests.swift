import Foundation
import Testing
@testable import AnimeGodCore

/// A distinct, run-to-run stable info hash per title (FNV-1a, repeated to
/// fill 40 hex digits), so ordering never depends on a random seed.
private func infoHash(of title: String) -> TorrentInfoHash {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in Array(title.utf8) {
        value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    return TorrentInfoHash(String(String(repeating: String(format: "%016lx", value), count: 3).prefix(40)))!
}

private func result(
    _ title: String,
    team: String? = nil,
    seeders: Int? = 10,
    publishedAt: Date = Date(timeIntervalSince1970: 1_780_000_000),
    size: Int64? = 1_000_000_000,
    category: TorrentCategory = .episode,
    queries: [String] = ["Ave Mujica"]
) -> TorrentSearchResult {
    var observation = TorrentObservation(
        source: .nyaa, title: title, infoHash: infoHash(of: title),
        size: size, seeders: seeders, publishedAt: publishedAt, category: category, team: team
    )
    observation.query = queries[0]
    return TorrentResultMerger.merge([observation], queries: queries)[0]
}

/// One fansub's weekly line, episodes `range`.
private func line(
    group: String,
    episodes: some Sequence<Int>,
    tags: String = "[WebRip 1080p HEVC-10bit AAC][简繁内封字幕]",
    seeders: Int = 10
) -> [TorrentSearchResult] {
    episodes.map { episode in
        result("[\(group)] Ave Mujica - \(String(format: "%02d", episode)) \(tags)", team: group, seeders: seeders)
    }
}

struct TorrentEpisodeSetBuilderTests {
    @Test func putsOneFansubsSeasonBackTogether() {
        let sets = TorrentEpisodeSetBuilder.build(from: line(group: "LoliHouse", episodes: 1...12))
        #expect(sets.count == 1)
        let season = try! #require(sets.first)
        #expect(season.group == "LoliHouse")
        #expect(season.variant.resolution == "1080p")
        #expect(season.variant.subtitleLanguages == [.simplifiedChinese, .traditionalChinese])
        #expect(season.expectedEpisodes == Array(stride(from: 1.0, through: 12.0, by: 1)))
        #expect(season.isComplete)
        #expect(season.coveredCount == 12)
        #expect(season.substituteCount == 0)
        #expect(season.downloadableEntries.count == 12)
        #expect(season.downloadSize == 12_000_000_000)
    }

    @Test func splitsOneFansubsResolutionsIntoSeparateSets() {
        let results = line(group: "Sakurato", episodes: 1...12)
            + line(group: "Sakurato", episodes: 1...12, tags: "[WebRip 720p AVC AAC][简日双语]")
        let sets = TorrentEpisodeSetBuilder.build(from: results)
        #expect(sets.count == 2)
        #expect(Set(sets.map(\.variant.resolution)) == ["1080p", "720p"])
        // The better picture leads when both are complete.
        #expect(sets.first?.variant.resolution == "1080p")
    }

    @Test func ignoresBatchesAndLooseReleases() {
        let results = line(group: "LoliHouse", episodes: 1...12)
            + [result("[VCB-Studio] Ave Mujica 01-12 Fin [Ma10p_1080p]", team: "VCB-Studio", category: .batch)]
            + [result("[Stray] Ave Mujica - 03 [1080p]", team: "Stray")]
        let sets = TorrentEpisodeSetBuilder.build(from: results)
        // The batch is what the user is trying to avoid, and a single loose
        // episode is not a season.
        #expect(sets.map(\.group) == ["LoliHouse"])
    }

    @Test func borrowsAMissingEpisodeFromTheClosestOtherFansub() {
        let results = line(group: "LoliHouse", episodes: Array(1...12).filter { $0 != 7 })
            + line(group: "Sakurato", episodes: 1...12, seeders: 3)
        let sets = TorrentEpisodeSetBuilder.build(from: results)
        let loliHouse = try! #require(sets.first { $0.group == "LoliHouse" })
        #expect(loliHouse.isComplete)
        #expect(loliHouse.missingEpisodes.isEmpty)
        let seven = try! #require(loliHouse.entries.first { $0.episode == 7 })
        #expect(seven.isSubstitute)
        #expect(seven.group == "Sakurato")
        // Sakurato's own set stays untouched.
        #expect(sets.first { $0.group == "Sakurato" }?.substituteCount == 0)
    }

    @Test func neverPatchesASubtitledSeasonWithARaw() {
        let results = line(group: "LoliHouse", episodes: Array(1...12).filter { $0 != 7 })
            + line(group: "Raws", episodes: [7], tags: "[1080p][MKV]")
        let sets = TorrentEpisodeSetBuilder.build(from: results)
        let loliHouse = try! #require(sets.first { $0.group == "LoliHouse" })
        #expect(loliHouse.missingEpisodes == [7])
        #expect(!loliHouse.isComplete)
    }

    @Test func prefersTheBorrowedEpisodeThatMatchesTheLine() {
        let results = line(group: "LoliHouse", episodes: Array(1...12).filter { $0 != 7 })
            + line(group: "LowRes", episodes: [7], tags: "[WebRip 720p AVC][简繁内封字幕]", seeders: 90)
            + line(group: "SameShape", episodes: [7], seeders: 5)
        let sets = TorrentEpisodeSetBuilder.build(from: results)
        let seven = try! #require(sets.first { $0.group == "LoliHouse" }?.entries.first { $0.episode == 7 })
        // 1080p like the rest of the season beats a healthier 720p swarm.
        #expect(seven.group == "SameShape")
    }

    @Test func leavesOutEpisodesTheLibraryAlreadyHas() {
        let sets = TorrentEpisodeSetBuilder.build(
            from: line(group: "LoliHouse", episodes: 1...12),
            options: TorrentEpisodeSetOptions(ownedEpisodes: [1, 2, 3, 4, 5])
        )
        let season = try! #require(sets.first)
        #expect(season.ownedCount == 5)
        #expect(season.coveredCount == 12)
        #expect(season.neededEpisodes == Array(stride(from: 6.0, through: 12.0, by: 1)))
        #expect(season.downloadableEntries.map(\.episode) == Array(stride(from: 6.0, through: 12.0, by: 1)))
    }

    @Test func countsEpisodesTheLibraryHasTowardsTheSeasonsLength() {
        // The indexes only still carry the tail of the season; the first
        // half is on disk and must not read as "not part of the season".
        let sets = TorrentEpisodeSetBuilder.build(
            from: line(group: "LoliHouse", episodes: 9...12),
            options: TorrentEpisodeSetOptions(ownedEpisodes: [1, 2, 3, 4, 5, 6, 7, 8])
        )
        let season = try! #require(sets.first)
        #expect(season.expectedEpisodes.count == 12)
        #expect(season.missingEpisodes.isEmpty)
        #expect(season.downloadableEntries.map(\.episode) == [9, 10, 11, 12])
    }

    @Test func keepsRecapsAndOVAsOutOfTheCount() {
        let results = line(group: "LoliHouse", episodes: 1...12)
            + [result("[LoliHouse] Ave Mujica - 12.5 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]", team: "LoliHouse")]
        let season = try! #require(TorrentEpisodeSetBuilder.build(from: results).first)
        #expect(season.expectedEpisodes.count == 12)
        #expect(season.coveredCount == 12)
        #expect(season.extras.map(\.episode) == [12.5])
        #expect(season.downloadableEntries.count == 12)
    }

    @Test func picksTheHealthiestReleaseWhenAnEpisodeWasPublishedTwice() {
        let weak = result("[LoliHouse] Ave Mujica - 05 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]", team: "LoliHouse", seeders: 1)
        let strong = result("[LoliHouse] Ave Mujica - 05v2 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]", team: "LoliHouse", seeders: 80)
        let sets = TorrentEpisodeSetBuilder.build(
            from: [weak, strong] + line(group: "LoliHouse", episodes: [1, 2, 3, 4]),
            options: TorrentEpisodeSetOptions(minimumEpisodes: 2)
        )
        let five = try! #require(sets.first?.entries.first { $0.episode == 5 })
        #expect(five.result.infoHash == strong.infoHash)
        #expect(sets.first?.entries.filter { $0.episode == 5 }.count == 1)
    }

    @Test func ranksTheSeasonThatCoversTheMostFirst() {
        let results = line(group: "Partial", episodes: 1...6)
            + line(group: "Full", episodes: 1...12, seeders: 4)
        let sets = TorrentEpisodeSetBuilder.build(
            from: results,
            options: TorrentEpisodeSetOptions(allowsSubstitutes: false)
        )
        #expect(sets.map(\.group) == ["Full", "Partial"])
        // A line that stopped at 6 is a six-episode set, not a twelve with
        // six holes: the indexes say nothing about what it meant to do.
        #expect(sets.last?.expectedEpisodes == Array(stride(from: 1.0, through: 6.0, by: 1)))
        #expect(sets.last?.missingEpisodes.isEmpty == true)
    }
}

struct TorrentEpisodeRangeTests {
    @Test func spansTheEpisodesThatWereSeen() {
        #expect(TorrentEpisodeSetBuilder.expectedEpisodes(in: [1, 2, 3, 4]) == [1, 2, 3, 4])
        #expect(TorrentEpisodeSetBuilder.expectedEpisodes(in: [2, 5, 9]) == Array(stride(from: 1.0, through: 9.0, by: 1)))
    }

    @Test func doesNotStretchTheSeasonToAMisparsedYear() {
        let range = TorrentEpisodeSetBuilder.expectedEpisodes(in: [1, 2, 3, 4, 5, 6, 2018])
        #expect(range == Array(stride(from: 1.0, through: 6.0, by: 1)))
    }

    @Test func keepsALongRunningShowsOwnNumbering() {
        let range = TorrentEpisodeSetBuilder.expectedEpisodes(in: [1084, 1085, 1086])
        #expect(range == [1084, 1085, 1086])
    }

    @Test func ignoresNonEpisodeNumbers() {
        #expect(TorrentEpisodeSetBuilder.expectedEpisodes(in: [12.5]).isEmpty)
        #expect(TorrentEpisodeSetBuilder.expectedEpisodes(in: []).isEmpty)
    }
}

struct TorrentTitleSignatureTests {
    @Test func dropsTheEpisodeAndEveryTagCarryingADigit() {
        let first = TorrentEpisodeSetBuilder.titleSignature("[LoliHouse] Ave Mujica - 05 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]")
        let second = TorrentEpisodeSetBuilder.titleSignature("[LoliHouse] Ave Mujica - 11 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]")
        #expect(first == second)
        #expect(first != TorrentEpisodeSetBuilder.titleSignature("[LoliHouse] Ave Mujica - 11 [BDRip 1080p HEVC][简繁内封字幕]"))
    }
}

struct TorrentEpisodeSetRankingTests {
    @Test func prefersTheLineThatReallyPublishedTheEpisodes() {
        // A BD line stalled at episode 6, and a weekly line that ran the
        // whole season: the weekly one is the recommendation, and the BD
        // line is offered as the six episodes it really is.
        let results = line(group: "SlowBD", episodes: 1...6, tags: "[BDRip 1080p HEVC][简繁内封字幕]")
            + line(group: "Weekly", episodes: 1...12, tags: "[WebRip 1080p HEVC][简繁内封字幕]")
        let sets = TorrentEpisodeSetBuilder.build(from: results)
        #expect(sets.first?.group == "Weekly")
        #expect(sets.first?.substituteCount == 0)
        let bd = try! #require(sets.first { $0.group == "SlowBD" })
        #expect(bd.expectedEpisodes.count == 6)
        #expect(bd.substituteCount == 0)
        #expect(bd.isComplete)
    }

    @Test func doesNotReadAnUnreportedSeederCountAsADeadSwarm() {
        let known = line(group: "Known", episodes: 1...4, seeders: 12)
        let unknown = line(group: "Known", episodes: [5], seeders: 0).map { result -> TorrentSearchResult in
            var copy = result
            copy.seeders = nil
            return copy
        }
        let season = try! #require(TorrentEpisodeSetBuilder.build(from: known + unknown).first)
        #expect(season.minimumSeeders == 12)
    }
}

struct TorrentEpisodeSetSeasonTests {
    @Test func measuresATaggedSecondSeasonAgainstItsOwnNumbering() {
        // One team keeps counting from season one; another restarts and
        // tags S2. Both are honest, and neither is missing 28 episodes.
        let results = line(group: "Continuous", episodes: 29...38)
            + line(group: "Restarted", episodes: 1...10, tags: "[S2][WebRip 1080p HEVC][简繁内封字幕]")
        let sets = TorrentEpisodeSetBuilder.build(from: results)
        let restarted = try! #require(sets.first { $0.group == "Restarted" })
        #expect(restarted.variant.season == 2)
        #expect(restarted.expectedEpisodes == Array(stride(from: 1.0, through: 10.0, by: 1)))
        #expect(restarted.isComplete)
        let continuous = try! #require(sets.first { $0.group == "Continuous" })
        #expect(continuous.expectedEpisodes == Array(stride(from: 29.0, through: 38.0, by: 1)))
        #expect(continuous.isComplete)
        #expect(continuous.substituteCount == 0)
    }

    @Test func doesNotPadAThinLineOutIntoAWholeSeason() {
        let results = line(group: "Thin", episodes: [1, 2])
            + line(group: "Whole", episodes: 1...12, tags: "[WebRip 1080p HEVC][简繁内封字幕]")
        let sets = TorrentEpisodeSetBuilder.build(from: results)
        let thin = try! #require(sets.first { $0.group == "Thin" })
        #expect(thin.expectedEpisodes == [1, 2])
        #expect(thin.substituteCount == 0)
        #expect(sets.first?.group == "Whole")
    }

    @Test func offersTheWholeSeasonAcrossFansubsWhenNoOneLineHasIt() {
        // Nobody published all twelve: the first half is one team's, the
        // second half another's, and the point of the feature is one click.
        let results = line(group: "First", episodes: 1...6)
            + line(group: "Second", episodes: 7...12, seeders: 4)
        let sets = TorrentEpisodeSetBuilder.build(from: results)
        let mixed = try! #require(sets.first { $0.isMixed })
        #expect(mixed.group == nil)
        #expect(mixed.expectedEpisodes == Array(stride(from: 1.0, through: 12.0, by: 1)))
        #expect(mixed.isComplete)
        #expect(mixed.substituteCount == 6)
        #expect(mixed.downloadableEntries.count == 12)
        // Both fansubs' own sets are still there, untouched.
        #expect(sets.filter { !$0.isMixed }.allSatisfy { $0.substituteCount == 0 })
    }

    @Test func doesNotOfferAMixWhenOneFansubAlreadyCoversEverything() {
        let sets = TorrentEpisodeSetBuilder.build(from: line(group: "LoliHouse", episodes: 1...12))
        #expect(sets.allSatisfy { !$0.isMixed })
    }
}
