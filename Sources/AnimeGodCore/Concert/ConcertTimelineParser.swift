import Foundation

/// A setlist with times, pasted in by hand.
///
/// This is the answer for the discs no source can place. A rip whose chapter
/// marks were stripped has no timeline anywhere — no catalogue publishes where
/// a song starts, and without marks there is nothing to infer from — but people
/// write these out and post them, and one paste is a great deal less work than
/// marking sixteen songs by hand while a concert plays.
///
/// So the reader is deliberately forgiving. What these lists have in common is
/// a timecode and a name on the same line; everything else about them varies,
/// and a reader that only accepted one layout would be a reader that mostly
/// refused.
public enum ConcertTimelineParser {
    /// One disc's worth of pasted timeline.
    public struct Disc: Hashable, Sendable {
        /// `DAY1`, `Disc 2` — whatever the paste called it, as a number.
        public var number: Int?
        public var entries: [Entry]

        public init(number: Int? = nil, entries: [Entry]) {
            self.number = number
            self.entries = entries
        }
    }

    public struct Entry: Hashable, Sendable {
        public var startTime: TimeInterval
        public var title: String
        public var isEncore: Bool

        public init(startTime: TimeInterval, title: String, isEncore: Bool = false) {
            self.startTime = startTime
            self.title = title
            self.isEncore = isEncore
        }
    }

    /// Two lines that each carry a time and a name are a timeline.
    ///
    /// It was three, on the reasoning that two could be a coincidence — and the
    /// cost of that was a paste of two songs being thrown away whole while the
    /// sheet reported "no times found in that", which was not true and gave
    /// nobody anything to act on. One stray timecode in a block of prose is
    /// still refused, which is what the floor is actually for; the second line
    /// is what makes it a sequence rather than a mention.
    public static let minimumEntries = 2

    /// How many lines carried a time at all, whatever became of them.
    ///
    /// So a refusal can say which refusal it is: nothing in the text looked
    /// like a timeline, or something did and there was not enough of it.
    public static func timedLineCount(in text: String) -> Int {
        text.components(separatedBy: .newlines)
            .map(normalise)
            .filter { !$0.isEmpty && entry(in: $0, isEncore: false) != nil }
            .count
    }

    public static func parse(_ text: String) -> [Disc] {
        var discs: [Disc] = []
        var current = Disc(entries: [])
        var isEncore = false

        func flush() {
            if current.entries.count >= minimumEntries { discs.append(current) }
            current = Disc(entries: [])
            isEncore = false
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = normalise(rawLine)
            guard !line.isEmpty else { continue }

            if let entry = entry(in: line, isEncore: isEncore) {
                // Times only ever go forwards inside one disc. A line that goes
                // backwards is the next disc, even when the paste forgot to say
                // so — which is how a list of two nights with no headings still
                // comes apart correctly.
                if let last = current.entries.last, entry.startTime < last.startTime {
                    flush()
                }
                current.entries.append(entry)
                continue
            }

            // A line with no timecode is a heading, and there are two kinds.
            if isEncoreHeading(line) {
                isEncore = true
                continue
            }
            if let number = discHeading(line) {
                flush()
                current.number = number
                continue
            }
        }
        flush()
        return discs
    }

    // MARK: - Lines

    /// Folds away what these lists differ about before anything is read: the
    /// full-width punctuation a Chinese or Japanese paste uses, and the
    /// brackets some of them wrap the time in.
    static func normalise(_ line: String) -> String {
        line
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "．", with: ".")
            .replacingOccurrences(of: "　", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `00:01:56 1.迷星叫`, `1:56 迷星叫`, `[00:01:56] 迷星叫`, `迷星叫 00:01:56`.
    static func entry(in line: String, isEncore: Bool) -> Entry? {
        let pattern = #"(?<!\d)(?:(\d{1,3}):)?(\d{1,2}):(\d{2})(?!\d)"#
        guard let match = line.range(of: pattern, options: .regularExpression) else { return nil }
        guard let seconds = time(String(line[match])) else { return nil }

        var title = line
        title.removeSubrange(match)
        title = strip(title)
        guard !title.isEmpty else { return nil }
        return Entry(startTime: seconds, title: title, isEncore: isEncore)
    }

    /// Takes the decoration off what is left once the time is gone: the track
    /// number, the brackets the time sat in, and the dashes between them.
    static func strip(_ text: String) -> String {
        var title = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t[]【】()（）<>《》-—–~～|"))
        // A leading track number. With a marker in front of it — `#3`, `No.4`,
        // `M05` — a space is separator enough; without one a separator is
        // required, or a song called `15 分の永遠` would lose its first word.
        for numbering in [
            #"^(?:#|no\.?|m|track)\s*\d{1,3}\s*[.、,:：)）\]】]?\s*"#,
            #"^\d{1,3}\s*[.、,:：)）\]】]\s*"#
        ] {
            guard let range = title.range(of: numbering, options: [.regularExpression, .caseInsensitive])
            else { continue }
            title.removeSubrange(range)
            break
        }
        return title.trimmingCharacters(in: CharacterSet(charactersIn: " \t[]【】()（）-—–~～|."))
    }

    static let encoreHeadings = ["encore", "アンコール", "安可", "返场", "返場", "en", "ec"]

    static func isEncoreHeading(_ line: String) -> Bool {
        let folded = line.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-—–[]【】()（）<>《》:：*#=~"))
        guard folded.count <= 12 else { return false }
        return encoreHeadings.contains { folded == $0 || folded.hasPrefix($0) }
    }

    /// `DAY1`, `Day 2`, `DISC 1`, `1日目`, `第2日` on a line of their own.
    ///
    /// The same reader the scanner uses for folder names, so a paste and a
    /// folder cannot disagree about what counts as a second night.
    static func discHeading(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t-—–[]【】()（）<>《》:：*#="))
        // A heading is a heading and not a song with a number in its name, so it
        // has to be short and has to be mostly the label.
        guard trimmed.count <= 16, let label = AnimeFilenameParser.discLabel(in: trimmed) else { return nil }
        let remainder = trimmed
            .replacingCharacters(in: label.range, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-—–:：."))
        return remainder.isEmpty ? label.number : nil
    }

    /// `HH:MM:SS` or `MM:SS`.
    static func time(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.map { $0! }
        switch numbers.count {
        case 2: return TimeInterval(numbers[0] * 60 + numbers[1])
        case 3: return TimeInterval(numbers[0] * 3600 + numbers[1] * 60 + numbers[2])
        default: return nil
        }
    }
}

public extension ConcertTimelineParser.Disc {
    /// The pasted disc as a programme: the songs in the order they happened,
    /// and where each one starts.
    ///
    /// A song runs until the next one begins. The last one has no next, and
    /// guessing its length from the programme's end would make the curtain call
    /// part of it — so it has none, which is honest.
    func programme() -> (tracks: [ConcertTrack], placements: [ConcertSetlistAlignment.Placement]) {
        var tracks: [ConcertTrack] = []
        var placements: [ConcertSetlistAlignment.Placement] = []
        for (index, entry) in entries.enumerated() {
            let next = entries.indices.contains(index + 1) ? entries[index + 1].startTime : nil
            let length = next.map { $0 - entry.startTime }
            let track = ConcertTrack(
                position: index + 1,
                title: entry.title,
                duration: (length ?? 0) > 0 ? length : nil,
                kind: .song,
                isEncore: entry.isEncore
            )
            tracks.append(track)
            placements.append(.init(
                trackID: track.id, trackPosition: track.position,
                startTime: entry.startTime, chapterIndex: nil
            ))
        }
        return (tracks, placements)
    }
}
