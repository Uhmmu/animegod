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

    /// The scans are **not** catalogue numbers, and this is not hypothetical:
    /// this exact folder shape matched MyGO's 7th LIVE and its Extra Studio
    /// Live to a compilation called *Walking Without Rhythm*, which Discogs
    /// files under `IMG015`, and Ave Mujica's 0th LIVE to *Retro Destiny*,
    /// filed under `ANIME-01`. A label does not name a file.
    @Test func doesNotReadAScanFilenameAsACatalogueNumber() throws {
        var paths: [String: Data?] = [
            "MyGO 7th LIVE.mkv": nil,
            "OST/BRMM-10876.cue": cueSheet,
        ]
        // `updateValue`, not `paths[key] = nil`: assigning nil through the
        // subscript of a dictionary of optionals *removes* the key, so the
        // first version of this test created no scans at all and proved
        // nothing.
        for index in 1...13 {
            paths.updateValue(nil, forKey: "Scans/IMG-\(String(format: "%02d", index)).png")
        }
        for index in 1...5 { paths.updateValue(nil, forKey: "BK/ANIME-0\(index).jpg") }
        let root = try makeRelease(paths)
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ConcertReleaseFileReader.read(folder: root)
        // The one real number survives; twenty-three scans contribute none.
        #expect(files.catalogNumbers.map(\.description) == ["BRMM-10876"])
        // And they are still the artwork — only the number-reading changed.
        #expect(files.coverImageURLs.count == 18)
    }

    /// A sequence number on a file that is not an image is still a sequence
    /// number. Four digits is what a real one has.
    @Test func wantsARealNumberOnAFileInsideTheRelease() throws {
        let root = try makeRelease([
            "Live.mkv": nil,
            "Disc 2/VOL-03.log": nil,
            "LABX-8333.log": nil,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ConcertReleaseFileReader.read(folder: root)
        #expect(files.catalogNumbers.map(\.description) == ["LABX-8333"])
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

    /// The release with no cue sheet, no catalogue number in any name, and a
    /// saved shop page sitting beside the disc.
    ///
    /// The real one: `ずっと真夜中でいいのに。 - 沈香学 [2023.06.07]`, one `.iso` and
    /// a `.txt`. The EAN in that text is the only exact key in the whole
    /// folder, and both Discogs and MusicBrainz answer it with one release —
    /// whose third disc is the live Blu-ray the `.iso` holds. Without it the
    /// work stays an anime named after the album.
    @Test func readsABarcodeOutOfTheInfoTextWhenThereIsNoCueSheet() throws {
        // Amazon's own listing, bidirectional marks and all.
        let listing = """
        登録情報\r
        メーカー ‏ : ‎ Universal Music\r
        EAN ‏ : ‎ 4988031567562\r
        ASIN ‏ : ‎ B0BY1Y13WC\r
        ディスク枚数 ‏ : ‎ 3\r
        """
        let root = try makeRelease([
            "Release/20230115 ROAD GAME.iso": nil,
            "Release/Release.txt": listing.data(using: .utf8)
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ConcertReleaseFileReader.read(folder: root)
        #expect(files.barcode == "4988031567562")
    }

    /// The keyword is what makes it a barcode. A thirteen-digit run on its own
    /// is as likely to be an ASIN or a date, and an exact key that is exactly
    /// wrong answers with somebody else's record.
    @Test func doesNotTakeAnyLongNumberForABarcode() {
        #expect(ReleaseInfoText.barcode(in: "ディスク枚数 : 3\n4988031567562") == nil)
        #expect(ReleaseInfoText.barcode(in: "JAN: 4988031567562") == "4988031567562")
        #expect(ReleaseInfoText.barcode(in: "UPC 012345678905") == "012345678905")
    }

    /// A cue sheet's own `CATALOG` line is the better source and stays the one
    /// that is used.
    @Test func theCueSheetsBarcodeWins() throws {
        let root = try makeRelease([
            "Release/Live.mkv": nil,
            "Release/OST/BRMM-10876.cue": cueSheet,
            "Release/Release.txt": "EAN : 4988031567562".data(using: .utf8)
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ConcertReleaseFileReader.read(folder: root).barcode == "4562494358488")
    }

    @Test func aFolderWithNothingInItSaysNothing() throws {
        let root = try makeRelease(["Release/Live.mkv": nil])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ConcertReleaseFileReader.read(folder: root).isEmpty)
    }
}
