import Foundation

/// Where each song of a setlist starts in the disc's own timeline.
public struct ConcertSetlistAlignment: Hashable, Sendable {
    /// How the timeline was arrived at. The page says this out loud, because
    /// the methods are not equally trustworthy and a viewer who knows the
    /// timeline was inferred will correct it instead of distrusting the
    /// whole feature.
    public enum Method: String, Hashable, Sendable {
        /// The disc named its own chapters after the songs. Nothing to infer.
        case chapterTitles
        /// Song lengths matched against the spans between chapter marks.
        case durations
        /// As many chapters as songs and no lengths to check with, so the
        /// nth chapter is the nth song.
        case oneToOne
        /// No usable chapter marks: the songs are laid end to end. Right only
        /// for a concert with no talk in it, which is no concert — it exists
        /// so the list is still clickable, and says so with a low confidence.
        case cumulative
        /// Nothing to align, or nothing to align against.
        case none
    }

    public struct Placement: Hashable, Sendable {
        public let trackID: UUID
        public let trackPosition: Int
        public var startTime: TimeInterval
        /// The chapter mark this song was pinned to, when it was pinned to
        /// one. Nil means the time was computed, not read off the disc.
        public var chapterIndex: Int?
        /// How long the disc leaves for this song — the run of chapters it
        /// was given. Nil when there were no chapters to measure.
        public var allottedDuration: TimeInterval?

        public init(
            trackID: UUID,
            trackPosition: Int,
            startTime: TimeInterval,
            chapterIndex: Int?,
            allottedDuration: TimeInterval? = nil
        ) {
            self.trackID = trackID
            self.trackPosition = trackPosition
            self.startTime = startTime
            self.chapterIndex = chapterIndex
            self.allottedDuration = allottedDuration
        }
    }

    public var placements: [Placement]
    public var method: Method
    /// 0…1. At or above `trustworthyConfidence` the page presents the
    /// timeline as fact; below it, it offers the controls to correct it.
    public var confidence: Double

    public static let trustworthyConfidence = 0.7

    public static let empty = ConcertSetlistAlignment(placements: [], method: .none, confidence: 0)

    public init(placements: [Placement], method: Method, confidence: Double) {
        self.placements = placements
        self.method = method
        self.confidence = min(1, max(0, confidence))
    }

    public var isTrustworthy: Bool { confidence >= Self.trustworthyConfidence }

    public func startTime(forTrackID id: UUID) -> TimeInterval? {
        placements.first { $0.trackID == id }?.startTime
    }
}

/// Works out where each song of a concert disc begins.
///
/// **No source publishes this.** Discogs, MusicBrainz and Bangumi each give a
/// setlist; not one gives "track 7 starts at 42:13", and no setlist database
/// covers Japanese anime concerts well enough to ask. What does know is the
/// disc: a concert Blu-ray carries a chapter mark at every song, which the
/// player already reads.
///
/// The counts do not agree, which is the whole problem. Measured on
/// `ANZX-10294` (結束バンドLIVE-恒星-): 16 songs running 70.7 minutes on a
/// programme of about 93 — the rest is the band talking. So chapter marks are
/// a *superset* of song starts, and taking the nth chapter for the nth song
/// is wrong on every disc that also marks its MC segments.
///
/// What survives that is the shape of the lengths, but only under the right
/// model of the disc. Charging each song for the whole span up to the *next
/// song's* mark does not work, and the arithmetic says so: on a disc whose
/// MC segments are marked, pinning song two to the MC mark leaves song one a
/// span exactly its own length, which scores better than the truth and shifts
/// the entire chain by one. So the disc is modelled as a run of segments
/// between consecutive marks, each song is given a **contiguous run** of
/// them, and the MC segments are left explicitly unassigned. A song's run
/// then has to match its own length rather than its length plus whatever
/// followed it, and the correct chain is the cheapest one by a wide margin.
public enum ConcertSetlistAligner {
    // MARK: - Tuning

    /// How far a chapter mark may sit inside a song before the fit is called
    /// impossible. Marks are authored by hand and a published length is
    /// rounded to the second, so a few seconds of disagreement is normal.
    static let fitTolerance: TimeInterval = 8

