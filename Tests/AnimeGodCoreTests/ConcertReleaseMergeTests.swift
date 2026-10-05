import Foundation
import Testing
@testable import AnimeGodCore

/// Three sources, each good at something different, folded into one record.
/// Every preference here was measured, and getting one wrong is silent — a page
/// that quietly shows the weaker source's answer looks fine.
struct ConcertReleaseMergeTests {
    /// MusicBrainz as it really answers for `ANZX-10294`: the setlist with
    /// lengths, the media named, no cover of its own in this fixture.
    private func musicBrainz(
        releaseTitle: String = "跡暖空",
        discTitle: String? = "結束バンドLIVE-恒星-"
    ) -> ConcertRelease {
        ConcertRelease(
            provider: .musicBrainz,
            externalID: "295db787",
            title: releaseTitle,
            artistNames: ["結束バンド"],
            releaseDate: "2023-11-22",
            country: "JP",
            labels: ["Aniplex"],
            catalogNumbers: ["ANZX-10294"],
            barcode: "4534530147127",
            discs: [
                ConcertDisc(position: 1, title: discTitle, format: "Blu-ray", tracks: [
                    ConcertTrack(position: 1, title: "ひとりぼっち東京", duration: 233),
                    ConcertTrack(position: 2, title: "ギターと孤独と蒼い惑星", duration: 239)
                ]),
                ConcertDisc(position: 2, title: nil, format: "CD", tracks: [
                    ConcertTrack(position: 1, title: "青春コンプレックス", duration: 332)
                ])
            ],
            sourceURL: URL(string: "https://musicbrainz.org/release/295db787"),
            isLiveRecording: true
        )
    }

    /// Discogs as it really answers: the release facts, a small `secondary`
    /// image, a hand-entered track list with a duplicate in it and no lengths.
    private func discogs() -> ConcertRelease {
        ConcertRelease(
            provider: .discogs,
            externalID: "30770007",
            title: "結束バンド LIVE-恒星-",
            artistNames: ["結束バンド", "Kessoku Band"],
            releaseDate: "2023-11-22",
            country: "Japan",
            labels: ["Aniplex"],
            catalogNumbers: ["ANZX 10294"],
            barcode: "4 534530 147127",
            genres: ["Rock", "J-Rock"],
            discs: [ConcertDisc(position: 1, format: "Blu-ray", tracks: [
                ConcertTrack(position: 1, title: "ひとりぼっち東京"),
                ConcertTrack(position: 2, title: "ひみつ基地"),
                ConcertTrack(position: 3, title: "ひみつ基地")
            ])],
            coverImageURLs: [URL(string: "https://i.discogs.com/secondary-445x600.jpeg")!]
        )
    }

    private func bangumiPerformance() -> ConcertRelease {
        ConcertRelease(
            provider: .bangumi,
            externalID: "466281",
            title: "結束バンドLIVE-恒星-",
            coverImageURLs: [URL(string: "https://lain.bgm.tv/pic/cover/l/466281.jpg")!],
            score: 7.7,
            ratingCount: 120,
            venue: "Zepp Haneda（TOKYO）",
            performedOn: "2023年5月21日",
            officialSiteURL: URL(string: "https://bocchi.rocks"),
            isPerformanceRecord: true,
            isLiveRecording: true
        )
    }

    private func bangumiDisc() -> ConcertRelease {
        ConcertRelease(
            provider: .bangumi,
            externalID: "512098",
            title: "結束バンドLIVE-恒星",
            releaseDate: "2023-11-22",
            discs: [ConcertDisc(position: 1, format: "Blu-ray", tracks: [
                ConcertTrack(position: 1, title: "ひとりぼっち東京"),
                ConcertTrack(position: 2, title: "ギターと孤独と蒼い惑星"),
                ConcertTrack(position: 3, title: "ラブソングが歌えない")
            ])],
            coverImageURLs: [URL(string: "https://lain.bgm.tv/pic/cover/l/512098.jpg")!],
            score: 8.2,
            ratingCount: 18,
            summary: "Zepp Haneda（TOKYO）で開催された"
        )
    }

    // MARK: - Who answers what

