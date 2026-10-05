import Foundation
import Testing
@testable import AnimeGodCore

/// Where does song seven start? No source answers it, so the answer is
/// inferred from the disc's own chapter marks and the published song lengths.
/// These tests are built on a real disc: the sixteen songs and sixteen
/// lengths below are what MusicBrainz holds for `ANZX-10294`
/// (結束バンドLIVE-恒星-), which totals 70.65 minutes of music.
struct ConcertSetlistAlignerTests {
    /// The real disc-one setlist, with the real published lengths.
    static let kessoku: [(String, TimeInterval)] = [
        ("ひとりぼっち東京", 233), ("ギターと孤独と蒼い惑星", 239), ("ラブソングが歌えない", 205),
        ("Distortion!!", 215), ("ひみつ基地", 233), ("カラカラ", 268),
        ("あのバンド", 307), ("小さな海", 251), ("なにが悪い", 243),
        ("青い春と西の空", 259), ("忘れてやらない", 288), ("星座になれたら", 296),
        ("フラッシュバッカー", 313), ("転がる岩、君に朝が降る", 288), ("光の中へ", 269),
        ("青春コンプレックス", 332)
    ]

    private func tracks(
        _ setlist: [(String, TimeInterval)] = kessoku,
        withLengths: Bool = true
    ) -> [ConcertTrack] {
        setlist.enumerated().map { index, entry in
            ConcertTrack(position: index + 1, title: entry.0,
                         duration: withLengths ? entry.1 : nil, kind: .song)
        }
    }

    private func marks(_ times: [TimeInterval], titles: [String]? = nil) -> [ConcertChapterMark] {
        times.enumerated().map { index, time in
            ConcertChapterMark(index: index, title: titles?[index] ?? "Chapter \(index + 1)", startTime: time)
        }
    }

    /// Lays the setlist out with talk after the songs named in `talkAfter`,
    /// and reports both the song start times and every chapter the disc would
    /// carry if it marked its MC segments too.
    private func stage(
        talkAfter: [Int: TimeInterval],
        markTalk: Bool,
        openingFilm: TimeInterval = 0,
        setlist: [(String, TimeInterval)] = kessoku
    ) -> (songStarts: [TimeInterval], chapterTimes: [TimeInterval], duration: TimeInterval) {
        var cursor = openingFilm
        var starts: [TimeInterval] = []
        var chapters: [TimeInterval] = openingFilm > 0 ? [0] : []
        for (index, entry) in setlist.enumerated() {
            starts.append(cursor)
            chapters.append(cursor)
            cursor += entry.1
            if let talk = talkAfter[index + 1] {
                if markTalk { chapters.append(cursor) }
                cursor += talk
            }
        }
        return (starts, chapters, cursor)
    }

    // MARK: - The regression this whole design exists for

    /// A disc that marks its MC segments as well as its songs has more
    /// chapters than songs, and the obvious cost function — charge each song
    /// for the span up to the *next song's* mark — prefers to pin song two to
    /// the MC mark, because that leaves song one a span exactly its own
    /// length. The whole chain then comes out one song late. Every start time
    /// here is checked, so that failure cannot come back quietly.
    @Test func doesNotSlideOntoTheMCMarks() {
        let staged = stage(talkAfter: [4: 300, 8: 280, 12: 240], markTalk: true)
        #expect(staged.chapterTimes.count == 19, "16 songs and 3 marked MC segments")

        let alignment = ConcertSetlistAligner.align(
            tracks: tracks(), chapters: marks(staged.chapterTimes), duration: staged.duration
        )

        #expect(alignment.method == .durations)
        #expect(alignment.placements.map(\.startTime) == staged.songStarts)
        #expect(alignment.confidence > 0.95)
        #expect(alignment.isTrustworthy)
    }

    /// The commoner disc: a mark at every song and nowhere else, so each
    /// song's segment carries whatever talk followed it.
    @Test func alignsADiscThatMarksOnlyItsSongs() {
        let staged = stage(talkAfter: [4: 300, 8: 280, 12: 240], markTalk: false)
        #expect(staged.chapterTimes.count == 16)

        let alignment = ConcertSetlistAligner.align(
            tracks: tracks(), chapters: marks(staged.chapterTimes), duration: staged.duration
        )

        #expect(alignment.method == .durations)
        #expect(alignment.placements.map(\.startTime) == staged.songStarts)
        // Thirteen of the sixteen songs run straight into the next, so the
        // typical song is given exactly its own length even though three are
        // given four or five minutes more.
        #expect(alignment.confidence > 0.95)
    }

