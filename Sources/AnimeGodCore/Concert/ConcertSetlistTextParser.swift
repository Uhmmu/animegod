import Foundation

/// Reads a setlist out of prose.
///
/// Bangumi's 音乐 subject for a concert Blu-ray has no track-list field: the
/// setlist is in the free-text summary, under a heading, numbered by hand.
/// Measured on subject 512098 (結束バンドLIVE-恒星), the summary carries
/// `〈収録楽曲〉` and then sixteen lines of `01．ひとりぼっち東京`. That is a real
/// setlist and worth reading, because it is there for discs MusicBrainz has
/// never heard of.
///
/// The hazard is everything *else* in the summary that starts with a number.
/// The same text holds `17:00開場／18：00開演` and `・5.1chサラウンド`, both of
/// which match any reasonable "numbered line" pattern. What tells a setlist
/// apart is not the shape of one line but the shape of the run: a setlist
/// counts from one, upwards, without gaps. So every candidate is collected and
/// then the longest unbroken run starting at one is taken, which drops `17:`
/// and `5.` without having to enumerate what they might be.
public enum ConcertSetlistTextParser {
    /// Headings a listing puts above its setlist. When one is present only the
    /// text after it is considered, which is both safer and cheaper.
    static let headings = [
        "収録楽曲", "収録曲", "収録内容", "曲目", "セットリスト", "セトリ",
        "tracklist", "track list", "曲目列表", "收录曲目", "收录内容", "歌单"
    ]

    /// Two numbered lines are a coincidence; three in a row are a list.
    static let minimumSongs = 3

    /// The encore restarts the numbering. Measured on the same subject: the
    /// main set runs `01`…`13`, then a bare `アンコール` line, then `01`…`03`
    /// again — sixteen songs written as two runs from one. Reading only the
    /// longest run would quietly drop the last three songs of the concert.
    static let encoreHeadings = ["アンコール", "encore", "安可", "アンコール", "ダブルアンコール", "w.encore"]

    /// Where the live ends and the box's other discs begin. Everything after
    /// one of these is a different programme.
    static let boundaryHeadings = [
        "特典映像", "映像特典", "disc 2", "disc2", "disc 3", "disc3",
        "ディスク2", "ディスク3", "bonus", "特典"
    ]

    public static func songs(in text: String?) -> [ConcertTrack] {
        guard let text, !text.isEmpty else { return [] }
        let sections = sectioned(afterHeading(in: text))
        let main = longestRunFromOne(in: sections.main)
        guard main.count >= minimumSongs else { return [] }
        let encore = longestRunFromOne(in: sections.encore)
        let all = main.map { ($0, false) } + encore.map { ($0, true) }
        return all.enumerated().map { index, pair in
            let classified = ConcertTrackClassifier.classify(title: pair.0.title)
            return ConcertTrack(
                position: index + 1,
                title: classified.title,
                duration: nil,
                kind: classified.kind,
                isEncore: pair.1 || classified.isEncore
            )
        }
    }

    /// Splits the numbered lines into the main set and the encore, and stops
    /// at the first heading that belongs to another disc.
    private static func sectioned(_ text: String) -> (main: [Entry], encore: [Entry]) {
        var main: [Entry] = []
        var encore: [Entry] = []
        var inEncore = false
        for line in text.components(separatedBy: .newlines) {
            let folded = line.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t　・*-—●○◆☆★【】〈〉[]"))
            if boundaryHeadings.contains(where: { folded.contains($0) }) { break }
            if let entry = numberedEntry(in: line) {
                if inEncore { encore.append(entry) } else { main.append(entry) }
                continue
            }
            // A bare `アンコール` line, not a song whose title contains it.
            if encoreHeadings.contains(where: { folded.contains($0) }), folded.count <= 24 {
                inEncore = true
            }
        }
        return (main, encore)
    }

    /// Everything after the last setlist heading, or the whole text when there
    /// is none. The *last* one: a limited edition's summary describes disc one
    /// and then disc two, and the heading nearest the numbers is the one that
    /// introduces them.
    private static func afterHeading(in text: String) -> String {
        let folded = text.lowercased()
        var best: String.Index?
        for heading in headings {
            var searchRange = folded.startIndex..<folded.endIndex
            while let found = folded.range(of: heading.lowercased(), range: searchRange) {
                if best == nil || found.upperBound > best! { best = found.upperBound }
                guard found.upperBound < folded.endIndex else { break }
                searchRange = found.upperBound..<folded.endIndex
            }
        }
        guard let best else { return text }
        return String(text[best...])
    }

    private struct Entry {
        let number: Int
        let title: String
    }

    /// `01．ひとりぼっち東京`, `1. Distortion!!`, `M03 カラカラ`, `12）星座になれたら`.
    private static func numberedEntry(in line: String) -> Entry? {
        // Full-width spaces are what these listings indent with.
        var working = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t　・*-—●○◆☆★"))
        guard !working.isEmpty else { return nil }

        // An optional marker in front of the number.
        for marker in ["track", "no.", "no", "m", "#", "en", "第"] {
            let lowered = working.lowercased()
            if lowered.hasPrefix(marker), working.count > marker.count {
                let next = working[working.index(working.startIndex, offsetBy: marker.count)]
                if next.isNumber {
                    working = String(working.dropFirst(marker.count))
                    break
                }
            }
        }

        var digits = ""
        var index = working.startIndex
        while index < working.endIndex, working[index].isNumber, digits.count < 3 {
            digits.append(working[index])
            index = working.index(after: index)
        }
        guard let number = Int(digits), number > 0, index < working.endIndex else { return nil }

        // A separator has to be there: without one, `5.1ch` and a bare year
        // are indistinguishable from a track.
        let separators = CharacterSet(charactersIn: "．.、,:：)）]】。曲首 　\t")
        guard let scalar = working[index].unicodeScalars.first, separators.contains(scalar) else { return nil }
        let title = String(working[working.index(after: index)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t　．.、,:：)）]】"))
        guard !title.isEmpty else { return nil }
        return Entry(number: number, title: title)
    }

    /// The longest `1, 2, 3, …` with no gaps. A limited edition lists two
    /// discs, both counting from one, so the longer of the two wins — which is
    /// the live rather than the bonus disc.
    private static func longestRunFromOne(in candidates: [Entry]) -> [Entry] {
        var best: [Entry] = []
        var current: [Entry] = []
        for entry in candidates {
            if entry.number == 1 {
                if current.count > best.count { best = current }
                current = [entry]
            } else if let last = current.last, entry.number == last.number + 1 {
                current.append(entry)
            } else if entry.number != current.last?.number {
                // A number that continues nothing ends the run. A repeat of
                // the same number is a duplicated line, not a break.
                if current.count > best.count { best = current }
                current = []
            }
        }
        return current.count > best.count ? current : best
    }
}