    @Test func takesEachFieldFromTheSourceThatKnowsIt() throws {
        let merged = try #require(ConcertReleaseMerge.merge(
            [discogs(), musicBrainz(), bangumiPerformance(), bangumiDisc()]
        ))

        // The setlist and the lengths: only MusicBrainz publishes lengths, and
        // Discogs' list has a duplicate in it.
        #expect(merged.discs.first?.tracks.map(\.title) == ["ひとりぼっち東京", "ギターと孤独と蒼い惑星"])
        #expect(merged.discs.first?.tracks.allSatisfy { $0.duration != nil } == true)
        // The hall and the date of the performance: only Bangumi has them.
        #expect(merged.venue == "Zepp Haneda（TOKYO）")
        #expect(merged.performedOn == "2023年5月21日")
        #expect(merged.officialSiteURL?.host() == "bocchi.rocks")
        // A score somebody voted on, and the one more people voted on: the
        // performance's 120 against the disc's 18.
        #expect(merged.score == 7.7)
        #expect(merged.ratingCount == 120)
        // The release facts, Discogs first.
        #expect(merged.genres.contains("J-Rock"))
        #expect(merged.labels == ["Aniplex"])
        #expect(merged.barcode == "4 534530 147127")
        // The record is stored under the source with the setlist.
        #expect(merged.provider == .musicBrainz)
        #expect(merged.externalID == "295db787")
        #expect(!merged.isPerformanceRecord)
        #expect(merged.isLiveRecording)
    }

    /// A live Blu-ray is often a medium inside an album's release, so the
    /// release title is the album's name and the medium's title is the
    /// concert's. Taking the release title would call this concert `跡暖空`.
    @Test func namesTheConcertAfterItsDiscNotItsAlbum() throws {
        let merged = try #require(ConcertReleaseMerge.merge([musicBrainz(), discogs()]))
        #expect(merged.title == "結束バンドLIVE-恒星-")
    }

    /// When the medium has no title of its own there is nothing better than the
    /// release's.
    @Test func fallsBackToTheReleaseTitle() throws {
        let merged = try #require(ConcertReleaseMerge.merge([
            musicBrainz(releaseTitle: "結束バンドLIVE-恒星-", discTitle: nil)
        ]))
        #expect(merged.title == "結束バンドLIVE-恒星-")
    }

    /// Covers best first: Bangumi's full-size scan over the archive's, and
    /// Discogs' 445×600 `secondary` image last because it is as likely to be
    /// the back of the case as the front.
    @Test func ordersCoversBestFirst() throws {
        let merged = try #require(ConcertReleaseMerge.merge(
            [discogs(), musicBrainz(), bangumiPerformance(), bangumiDisc()]
        ))
        #expect(merged.coverImageURLs.first?.host() == "lain.bgm.tv")
        #expect(merged.coverImageURLs.last?.host() == "i.discogs.com")
        #expect(merged.coverImageURLs.count == 3)
    }

    // MARK: - When a source is missing

    /// Two of six real concert Blu-rays were not in MusicBrainz at all. Bangumi
    /// wrote its setlist in prose, and that is better than Discogs' typo.
    @Test func usesBangumisProseSetlistWhenMusicBrainzHasNothing() throws {
        let merged = try #require(ConcertReleaseMerge.merge([discogs(), bangumiDisc()]))
        #expect(merged.discs.first?.tracks.count == 3)
        #expect(merged.discs.first?.tracks.map(\.title)
            == ["ひとりぼっち東京", "ギターと孤独と蒼い惑星", "ラブソングが歌えない"])
    }

    /// Discogs last rather than never: a wrong order still beats no setlist.
    @Test func fallsAllTheWayBackToDiscogs() throws {
        let merged = try #require(ConcertReleaseMerge.merge([discogs()]))
        #expect(merged.discs.first?.tracks.count == 3)
        #expect(merged.provider == .discogs)
        // Nothing claimed it was live, so nothing says it is.
        #expect(!merged.isLiveRecording)
    }

    /// Only the hall was found. That is still worth storing — it is the one
    /// thing no other source has — and the disc is still playable without a
    /// setlist.
    @Test func keepsAPerformanceOnItsOwn() throws {
        let merged = try #require(ConcertReleaseMerge.merge([bangumiPerformance()]))
        #expect(merged.venue == "Zepp Haneda（TOKYO）")
        #expect(merged.discs.isEmpty)
        #expect(merged.isLiveRecording)
        // Merged records describe the disc, never only the performance, or the
        // store could not tell a found concert from a failed lookup.
        #expect(!merged.isPerformanceRecord)
    }

    /// Plenty of 演出 subjects have no votes at all and Bangumi reports those as
    /// a score of 0. A 0 from nobody must not beat an 8.2 from eighteen people.
    @Test func ignoresAScoreNobodyVotedOn() throws {
        var unvoted = bangumiPerformance()
        unvoted.score = nil
        unvoted.ratingCount = 0
        let merged = try #require(ConcertReleaseMerge.merge([unvoted, bangumiDisc(), musicBrainz()]))
        #expect(merged.score == 8.2)
        #expect(merged.ratingCount == 18)
        // The hall still comes from the entry with no votes.
        #expect(merged.venue == "Zepp Haneda（TOKYO）")
    }

    @Test func nothingFoundIsNothing() {
        #expect(ConcertReleaseMerge.merge([]) == nil)
    }

    /// A box's numbers come from both sources in different spellings, and both
    /// are kept so either one finds the work again.
    @Test func keepsEverySpellingOfTheCatalogueNumber() throws {
        let merged = try #require(ConcertReleaseMerge.merge([discogs(), musicBrainz()]))
        #expect(merged.catalogNumbers == ["ANZX-10294", "ANZX 10294"])
        #expect(merged.artistNames == ["結束バンド", "Kessoku Band"])
    }

    /// Only the CD has a song on a release whose Blu-ray carries none: the
    /// video discs are what a timeline is laid over, so the count follows them.
    @Test func countsOnlyWhatIsOnTheVideoDiscs() throws {
        let merged = try #require(ConcertReleaseMerge.merge([musicBrainz()]))
        #expect(merged.videoDiscs.count == 1)
        #expect(merged.songCount == 2)
        #expect(merged.totalSongDuration == 472)
    }

    /// setlist.fm: what was played on the night, with no lengths on it.
    private func setlistFM() -> ConcertRelease {
        var release = ConcertRelease(
            provider: .setlistFM,
            externalID: "63ab8213",
            title: #"Kessoku Band LIVE "Kosei""#,
            artistNames: ["Kessoku Band"],
            discs: [ConcertDisc(position: 1, title: "2023-05-21", format: "Blu-ray", tracks: [
                ConcertTrack(position: 1, title: "Hitoribocchi Tokyo"),
                ConcertTrack(position: 2, title: "Guitar to Kodoku to Aoi Hoshi"),
                ConcertTrack(position: 3, title: "Love Song ga Utaenai"),
                ConcertTrack(position: 4, title: "Seishun Complex", isEncore: true)
            ])]
        )
        release.venue = "Zepp Haneda (TOKYO), Ota"
        release.performedOn = "2023-05-21"
        release.isLiveRecording = true
        return release
    }

    /// Ahead of Discogs and behind the two that publish the songs in Japanese.
    ///
    /// Discogs' list for this release is measurably wrong — `ひみつ基地` twice and
    /// `ラブソングが歌えない` missing — and setlist.fm's is a night's own running
    /// order. Neither has lengths, so neither can beat MusicBrainz.
    @Test func setlistFMSitsBetweenBangumiAndDiscogs() throws {
        let withEverything = try #require(ConcertReleaseMerge.merge([
            musicBrainz(), discogs(), bangumiDisc(), setlistFM()
        ]))
        #expect(withEverything.discs.first?.tracks.first?.title == "ひとりぼっち東京")
        #expect(withEverything.discs.first?.tracks.first?.duration == 233)

        // Without MusicBrainz or Bangumi, it answers instead of Discogs.
        let withoutTheJapanese = try #require(ConcertReleaseMerge.merge([discogs(), setlistFM()]))
        #expect(withoutTheJapanese.discs.first?.tracks.map(\.title) == [
            "Hitoribocchi Tokyo", "Guitar to Kodoku to Aoi Hoshi",
            "Love Song ga Utaenai", "Seishun Complex"
        ])
        #expect(withoutTheJapanese.discs.first?.tracks.last?.isEncore == true)
    }

    /// The venue of the night, with its city, beats the hall on its own — and
    /// it is the one field where setlist.fm leads outright.
    @Test func setlistFMLeadsTheVenue() throws {
        let merged = try #require(ConcertReleaseMerge.merge([
            musicBrainz(), bangumiPerformance(), setlistFM()
        ]))
        #expect(merged.venue == "Zepp Haneda (TOKYO), Ota")
        // Bangumi still owns the date it published and the score people voted.
        #expect(merged.performedOn == "2023年5月21日")
        #expect(merged.score == 7.7)
    }

    /// A page can be built out of setlist.fm alone: it is the only source that
    /// answers for a live nothing pressed to disc.
    @Test func setlistFMAloneIsStillARelease() throws {
        let merged = try #require(ConcertReleaseMerge.merge([setlistFM()]))
        #expect(merged.provider == .setlistFM)
        #expect(merged.title == #"Kessoku Band LIVE "Kosei""#)
        #expect(merged.songCount == 4)
        #expect(merged.isLiveRecording)
    }
}

