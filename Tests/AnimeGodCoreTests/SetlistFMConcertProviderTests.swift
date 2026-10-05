import Foundation
import Testing

@testable import AnimeGodCore

/// setlist.fm is the only source here that is about the concert rather than a
/// disc of it, and the fixtures are its real answers for the release in the
/// library: MyGO's *6th LIVE*, 27 and 28 July 2024, trimmed to the fields that
/// are read.
@Suite(.serialized)
struct SetlistFMConcertProviderTests {
    static let firstNightJSON = #"""
    {"type":"setlists","itemsPerPage":20,"page":1,"total":1,"setlist":[{"id":"63ab8213","versionId":"g5b42a7a4","eventDate":"27-07-2024","artist":{"mbid":"be91faa6-5277-4b73-b97c-10786db10598","name":"MyGO!!!!!"},"venue":{"name":"Musashino no Mori Sougou Sports Plaza","city":{"name":"Choufu","country":{"name":"Japan"}}},"tour":{"name":"MyGO!!!!! 6th LIVE \"Mitsuketa Keshiki, Tazusaete\""},"sets":{"set":[{"song":[{"name":"Mayoi Uta"},{"name":"Utaimashou Narashimashou"},{"name":"Sasurai"},{"name":"Melody"},{"name":"Hekitenbansou"},{"name":"Kokyuu","info":"Live debut"},{"name":"Silhouette Dance"},{"name":"Senzai Hyoumei"},{"name":"Refrain","info":"Live debut"},{"name":"Noroshi"},{"name":"Kaisou"},{"name":"Namonaki"},{"name":"Utakotoba"},{"name":"Panorama","info":"Live debut"}]},{"encore":1,"song":[{"name":"Hitoshizuku"},{"name":"Otoichie"}]}]},"url":"https://www.setlist.fm/setlist/mygo/2024/musashino-no-mori-sougou-sports-plaza-choufu-japan-63ab8213.html"}]}
    """#

    static let secondNightJSON = #"""
    {"type":"setlists","itemsPerPage":20,"page":1,"total":1,"setlist":[{"id":"63ab820b","versionId":"g4342a79b","eventDate":"28-07-2024","artist":{"mbid":"be91faa6-5277-4b73-b97c-10786db10598","name":"MyGO!!!!!"},"venue":{"name":"Musashino no Mori Sougou Sports Plaza","city":{"name":"Choufu","country":{"name":"Japan"}}},"tour":{"name":"MyGO!!!!! 6th LIVE \"Mitsuketa Keshiki, Tazusaete\""},"sets":{"set":[{"song":[{"name":"Kokyuu"},{"name":"Noroshi"},{"name":"Silhouette Dance"},{"name":"Refrain"},{"name":"Senzai Hyoumei"},{"name":"Kaisou"},{"name":"Mayoi Uta"},{"name":"Utaimashou Narashimashou"},{"name":"Sasurai"},{"name":"Melody"},{"name":"Hekitenbansou"},{"name":"Namonaki"},{"name":"Utakotoba"},{"name":"Panorama"}]},{"encore":1,"song":[{"name":"Hitoshizuku"},{"name":"Tanebi"}]}]},"url":"https://www.setlist.fm/setlist/mygo/2024/musashino-no-mori-sougou-sports-plaza-choufu-japan-63ab820b.html"}]}
    """#

    private func provider() -> SetlistFMConcertProvider {
        SetlistFMConcertProvider(
            apiKey: "test-key",
            session: SetlistFMStubURLProtocol.makeSession(),
            baseURL: URL(string: "https://setlist.example.test/rest/1.0")!
        )
    }

    /// Both nights, read as the two nights of one release.
    @Test func readsTwoNightsAsOneRelease() async throws {
        SetlistFMStubURLProtocol.reset(responses: [
            "artistName=MyGO!!!!!&date=27-07-2024": Self.firstNightJSON,
            "artistName=MyGO!!!!!&date=28-07-2024": Self.secondNightJSON,
        ])
        let nights = try await provider().setlists(
            artist: "MyGO!!!!!", isoDates: ["2024-07-27", "2024-07-28"]
        )
        #expect(nights.count == 2)

        let release = try #require(SetlistFMConcertProvider.release(
            from: nights, fallbackTitle: "MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」"
        ))
        #expect(release.provider == .setlistFM)
        // Every record here is a performance that happened, which is the third
        // machine-readable "this is a concert" in the app.
        #expect(release.isLiveRecording)
        #expect(release.artistNames == ["MyGO!!!!!"])
        #expect(release.title == #"MyGO!!!!! 6th LIVE "Mitsuketa Keshiki, Tazusaete""#)
        // The hall and the city. Bangumi gives the hall alone.
        #expect(release.venue == "Musashino no Mori Sougou Sports Plaza, Choufu")
        #expect(release.performedOn == "2024-07-27 – 2024-07-28")
        #expect(release.discs.count == 2)
        #expect(release.discs.map(\.title) == ["2024-07-27", "2024-07-28"])
        // Sixteen songs each, which is what MusicBrainz says for the same two
        // discs.
        #expect(release.discs.map { $0.songs.count } == [16, 16])
        #expect(release.songCount == 32)
    }

    /// The two nights are **not** the same concert twice, and this is the only
    /// source that knows: a different running order and a different last song.
    @Test func tellsTheTwoNightsApart() async throws {
        SetlistFMStubURLProtocol.reset(responses: [
            "artistName=MyGO!!!!!&date=27-07-2024": Self.firstNightJSON,
            "artistName=MyGO!!!!!&date=28-07-2024": Self.secondNightJSON,
        ])
        let nights = try await provider().setlists(
            artist: "MyGO!!!!!", isoDates: ["2024-07-27", "2024-07-28"]
        )
        let first = try #require(nights.first).tracks
        let second = try #require(nights.last).tracks

        #expect(first.first?.title == "Mayoi Uta")
        #expect(second.first?.title == "Kokyuu")
        #expect(first.last?.title == "Otoichie")
        #expect(second.last?.title == "Tanebi")
        // Fourteen in the main set, two in the encore, and the encore is
        // flagged rather than renumbered.
        #expect(first.filter(\.isEncore).map(\.title) == ["Hitoshizuku", "Otoichie"])
        #expect(first.map(\.position) == Array(1...16))
        // No source publishes where a song starts, and this one does not
        // pretend to: no lengths either.
        #expect(first.allSatisfy { $0.duration == nil })
    }

    /// An ISO date goes out in the API's own `dd-MM-yyyy`, and a User-Agent
    /// goes with it — without one every request is refused with 403, API key
    /// or not.
    @Test func sendsTheDateAndAUserAgentTheAPIAccepts() async throws {
        SetlistFMStubURLProtocol.reset(responses: [
            "artistName=MyGO!!!!!&date=27-07-2024": Self.firstNightJSON,
        ])
        _ = try await provider().setlists(artist: "MyGO!!!!!", isoDates: ["2024-07-27"])

        let request = try #require(SetlistFMStubURLProtocol.requests.last)
        #expect(request.url?.query()?.contains("date=27-07-2024") == true)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.isEmpty == false)
        // And the language is pinned. `URLSession` would otherwise send the
        // system's, and the API answers `406 Not Acceptable` to a language it
        // does not publish in — measured against the real service: `ja` is 406
        // and `en` is 200, so a Mac in Japanese or Chinese got nothing at all.
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
    }

    /// 404 is how the API says "nobody played that day". Reporting it as a
    /// failure would turn nothing-to-add into an error on the page.
    @Test func anEmptyResultIsNotAFailure() async throws {
        SetlistFMStubURLProtocol.reset(responses: [:])
        let nights = try await provider().setlists(artist: "Nobody", isoDates: ["2020-01-01"])
        #expect(nights.isEmpty)
        #expect(SetlistFMConcertProvider.release(from: nights, fallbackTitle: "x") == nil)
    }

    /// With no dates to go on, a year of the artist's nights is narrowed by the
    /// tour's name — on Latin words only, because the subtitle is romanised
    /// there and Japanese here.
    @Test func matchesATourAcrossTheRomanisation() {
        let title = "MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」"
        #expect(SetlistFMConcertProvider.tourMatches(
            title: title, tour: #"MyGO!!!!! 6th LIVE "Mitsuketa Keshiki, Tazusaete""#
        ))
        // The same artist's other tour that year shares only the name.
        #expect(!SetlistFMConcertProvider.tourMatches(
            title: title, tour: #"MyGO!!!!! ZEPP TOUR 2024 "Houkousuru Katsubou""#
        ))
        #expect(!SetlistFMConcertProvider.tourMatches(title: title, tour: nil))
        // Nothing Latin to compare: refused rather than guessed.
        #expect(!SetlistFMConcertProvider.tourMatches(
            title: "結束バンドLIVE-恒星-", tour: #"Kessoku Band LIVE "Kosei""#
        ))
    }
}

/// Its own stub class, not a shared one. `.serialized` orders the tests inside
/// a suite and says nothing about two suites, so two suites sharing one static
/// registry overwrite each other's fixtures.
final class SetlistFMStubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var responses: [String: String] = [:]
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    private static let lock = NSLock()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SetlistFMStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset(responses: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        Self.responses = responses
        Self.seen = []
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Keyed on the query: every call is the same path, and the date is the
        // whole question.
        let query = request.url?.query()?.replacingOccurrences(of: "%21", with: "!") ?? ""
        Self.lock.lock()
        let body = Self.responses[query]
        Self.seen.append(request)
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The dates a concert happened on, in the three spellings that have to meet:
/// Bangumi's 开始/结束 span, setlist.fm's `dd-MM-yyyy`, and the app's ISO.
@Suite("Concert event dates")
struct ConcertEventDatesTests {
    /// The case this exists for: Bangumi publishes a two-night live as its
    /// first and last day, and setlist.fm has to be asked about each night.
    @Test func expandsARangeIntoItsNights() {
        #expect(ConcertEventDates.dates(in: "2024-07-27 – 2024-07-28")
            == ["2024-07-27", "2024-07-28"])
        #expect(ConcertEventDates.dates(in: "2024-07-27") == ["2024-07-27"])
        #expect(ConcertEventDates.dates(in: "2026年2月28日") == ["2026-02-28"])
        #expect(ConcertEventDates.dates(in: "2023/5/21") == ["2023-05-21"])
        #expect(ConcertEventDates.dates(in: "") == [])
    }

    /// A tour's span is not a release, and asking about every day of one would
    /// spend the key's daily budget on a single folder.
    @Test func capsTheExpansion() {
        let dates = ConcertEventDates.dates(in: "2024-01-01 – 2024-12-31")
        #expect(dates.count == SetlistFMConcertProvider.maximumNights)
        #expect(dates.first == "2024-01-01")
    }

    @Test func convertsBothWays() {
        #expect(ConcertEventDates.setlistFMDate(fromISO: "2024-07-27") == "27-07-2024")
        #expect(ConcertEventDates.iso(fromSetlistFM: "27-07-2024") == "2024-07-27")
        #expect(ConcertEventDates.iso(fromSetlistFM: nil) == nil)
        #expect(ConcertEventDates.year(in: "2024-07-27 – 2024-07-28") == 2024)
    }

    /// A release date with no day on it still names a year, and the year is
    /// what the fallback search needs.
    @Test func readsAPartialDate() {
        #expect(ConcertEventDates.year(in: "2023-11") == nil)
        #expect(ConcertEventDates.year(in: "2023-11-22") == 2023)
    }

    /// Opt-in, and the one that would catch the API moving under us. Needs
    /// `ANIMEGOD_LIVE_TESTS=1` and `ANIMEGOD_SETLISTFM_KEY`.
    @Test func liveContractSmokeTest() async throws {
        guard ProcessInfo.processInfo.environment["ANIMEGOD_LIVE_TESTS"] == "1",
              let key = ProcessInfo.processInfo.environment["ANIMEGOD_SETLISTFM_KEY"]
        else { return }

        let provider = SetlistFMConcertProvider(apiKey: key)
        let release = try #require(await provider.concert(
            artist: "MyGO!!!!!",
            isoDates: ConcertEventDates.dates(in: "2024-07-27 – 2024-07-28"),
            year: 2024,
            fallbackTitle: "MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」"
        ))
        #expect(release.discs.count == 2)
        #expect(release.discs.map { $0.songs.count } == [16, 16])
        #expect(release.venue?.contains("Musashino") == true)
        #expect(release.isLiveRecording)
        // Different last song each night is the fact no other source here has.
        #expect(release.discs.first?.songs.last?.title != release.discs.last?.songs.last?.title)

        // And the year fallback finds the same tour without being told a date.
        let byTour = try #require(await provider.concert(
            artist: "MyGO!!!!!",
            isoDates: [],
            year: 2024,
            fallbackTitle: "MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」"
        ))
        #expect(byTour.discs.allSatisfy { $0.songs.count == 16 })
    }
}