    /// Most concert discs open on a film. The first song is not chapter one,
    /// and charging for the wait would drag it onto the film's own mark.
    @Test func letsADiscOpenOnAFilm() throws {
        let staged = stage(talkAfter: [8: 280], markTalk: true, openingFilm: 180)
        let alignment = ConcertSetlistAligner.align(
            tracks: tracks(), chapters: marks(staged.chapterTimes), duration: staged.duration
        )
        #expect(alignment.method == .durations)
        #expect(alignment.placements.first?.startTime == 180)
        #expect(alignment.placements.map(\.startTime) == staged.songStarts)
    }

    /// A mark dropped inside a song — a long intro, a costume change — leaves
    /// more chapters than songs without meaning anything. The song takes both
    /// segments rather than surrendering one to the song behind it.
    @Test func letsOneSongSpanSeveralMarks() throws {
        var staged = stage(talkAfter: [4: 300, 8: 280, 12: 240], markTalk: true)
        let seventhStart = try #require(staged.songStarts.indices.contains(6) ? staged.songStarts[6] : nil)
        staged.chapterTimes.append(seventhStart + 150)
        staged.chapterTimes.sort()

        let alignment = ConcertSetlistAligner.align(
            tracks: tracks(), chapters: marks(staged.chapterTimes), duration: staged.duration
        )

        #expect(alignment.method == .durations)
        #expect(alignment.placements.map(\.startTime) == staged.songStarts)
        #expect(alignment.placements[6].allottedDuration == 307)
    }

    // MARK: - Without lengths

    @Test func fallsBackToOneChapterPerSongWhenNothingHasALength() {
        let staged = stage(talkAfter: [:], markTalk: false)
        let alignment = ConcertSetlistAligner.align(
            tracks: tracks(withLengths: false),
            chapters: marks(staged.chapterTimes),
            duration: staged.duration
        )
        #expect(alignment.method == .oneToOne)
        #expect(alignment.placements.map(\.startTime) == staged.songStarts)
        // The counts agreeing is not evidence that the disc marks only songs.
        #expect(!alignment.isTrustworthy)
    }

    /// No chapter marks at all — a remux that dropped them. The list is still
    /// worth showing and still clickable, and the confidence says why not to
    /// trust it.
    @Test func laysSongsEndToEndWithNoMarksAtAll() {
        let alignment = ConcertSetlistAligner.align(
            tracks: tracks(), chapters: [], duration: 5000
        )
        #expect(alignment.method == .cumulative)
        #expect(alignment.placements.first?.startTime == 0)
        #expect(alignment.placements[1].startTime == 233)
        #expect(alignment.placements[2].startTime == 472)
        #expect(alignment.confidence < 0.3)
    }

    @Test func reportsNothingWhenThereIsNothingToAlign() {
        #expect(ConcertSetlistAligner.align(tracks: [], chapters: [], duration: 0).method == .none)
        let noLengths = ConcertSetlistAligner.align(
            tracks: tracks(withLengths: false), chapters: [], duration: 5000
        )
        #expect(noLengths.method == .none)
    }

    // MARK: - When the disc names its chapters

    /// A ripper who rebuilt the chapters after the songs has answered the
    /// question outright, and guessing anyway could only do worse.
    @Test func believesChapterTitlesWhenTheyNameTheSongs() {
        let staged = stage(talkAfter: [4: 300], markTalk: false)
        let named = marks(staged.chapterTimes, titles: Self.kessoku.map(\.0))
        let alignment = ConcertSetlistAligner.align(
            tracks: tracks(withLengths: false), chapters: named, duration: staged.duration
        )
        #expect(alignment.method == .chapterTitles)
        #expect(alignment.confidence == 1)
        #expect(alignment.placements.map(\.startTime) == staged.songStarts)
    }

    /// Decorated the way a ripper decorates them, and in a different width.
    @Test func readsThroughChapterTitleDecoration() {
        let staged = stage(talkAfter: [:], markTalk: false)
        let titles = Self.kessoku.enumerated().map { index, entry in
            "M\(String(format: "%02d", index + 1)) \(entry.0)"
        }
        let alignment = ConcertSetlistAligner.align(
            tracks: tracks(), chapters: marks(staged.chapterTimes, titles: titles),
            duration: staged.duration
        )
        #expect(alignment.method == .chapterTitles)
        #expect(alignment.placements.map(\.startTime) == staged.songStarts)
    }

    @Test(arguments: ["", "   ", "Chapter 1", "chapter 12", "チャプター 3", "第3章", "03", "00:12:34", "Track 2"])
    func knowsAnUnnamedChapterWhenItSeesOne(_ title: String) {
        #expect(ConcertSetlistAligner.isGenericChapterTitle(title))
    }

