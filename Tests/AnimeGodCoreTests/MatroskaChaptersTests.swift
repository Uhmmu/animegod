import Foundation
import Testing

@testable import AnimeGodCore

/// Reading a file's chapter marks without playing it. The fixtures are built
/// byte by byte, so what is being tested is the parsing rather than one muxer's
/// habits.
struct MatroskaChaptersTests {
    // MARK: - Building EBML by hand

    private func vint(_ value: UInt64, length: Int) -> Data {
        var bytes = [UInt8]()
        for index in stride(from: length - 1, through: 0, by: -1) {
            bytes.append(UInt8((value >> (8 * index)) & 0xFF))
        }
        bytes[0] |= UInt8(0x80 >> (length - 1))
        return Data(bytes)
    }

    private func element(_ id: [UInt8], _ body: Data) -> Data {
        Data(id) + vint(UInt64(body.count), length: 4) + body
    }

    private func unsigned(_ id: [UInt8], _ value: UInt64) -> Data {
        var bytes = [UInt8]()
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        return element(id, Data(bytes))
    }

    private func atom(_ seconds: Double, _ title: String, hidden: Bool = false) -> Data {
        var body = unsigned([0x91], UInt64(seconds * 1_000_000_000))
        if hidden { body += unsigned([0x98], 1) }
        body += element([0x80], element([0x85], Data(title.utf8)))
        return element([0xB6], body)
    }

    private func file(chapters: Data, chaptersAfterCluster: Bool = false) -> Data {
        let header = element([0x1A, 0x45, 0xDF, 0xA3], Data([0x42, 0x86, 0x81, 0x01]))
        let chaptersElement = element([0x10, 0x43, 0xA7, 0x70], chapters)
        var segmentBody = Data()
        if chaptersAfterCluster {
            // A SeekHead that points past the first cluster, which is where
            // some muxers leave the chapters.
            let seekBody = element([0x53, 0xAB], Data([0x10, 0x43, 0xA7, 0x70]))
                + unsigned([0x53, 0xAC], 0)
            var seekHead = element([0x11, 0x4D, 0x9B, 0x74], element([0x4D, 0xBB], seekBody))
            let cluster = element([0x1F, 0x43, 0xB6, 0x75], Data(repeating: 0, count: 32))
            // The position is relative to the segment's data, so it is known
            // only once the parts before it are sized.
            let position = UInt64(seekHead.count + cluster.count)
            let fixedSeek = element([0x53, 0xAB], Data([0x10, 0x43, 0xA7, 0x70]))
                + unsigned([0x53, 0xAC], position)
            seekHead = element([0x11, 0x4D, 0x9B, 0x74], element([0x4D, 0xBB], fixedSeek))
            segmentBody = seekHead + cluster + chaptersElement
        } else {
            segmentBody = chaptersElement + element([0x1F, 0x43, 0xB6, 0x75], Data(repeating: 0, count: 8))
        }
        return header + element([0x18, 0x53, 0x80, 0x67], segmentBody)
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mkv")
        try data.write(to: url)
        return url
    }

    // MARK: - What it reads

    @Test func readsTimesAndNames() throws {
        let edition = element([0x45, 0xB9], atom(0, "Start")
            + atom(52.2, "Narration 1")
            + atom(143.7, "虚仮にしてくれ (Koke)"))
        let url = try write(file(chapters: edition))
        defer { try? FileManager.default.removeItem(at: url) }

        let marks = MatroskaChapters.read(contentsOf: url)
        #expect(marks.map(\.title) == ["Start", "Narration 1", "虚仮にしてくれ (Koke)"])
        #expect(marks.map(\.index) == [1, 2, 3])
        #expect(abs(marks[1].startTime - 52.2) < 0.001)
    }

    /// Some muxers write the chapters after the first cluster, and then the
    /// SeekHead is the only thing that says where they are.
    @Test func followsTheSeekHeadWhenChaptersComeLate() throws {
        let edition = element([0x45, 0xB9], atom(0, "一") + atom(60, "二"))
        let url = try write(file(chapters: edition, chaptersAfterCluster: true))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MatroskaChapters.read(contentsOf: url).map(\.title) == ["一", "二"])
    }

    /// A hidden chapter is not a mark anybody is meant to see.
    @Test func skipsHiddenChapters() throws {
        let edition = element([0x45, 0xB9], atom(0, "一") + atom(30, "隠し", hidden: true) + atom(60, "二"))
        let url = try write(file(chapters: edition))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MatroskaChapters.read(contentsOf: url).map(\.title) == ["一", "二"])
    }

    @Test func aFileWithNoChaptersSaysSo() throws {
        let url = try write(file(chapters: Data()))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MatroskaChapters.read(contentsOf: url).isEmpty)

        // And something that is not Matroska at all is not a crash.
        let nonsense = try write(Data(repeating: 0xAB, count: 4096))
        defer { try? FileManager.default.removeItem(at: nonsense) }
        #expect(MatroskaChapters.read(contentsOf: nonsense).isEmpty)
    }

    // MARK: - Whether they are worth adopting

    /// A rip that kept its chapters usually numbers them, and a numbering is
    /// not a setlist. Measured on a real one: the 8th LIVE rip's 23 chapters
    /// are `Chapter 01` through `Chapter 23`.
    @Test func tellsANumberingFromASetlist() {
        let numbered = (1...23).map {
            ConcertChapterMark(index: $0, title: String(format: "Chapter %02d", $0), startTime: Double($0) * 60)
        }
        #expect(!numbered.carryRealNames)

        let named = ["Start", "Narration 1", "虚仮にしてくれ (Koke)", "ミラーチューン (Mirror Tune)"]
            .enumerated()
            .map { ConcertChapterMark(index: $0.offset + 1, title: $0.element, startTime: Double($0.offset) * 60) }
        #expect(named.carryRealNames)

        // Unnamed marks are a numbering with the numbers left off.
        let blank = (1...10).map { ConcertChapterMark(index: $0, title: "", startTime: Double($0) * 60) }
        #expect(!blank.carryRealNames)
    }
}
