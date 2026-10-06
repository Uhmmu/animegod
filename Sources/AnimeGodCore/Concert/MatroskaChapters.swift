import Foundation

/// Reads a Matroska file's chapter marks — the times **and the names** —
/// without playing it.
///
/// The marks only reached the app while mpv had the file open, because that is
/// where they were read from. So a concert whose encode kept its chapters, with
/// every song named, showed a catalogue's track list on its page with no times
/// against it, while the player's own chapter menu had the lot. Measured on a
/// real one: 29 chapters, `虚仮にしてくれ (Koke)`, `ミラーチューン (Mirror Tune)`,
/// `Narration 1`, `Narration 2`.
///
/// Only the head of the file is read. A Matroska Segment lists its top-level
/// elements before the first Cluster in nearly every muxer's output, and when
/// it does not, the SeekHead says where Chapters is — so neither case reads
/// more than a few hundred kilobytes of a file that may be six gigabytes.
public enum MatroskaChapters {
    enum ID {
        static let segment: UInt64 = 0x1853_8067
        static let seekHead: UInt64 = 0x114D_9B74
        static let seek: UInt64 = 0x4DBB
        static let seekID: UInt64 = 0x53AB
        static let seekPosition: UInt64 = 0x53AC
        static let chapters: UInt64 = 0x1043_A770
        static let cluster: UInt64 = 0x1F43_B675
        static let editionEntry: UInt64 = 0x45B9
        static let chapterAtom: UInt64 = 0xB6
        static let timeStart: UInt64 = 0x91
        static let display: UInt64 = 0x80
        static let string: UInt64 = 0x85
        static let flagHidden: UInt64 = 0x98
    }

    /// How far into a file to look for the top-level elements before giving up.
    static let headroom: UInt64 = 64 * 1024 * 1024