    @Test(arguments: ["青春コンプレックス", "Distortion!!", "M01 ひとりぼっち東京", "あのバンド"])
    func knowsANamedChapterWhenItSeesOne(_ title: String) {
        #expect(!ConcertSetlistAligner.isGenericChapterTitle(title))
    }

    /// Every numbering scheme a ripper uses, and the one song title that
    /// looks like one: `1/6` has to survive.
    @Test(arguments: [
        ("m01ひとりぼっち東京", "ひとりぼっち東京"),
        ("03光の中へ", "光の中へ"),
        ("7あのバンド", "あのバンド"),
        ("t12星座になれたら", "星座になれたら"),
        ("16", "16"),
        ("distortion", "distortion")
    ])
    func takesTheRipperSTrackNumberOff(_ pair: (String, String)) {
        #expect(ConcertSetlistAligner.withoutLeadingIndex(pair.0) == pair.1)
    }

    /// A short title must not be matched by surplus alone — `海` is inside
    /// `小さな海`, and they are different songs.
    @Test func doesNotMatchASongByACoincidentalSubstring() {
        #expect(!ConcertSetlistAligner.titlesMatch("小さな海", "海"))
    }

    // MARK: - What is not on the timeline

    /// Discogs lists `オーディオコメンタリー` and the making-of as tracks of the
    /// same disc. Neither is a place on the programme, and counting them would
    /// make the song count disagree with the chapter count for no reason.
    @Test func ignoresCommentaryAndBonusFeatures() {
        let staged = stage(talkAfter: [:], markTalk: false)
        var list = tracks()
        list.append(ConcertTrack(position: 17, title: "オーディオコメンタリー", duration: 4200, kind: .commentary))
        list.append(ConcertTrack(position: 18, title: "Making of -恒星-", duration: 5886, kind: .bonus))

        let alignment = ConcertSetlistAligner.align(
            tracks: list, chapters: marks(staged.chapterTimes), duration: staged.duration
        )
        #expect(alignment.placements.count == 16)
        #expect(alignment.placements.map(\.startTime) == staged.songStarts)
    }

    // MARK: - Correcting it by hand

    @Test func nudgesTheWholeListOneChapterAlong() throws {
        let staged = stage(talkAfter: [:], markTalk: false)
        let chapters = marks(staged.chapterTimes)
        let alignment = ConcertSetlistAligner.align(
            tracks: tracks(withLengths: false), chapters: chapters, duration: staged.duration
        )
        let moved = ConcertSetlistAligner.shifting(alignment, by: 1, chapters: chapters)

        #expect(moved.placements[0].startTime == staged.songStarts[1])
        #expect(moved.placements[14].startTime == staged.songStarts[15])
        // The last song has nowhere to go, so it keeps the time it had.
        #expect(moved.placements[15].startTime == staged.songStarts[15])
        // A correction made by hand is better evidence than anything inferred.
        #expect(moved.isTrustworthy)
    }

    @Test func aNudgeOfZeroChangesNothing() {
        let staged = stage(talkAfter: [:], markTalk: false)
        let chapters = marks(staged.chapterTimes)
        let alignment = ConcertSetlistAligner.align(
            tracks: tracks(), chapters: chapters, duration: staged.duration
        )
        #expect(ConcertSetlistAligner.shifting(alignment, by: 0, chapters: chapters) == alignment)
    }
}

/// Which chapter each song lands on is also what renames the disc's chapters in
/// the player, so the mapping has to be recoverable from the alignment alone.
struct ConcertChapterNamingTests {
    @Test func everySongReportsTheChapterItStartsOn() {
        let songs = (1...3).map { ConcertTrack(position: $0, title: "Song \($0)", duration: 240) }
        // Three four-minute songs with a marked one-minute MC after the first
        // two. The MC being *shorter* than a song is what the alignment has to
        // go on: with MC segments the same length as the songs, pinning the
        // songs to the MC marks costs exactly the same and nothing could tell
        // the two apart.
        let marks = [0.0, 240, 300, 540, 600].enumerated().map {
            ConcertChapterMark(index: $0.offset, startTime: $0.element)
        }
        let alignment = ConcertSetlistAligner.align(tracks: songs, chapters: marks, duration: 900)

        #expect(alignment.method == .durations)
        let byChapter = Dictionary(
            uniqueKeysWithValues: alignment.placements.compactMap { placement in
                placement.chapterIndex.map { ($0, placement.trackPosition) }
            }
        )
        // The songs claim chapters 0, 2 and 4; the MC marks at 1 and 3 are not
        // claimed, and in the player those keep their own titles because
        // calling them anything would be a guess.
        #expect(byChapter == [0: 1, 2: 2, 4: 3])
    }
}
