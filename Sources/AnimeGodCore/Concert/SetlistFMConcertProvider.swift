import Foundation

/// setlist.fm: what was actually played, on the night it was played.
///
/// The fourth source, and the only one that is about the *concert* rather than
/// about a disc of it. That is what it is for here. Measured on the release in
/// the real library — MyGO's *6th LIVE「見つけた景色、たずさえて」*, two nights at
/// 武蔵野の森総合スポーツプラザ:
///
/// | | |
/// |---|---|
/// | 27-07-2024 | 14 songs + 2 encore, ending `Hitoshizuku` / `Otoichie` |
/// | 28-07-2024 | 14 songs + 2 encore, ending `Hitoshizuku` / `Tanebi` |
///
/// Sixteen each, which is what MusicBrainz says too — and **the two nights are
/// in a different order with a different last song**, which no other source
/// here distinguishes. It also carries the venue and the city, and the tour the
/// night belonged to.
///
/// What it does not carry is **song lengths** — so it cannot feed the chapter
/// alignment — and its song titles for Japanese artists are **romanised**
/// (`Mayoi Uta`, not `迷星叫`). Both are why it sits behind MusicBrainz and
/// Bangumi in the merge and ahead of Discogs, whose hand-entered lists are
/// measurably wrong on these releases.
///
/// Two things about the API that cost a request each to learn:
///
/// * **A request with no `User-Agent` is refused with `403 Forbidden`**, API
///   key or not. Nothing in the response says why.
/// * **An empty result is `404 Not Found`**, with a JSON body saying
///   `"not found"`. It is the ordinary answer for an artist who has no setlist
///   on that date, so treating it as an error would turn "nothing to add" into
///   a failure on the page.
/// * **It answers `406 Not Acceptable` to a language it does not publish in**,
///   and `URLSession` fills `Accept-Language` in from the system locale — so on
///   this machine every request failed until the header was set to `en`. A fault
///   that only appears for users whose Mac is not in English, which is to say
///   the ones this app is for.
public struct SetlistFMConcertProvider: Sendable {
    public let id: ConcertProviderID = .setlistFM

    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL
    private let userAgent: String
    private let pacer: ConcertRequestPacer

    /// The key allows 2 a second and 1440 a day. Paced at half a second, which
    /// is the published rate, because the daily budget is small enough that a
    /// retry storm would spend it.
    static let minimumInterval: TimeInterval = 0.55
    /// How many nights a date range may be expanded to. A two-night live is the
    /// case this exists for; a tour's twenty dates are not one release, and
    /// asking about each would spend the day's budget on one folder.
    public static let maximumNights = 4

    public init(
        apiKey: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.setlist.fm/rest/1.0")!,
        userAgent: String = "AnimeGod/0.5 ( https://github.com/Uhmmu/animegod )"
    ) {
        self.apiKey = apiKey
        self.session = session
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.pacer = ConcertRequestPacer(minimumInterval: Self.minimumInterval)
    }

    // MARK: - Lookups

    /// The setlists this artist played on these dates, in the order the dates
    /// were given.
    ///
    /// Dates are ISO (`2024-07-27`); the API wants `dd-MM-yyyy` and gets it
    /// here rather than at the call site.
    public func setlists(artist: String, isoDates: [String]) async throws -> [Setlist] {
        var found: [Setlist] = []
        for date in isoDates.prefix(Self.maximumNights) {
            guard let wire = ConcertEventDates.setlistFMDate(fromISO: date) else { continue }
            let page = try await search([
                URLQueryItem(name: "artistName", value: artist),
                URLQueryItem(name: "date", value: wire)
            ])
            found.append(contentsOf: page)
        }
        return found
    }

    /// Everything this artist played in a year, for a release that knows its
    /// title but not its dates.
    public func setlists(artist: String, year: Int) async throws -> [Setlist] {
        try await search([
            URLQueryItem(name: "artistName", value: artist),
            URLQueryItem(name: "year", value: String(year))
        ])
    }

