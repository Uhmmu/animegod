import Foundation
import Testing
@testable import AnimeGodCore

/// Is this season still running? The Subscribe button in Find Releases turns
/// on this answer, so both mistakes matter: offering to follow a show that
/// ended in 2019, and not offering one that airs on Friday.
struct TorrentReleaseScheduleTests {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let week: TimeInterval = 7 * 86_400
    /// A single hex digit stands in for a whole info hash; every release in
    /// one test needs its own or the merger folds them together.
    private static let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]

    private func episode(
        _ number: Int,
        group: String = "LoliHouse",
        publishedAt: Date,
        hash: String? = nil
    ) -> TorrentSearchResult {
        let title = "[\(group)] Ave Mujica - \(String(format: "%02d", number)) [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]"
        // A single hex digit stands in for a whole info hash; every release
        // in one test needs its own or the merger folds them together.
        let digit = hash ?? Self.digits[number % Self.digits.count]
        var observation = TorrentObservation(
            source: .nyaa,
            title: title,
            infoHash: TorrentInfoHash(String(repeating: digit, count: 40))!,
            seeders: 20,
            publishedAt: publishedAt,
            category: .episode,
            team: group
        )
        observation.query = "Ave Mujica"
        return TorrentResultMerger.merge([observation], queries: ["Ave Mujica"])[0]
    }

    /// Ten weekly episodes, the last one three days ago.
    private var running: [TorrentSearchResult] {
        (1...10).map { episode($0, publishedAt: start.addingTimeInterval(Double($0) * week)) }
    }

    @Test func aWeeklyShowWhoseLastEpisodeIsDaysOldIsStillRunning() {
        let now = start.addingTimeInterval(10 * week + 3 * 86_400)
        let schedule = TorrentReleaseSchedule.analyse(results: running, now: now)
        #expect(schedule.latestEpisode == 10)
        #expect(schedule.episodeCount == 10)
        #expect(schedule.averageInterval == week)
        #expect(schedule.isOngoing)
        #expect(schedule.nextEpisode == 11)
        #expect(schedule.estimatedNextEpisodeAt == start.addingTimeInterval(11 * week))
    }

    @Test func aSeasonNobodyHasAddedToInMonthsHasFinished() {
        let now = start.addingTimeInterval(10 * week + 120 * 86_400)
        let schedule = TorrentReleaseSchedule.analyse(results: running, now: now)
        #expect(!schedule.isOngoing)
        #expect(schedule.estimatedNextEpisodeAt == nil)
        // The rhythm is still reported — the Subscriptions page shows it for
        // a rule that was made while the show was running.
        #expect(schedule.averageInterval == week)
    }

    @Test func theMetadataEpisodeCountSettlesIt() {
        // The last episode of a 10-episode season, a fortnight ago: airing
        // has stopped whatever the cadence suggests.
        let now = start.addingTimeInterval(10 * week + 12 * 86_400)
        let finished = TorrentReleaseSchedule.analyse(results: running, expectedEpisodeCount: 10, now: now)
        #expect(!finished.isOngoing)
        #expect(finished.remainingEpisodeCount == 0)

        let ongoing = TorrentReleaseSchedule.analyse(results: running, expectedEpisodeCount: 13, now: now)
        #expect(ongoing.isOngoing)
        #expect(ongoing.remainingEpisodeCount == 3)
    }

    @Test func aSeasonDumpedInOneAfternoonHasNoCadence() {
        let sameDay = (1...12).map { episode($0, publishedAt: start.addingTimeInterval(Double($0) * 600)) }
        let schedule = TorrentReleaseSchedule.analyse(results: sameDay, now: start.addingTimeInterval(2 * 86_400))
        #expect(schedule.averageInterval == nil)
        // Recent enough to still be worth following, but with nothing to
        // estimate from there is no date to show.
        #expect(schedule.isOngoing)
        #expect(schedule.estimatedNextEpisodeAt == nil)

        let old = TorrentReleaseSchedule.analyse(results: sameDay, now: start.addingTimeInterval(400 * 86_400))
        #expect(!old.isOngoing)
    }

    @Test func lastSeasonsEpisodesDoNotStretchTheCadence() {
        // The show has run for years, so the same search carries a line
        // still counting 25–36 from last year beside the season that
        // restarted at 1. Averaging over both would report a cadence of
        // months and an episode number from the wrong season — and the old
        // run is the higher-numbered one, so picking "the last run" would
        // pick it. Recency is what decides.
        let previous = (25...36).map {
            episode($0, group: "Old", publishedAt: start.addingTimeInterval(-365 * 86_400 + Double($0) * week),
                    hash: Self.digits[($0 + 3) % Self.digits.count])
        }
        let now = start.addingTimeInterval(10 * week + 2 * 86_400)
        let schedule = TorrentReleaseSchedule.analyse(results: previous + running, now: now)
        #expect(schedule.averageInterval == week)
        #expect(schedule.latestEpisode == 10)
        #expect(schedule.episodeCount == 10)
        #expect(schedule.isOngoing)
    }

    @Test func batchesAndRecapsNeverSetTheRhythm() {
        var batch = TorrentObservation(
            source: .nyaa,
            title: "[LoliHouse] Ave Mujica [01-13][WebRip 1080p][简繁内封]",
            infoHash: TorrentInfoHash(String(repeating: "b", count: 40))!,
            publishedAt: start.addingTimeInterval(11 * week),
            category: .batch,
            team: "LoliHouse"
        )
        batch.query = "Ave Mujica"
        let merged = TorrentResultMerger.merge([batch], queries: ["Ave Mujica"])
        let now = start.addingTimeInterval(11 * week + 86_400)
        let schedule = TorrentReleaseSchedule.analyse(results: running + merged, now: now)
        #expect(schedule.latestEpisode == 10)
    }

    @Test func episodesOnlyTheLibraryHasStillCountAsProgress() {
        // The indexes dropped episodes 1–4; the library has them.
        let recent = Array(running.suffix(6))
        let now = start.addingTimeInterval(10 * week + 86_400)
        let schedule = TorrentReleaseSchedule.analyse(
            results: recent, ownedEpisodes: [1, 2, 3, 4], now: now
        )
        #expect(schedule.episodeCount == 10)
        #expect(schedule.latestEpisode == 10)
    }

    @Test func nothingToGoOnMeansNotOngoing() {
        #expect(!TorrentReleaseSchedule.analyse(results: []).isOngoing)
        let undated = TorrentReleaseSchedule.analyse(results: [episode(1, publishedAt: .distantPast)])
        #expect(!undated.isOngoing)
    }
}

