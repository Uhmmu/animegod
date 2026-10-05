import Foundation
import Testing
@testable import AnimeGodCore

/// The order the sources are asked in is the design, so it is tested without
/// any of them: a fake records what it was asked.
struct ConcertIdentifierTests {
    private actor Log {
        var asked: [String] = []
        func record(_ entry: String) { asked.append(entry) }
    }

    private struct FakeSource: ConcertReleaseSource {
        let id: ConcertProviderID
        var byCatalogNumber: [String: ConcertRelease] = [:]
        var byTitle: [ConcertRelease] = []
        var full: [String: ConcertRelease] = [:]
        var throwsEverything: Bool = false
        let log: Log

        func releases(catalogNumber: ConcertCatalogNumber) async throws -> [ConcertRelease] {
            await log.record("\(id.rawValue):catno:\(catalogNumber.description)")
            if throwsEverything { throw MetadataProviderError.httpStatus(503) }
            return [byCatalogNumber[catalogNumber.description]].compactMap { $0 }
        }

        func releases(title: String, artist: String?) async throws -> [ConcertRelease] {
            await log.record("\(id.rawValue):title:\(title)")
            if throwsEverything { throw MetadataProviderError.httpStatus(503) }
            return byTitle
        }

        func release(id externalID: String) async throws -> ConcertRelease {
            await log.record("\(id.rawValue):release:\(externalID)")
            if throwsEverything { throw MetadataProviderError.httpStatus(503) }
            return full[externalID] ?? byCatalogNumber.values.first!
        }
    }

    private func stub(
        _ provider: ConcertProviderID,
        externalID: String,
        title: String,
        isPerformance: Bool = false,
        isLive: Bool = false,
        venue: String? = nil,
        songs: Int = 0
    ) -> ConcertRelease {
        ConcertRelease(
            provider: provider,
            externalID: externalID,
            title: title,
            catalogNumbers: ["ANZX-10294"],
            discs: songs == 0 ? [] : [ConcertDisc(position: 1, format: "Blu-ray", tracks:
                (1...songs).map { ConcertTrack(position: $0, title: "Song \($0)", duration: 240) })],
            venue: venue,
            isPerformanceRecord: isPerformance,
            isLiveRecording: isLive
        )
    }

    // MARK: - The happy path

    @Test func identifiesByCatalogueNumberThenAsksBangumiByTheRealTitle() async throws {
        let log = Log()
        let discogs = FakeSource(
            id: .discogs,
            byCatalogNumber: ["ANZX-10294": stub(.discogs, externalID: "30770007", title: "結束バンド LIVE-恒星-")],
            log: log
        )
        let musicBrainz = FakeSource(
            id: .musicBrainz,
            byCatalogNumber: ["ANZX-10294": stub(.musicBrainz, externalID: "295db787", title: "結束バンドLIVE-恒星-")],
            full: ["295db787": stub(.musicBrainz, externalID: "295db787",
                                    title: "結束バンドLIVE-恒星-", isLive: true, songs: 16)],
            log: log
        )
        let bangumi = FakeSource(
            id: .bangumi,
            byTitle: [
                stub(.bangumi, externalID: "466281", title: "結束バンドLIVE-恒星-",
                     isPerformance: true, isLive: true, venue: "Zepp Haneda（TOKYO）"),
                stub(.bangumi, externalID: "512098", title: "結束バンドLIVE-恒星")
            ],
            full: [
                "466281": stub(.bangumi, externalID: "466281", title: "結束バンドLIVE-恒星-",
                               isPerformance: true, isLive: true, venue: "Zepp Haneda（TOKYO）"),
                "512098": stub(.bangumi, externalID: "512098", title: "結束バンドLIVE-恒星")
            ],
            log: log
        )

        let found = await ConcertIdentifier(discogs: discogs, musicBrainz: musicBrainz, bangumi: bangumi)
            .identify(folderName: "[ANZX-10294~10296] 結束バンドLIVE-恒星- [BDMV][1080P]")

        let release = try #require(found.release)
        #expect(found.catalogNumber?.description == "ANZX-10294")
        #expect(release.venue == "Zepp Haneda（TOKYO）")
        #expect(release.songCount == 16)
        // A source said it is live, so it moves into the section on its own.
        #expect(found.isConcert)
        #expect(found.failures.isEmpty)

        // Bangumi is asked with the *release's* title, not the folder's — that
        // is the whole reason it is asked last.
        let asked = await log.asked
        #expect(asked.contains("bangumi:title:結束バンドLIVE-恒星-"))
        #expect(!asked.contains { $0.contains("BDMV") })
        // And both of Bangumi's halves are fetched, because neither has the
        // other's half of the answer.
        #expect(asked.contains("bangumi:release:466281"))
        #expect(asked.contains("bangumi:release:512098"))
    }