/// Who answered what. A concert page is four services and a folder, no two of
/// them answering the same question — and setlist.fm asks to be credited where
/// its data is shown, which a credit that only appears when it led the whole
/// record would not do.
@Suite("Per-field attribution")
struct ConcertAttributionTests {
    private func musicBrainz() -> ConcertRelease {
        ConcertRelease(
            provider: .musicBrainz, externalID: "295db787", title: "跡暖空",
            artistNames: ["結束バンド"], releaseDate: "2023-11-22", country: "JP",
            labels: ["Aniplex"], catalogNumbers: ["ANZX-10294"], barcode: "4534530147127",
            discs: [ConcertDisc(position: 1, title: "結束バンドLIVE-恒星-", format: "Blu-ray", tracks: [
                ConcertTrack(position: 1, title: "ひとりぼっち東京", duration: 233)
            ])]
        )
    }

    private func bangumi() -> ConcertRelease {
        ConcertRelease(
            provider: .bangumi, externalID: "466281", title: "結束バンドLIVE-恒星-",
            coverImageURLs: [URL(string: "https://lain.bgm.tv/pic/cover/l/466281.jpg")!],
            score: 7.7, ratingCount: 120, venue: "Zepp Haneda（TOKYO）",
            performedOn: "2023年5月21日", isPerformanceRecord: true, isLiveRecording: true
        )
    }