    /// An overture or opening film before the first song costs nothing up to
    /// here. It is not an alignment error, and charging for it would drag the
    /// first song onto the opening film's own mark.
    static let freeLeadIn: TimeInterval = 300

    /// A run shorter than its song means the song does not fit, which makes
    /// the alignment wrong rather than merely loose. A run longer than its
    /// song is talk the disc did not mark, which is ordinary — so an underrun
    /// costs several times what an overrun does, but an overrun is never
    /// free: it being free is what let a shifted chain win.
    static let underrunWeight: Double = 1.0
    static let overrunWeight: Double = 0.3

    /// A song may be marked in the middle — a long intro, a costume change —
    /// so a run of a few segments is allowed. Past this it would be a song
    /// swallowing the MC and the song after it.
    static let maxSegmentsPerSong = 4

    /// The typical gap between what a song is given and what it runs, past
    /// which the alignment stops looking like a concert.
    static let plausibleMedianResidual: TimeInterval = 25

    // MARK: - Entry point

    /// - Parameters:
    ///   - tracks: the disc's track list; entries that are not part of the
    ///     performance (commentary, bonus features) are ignored.
    ///   - chapters: the chapter marks the player read off the disc.
    ///   - duration: the programme's full length, which is what closes the
    ///     last segment.
    public static func align(
        tracks: [ConcertTrack],
        chapters: [ConcertChapterMark],
        duration: TimeInterval
    ) -> ConcertSetlistAlignment {
        let songs = tracks.filter { $0.kind.belongsOnTimeline }
        guard !songs.isEmpty else { return .empty }

        let marks = chapters
            .filter { $0.startTime >= 0 && (duration <= 0 || $0.startTime < duration) }
            .sorted { $0.startTime < $1.startTime }

        if let byTitle = alignByChapterTitles(songs: songs, marks: marks) { return byTitle }

        let lengths = songs.compactMap(\.duration)
        if lengths.count == songs.count, marks.count >= songs.count, duration > 0,
           let byDuration = alignByDurations(songs: songs, lengths: lengths, marks: marks, duration: duration) {
            return byDuration
        }

        if marks.count == songs.count, !marks.isEmpty {
            return ConcertSetlistAlignment(
                placements: zip(songs, marks).map {
                    .init(trackID: $0.id, trackPosition: $0.position,
                          startTime: $1.startTime, chapterIndex: $1.index)
                },
                method: .oneToOne,
                // The counts agreeing is real evidence and no evidence at
                // all at once: it is as likely on a disc that marks nothing
                // but songs as on one with as many MC marks as it has
                // missing songs.
                confidence: 0.6
            )
        }

        return alignCumulatively(songs: songs, from: marks.first?.startTime ?? 0, duration: duration)
    }

    /// Moves every song `offset` chapters along, for the viewer who can see
    /// the list is one song out. A song pushed past either end of the chapter
    /// list keeps the time it had, so the nudge can be taken back.
    public static func shifting(
        _ alignment: ConcertSetlistAlignment,
        by offset: Int,
        chapters: [ConcertChapterMark]
    ) -> ConcertSetlistAlignment {
        guard offset != 0, !chapters.isEmpty else { return alignment }
        let marks = chapters.sorted { $0.startTime < $1.startTime }
        var slotOf: [Int: Int] = [:]
        for (slot, mark) in marks.enumerated() { slotOf[mark.index] = slot }

        var moved = alignment
        moved.placements = alignment.placements.map { placement in
            var placement = placement
            guard let slot = placement.chapterIndex.flatMap({ slotOf[$0] }) else { return placement }
            let target = slot + offset
            guard marks.indices.contains(target) else { return placement }
            placement.startTime = marks[target].startTime
            placement.chapterIndex = marks[target].index
            return placement
        }
        // A correction made by hand is the best information there is.
        moved.confidence = max(moved.confidence, ConcertSetlistAlignment.trustworthyConfidence)
        return moved
    }

    // MARK: - The disc already said so