    // MARK: - What it refuses to do

    /// A folder with no catalogue number is left alone. A title search is not a
    /// fallback: MusicBrainz answers "MyGO!!!!! 2nd Live" with another artist's
    /// release at score 100, and filing a disc under the wrong concert
    /// automatically is worse than leaving it for someone to search by hand.
    @Test func doesNotGuessFromATitle() async throws {
        let log = Log()
        let musicBrainz = FakeSource(
            id: .musicBrainz,
            byTitle: [stub(.musicBrainz, externalID: "wrong", title: "2nd LIVEパラレルタイム")],
            log: log
        )
        let found = await ConcertIdentifier(musicBrainz: musicBrainz)
            .identify(folderName: "MyGO!!!!! 2nd LIVE そのままを抱きしめて [BDMV]")

        #expect(found.release == nil)
        #expect(found.isUnknown)
        #expect(await log.asked.isEmpty, "nothing should have been asked at all")
    }

    /// A service being down is not the same as a disc nobody has heard of, and
    /// only one of the two is worth retrying.
    @Test func reportsAFailureRatherThanCallingTheDiscUnknown() async throws {
        let log = Log()
        let discogs = FakeSource(id: .discogs, throwsEverything: true, log: log)
        let found = await ConcertIdentifier(discogs: discogs)
            .identify(folderName: "[ANZX-10294] 結束バンドLIVE-恒星-")

        #expect(found.release == nil)
        #expect(!found.isUnknown)
        #expect(found.failures[.discogs] != nil)
    }

    /// One source answering is enough; the other failing must not lose it.
    @Test func keepsWhatOneSourceAnsweredWhenTheOtherFails() async throws {
        let log = Log()
        let discogs = FakeSource(id: .discogs, throwsEverything: true, log: log)
        let musicBrainz = FakeSource(
            id: .musicBrainz,
            byCatalogNumber: ["ANZX-10294": stub(.musicBrainz, externalID: "295db787", title: "結束バンドLIVE-恒星-")],
            full: ["295db787": stub(.musicBrainz, externalID: "295db787",
                                    title: "結束バンドLIVE-恒星-", isLive: true, songs: 16)],
            log: log
        )
        let found = await ConcertIdentifier(discogs: discogs, musicBrainz: musicBrainz)
            .identify(folderName: "[ANZX-10294] 結束バンドLIVE-恒星-")

        #expect(found.release?.songCount == 16)
        #expect(found.failures[.discogs] != nil)
        #expect(found.isConcert)
    }

    /// Bangumi failing costs the hall and nothing else.
    @Test func bangumiFailingKeepsTheSetlist() async throws {
        let log = Log()
        let musicBrainz = FakeSource(
            id: .musicBrainz,
            byCatalogNumber: ["ANZX-10294": stub(.musicBrainz, externalID: "295db787", title: "結束バンドLIVE-恒星-")],
            full: ["295db787": stub(.musicBrainz, externalID: "295db787",
                                    title: "結束バンドLIVE-恒星-", isLive: true, songs: 16)],
            log: log
        )
        let bangumi = FakeSource(id: .bangumi, throwsEverything: true, log: log)
        let found = await ConcertIdentifier(musicBrainz: musicBrainz, bangumi: bangumi)
            .identify(folderName: "[ANZX-10294] 結束バンドLIVE-恒星-")

        #expect(found.release?.songCount == 16)
        #expect(found.release?.venue == nil)
        #expect(found.failures[.bangumi] != nil)
    }