    private func search(_ items: [URLQueryItem]) async throws -> [Setlist] {
        var components = URLComponents(
            url: baseURL.appending(path: "search/setlists"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = items
        do {
            let payload: SearchPayload = try await load(components.url!)
            return payload.setlist ?? []
        } catch MetadataProviderError.httpStatus(404) {
            // The ordinary "this artist played nothing that day".
            return []
        }
    }

    // MARK: - Transport

    private func load<T: Decodable>(_ url: URL) async throws -> T {
        await pacer.wait()
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Not optional: without it every request is 403, key or no key.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // And this one is not optional either, for the opposite reason.
        // URLSession fills `Accept-Language` in from the system locale, and
        // setlist.fm **refuses a language it does not publish in** with
        // `406 Not Acceptable` — measured: `ja` is 406, `zh-Hans-CN,zh-Hans`
        // alone is 406, `en` is 200. So the app's own language decides nothing
        // here; it would only decide whether the source works at all.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MetadataProviderError.invalidResponse }
        if http.statusCode == 404 { throw MetadataProviderError.httpStatus(404) }
        if http.statusCode == 429 {
            throw MetadataProviderError.rateLimited(retryAfter: Self.minimumInterval)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MetadataProviderError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MetadataProviderError.invalidResponse
        }
    }
}

// MARK: - Wire format

public extension SetlistFMConcertProvider {
    struct SearchPayload: Decodable, Sendable {
        public let setlist: [Setlist]?
    }

    /// One night.
    struct Setlist: Decodable, Sendable {
        public let id: String?
        /// `dd-MM-yyyy`, as the API publishes it.
        public let eventDate: String?
        public let artist: Artist?
        public let venue: Venue?
        public let tour: Tour?
        public let sets: Sets?
        public let url: String?

        public struct Artist: Decodable, Sendable {
            public let mbid: String?
            public let name: String?
        }

        public struct Venue: Decodable, Sendable {
            public let name: String?
            public let city: City?

            public struct City: Decodable, Sendable {
                public let name: String?
                public let country: Country?
                public struct Country: Decodable, Sendable { public let name: String? }
            }

            /// `武蔵野の森総合スポーツプラザ, Choufu` — the hall and the city, which
            /// is how a venue is written down. Bangumi gives the hall alone.
            public var displayName: String? {
                let parts = [name, city?.name].compactMap { $0 }.filter { !$0.isEmpty }
                return parts.isEmpty ? nil : parts.joined(separator: ", ")
            }
        }

        public struct Tour: Decodable, Sendable { public let name: String? }

        public struct Sets: Decodable, Sendable {
            public let set: [Section]?

            public struct Section: Decodable, Sendable {
                /// 1 for the first encore, 2 for the second. Absent on the main
                /// set, which is how the encore is told apart.
                public let encore: Int?
                public let name: String?
                public let song: [Song]?

                public struct Song: Decodable, Sendable {
                    public let name: String?
                    /// `with …`, `acoustic`, or a note about a guest. Kept out
                    /// of the title and shown as it is.
                    public let info: String?
                    /// A cover: the original artist, when the song is not the
                    /// performer's own.
                    public let cover: Cover?
                    public struct Cover: Decodable, Sendable { public let name: String? }
                }
            }
        }

        /// The songs of this night, in order, encores marked.
        ///
        /// A `tape` — walk-on music the editors note — has no name and is
        /// dropped: it is not a song anybody played.
        public var tracks: [ConcertTrack] {
            var tracks: [ConcertTrack] = []
            for section in sets?.set ?? [] {
                for song in section.song ?? [] {
                    guard let title = song.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !title.isEmpty
                    else { continue }
                    tracks.append(ConcertTrack(
                        position: tracks.count + 1,
                        title: title,
                        duration: nil,
                        kind: .song,
                        isEncore: section.encore != nil
                    ))
                }
            }
            return tracks
        }

        /// ISO, so it can sit beside every other date in the app.
        public var isoDate: String? { ConcertEventDates.iso(fromSetlistFM: eventDate) }
    }
}

// MARK: - Building a release

public extension SetlistFMConcertProvider {
    /// Folds a run of nights into one record: one disc per night, in date
    /// order, with the venue and the span they covered.
    ///
    /// One record rather than one per night because that is what the release
    /// is — two nights of one tour are one Blu-ray, which is also how the
    /// library files them.
    static func release(from setlists: [Setlist], fallbackTitle: String) -> ConcertRelease? {
        let nights = setlists
            .filter { !$0.tracks.isEmpty }
            .sorted { ($0.isoDate ?? "") < ($1.isoDate ?? "") }
        guard !nights.isEmpty, let first = nights.first else { return nil }
        let dates = nights.compactMap(\.isoDate)
        let title = first.tour?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        var release = ConcertRelease(
            provider: .setlistFM,
            externalID: first.id ?? dates.first ?? fallbackTitle,
            title: (title?.isEmpty == false ? title! : fallbackTitle),
            artistNames: [first.artist?.name].compactMap { $0 }.filter { !$0.isEmpty },
            discs: nights.enumerated().map { index, night in
                ConcertDisc(
                    position: index + 1,
                    // The night's date, which is the only thing that tells two
                    // nights apart. Shown only when no catalogue named the
                    // disc, since those names are better.
                    title: night.isoDate,
                    // Marked as video so the page and the aligner can see it:
                    // this is the programme of what is on the disc, whatever
                    // medium it was pressed on.
                    format: "Blu-ray",
                    tracks: night.tracks
                )
            },
            sourceURL: first.url.flatMap(URL.init(string:))
        )
        release.venue = first.venue?.displayName
        release.performedOn = dates.count > 1 ? "\(dates.first!) – \(dates.last!)" : dates.first
        // Every record here is a performance that happened. It is the third
        // machine-readable "this is a concert" in the app, after MusicBrainz's
        // `Live` secondary type and Bangumi's 演出 subject.
        release.isLiveRecording = true
        return release
    }
}

/// Reading and writing the dates a concert happened on.
///
/// Its own type because three spellings have to meet: Bangumi writes a range
/// (`2024-07-27 – 2024-07-28`, from its 开始/结束 infobox fields), setlist.fm
/// wants `dd-MM-yyyy`, and the app stores ISO.
public enum ConcertEventDates {
    /// Every date a string names, ISO, in order — and the nights in between
    /// when it names a range.
    ///
    /// A two-night live is published as its first and last day, so expanding
    /// the span is what turns one Bangumi field into the two queries that find
    /// both nights. Capped, because a tour's span is not a release.
    public static func dates(in text: String, limit: Int = SetlistFMConcertProvider.maximumNights) -> [String] {
        let found = triples(in: text)
        guard let first = found.first else { return [] }
        guard let last = found.dropFirst().last, last != first else { return [iso(first)] }
        guard let start = date(from: first), let end = date(from: last), start < end else {
            return found.prefix(limit).map(iso)
        }
        var dates: [String] = []
        var cursor = start
        let calendar = Calendar(identifier: .gregorian)
        while cursor <= end, dates.count < limit {
            dates.append(iso(components(of: cursor, calendar: calendar)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return dates
    }

    /// `2024-07-27` → `27-07-2024`.
    public static func setlistFMDate(fromISO iso: String) -> String? {
        guard let triple = triples(in: iso).first else { return nil }
        return String(format: "%02d-%02d-%04d", triple.day, triple.month, triple.year)
    }

    /// `27-07-2024` → `2024-07-27`.
    public static func iso(fromSetlistFM date: String?) -> String? {
        guard let date else { return nil }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return String(format: "%04d-%02d-%02d", parts[2], parts[1], parts[0])
    }

    /// The year a date string names, for the fallback search.
    public static func year(in text: String) -> Int? { triples(in: text).first?.year }

    // MARK: - Reading

    private struct Triple: Equatable { let year: Int; let month: Int; let day: Int }

    /// Every `year, month, day` a string holds, however it spells them:
    /// `2024-07-27`, `2024/7/27`, `2024年7月27日`, `2024.07.27`.
    private static func triples(in text: String) -> [Triple] {
        var numbers: [Int] = []
        var current = ""
        var found: [Triple] = []
        func flush() {
            if let value = Int(current) { numbers.append(value) }
            current = ""
            // A year leads, so four digits start a new date and anything
            // before three numbers is not one yet.
            while numbers.count >= 3 {
                let candidate = Triple(year: numbers[0], month: numbers[1], day: numbers[2])
                numbers.removeFirst(3)
                guard candidate.year > 1900, candidate.year < 2200,
                      (1...12).contains(candidate.month), (1...31).contains(candidate.day)
                else { continue }
                found.append(candidate)
            }
        }
        for character in text {
            if character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return found
    }

    private static func iso(_ triple: Triple) -> String {
        String(format: "%04d-%02d-%02d", triple.year, triple.month, triple.day)
    }

    private static func date(from triple: Triple) -> Date? {
        var components = DateComponents()
        components.year = triple.year
        components.month = triple.month
        components.day = triple.day
        return Calendar(identifier: .gregorian).date(from: components)
    }

    private static func components(of date: Date, calendar: Calendar) -> Triple {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return Triple(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1)
    }
}

// MARK: - Asking it what it is for

/// The one source asked by **artist and date** rather than by a catalogue key.
///
/// Its own protocol rather than another `ConcertReleaseSource`, because that
/// protocol's questions — a catalogue number, a barcode, a title — are the
/// wrong ones here: setlist.fm indexes none of them. A night is identified by
/// who played and when, which is exactly what the other three sources have
/// already told us by the time this is asked.
public protocol ConcertEventSource: Sendable {
    var id: ConcertProviderID { get }
    func concert(
        artist: String,
        isoDates: [String],
        year: Int?,
        fallbackTitle: String
    ) async throws -> ConcertRelease?
}

extension SetlistFMConcertProvider: ConcertEventSource {
    /// The nights of one concert, by the dates when they are known and by the
    /// tour's name when they are not.
    public func concert(
        artist: String,
        isoDates: [String],
        year: Int?,
        fallbackTitle: String
    ) async throws -> ConcertRelease? {
        let performer = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !performer.isEmpty else { return nil }
        if !isoDates.isEmpty {
            let nights = try await setlists(artist: performer, isoDates: isoDates)
            if let release = Self.release(from: nights, fallbackTitle: fallbackTitle) { return release }
        }
        // No dates: a year of this artist's nights, kept only where the tour
        // they belonged to is the one on the box.
        guard let year else { return nil }
        let nights = try await setlists(artist: performer, year: year)
        let onThisTour = nights.filter { Self.tourMatches(title: fallbackTitle, tour: $0.tour?.name) }
        return Self.release(from: onThisTour, fallbackTitle: fallbackTitle)
    }

    /// Whether a night's tour is the concert on the box.
    ///
    /// Compared on Latin words only, and that is the point: setlist.fm
    /// romanises Japanese, so the subtitle never matches — `MyGO!!!!! 6th LIVE
    /// "Mitsuketa Keshiki, Tazusaete"` against
    /// `MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」` shares `mygo`, `6th` and
    /// `live` and nothing else. That is enough, and it is what separates it
    /// from the same artist's `ZEPP TOUR 2024「彷徨する渇望」`, which shares only
    /// the name. Fewer than two Latin words to go on and the answer is no: a
    /// title written entirely in Japanese cannot be checked this way, and
    /// filing the wrong night's setlist is worse than filing none.
    static func tourMatches(title: String, tour: String?) -> Bool {
        guard let tour else { return false }
        let wanted = latinWords(in: title)
        guard wanted.count >= 2 else { return false }
        let offered = latinWords(in: tour)
        let shared = wanted.intersection(offered)
        return shared.count >= 2 && Double(shared.count) / Double(wanted.count) >= 0.6
    }

    private static func latinWords(in text: String) -> Set<String> {
        var words: Set<String> = []
        var current = ""
        func flush() {
            // A word of one character is a numeral or an initial and says
            // nothing; the ordinal `6th` survives because it is three.
            if current.count >= 2 { words.insert(current) }
            current = ""
        }
        for character in text.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return words
    }
}