/// The fansubs say when a season is over, and they say it in the filename.
/// Without this a show that finished on Thursday reads as "still airing" until
/// the silence tests notice, which for a weekly show takes a fortnight.
struct TorrentFinaleMarkerTests {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let week: TimeInterval = 7 * 86_400
    private static let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]

    private func release(
        _ title: String,
        hash: String,
        publishedAt: Date,
        category: TorrentCategory = .episode
    ) -> TorrentSearchResult {
        var observation = TorrentObservation(
            source: .nyaa,
            title: title,
            infoHash: TorrentInfoHash(String(repeating: hash, count: 40))!,
            seeders: 40,
            publishedAt: publishedAt,
            category: category,
            team: "LoliHouse"
        )
        observation.query = "Yani Suu Futari"
        return TorrentResultMerger.merge([observation], queries: ["Yani Suu Futari"])[0]
    }

    /// Twelve weekly episodes, the last one three days ago — the exact shape
    /// that used to read as "still airing".
    private func season(taggingFinale: Bool) -> [TorrentSearchResult] {
        (1...12).map { episode in
            let suffix = taggingFinale && episode == 12 ? "[END]" : ""
            return release(
                "[LoliHouse] Super no Ura de Yani Suu Futari - \(String(format: "%02d", episode)) [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]\(suffix)",
                hash: Self.digits[episode % Self.digits.count],
                publishedAt: start.addingTimeInterval(Double(episode) * week)
            )
        }
    }

    @Test func aFinaleTagEndsTheSeasonOnTheDay() {
        let now = start.addingTimeInterval(12 * week + 3 * 86_400)
        #expect(TorrentReleaseSchedule.analyse(results: season(taggingFinale: false), now: now).isOngoing)

        let tagged = TorrentReleaseSchedule.analyse(results: season(taggingFinale: true), now: now)
        #expect(tagged.isMarkedFinished)
        #expect(!tagged.isOngoing)
        #expect(tagged.estimatedNextEpisodeAt == nil)
        // The rhythm is still read off it, for a rule made while it ran.
        #expect(tagged.averageInterval == week)
    }

    @Test func aFullSeasonPackSaysTheSameThing() {
        let now = start.addingTimeInterval(12 * week + 3 * 86_400)
        let pack = release(
            "[LoliHouse] Super no Ura de Yani Suu Futari [01-12][WebRip 1080p HEVC-10bit AAC][简繁内封字幕]",
            hash: "f",
            publishedAt: start.addingTimeInterval(12 * week + 86_400),
            category: .batch
        )
        let schedule = TorrentReleaseSchedule.analyse(results: season(taggingFinale: false) + [pack], now: now)
        #expect(schedule.isMarkedFinished)
        #expect(!schedule.isOngoing)
    }

    @Test func aPackOfTheFirstHalfDoesNotEndAnything() {
        let now = start.addingTimeInterval(12 * week + 3 * 86_400)
        let pack = release(
            "[LoliHouse] Super no Ura de Yani Suu Futari [01-06][WebRip 1080p]",
            hash: "e",
            publishedAt: start.addingTimeInterval(7 * week),
            category: .batch
        )
        let schedule = TorrentReleaseSchedule.analyse(results: season(taggingFinale: false) + [pack], now: now)
        #expect(!schedule.isMarkedFinished)
        #expect(schedule.isOngoing)
    }

    @Test func aFinaleTagOnAnOlderEpisodeIsNotAboutThisOne() {
        // A split cour: episode 12 was tagged the end, then the show came back.
        let now = start.addingTimeInterval(13 * week + 86_400)
        let resumed = season(taggingFinale: true) + [release(
            "[LoliHouse] Super no Ura de Yani Suu Futari - 13 [WebRip 1080p]",
            hash: "d",
            publishedAt: start.addingTimeInterval(13 * week)
        )]
        #expect(TorrentReleaseSchedule.analyse(results: resumed, now: now).isOngoing)
    }

    @Test func markersAreWholeWordsNotSubstrings() {
        // 終 is a token in [終] and a letter in 少女終末旅行; end is a word in
        // "The End" and three letters in "Legend".
        #expect(TorrentReleaseSchedule.marksFinale("[LoliHouse] Title - 12 [1080p][END]"))
        #expect(TorrentReleaseSchedule.marksFinale("【喵萌奶茶屋】[Title][12][完][1080p]"))
        #expect(TorrentReleaseSchedule.marksFinale("[Nekomoe kissaten][Title][12 Fin][1080p]"))
        #expect(TorrentReleaseSchedule.marksFinale("[Title][12][最終回][1080p]"))
        #expect(!TorrentReleaseSchedule.marksFinale("[VCB-Studio] 少女終末旅行 - 01 [1080p]"))
        #expect(!TorrentReleaseSchedule.marksFinale("[Erai-raws] The Legend of Heroes - 05 [1080p]"))
        #expect(!TorrentReleaseSchedule.marksFinale("[Sub] Final Fantasy - 03 [1080p]"))
        #expect(!TorrentReleaseSchedule.marksFinale("[Sub] 完全犯罪 - 03 [1080p]"))
    }
}

