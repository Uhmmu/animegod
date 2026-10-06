import Foundation
import Testing

@testable import AnimeGodCore

/// Arranging the concert section. The fixtures are the real library's own
/// shapes — including the three concerts whose release carries no artist at
/// all, which is what the title fallback exists for.
struct ConcertShelvesTests {
    private func concert(
        _ title: String,
        artist: String? = nil,
        performed: String? = nil,
        released: String? = nil,
        hasRelease: Bool = true
    ) -> LibraryConcert {
        var release: ConcertRelease?
        if hasRelease {
            var made = ConcertRelease(
                provider: .musicBrainz, externalID: title, title: title,
                artistNames: [artist].compactMap { $0 },
                releaseDate: released
            )
            made.performedOn = performed
            release = made
        }
        return LibraryConcert(anime: Anime(title: title, kind: .live), release: release, discCount: 1)
    }

    @Test func readsTheDatesWhateverShapeTheyCameIn() {
        // A two-night span sorts by the night it began.
        let span = concert("6th", performed: "2024-07-27 – 2024-07-28", released: "2024-12-18")
        #expect(span.performanceDate == "2024-07-27")
        #expect(span.discReleaseDate == "2024-12-18")
        #expect(span.sortDate == "2024-07-27")

        // The disc's date when the concert's own is missing — and nothing is
        // invented when neither exists.
        #expect(concert("x", released: "2023-04-12").sortDate == "2023-04-12")
        #expect(concert("x", hasRelease: false).sortDate == nil)
    }

    /// Three of the eighteen real concerts have a release with no artist on it,
    /// because a Bangumi 演出 subject that omits 主演 carries none.
    @Test(arguments: [
        ("Ave Mujica 1st LIVE 「Perdere Omnia」", "Ave Mujica"),
        ("MyGO!!!!! 9th LIVE「Tsunagime no Mukouni」", "MyGO!!!!!"),
        ("BanG Dream! MyGO!!!!! LIVE ZEPP TOUR", "BanG Dream! MyGO!!!!!"),
        ("Roselia 6th LIVE", "Roselia"),
    ])
    func readsTheActOutOfTheTitle(_ title: String, _ expected: String) {
        #expect(ConcertShelves.bandFromTitle(title) == expected, "\(title)")
    }

    /// A title that is nothing but the concert's own name has no act in it, and
    /// guessing one would put a heading on a guess.
    @Test func doesNotInventAnAct() {
        #expect(ConcertShelves.bandFromTitle("LIVE 2024") == nil)
        #expect(ConcertShelves.bandFromTitle("ELEMENTS") == nil)
    }

    /// The catalogue's artist wins when there is one, and the fallback fills in
    /// only where it is missing — so one act is one shelf either way.
    @Test func oneActIsOneShelf() {
        let shelves = ConcertShelves.shelves(of: [
            concert("Ave Mujica 0th LIVE", artist: "Ave Mujica", performed: "2023-06-04"),
            concert("Ave Mujica 1st LIVE", performed: "2024-01-27"),
            concert("MyGO!!!!! 1st LIVE", artist: "MyGO!!!!!", performed: "2022-07-03"),
            concert("MyGO!!!!! 8th LIVE", artist: "MyGO!!!!!", performed: "2025-12-06"),
        ])
        #expect(shelves.map(\.band) == ["MyGO!!!!!", "Ave Mujica"])
        #expect(shelves.map { $0.concerts.count } == [2, 2])
        // The act with the most recent concert leads — the one being collected
        // now is at the top.
        #expect(shelves.first?.concerts.last?.displayTitle == "MyGO!!!!! 8th LIVE")
    }

    /// Within an act, the order the concerts happened — which is the order
    /// their own names already count in.
    @Test func eachActRunsInTheOrderItPlayed() {
        let shelves = ConcertShelves.shelves(of: [
            concert("MyGO!!!!! 3rd LIVE", artist: "MyGO!!!!!", performed: "2022-11-26"),
            concert("MyGO!!!!! 1st LIVE", artist: "MyGO!!!!!", performed: "2022-07-03"),
            concert("MyGO!!!!! 2nd LIVE", artist: "MyGO!!!!!", performed: "2022-09-10"),
        ])
        #expect(shelves.first?.concerts.map(\.displayTitle)
            == ["MyGO!!!!! 1st LIVE", "MyGO!!!!! 2nd LIVE", "MyGO!!!!! 3rd LIVE"])
    }

    /// A concert nobody dated is not the oldest one; it is unknown, and goes
    /// last rather than first.
    @Test func anUndatedConcertIsLastNotFirst() {
        let shelves = ConcertShelves.shelves(of: [
            concert("MyGO!!!!! 9th LIVE", artist: "MyGO!!!!!"),
            concert("MyGO!!!!! 1st LIVE", artist: "MyGO!!!!!", performed: "2022-07-03"),
        ])
        #expect(shelves.first?.concerts.map(\.displayTitle)
            == ["MyGO!!!!! 1st LIVE", "MyGO!!!!! 9th LIVE"])
    }

    /// Nothing with an act at all goes under one heading at the end, rather
    /// than one shelf each.
    @Test func whatHasNoActAtAllIsGatheredAtTheEnd() {
        let shelves = ConcertShelves.shelves(of: [
            concert("ELEMENTS", hasRelease: false),
            concert("LIVE 2024", hasRelease: false),
            concert("MyGO!!!!! 1st LIVE", artist: "MyGO!!!!!", performed: "2022-07-03"),
        ])
        #expect(shelves.count == 2)
        #expect(shelves.last?.concerts.count == 2)
    }

    /// The flat orders put the newest first, which is the opposite of a shelf
    /// and deliberately so: a shelf is a run to read, a list is a what's-new.
    @Test func theFlatOrdersPutTheNewestFirst() {
        let items = [
            concert("A", artist: "X", performed: "2022-07-03", released: "2024-01-01"),
            concert("B", artist: "X", performed: "2025-12-06", released: "2023-01-01"),
        ]
        #expect(ConcertShelves.sorted(items, by: .performance).map(\.displayTitle) == ["B", "A"])
        #expect(ConcertShelves.sorted(items, by: .release).map(\.displayTitle) == ["A", "B"])
        #expect(ConcertShelves.sorted(items, by: .title).map(\.displayTitle) == ["A", "B"])
        // Grouping flattens to the same thing the shelves show.
        #expect(ConcertShelves.sorted(items, by: .band).map(\.displayTitle) == ["A", "B"])
    }
}