    /// An ordinary anime Blu-ray carries a catalogue number too, and nothing
    /// about it says "live" — so it must not be swept into the concert section.
    @Test func doesNotCallAnAnimeDiscAConcert() async throws {
        let log = Log()
        let musicBrainz = FakeSource(
            id: .musicBrainz,
            byCatalogNumber: ["ANZX-10294": stub(.musicBrainz, externalID: "x", title: "Ave Mujica Blu-ray 1")],
            full: ["x": stub(.musicBrainz, externalID: "x", title: "Ave Mujica Blu-ray 1", songs: 2)],
            log: log
        )
        let found = await ConcertIdentifier(musicBrainz: musicBrainz)
            .identify(folderName: "[ANZX-10294] Ave Mujica [BDMV]")

        #expect(found.release != nil)
        #expect(!found.isConcert)
    }
}

/// The whole chain against the real services, opt-in.
///
/// The fakes above prove the order; this proves the order still describes what
/// the services do. Needs `ANIMEGOD_LIVE_TESTS=1`, and `ANIMEGOD_DISCOGS_KEY` /
/// `ANIMEGOD_DISCOGS_SECRET` for the half of it Discogs answers.
struct ConcertIdentifierLiveTests {
    @Test func identifiesARealDiscEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["ANIMEGOD_LIVE_TESTS"] == "1" else { return }
        let discogs = {
            guard let key = ProcessInfo.processInfo.environment["ANIMEGOD_DISCOGS_KEY"],
                  let secret = ProcessInfo.processInfo.environment["ANIMEGOD_DISCOGS_SECRET"]
            else { return DiscogsConcertProvider?.none }
            return DiscogsConcertProvider(credentials: .init(consumerKey: key, consumerSecret: secret))
        }()

        let found = await ConcertIdentifier(
            discogs: discogs,
            musicBrainz: MusicBrainzConcertProvider(),
            bangumi: BangumiConcertProvider()
        ).identify(folderName: "[ANZX-10294~10296] 結束バンドLIVE-恒星- [BDMV][1080P][x264][FLAC]")

        let release = try #require(found.release, "a real catalogue number must resolve")
        #expect(found.catalogNumber?.description == "ANZX-10294")
        // Named after the disc, not the release it may sit inside.
        #expect(release.title.contains("恒星"))
        // The setlist and its lengths, which only MusicBrainz publishes.
        #expect(release.songCount == 16)
        #expect(abs((release.totalSongDuration ?? 0) - 4239) < 2)
        // The live flag is what moves it into the section without being asked.
        #expect(found.isConcert)
        #expect(release.catalogNumbers.contains { $0.contains("10294") })
    }
}

/// The path for a release with no catalogue number anywhere: a BDRip whose
/// Blu-ray neither catalogue indexes. Bangumi is the only source that will
/// answer a title, and it is only trusted when the title plainly matches.
struct ConcertTitleIdentificationTests {
    private actor Log {
        var asked: [String] = []
        func record(_ entry: String) { asked.append(entry) }
    }

    private struct FakeBangumi: ConcertReleaseSource {
        let id: ConcertProviderID = .bangumi
        var byTitle: [ConcertRelease] = []
        var full: [String: ConcertRelease] = [:]
        let log: Log

        func releases(catalogNumber: ConcertCatalogNumber) async throws -> [ConcertRelease] { [] }
        func releases(title: String, artist: String?) async throws -> [ConcertRelease] {
            await log.record("title:\(title)")
            return byTitle
        }
        func release(id externalID: String) async throws -> ConcertRelease {
            await log.record("release:\(externalID)")
            return full[externalID]!
        }
    }

    /// setlist.fm's shape: asked by artist and date, never by a catalogue key.
    private struct FakeEventSource: ConcertEventSource {
        let id: ConcertProviderID = .setlistFM
        var answer: ConcertRelease?
        let log: Log

