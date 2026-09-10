import Foundation

/// One anime's contribution to a year's statistics.
public struct AnimeWatchTotal: Identifiable, Hashable, Sendable {
    public let animeID: UUID
    public let title: String
    public let watchTime: Double
    public let sessionCount: Int
    public let completedEpisodes: Int
    public var id: UUID { animeID }

    public init(animeID: UUID, title: String, watchTime: Double, sessionCount: Int, completedEpisodes: Int) {
        self.animeID = animeID
        self.title = title
        self.watchTime = watchTime
        self.sessionCount = sessionCount
        self.completedEpisodes = completedEpisodes
    }
}

public struct StudioWatchTotal: Identifiable, Hashable, Sendable {
    public let studio: String
    public let watchTime: Double
    public var id: String { studio }

    public init(studio: String, watchTime: Double) {
        self.studio = studio
        self.watchTime = watchTime
    }
}

public struct RatedAnimeEntry: Identifiable, Hashable, Sendable {
    public let animeID: UUID
    public let title: String
    public let score: Double
    public var id: UUID { animeID }

    public init(animeID: UUID, title: String, score: Double) {
        self.animeID = animeID
        self.title = title
        self.score = score
    }
}

/// Answers the diary questions of spec §17 — what did I watch, when, how
/// much, and from which studios — purely from watch history and caches.
public struct StatisticsReport: Sendable {
    public let year: Int
    public let totalWatchTime: Double
    public let sessionCount: Int
    public let completedEpisodeCount: Int
    public let distinctAnimeCount: Int
    public let monthlyWatchTime: [Double]
    public let weekdaySessions: [Int]
    public let hourSessions: [Int]
    public let topAnime: [AnimeWatchTotal]
    public let topStudios: [StudioWatchTotal]
    public let highestRated: [RatedAnimeEntry]
    public let availableYears: [Int]
}

public struct StatisticsBuilder: Sendable {
    public init() {}

    public func report(
        year: Int,
        events: [WatchEvent],
        metadataByAnimeID: [UUID: [AnimeMetadata]],
        profilesByAnimeID: [UUID: AnimeProfile],
        calendar: Calendar = .current
    ) -> StatisticsReport {
        let availableYears = Set(events.compactMap { calendar.dateComponents([.year], from: $0.endedAt).year })
            .union([year])
            .sorted(by: >)

        let inYear = events.filter { calendar.dateComponents([.year], from: $0.endedAt).year == year }

        var monthly = [Double](repeating: 0, count: 12)
        var weekday = [Int](repeating: 0, count: 7)
        var hour = [Int](repeating: 0, count: 24)
        var totals: [UUID: (watch: Double, sessions: Int, completed: Int, title: String)] = [:]

        for event in inYear {
            let components = calendar.dateComponents([.month, .weekday, .hour], from: event.endedAt)
            if let month = components.month { monthly[month - 1] += event.watchedDuration }
            if let weekdayIndex = components.weekday { weekday[weekdayIndex - 1] += 1 }
            if let hourIndex = components.hour { hour[hourIndex] += 1 }
            let title = totals[event.animeID]?.title
                ?? preferredTitle(for: event.animeID, metadata: metadataByAnimeID[event.animeID], fallback: event.animeTitle)
            var total = totals[event.animeID] ?? (watch: 0, sessions: 0, completed: 0, title: title)
            total.watch += event.watchedDuration
            total.sessions += 1
            total.completed += event.completedEpisode ? 1 : 0
            totals[event.animeID] = total
        }

        let topAnime = totals
            .map { animeID, total in
                AnimeWatchTotal(
                    animeID: animeID,
                    title: total.title,
                    watchTime: total.watch,
                    sessionCount: total.sessions,
                    completedEpisodes: total.completed
                )
            }
            .sorted { $0.watchTime > $1.watchTime }

        var studioTotals: [String: Double] = [:]
        for entry in topAnime {
            let studios = metadataByAnimeID[entry.animeID]?.compactMap(\.studios).flatMap { $0 } ?? []
            for studio in Set(studios) {
                studioTotals[studio, default: 0] += entry.watchTime
            }
        }
        let topStudios = studioTotals
            .map(StudioWatchTotal.init)
            .sorted { $0.watchTime > $1.watchTime }

        // Highest personal scores among anime actually watched that year;
        // a score never borrows weight from watch time.
        let watchedIDs = Set(totals.keys)
        let highestRated = profilesByAnimeID
            .filter { watchedIDs.contains($0.key) }
            .compactMap { animeID, profile -> RatedAnimeEntry? in
                guard let score = profile.score else { return nil }
                let title = totals[animeID]?.title ?? "Unknown Anime"
                return RatedAnimeEntry(animeID: animeID, title: title, score: score)
            }
            .sorted { $0.score > $1.score }

        return StatisticsReport(
            year: year,
            totalWatchTime: inYear.reduce(0) { $0 + $1.watchedDuration },
            sessionCount: inYear.count,
            completedEpisodeCount: inYear.reduce(0) { $0 + ($1.completedEpisode ? 1 : 0) },
            distinctAnimeCount: totals.count,
            monthlyWatchTime: monthly,
            weekdaySessions: weekday,
            hourSessions: hour,
            topAnime: topAnime,
            topStudios: topStudios,
            highestRated: Array(highestRated.prefix(10)),
            availableYears: availableYears
        )
    }

    private func preferredTitle(for animeID: UUID, metadata: [AnimeMetadata]?, fallback: String) -> String {
        let sources = metadata ?? []
        let preferred = sources.first(where: { $0.provider == .bangumi }) ?? sources.first
        return preferred?.title ?? fallback
    }
}