/// A show published under two numbering schemes at once.
struct TorrentConcurrentNumberingTests {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let week: TimeInterval = 7 * 86_400
    private static let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]

    private func release(_ title: String, hash: String, publishedAt: Date) -> TorrentSearchResult {
        var observation = TorrentObservation(
            source: .nyaa,
            title: title,
            infoHash: TorrentInfoHash(String(repeating: hash, count: 40))!,
            seeders: 100,
            publishedAt: publishedAt,
            category: .episode
        )
        observation.query = "One Piece"
        return TorrentResultMerger.merge([observation], queries: ["One Piece"])[0]
    }

    @Test func theLongerOfTwoCurrentRunsIsTheSeason() {
        // One Piece really is published as both `1179` and `S23E25` in the
        // same week. Picking the run by recency alone reported the season as
        // "25 episodes, newest EP 25" — true of one team's numbering and
        // nonsense as a description of the show.
        let absolute = (1160...1179).map { episode in
            release(
                "[Erai-raws] One Piece - \(episode) [1080p]",
                hash: Self.digits[episode % Self.digits.count],
                publishedAt: start.addingTimeInterval(Double(episode - 1160) * week)
            )
        }
        let perSeason = (24...25).map { episode in
            release(
                "[AnoZu] One Piece S23E\(episode) 1080p CR WEB-DL",
                hash: Self.digits[(episode + 7) % Self.digits.count],
                publishedAt: start.addingTimeInterval(Double(episode - 6) * week)
            )
        }
        let now = start.addingTimeInterval(20 * week)
        let schedule = TorrentReleaseSchedule.analyse(results: absolute + perSeason, now: now)
        #expect(schedule.latestEpisode == 1179)
        #expect(schedule.episodeCount == 20)
        #expect(schedule.isOngoing)
    }
}