        func concert(
            artist: String,
            isoDates: [String],
            year: Int?,
            fallbackTitle: String
        ) async throws -> ConcertRelease? {
            let dates = isoDates.joined(separator: ",")
            await log.record("setlistFM:\(artist):\(dates):\(year.map(String.init) ?? "-")")
            return answer
        }
    }

    private func subject(
        _ id: String, _ title: String, performance: Bool, venue: String? = nil, score: Double? = nil,
        artist: String? = nil, performedOn: String? = nil
    ) -> ConcertRelease {
        var release = ConcertRelease(
            provider: .bangumi, externalID: id, title: title,
            artistNames: [artist].compactMap { $0 },
            score: score, venue: venue,
            isPerformanceRecord: performance, isLiveRecording: performance
        )
        release.performedOn = performedOn
        return release
    }

    @Test func takesTheHallFromAPlainlyMatchingTitle() async throws {
        let log = Log()
        let work = "MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」"
        let bangumi = FakeBangumi(
            byTitle: [subject("492657", work, performance: true, venue: "ぴあアリーナMM", score: 8.7)],
            full: ["492657": subject("492657", work, performance: true, venue: "ぴあアリーナMM", score: 8.7)],
            log: log
        )
        let found = await ConcertIdentifier(bangumi: bangumi).identify(title: work)

        let release = try #require(found.release)
        #expect(release.venue == "ぴあアリーナMM")
        #expect(release.score == 8.7)
        // There is no setlist to be had this way, which is also why there is no
        // setlist to get wrong.
        #expect(release.discs.isEmpty)
    }

