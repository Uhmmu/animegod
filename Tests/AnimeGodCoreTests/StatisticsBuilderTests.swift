import Foundation
import Testing
@testable import AnimeGodCore

struct StatisticsBuilderTests {
    /// Fixed GMT calendar keeps weekday/hour buckets deterministic.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func event(
        animeID: UUID,
        title: String,
        on date: Date,
        duration: Double,
        completed: Bool = false
    ) -> WatchEvent {
        WatchEvent(
            animeID: animeID,
            episodeID: UUID(),
            animeTitle: title,
            episodeLabel: "Episode 1",
            startedAt: date.addingTimeInterval(-duration),
            endedAt: date,
            watchedDuration: duration,
            completion: completed ? 1 : 0.5,
            completedEpisode: completed
        )
    }

    @Test func aggregatesAYearOfWatchingHabits() {
        let frieren = UUID(), mygo = UUID()
        // 2026-01-10 is a Saturday in GMT; 18:00 local bucket.
        let events = [
            event(animeID: frieren, title: "Frieren", on: date(2026, 1, 10, 18), duration: 1440, completed: true),
            event(animeID: frieren, title: "Frieren", on: date(2026, 3, 15, 21), duration: 1440),
            event(animeID: mygo, title: "MyGO", on: date(2026, 3, 16, 22), duration: 2400, completed: true),
            // A different year must stay out of the 2026 report.
            event(animeID: mygo, title: "MyGO", on: date(2025, 12, 31, 23), duration: 5000)
        ]
        let metadata: [UUID: [AnimeMetadata]] = [
            frieren: [metadataFor(frieren, title: "Sousou no Frieren", studios: ["Madhouse"])],
            mygo: [metadataFor(mygo, title: "BanG Dream! It's MyGO!!!!!", studios: ["SANZIGEN"])]
        ]
        let profiles: [UUID: AnimeProfile] = [
            frieren: profileFor(frieren, score: 9.5),
            mygo: profileFor(mygo, score: 8.0)
        ]

        let report = StatisticsBuilder().report(
            year: 2026,
            events: events,
            metadataByAnimeID: metadata,
            profilesByAnimeID: profiles,
            calendar: calendar
        )

        #expect(report.totalWatchTime == 5280)
        #expect(report.sessionCount == 3)
        #expect(report.completedEpisodeCount == 2)
        #expect(report.distinctAnimeCount == 2)
        #expect(report.availableYears == [2026, 2025])

        // Monthly buckets: January and March.
        #expect(report.monthlyWatchTime[0] == 1440)
        #expect(report.monthlyWatchTime[2] == 3840)
        #expect(report.monthlyWatchTime[11] == 0)

        // Weekday: Calendar.weekday is 1=Sunday … 7=Saturday.
        // 2026-01-10 is a Saturday, 03-15 a Sunday, 03-16 a Monday.
        #expect(report.weekdaySessions[7 - 1] == 1)  // Saturday
        #expect(report.weekdaySessions[0] == 1)      // Sunday
        #expect(report.weekdaySessions[1] == 1)      // Monday

        // Hours 18, 21, 22 each got one session.
        #expect(report.hourSessions[18] == 1)
        #expect(report.hourSessions[21] == 1)
        #expect(report.hourSessions[22] == 1)

        // Top anime ordered by watch time with metadata titles preferred.
        // Frieren: 1440 + 1440 = 2880s in 2026; MyGO: 2400s (2025 excluded).
        #expect(report.topAnime.first?.animeID == frieren)
        #expect(report.topAnime.first?.title == "Sousou no Frieren")
        #expect(report.topAnime.last?.title == "BanG Dream! It's MyGO!!!!!")

        // Studios aggregate over their anime's in-year watch time.
        #expect(report.topStudios.first?.studio == "Madhouse")
        #expect(report.topStudios.first?.watchTime == 2880)
        #expect(report.topStudios.last?.studio == "SANZIGEN")

        // Personal scores only include anime actually watched in the year.
        #expect(report.highestRated.first?.score == 9.5)
        #expect(report.highestRated.count == 2)
    }

    @Test func emptyHistoryProducesAnEmptyButValidReport() {
        let report = StatisticsBuilder().report(
            year: 2026,
            events: [],
            metadataByAnimeID: [:],
            profilesByAnimeID: [:],
            calendar: calendar
        )
        #expect(report.totalWatchTime == 0)
        #expect(report.sessionCount == 0)
        #expect(report.distinctAnimeCount == 0)
        #expect(report.topAnime.isEmpty)
        #expect(report.topStudios.isEmpty)
        #expect(report.highestRated.isEmpty)
        #expect(report.availableYears == [2026])
    }

    @Test func studioAggregationSplitsWatchTimeAcrossKnownStudios() {
        let anime = UUID()
        let events = [event(animeID: anime, title: "Show", on: date(2026, 6, 1, 20), duration: 3600)]
        let metadata: [UUID: [AnimeMetadata]] = [
            anime: [metadataFor(anime, title: "Show", studios: ["Studio A", "Studio B"])]
        ]

        let report = StatisticsBuilder().report(
            year: 2026, events: events, metadataByAnimeID: metadata, profilesByAnimeID: [:], calendar: calendar
        )

        // Co-productions credit every listed studio with the watch time.
        #expect(report.topStudios.map(\.studio).sorted() == ["Studio A", "Studio B"])
        #expect(report.topStudios.allSatisfy { $0.watchTime == 3600 })
    }

    private func metadataFor(_ animeID: UUID, title: String, studios: [String]) -> AnimeMetadata {
        AnimeMetadata(
            animeID: animeID,
            provider: .bangumi,
            externalID: "1",
            title: title,
            originalTitle: title,
            summary: "",
            posterURL: nil,
            airDate: nil,
            platform: nil,
            score: nil,
            rank: nil,
            ratingCount: nil,
            studios: studios
        )
    }

    private func profileFor(_ animeID: UUID, score: Double) -> AnimeProfile {
        AnimeProfile(animeID: animeID, status: .completed, score: score)
    }
}