/// A season length looked up by title can be about a different work.
struct TorrentEpisodeCountSanityTests {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let week: TimeInterval = 7 * 86_400
    private static let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]

    private func season(_ range: ClosedRange<Int>) -> [TorrentSearchResult] {
        range.map { episode in
            var observation = TorrentObservation(
                source: .nyaa,
                title: "[Erai-raws] Sousou no Frieren - \(episode) [1080p]",
                infoHash: TorrentInfoHash(String(repeating: Self.digits[episode % Self.digits.count], count: 40))!,
                seeders: 50,
                publishedAt: start.addingTimeInterval(Double(episode) * week),
                category: .episode
            )
            observation.query = "Sousou no Frieren"
            return TorrentResultMerger.merge([observation], queries: ["Sousou no Frieren"])[0]
        }
    }

    @Test func aCountSmallerThanWhatIsPublishedIsIgnored() {
        // Searching the romaji title confidently matches a 12-episode
        // spin-off. Believing it would call a show at episode 20 finished and
        // take the Subscribe button away from a season that is still running.
        let now = start.addingTimeInterval(20 * week + 2 * 86_400)
        let schedule = TorrentReleaseSchedule.analyse(
            results: season(1...20), expectedEpisodeCount: 12, now: now
        )
        #expect(schedule.expectedEpisodeCount == nil)
        #expect(schedule.isOngoing)
        #expect(schedule.remainingEpisodeCount == nil)
    }

    @Test func aCountThatFitsIsUsed() {
        let now = start.addingTimeInterval(20 * week + 2 * 86_400)
        let schedule = TorrentReleaseSchedule.analyse(
            results: season(1...20), expectedEpisodeCount: 24, now: now
        )
        #expect(schedule.expectedEpisodeCount == 24)
        #expect(schedule.remainingEpisodeCount == 4)
        #expect(schedule.isOngoing)
    }

    @Test func aCountThatExactlyMatchesEndsTheSeason() {
        // Six weeks after episode 12 of twelve: nothing is coming.
        let now = start.addingTimeInterval(18 * week)
        let schedule = TorrentReleaseSchedule.analyse(
            results: season(1...12), expectedEpisodeCount: 12, now: now
        )
        #expect(!schedule.isOngoing)
        #expect(schedule.remainingEpisodeCount == 0)
    }
}