    /// Bangumi answers a loose query with the artist's other concerts. Taking
    /// the top hit would put last year's tour on this year's page.
    @Test func refusesANeighbouringConcert() async throws {
        let log = Log()
        let bangumi = FakeBangumi(
            byTitle: [
                subject("492671", "MyGO!!!!! ZEPP TOUR 2024「彷徨する渇望」", performance: true, venue: "Zepp"),
                subject("492675", "MyGO!!!!! 5th LIVE「迷うことに迷わない」", performance: true, venue: "KT Zepp")
            ],
            log: log
        )
        let found = await ConcertIdentifier(bangumi: bangumi)
            .identify(title: "MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」")

        #expect(found.release == nil)
        #expect(await log.asked == ["title:MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」"],
                "nothing should have been fetched")
    }

    /// The automatic pass points this at every work no provider could match, so
    /// it has to be able to say no. A 音乐 subject is an album as easily as a
    /// concert; only a 演出 is an event that happened in a hall.
    @Test func requiringAPerformanceRefusesAnAlbum() async throws {
        let log = Log()
        let album = subject("512098", "跡暖空", performance: false)
        let bangumi = FakeBangumi(byTitle: [album], full: ["512098": album], log: log)

        let loose = await ConcertIdentifier(bangumi: bangumi).identify(title: "跡暖空")
        #expect(loose.release != nil, "asked about a concert, the album still answers")

        let strict = await ConcertIdentifier(bangumi: bangumi)
            .identify(title: "跡暖空", requiringPerformance: true)
        #expect(strict.release == nil, "asked whether this is a concert, an album is not one")
    }

    /// And it has to be able to say yes, for the case it exists for: a work no
    /// anime index lists, which Bangumi files as a performance.
    @Test func requiringAPerformanceAcceptsOne() async throws {
        let log = Log()
        let work = "MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」"
        let live = subject("492657", work, performance: true, venue: "ぴあアリーナMM", score: 8.7)
        let bangumi = FakeBangumi(byTitle: [live], full: ["492657": live], log: log)

        let found = await ConcertIdentifier(bangumi: bangumi)
            .identify(title: work, requiringPerformance: true)
        #expect(found.release?.venue == "ぴあアリーナMM")
        #expect(found.isConcert)
    }

    @Test func anEmptyTitleAsksNothing() async throws {
        let log = Log()
        let found = await ConcertIdentifier(bangumi: FakeBangumi(log: log)).identify(title: "")
        #expect(found.release == nil)
        #expect(await log.asked.isEmpty)
    }

    /// Against the real service, opt-in: this is the user's own disc, and the
    /// point is that Bangumi has it while neither catalogue does.
    @Test func liveTitleLookup() async throws {
        guard ProcessInfo.processInfo.environment["ANIMEGOD_LIVE_TESTS"] == "1" else { return }
        let identifier = ConcertIdentifier(bangumi: BangumiConcertProvider())

        // The title as the library actually holds it, nights and all.
        for title in ["MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」DAY1",
                      "MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」"] {
            let found = await identifier.identify(title: title, requiringPerformance: true)
            let release = try #require(found.release, "\(title) is a concert")
            #expect(release.venue?.isEmpty == false)
            #expect(release.score != nil)
            #expect(found.isConcert)
        }

        // And the works in the same library that are not concerts. The pass is
        // pointed at every unmatched work, so a false positive here would file
        // an anime under the wrong thing entirely.
        for title in ["Ave Mujica", "Domestic na Kanojo", "SENNEN_JYOYU"] {
            let found = await identifier.identify(title: title, requiringPerformance: true)
            #expect(found.release == nil, "\(title) is not a concert")
        }
    }

    // MARK: - setlist.fm, asked by what the others already answered

    /// It indexes neither a catalogue number nor a title, so it can only be
    /// asked once something else has supplied an artist and a date — and
    /// Bangumi's 演出 subject supplies both, the date as a span that expands
    /// into the two nights of a two-night live.
    @Test func asksSetlistFMWithTheArtistAndDatesBangumiFound() async throws {
        let log = Log()
        let work = "MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」"
        let live = subject("492657", work, performance: true, venue: "武蔵野の森総合スポーツプラザ",
                           score: 8.7, artist: "MyGO!!!!!", performedOn: "2024-07-27 – 2024-07-28")
        let bangumi = FakeBangumi(byTitle: [live], full: ["492657": live], log: log)

        var nights = ConcertRelease(
            provider: .setlistFM, externalID: "63ab8213", title: #"MyGO!!!!! 6th LIVE "Mitsuketa Keshiki""#,
            discs: [
                ConcertDisc(position: 1, title: "2024-07-27", format: "Blu-ray",
                            tracks: [ConcertTrack(position: 1, title: "Mayoi Uta")]),
                ConcertDisc(position: 2, title: "2024-07-28", format: "Blu-ray",
                            tracks: [ConcertTrack(position: 1, title: "Kokyuu")])
            ]
        )
        nights.venue = "Musashino no Mori Sougou Sports Plaza, Choufu"
        nights.isLiveRecording = true

        let found = await ConcertIdentifier(
            bangumi: bangumi,
            setlistFM: FakeEventSource(answer: nights, log: log)
        ).identify(title: work, requiringPerformance: true)

        let release = try #require(found.release)
        // Both nights' running orders, which nothing else here had — and
        // Bangumi's score and hall are still there.
        #expect(release.discs.count == 2)
        #expect(release.score == 8.7)
        // The hall with its city beats the hall on its own.
        #expect(release.venue == "Musashino no Mori Sougou Sports Plaza, Choufu")
        #expect(await log.asked.contains("setlistFM:MyGO!!!!!:2024-07-27,2024-07-28:2024"))
    }

    /// With no artist there is no question to ask, and asking anyway spends a
    /// request from a small daily budget on nothing.
    @Test func doesNotAskSetlistFMWithoutAnArtist() async throws {
        let log = Log()
        let live = subject("1", "Some Live", performance: true, performedOn: "2024-07-27")
        let bangumi = FakeBangumi(byTitle: [live], full: ["1": live], log: log)

        _ = await ConcertIdentifier(
            bangumi: bangumi,
            setlistFM: FakeEventSource(answer: nil, log: log)
        ).identify(title: "Some Live", requiringPerformance: true)

        #expect(await log.asked.allSatisfy { !$0.hasPrefix("setlistFM") })
    }
}
