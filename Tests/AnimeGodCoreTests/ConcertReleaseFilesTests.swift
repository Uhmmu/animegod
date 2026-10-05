import Foundation
import Testing
@testable import AnimeGodCore

/// A release says more about itself in its own folder than any catalogue does,
/// and the proof is the download this was written for: the folder was named
/// `[DBD-Raws][MyGO!!!!! 6th LIVE…][1080P][BDRip][HEVC-10bit][FLAC][MKV]` and
/// carried no catalogue number at all, while `BRMM-10876.cue` sat two levels
/// down — and that number answers with the release and both nights' setlists.
struct ConcertReleaseFilesTests {
    private func makeRelease(_ paths: [String: Data?]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        for (path, contents) in paths {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try (contents ?? Data([0x01])).write(to: url)
        }
        return root
    }

    /// A cue sheet written the way the real one is: GBK, CRLF, `CATALOG`, and
    /// the next track's `INDEX 00` standing in for this track's length.
    private var cueSheet: Data {
        let text = """
        REM DATE 2024\r
        CATALOG 4562494358488\r
        PERFORMER "MyGO!!!!!"\r
        TITLE "跡暖空"\r
        FILE "01. 歩拾道.wav" WAVE\r
          TRACK 01 AUDIO\r
            TITLE "歩拾道"\r
            INDEX 01 00:00:00\r
          TRACK 02 AUDIO\r
            TITLE "明弦音"\r
            INDEX 00 04:20:27\r
        FILE "02. 明弦音.wav" WAVE\r
            INDEX 01 00:00:00\r
          TRACK 03 AUDIO\r
            TITLE "孤壊牢"\r
            INDEX 00 04:02:24\r
        """
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return text.data(using: gbk)!
    }

    @Test func readsTheCatalogueNumberOutOfACueSheetsName() throws {
        let root = try makeRelease([
            "[DBD-Raws][Live][1080P][BDRip][HEVC-10bit][FLAC][MKV]/Live.mkv": nil,
            "[DBD-Raws][Live][1080P][BDRip][HEVC-10bit][FLAC][MKV]/OST/BRMM-10876.cue": cueSheet
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ConcertReleaseFileReader.read(folder: root)
        #expect(files.catalogNumbers.map(\.description) == ["BRMM-10876"])
        // And the sheet's own contents, decoded out of GBK.
        #expect(files.barcode == "4562494358488")
        #expect(files.performer == "MyGO!!!!!")
        #expect(files.albumTitle == "跡暖空")
        #expect(files.cueTracks.map(\.title) == ["歩拾道", "明弦音", "孤壊牢"])
        // A track's length is where the next track's pregap begins.
        #expect(files.cueTracks.first?.duration.map { Int($0) } == 260)
    }

    /// Every group names the artwork folder differently, so the rule is not the
    /// name: several images in a folder are the artwork whatever it is called.
    @Test func findsArtworkWhateverTheFolderIsCalled() throws {
        let root = try makeRelease([
            "Release/Live.mkv": nil,
            "Release/Cover.jpg": nil,
            "Release/書影/01.jpg": nil,
            "Release/書影/02.jpg": nil,
            "Release/書影/03.jpg": nil,
            "Release/thumbs/one.jpg": nil
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ConcertReleaseFileReader.read(folder: root)
        // The loose `Cover.jpg` was put there to be the cover, so it leads.
        #expect(files.coverImageURLs.first?.lastPathComponent == "Cover.jpg")
        #expect(files.coverImageURLs.count == 4)
        // One image in a folder is a thumbnail, not a scan.
        #expect(!files.coverImageURLs.contains { $0.lastPathComponent == "one.jpg" })
    }

    /// A rip with no cue sheet still names its tracks.
    @Test func readsATrackListOffAudioFilenames() throws {
        let root = try makeRelease([
            "Release/Live.mkv": nil,
            "Release/OST/01. 歩拾道.flac": nil,
            "Release/OST/02. 明弦音.flac": nil,
            "Release/OST/03. 孤壊牢.flac": nil
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ConcertReleaseFileReader.read(folder: root)
        #expect(files.cueTracks.map(\.title) == ["歩拾道", "明弦音", "孤壊牢"])
    }

    /// What came in the box, and only what sits beside the video: the discs
    /// inside `CDs/` are part of `CDs`, not five more things.
    @Test func listsWhatElseIsInTheBox() throws {
        let root = try makeRelease([
            "Release/Live.mkv": nil,
            "Release/CDs/Bonus A/01.flac": nil,
            "Release/CDs/Bonus B/01.flac": nil,
            "Release/menu/menu.mkv": nil
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ConcertReleaseFileReader.read(folder: root)
        #expect(files.extras.map(\.name) == ["CDs", "menu"])
        #expect(files.extras.first?.itemCount == 2)
    }

    @Test func aFolderWithNothingInItSaysNothing() throws {
        let root = try makeRelease(["Release/Live.mkv": nil])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ConcertReleaseFileReader.read(folder: root).isEmpty)
    }
}
