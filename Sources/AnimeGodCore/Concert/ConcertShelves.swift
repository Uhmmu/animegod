import Foundation

/// How the concert section is arranged.
public enum ConcertSortOrder: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Grouped by the act, each group in the order the concerts happened.
    case band
    /// Flat, the most recent performance first.
    case performance
    /// Flat, the most recently released disc first.
    case release
    case title

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .band: String(localized: "Band", bundle: .module)
        case .performance: String(localized: "Performance Date", bundle: .module)
        case .release: String(localized: "Release Date", bundle: .module)
        case .title: String(localized: "Name", bundle: .module)
        }
    }

    public static let storageKey = "concerts.sortOrder"
}

/// One act's concerts.
public struct ConcertShelf: Identifiable, Sendable {
    public let band: String
    public let concerts: [LibraryConcert]

    public var id: String { band }

    public init(band: String, concerts: [LibraryConcert]) {
        self.band = band
        self.concerts = concerts
    }
}

public extension LibraryConcert {
    /// When the concert happened, ISO, from whatever shape the source wrote.
    ///
    /// A span (`2024-07-27 – 2024-07-28`, two nights) sorts by its first night,
    /// which is when the thing being watched began.
    var performanceDate: String? {
        release?.performedOn.flatMap { ConcertEventDates.dates(in: $0).first }
    }

    /// When the disc shipped, which is not when the concert happened — measured
    /// across this library, the gap runs from four months to a year and a half.
    var discReleaseDate: String? {
        release?.releaseDate.flatMap { ConcertEventDates.dates(in: $0).first }
    }

    /// The date to file it under: the night it happened, else the day it
    /// shipped. Nothing invents one.
    var sortDate: String? { performanceDate ?? discReleaseDate }
}

public enum ConcertShelves {
    /// What to call the act, for a group heading.
    ///
    /// The catalogue's own artist name when there is one — and often there is
    /// not: three of the eighteen concerts in the real library have a release
    /// with no artist on it at all, because a Bangumi 演出 subject that omits
    /// 主演 carries none. So the title answers instead, cut at the ordinal that
    /// starts the concert's own name: `Ave Mujica 1st LIVE 「Perdere Omnia」`
    /// is Ave Mujica's, and says so in its first two words.
    public static func band(of concert: LibraryConcert) -> String? {
        if let artist = concert.release?.artistNames.first?
            .trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            return artist
        }
        return bandFromTitle(concert.displayTitle)
    }

    /// The run of a title before the ordinal or the live word that starts the
    /// concert's own name.
    static func bandFromTitle(_ title: String) -> String? {
        let words = title.split(separator: " ", omittingEmptySubsequences: true)
        var act: [Substring] = []
        for word in words {
            if startsTheConcertsOwnName(String(word)) { break }
            act.append(word)
        }
        guard !act.isEmpty, act.count < words.count else { return nil }
        let name = act.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// `6th`, `12th☆LIVE`, `LIVE`, `ZEPP`, `TOUR` — where the act's name stops
    /// and the concert's begins.
    private static func startsTheConcertsOwnName(_ word: String) -> Bool {
        let folded = word.lowercased()
        if ["live", "tour", "zepp", "concert", "ライブ", "ツアー", "コンサート", "合同ライブ"]
            .contains(where: { folded.hasPrefix($0) }) { return true }
        // An ordinal: digits then `st`/`nd`/`rd`/`th`, however it is decorated.
        let digits = folded.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let rest = folded.dropFirst(digits.count)
        return ["st", "nd", "rd", "th"].contains { rest.hasPrefix($0) }
    }

    /// Grouped by act, each act's concerts **in the order they happened** —
    /// which is the order their names already count in, 1st to 9th — and the
    /// acts themselves most recent first, so the one being collected now is at
    /// the top. Concerts with no act at all come last, under one heading.
    public static func shelves(of concerts: [LibraryConcert]) -> [ConcertShelf] {
        var order: [String] = []
        var grouped: [String: [LibraryConcert]] = [:]
        var unknown: [LibraryConcert] = []
        for concert in concerts {
            guard let band = band(of: concert) else { unknown.append(concert); continue }
            // Grouped case- and width-insensitively so two spellings of one act
            // are one shelf; the heading keeps the first spelling seen.
            let key = band.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            if grouped[key] == nil { order.append(key); grouped[key] = [] }
            grouped[key]?.append(concert)
        }
        var shelves = order.compactMap { key -> ConcertShelf? in
            guard let items = grouped[key], let first = items.first else { return nil }
            return ConcertShelf(
                band: band(of: first) ?? key,
                concerts: items.sorted(by: chronologically)
            )
        }
        shelves.sort { left, right in
            let leftNewest = left.concerts.compactMap(\.sortDate).max()
            let rightNewest = right.concerts.compactMap(\.sortDate).max()
            if leftNewest != rightNewest {
                return (leftNewest ?? "") > (rightNewest ?? "")
            }
            return left.band.localizedStandardCompare(right.band) == .orderedAscending
        }
        if !unknown.isEmpty {
            shelves.append(ConcertShelf(
                band: String(localized: "Other", bundle: .module),
                concerts: unknown.sorted(by: chronologically)
            ))
        }
        return shelves
    }

    /// Oldest first, and anything undated last — a concert nobody dated is not
    /// "the oldest", it is unknown.
    static func chronologically(_ left: LibraryConcert, _ right: LibraryConcert) -> Bool {
        switch (left.sortDate, right.sortDate) {
        case let (leftDate?, rightDate?):
            if leftDate != rightDate { return leftDate < rightDate }
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): break
        }
        return left.displayTitle.localizedStandardCompare(right.displayTitle) == .orderedAscending
    }

    /// The flat orders.
    public static func sorted(_ concerts: [LibraryConcert], by order: ConcertSortOrder) -> [LibraryConcert] {
        switch order {
        case .band:
            return shelves(of: concerts).flatMap(\.concerts)
        case .performance:
            return concerts.sorted { newestFirst($0.performanceDate, $1.performanceDate, $0, $1) }
        case .release:
            return concerts.sorted { newestFirst($0.discReleaseDate, $1.discReleaseDate, $0, $1) }
        case .title:
            return concerts.sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
        }
    }

    private static func newestFirst(
        _ left: String?, _ right: String?,
        _ leftConcert: LibraryConcert, _ rightConcert: LibraryConcert
    ) -> Bool {
        switch (left, right) {
        case let (leftDate?, rightDate?):
            if leftDate != rightDate { return leftDate > rightDate }
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): break
        }
        return leftConcert.displayTitle.localizedStandardCompare(rightConcert.displayTitle)
            == .orderedAscending
    }
}