    public static func read(contentsOf url: URL) -> [ConcertChapterMark] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let blob = chaptersElement(in: handle) else { return [] }
        return marks(in: blob)
    }

    // MARK: - Finding the element

    static func chaptersElement(in handle: FileHandle) -> Data? {
        var reader = Reader(handle: handle)
        // The EBML header, skipped whole.
        guard let header = reader.readElement(), header.id != ID.segment else { return nil }
        reader.skip(header.size)
        guard let segment = reader.readElement(), segment.id == ID.segment else { return nil }
        let segmentStart = reader.offset

        var seekHeadEntries: [UInt64: UInt64] = [:]
        while reader.offset < segmentStart + headroom {
            guard let element = reader.readElement() else { return nil }
            switch element.id {
            case ID.chapters:
                return reader.read(element.size)
            case ID.seekHead:
                guard let data = reader.read(element.size) else { return nil }
                seekHeadEntries = seekEntries(in: data)
            case ID.cluster:
                // Past the point where a muxer writes metadata. The SeekHead is
                // the only thing that can still say where Chapters is, and its
                // positions are relative to the start of the segment's data.
                guard let position = seekHeadEntries[ID.chapters] else { return nil }
                reader.seek(to: segmentStart + position)
                guard let element = reader.readElement(), element.id == ID.chapters else { return nil }
                return reader.read(element.size)
            default:
                reader.skip(element.size)
            }
        }
        return nil
    }

    static func seekEntries(in data: Data) -> [UInt64: UInt64] {
        var entries: [UInt64: UInt64] = [:]
        var reader = Reader(data: data)
        while let seek = reader.readElement() {
            guard seek.id == ID.seek, let body = reader.read(seek.size) else {
                reader.skip(seek.size)
                continue
            }
            var inner = Reader(data: body)
            var id: UInt64?
            var position: UInt64?
            while let field = inner.readElement() {
                guard let value = inner.read(field.size) else { break }
                switch field.id {
                case ID.seekID: id = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                case ID.seekPosition: position = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                default: break
                }
            }
            if let id, let position { entries[id] = position }
        }
        return entries
    }

    // MARK: - Reading the marks

    static func marks(in chapters: Data) -> [ConcertChapterMark] {
        var found: [(time: TimeInterval, title: String)] = []
        collectAtoms(in: chapters, into: &found)
        return found
            .sorted { $0.time < $1.time }
            .enumerated()
            .map { ConcertChapterMark(index: $0.offset + 1, title: $0.element.title, startTime: $0.element.time) }
    }

    private static func collectAtoms(in data: Data, into found: inout [(time: TimeInterval, title: String)]) {
        var reader = Reader(data: data)
        while let element = reader.readElement() {
            guard let body = reader.read(element.size) else { return }
            switch element.id {
            case ID.editionEntry:
                collectAtoms(in: body, into: &found)
            case ID.chapterAtom:
                if let atom = atom(in: body) { found.append(atom) }
                // Chapters nest, and a nested one is still a mark.
                collectAtoms(in: body, into: &found)
            default:
                break
            }
        }
    }

    private static func atom(in data: Data) -> (time: TimeInterval, title: String)? {
        var reader = Reader(data: data)
        var start: TimeInterval?
        var title: String?
        var isHidden = false
        while let element = reader.readElement() {
            guard let body = reader.read(element.size) else { break }
            switch element.id {
            case ID.timeStart:
                // Nanoseconds, which is the one unit Matroska does not scale by
                // the segment's own timecode scale.
                start = TimeInterval(body.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }) / 1_000_000_000
            case ID.flagHidden:
                isHidden = body.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } != 0
            case ID.display:
                if title == nil { title = string(in: body) }
            default:
                break
            }
        }
        guard let start, !isHidden else { return nil }
        return (start, title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private static func string(in display: Data) -> String? {
        var reader = Reader(data: display)
        while let element = reader.readElement() {
            guard let body = reader.read(element.size) else { break }
            if element.id == ID.string { return String(data: body, encoding: .utf8) }
        }
        return nil
    }

    // MARK: - EBML

    struct Element {
        let id: UInt64
        let size: UInt64
    }

    /// Reads EBML out of a file or a block of bytes, the same way for both.
    struct Reader {
        private let handle: FileHandle?
        private let data: Data?
        private(set) var offset: UInt64 = 0

        init(handle: FileHandle) {
            self.handle = handle
            self.data = nil
        }

        init(data: Data) {
            self.handle = nil
            self.data = data
        }

        mutating func seek(to position: UInt64) {
            offset = position
            try? handle?.seek(toOffset: position)
        }

        mutating func skip(_ count: UInt64) {
            seek(to: offset + count)
        }

        mutating func read(_ count: UInt64) -> Data? {
            // A size that would read the whole file is a corrupt or unknown
            // one; nothing read here is ever that large.
            guard count <= 32 * 1024 * 1024 else { return nil }
            if let data {
                let start = Int(offset)
                let end = start + Int(count)
                guard start >= 0, end <= data.count else { return nil }
                offset += count
                return data.subdata(in: start..<end)
            }
            guard let read = try? handle?.read(upToCount: Int(count)), read.count == Int(count) else {
                return nil
            }
            offset += count
            return read
        }

        private mutating func byte() -> UInt8? {
            read(1)?.first
        }

        /// - Parameter keepMarker: an element ID keeps the length marker that a
        ///   size strips, which is why `0x1F43B675` is written as it is.
        mutating func number(keepMarker: Bool) -> UInt64? {
            guard let first = byte() else { return nil }
            var mask: UInt8 = 0x80
            var length = 1
            while length <= 8, first & mask == 0 {
                mask >>= 1
                length += 1
            }
            guard length <= 8 else { return nil }
            var value = UInt64(keepMarker ? first : first & (mask &- 1))
            if length > 1 {
                guard let rest = read(UInt64(length - 1)) else { return nil }
                for byte in rest { value = (value << 8) | UInt64(byte) }
            }
            return value
        }

        mutating func readElement() -> Element? {
            guard let id = number(keepMarker: true), let size = number(keepMarker: false) else {
                return nil
            }
            return Element(id: id, size: size)
        }
    }
}

public extension Array where Element == ConcertChapterMark {
    /// Whether these marks say anything a person did not already know.
    ///
    /// A rip that kept its chapters usually names them `Chapter 01` … and that
    /// is a numbering, not a setlist. Marks worth adopting are the ones that
    /// carry actual names.
    var carryRealNames: Bool {
        let named = filter { mark in
            let title = mark.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return false }
            let folded = title.lowercased()
            guard folded.hasPrefix("chapter") || folded.hasPrefix("チャプター") else { return true }
            // `Chapter 01` is a number; `Chapter: 迷星叫` is a name.
            return title.rangeOfCharacter(from: CharacterSet.letters) != nil
                && title.drop { !$0.isWhitespace }.contains { $0.isLetter && !$0.isASCII }
        }
        return named.count >= 3
    }
}