    /// Some discs — and most rippers who rebuild chapters — name each chapter
    /// after the song. When they do there is nothing to infer, and inferring
    /// anyway could only do worse.
    private static func alignByChapterTitles(
        songs: [ConcertTrack],
        marks: [ConcertChapterMark]
    ) -> ConcertSetlistAlignment? {
        guard marks.count >= songs.count else { return nil }
        let named = marks.filter { !isGenericChapterTitle($0.title) }
        guard named.count >= songs.count else { return nil }

        var placements: [ConcertSetlistAlignment.Placement] = []
        var cursor = 0
        for song in songs {
            let key = normalise(song.title)
            guard !key.isEmpty else { return nil }
            guard let slot = named[cursor...].firstIndex(where: { matchesSong(key, chapterTitle: $0.title) })
            else { return nil }
            cursor = slot + 1
            placements.append(.init(trackID: song.id, trackPosition: song.position,
                                    startTime: named[slot].startTime, chapterIndex: named[slot].index))
        }
        return ConcertSetlistAlignment(placements: placements, method: .chapterTitles, confidence: 1)
    }

    /// `Chapter 3`, `チャプター 3`, `03`, `00:12:34` — a mark the authoring
    /// tool numbered rather than named.
    static func isGenericChapterTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        for prefix in ["chapter", "chapitre", "kapitel", "チャプター", "チャプタ", "track", "part", "第"] {
            guard lower.hasPrefix(prefix) else { continue }
            let rest = lower.dropFirst(prefix.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " 　.-:#章节話话"))
            if rest.isEmpty || Int(rest) != nil { return true }
        }
        // A bare number, or a timecode the ripper used as a name.
        return trimmed.allSatisfy { $0.isNumber || $0 == ":" || $0 == "." }
    }

    /// Whether a chapter mark names this song, with the ripper's own numbering
    /// taken off first.
    static func matchesSong(_ songKey: String, chapterTitle: String) -> Bool {
        let marked = normalise(chapterTitle)
        return titlesMatch(marked, songKey) || titlesMatch(withoutLeadingIndex(marked), songKey)
    }

    /// `M01 ひとりぼっち東京`, `03.光の中へ`, `#7 あのバンド` — a ripper's own
    /// numbering in front of the song's name. It has to come off before the
    /// comparison, or a four-character title would be mostly prefix and fail
    /// the similarity test that a twelve-character one passes: `m15光の中へ`
    /// against `光の中へ` is only 57 % the same string.
    static func withoutLeadingIndex(_ normalised: String) -> String {
        let scalars = Array(normalised)
        var index = 0
        while index < scalars.count, index < 2, scalars[index].isLetter, scalars[index].isASCII {
            index += 1
        }
        var digits = 0
        while index < scalars.count, scalars[index].isNumber, scalars[index].isASCII {
            index += 1
            digits += 1
        }
        // Digits are what make it a number, and something has to be left of
        // the title — `1/6` normalises to `16` and is a song, not an index.
        guard (1...3).contains(digits), index < scalars.count else { return normalised }
        return String(scalars[index...])
    }

    /// Deliberately strict. A chapter title either is the song's name or it
    /// is not: a loose comparison would pair `星座になれたら` with
    /// `星座になれたら (Acoustic)` on one disc and with the wrong song on the
    /// next, and the durations method is the better answer whenever the
    /// titles are not plainly the same.
    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (long, short) = a.count >= b.count ? (a, b) : (b, a)
        // A mark named `M14 青春コンプレックス` or `青春コンプレックス -encore-`
        // is still that song, as long as the name is most of what is there.
        return long.contains(short) && Double(short.count) / Double(long.count) >= 0.6
    }

    /// Folds away everything a chapter title and a track title can disagree
    /// about while naming the same song: case, width, spacing, and whatever
    /// punctuation each side decorates its own list with.
    static func normalise(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        return String(folded.filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Song lengths against chapter spans

    /// The disc as segments between consecutive marks, with the programme's
    /// end closing the last one.
    private static func segments(marks: [ConcertChapterMark], duration: TimeInterval) -> [TimeInterval] {
        marks.indices.map { index in
            let end = index + 1 < marks.count ? marks[index + 1].startTime : duration
            return max(0, end - marks[index].startTime)
        }
    }

    private static func alignByDurations(
        songs: [ConcertTrack],
        lengths: [TimeInterval],
        marks: [ConcertChapterMark],
        duration: TimeInterval
    ) -> ConcertSetlistAlignment? {
        let n = songs.count
        let m = marks.count
        let spans = segments(marks: marks, duration: duration)
        // Prefix sums so the total of a run is one subtraction.
        var prefix = [TimeInterval](repeating: 0, count: m + 1)
        for index in 0..<m { prefix[index + 1] = prefix[index] + spans[index] }

        let infinity = Double.greatestFiniteMagnitude
        // best[i][a]: the cheapest way to place songs i… using segments a…
        // `run[i][a]` remembers how many segments song i was given there, and
        // -1 means "segment a was left to the MC and song i starts later".
        var best = Array(repeating: Array(repeating: infinity, count: m + 1), count: n + 1)
        var run = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for a in 0...m { best[n][a] = 0 }

        for i in stride(from: n - 1, through: 0, by: -1) {
            for a in stride(from: m - 1, through: 0, by: -1) {
                var cheapest = infinity
                var chosen = -1
                let maxRun = min(Self.maxSegmentsPerSong, m - a)
                for length in 1...maxRun {
                    let tail = best[i + 1][a + length]
                    guard tail < infinity else { continue }
                    let total = prefix[a + length] - prefix[a]
                    var cost = fitCost(run: total, songLength: lengths[i]) + tail
                    // Whatever sits before the first song is the opening, not
                    // an error — up to a point.
                    if i == 0 { cost += overrunWeight * max(0, marks[a].startTime - freeLeadIn) }
                    if cost < cheapest { cheapest = cost; chosen = length }
                }
                // Leaving this segment to the MC and starting the song later.
                if best[i][a + 1] < cheapest { cheapest = best[i][a + 1]; chosen = -1 }
                best[i][a] = cheapest
                run[i][a] = chosen
            }
        }
        guard best[0][0] < infinity else { return nil }

        var placements: [ConcertSetlistAlignment.Placement] = []
        var residuals: [TimeInterval] = []
        var fits = 0
        var a = 0
        for i in 0..<n {
            while a < m, run[i][a] == -1 { a += 1 }
            guard a < m, run[i][a] > 0 else { return nil }
            let length = run[i][a]
            let total = prefix[a + length] - prefix[a]
            placements.append(.init(
                trackID: songs[i].id, trackPosition: songs[i].position,
                startTime: marks[a].startTime, chapterIndex: marks[a].index,
                allottedDuration: total
            ))
            residuals.append(abs(total - lengths[i]))
            if total >= lengths[i] - fitTolerance { fits += 1 }
            a += length
        }
        guard placements.count == n else { return nil }

        return ConcertSetlistAlignment(
            placements: placements,
            method: .durations,
            confidence: confidence(fits: fits, of: n, residuals: residuals)
        )
    }

    private static func fitCost(run: TimeInterval, songLength: TimeInterval) -> Double {
        if run < songLength - fitTolerance {
            return underrunWeight * (songLength - fitTolerance - run)
        }
        return overrunWeight * max(0, run - songLength)
    }

    /// Two questions, and an alignment has to answer both: does every song
    /// fit in the room the disc gives it, and is what is left over the size
    /// of stage talk rather than of another song?
    private static func confidence(fits: Int, of total: Int, residuals: [TimeInterval]) -> Double {
        let fitShare = Double(fits) / Double(total)
        guard !residuals.isEmpty else { return fitShare }
        let sorted = residuals.sorted()
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
        let tightness = median <= plausibleMedianResidual ? 1 : plausibleMedianResidual / median
        return fitShare * tightness
    }

    // MARK: - Nothing to go on

    private static func alignCumulatively(
        songs: [ConcertTrack],
        from start: TimeInterval,
        duration: TimeInterval
    ) -> ConcertSetlistAlignment {
        guard songs.allSatisfy({ $0.duration != nil }) else { return .empty }
        var cursor = start
        var placements: [ConcertSetlistAlignment.Placement] = []
        for song in songs {
            guard duration <= 0 || cursor < duration else { return .empty }
            placements.append(.init(trackID: song.id, trackPosition: song.position,
                                    startTime: cursor, chapterIndex: nil))
            cursor += song.duration ?? 0
        }
        return ConcertSetlistAlignment(placements: placements, method: .cumulative, confidence: 0.25)
    }
}
