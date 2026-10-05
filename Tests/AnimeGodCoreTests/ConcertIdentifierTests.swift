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
