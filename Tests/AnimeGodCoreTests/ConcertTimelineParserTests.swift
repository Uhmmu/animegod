import Foundation
import Testing
@testable import AnimeGodCore

/// A pasted timeline is the answer for the discs no source can place, so the
/// reader has to survive the shapes these lists actually come in. The first
/// fixture is one a viewer found and pasted, unedited.
struct ConcertTimelineParserTests {
    static let pasted = """
    Day1
    00:01:56 1.迷星叫
    00:05:19 2.歌いましょう鳴らしましょう
    00:12:03 3.砂寸奏
    00:15:38 4.迷路日々
    00:19:19 5.碧天伴走
    00:26:04 6.処救生
    00:29:41 7.影色舞
    00:33:17 8.潜在表明
    00:40:07 9.輪符雨
    00:43:34 10.無路矢
    00:47:25 11.回層浮
    00:54:19 12.名無声
    00:58:50 13.詩超絆
    01:02:45 14.端程山
    Encore
    01:08:45 15.壱雫空
    01:36:03 16.音一会
    01:41:06 谢幕

    DAY2
    00:02:33 1.処救生
    00:06:16 2.無路矢
    00:10:00 3.影色舞
    00:16:58 4.輪符雨
    00:20:30 5.潜在表明
    00:25:00 6.回層浮
    00:31:27 7.迷星叫
    00:34:50 8.歌いましょう鸣らしましょう
    00:40:18 9.砂寸奏
    00:43:53 10.迷路日々
    00:47:34 11.碧天伴走
    00:55:35 12.名無声
    01:00:19 13.詩超絆
    01:04:28 14.端程山
    Encore
    01:10:15 15.壱雫空
    01:38:11 16.焚音打
    01:42:48 谢幕
    01:45:30 比心
    """

    @Test func readsBothNightsOutOfOnePaste() throws {
        let discs = ConcertTimelineParser.parse(Self.pasted)
        #expect(discs.count == 2)
        #expect(discs.map(\.number) == [1, 2])
        // Fourteen songs, two encores, then 谢幕.
        #expect(discs[0].entries.count == 17)
        // Sixteen songs, then 谢幕 and 比心.
        #expect(discs[1].entries.count == 18)

        let first = try #require(discs.first?.entries.first)
        #expect(first.startTime == 116)
        // The track number comes off; the name does not.
        #expect(first.title == "迷星叫")
        #expect(!first.isEncore)

        // `Encore` on its own line marks everything after it.
        let encore = discs[0].entries.filter(\.isEncore)
        #expect(encore.map(\.title) == ["壱雫空", "音一会", "谢幕"])
        #expect(encore.first?.startTime == 4_125)

        // What is not a song is still a place in the programme, and the point of
        // the list is being able to jump to it.
        #expect(discs[1].entries.last?.title == "比心")
        #expect(discs[1].entries.last?.startTime == 6_330)
    }

    /// Every layout these lists are written in, one line each.
    @Test(arguments: [
        ("00:01:56 1.迷星叫", 116.0, "迷星叫"),
        ("1:56 迷星叫", 116.0, "迷星叫"),
        ("[00:01:56] 迷星叫", 116.0, "迷星叫"),
        ("00:01:56 - 迷星叫", 116.0, "迷星叫"),
        ("迷星叫 00:01:56", 116.0, "迷星叫"),
        ("01. 00:01:56 迷星叫", 116.0, "迷星叫"),
        ("00：01：56　1．迷星叫", 116.0, "迷星叫"),
        ("#3 00:01:56 迷星叫", 116.0, "迷星叫"),
        ("00:01:56 15 分の永遠", 116.0, "15 分の永遠"),
        ("1:02:45 14.端程山", 3_765.0, "端程山")
    ])
    func readsALineHoweverItIsWritten(_ sample: (String, Double, String)) {
        let entry = ConcertTimelineParser.entry(in: ConcertTimelineParser.normalise(sample.0), isEncore: false)
        #expect(entry?.startTime == sample.1)
        #expect(entry?.title == sample.2)
    }

    /// A paste that never says where one night ends still comes apart, because
    /// times only go forwards inside one disc.
    @Test func splitsOnTimeGoingBackwards() {
        let text = """
        00:01:00 A
        00:05:00 B
        00:09:00 C
        00:02:00 D
        00:06:00 E
        00:10:00 F
        """
        let discs = ConcertTimelineParser.parse(text)
        #expect(discs.count == 2)
        #expect(discs[0].entries.map(\.title) == ["A", "B", "C"])
        #expect(discs[1].entries.map(\.title) == ["D", "E", "F"])
    }

    @Test(arguments: ["Day1", "DAY 2", "Disc 1", "ディスク2", "1日目", "第2日", "[DAY1]"])
    func knowsADiscHeading(_ line: String) {
        #expect(ConcertTimelineParser.discHeading(ConcertTimelineParser.normalise(line)) != nil)
    }

    /// A song whose name has a number in it is not a heading.
    @Test(arguments: ["迷星叫", "BanG Dream! 10th☆LIVE DAY1:Returns", "2 of Us"])
    func doesNotMistakeASongForAHeading(_ line: String) {
        #expect(ConcertTimelineParser.discHeading(line) == nil)
    }

    @Test(arguments: ["Encore", "ENCORE", "アンコール", "安可", "返场", "- Encore -"])
    func knowsAnEncoreHeading(_ line: String) {
        #expect(ConcertTimelineParser.isEncoreHeading(ConcertTimelineParser.normalise(line)))
    }

    /// Two numbered lines are not a timeline, and prose is not one either.
    @Test func refusesWhatIsNotATimeline() {
        #expect(ConcertTimelineParser.parse("").isEmpty)
        #expect(ConcertTimelineParser.parse("00:01:00 A\n00:05:00 B").isEmpty)
        #expect(ConcertTimelineParser.parse("这是一段没有时间码的说明文字。").isEmpty)
    }
}

/// What a pasted disc becomes: the programme in the order it happened, with
/// every entry's start and each one's length taken from the next one's start.
struct ConcertPastedProgrammeTests {
    @Test func turnsAPastedNightIntoAProgramme() throws {
        let discs = ConcertTimelineParser.parse(ConcertTimelineParserTests.pasted)
        let (tracks, placements) = try #require(discs.first).programme()

        #expect(tracks.count == 17)
        #expect(tracks.map(\.position) == Array(1...17))
        #expect(tracks.first?.title == "迷星叫")
        // 00:01:56 to 00:05:19 is 3:23.
        #expect(tracks.first?.duration == 203)
        // The last entry has no next, so it has no length rather than a wrong
        // one: the curtain call is not part of the song before it.
        #expect(tracks.last?.duration == nil)
        #expect(tracks.last?.title == "谢幕")

        #expect(placements.count == tracks.count)
        #expect(placements.first?.startTime == 116)
        #expect(placements.last?.startTime == 6_066, "01:41:06")
        // Every placement points at the track it was made from, so the page can
        // line the two up.
        #expect(zip(tracks, placements).allSatisfy { $0.id == $1.trackID })
        // And the encore is still marked.
        #expect(tracks.filter(\.isEncore).map(\.title) == ["壱雫空", "音一会", "谢幕"])
    }

    /// The second night is a different programme, not a continuation.
    @Test func keepsTheNightsApart() throws {
        let discs = ConcertTimelineParser.parse(ConcertTimelineParserTests.pasted)
        #expect(discs.count == 2)
        let second = try #require(discs.last).programme()
        #expect(second.tracks.first?.title == "処救生")
        #expect(second.placements.first?.startTime == 153)
        #expect(second.tracks.last?.title == "比心")
    }
}