    private func setlistFM() -> ConcertRelease {
        var release = ConcertRelease(
            provider: .setlistFM, externalID: "63ab8213", title: "Kessoku Band LIVE",
            discs: [ConcertDisc(position: 1, format: "Blu-ray", tracks: [
                ConcertTrack(position: 1, title: "Hitoribocchi Tokyo")
            ])]
        )
        release.venue = "Zepp Haneda (TOKYO), Ota"
        release.isLiveRecording = true
        return release
    }

    private func local() -> ConcertRelease {
        ConcertRelease(
            provider: .localFiles, externalID: "folder", title: "folder",
            coverImageURLs: [URL(fileURLWithPath: "/Volumes/T7/x/Scans/01.png")],
            extras: [ConcertExtra(name: "Scans", itemCount: 27)]
        )
    }

    /// The case the whole thing exists for: setlist.fm gave only the venue, and
    /// is credited for exactly that.
    @Test func creditsASourceThatOnlyGaveOneField() throws {
        let merged = try #require(ConcertReleaseMerge.merge([
            musicBrainz(), bangumi(), setlistFM(), local()
        ]))
        #expect(merged.attribution[.venue] == .setlistFM)
        #expect(merged.venue == "Zepp Haneda (TOKYO), Ota")
        // And it is not credited with the setlist, which MusicBrainz won.
        #expect(merged.attribution[.setlist] == .musicBrainz)
        #expect(merged.attribution[.rating] == .bangumi)
        #expect(merged.attribution[.performedOn] == .bangumi)
        // The scans beat every service's cover, and only the folder knows the
        // box.
        #expect(merged.attribution[.covers] == .localFiles)
        #expect(merged.attribution[.extras] == .localFiles)
        #expect(merged.attribution[.catalogNumbers] == .musicBrainz)
    }

    /// Nothing is credited for a field nobody answered — an absent entry says
    /// "not known", which is not the same as crediting a source with a blank.
    @Test func doesNotCreditAnUnansweredField() throws {
        let merged = try #require(ConcertReleaseMerge.merge([musicBrainz()]))
        #expect(merged.attribution[.venue] == nil)
        #expect(merged.attribution[.rating] == nil)
        #expect(merged.attribution[.summary] == nil)
        #expect(merged.attribution[.extras] == nil)
        #expect(merged.attribution[.setlist] == .musicBrainz)
    }

    /// Grouped for the page, most generous source first and the folder last,
    /// because the folder is not a service and the credit is about services.
    @Test func groupsCreditsBySource() throws {
        let merged = try #require(ConcertReleaseMerge.merge([
            musicBrainz(), bangumi(), setlistFM(), local()
        ]))
        let credits = merged.credits
        #expect(credits.first?.provider == .musicBrainz)
        #expect(credits.last?.provider == .localFiles)
        #expect(credits.contains { $0.provider == .setlistFM && $0.fields == [.venue] })
        // Every credited field appears exactly once across the groups.
        let all = credits.flatMap(\.fields)
        #expect(Set(all).count == all.count)
        #expect(Set(all) == Set(merged.attribution.keys))
    }

    /// The map has to survive the round trip through the database, where it is
    /// one JSON column — and as an object, not as a flat array of alternating
    /// keys and values, which is what `Dictionary`'s own coding would give.
    @Test func encodesAsAnObject() throws {
        let merged = try #require(ConcertReleaseMerge.merge([musicBrainz(), setlistFM()]))
        let data = try JSONEncoder().encode(merged.attribution)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"venue\":\"setlistFM\""))

        let decoded = try JSONDecoder()
            .decode([ConcertReleaseField: ConcertProviderID].self, from: data)
        #expect(decoded == merged.attribution)
    }
}
