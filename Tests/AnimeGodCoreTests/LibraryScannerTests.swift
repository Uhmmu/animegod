import Foundation
import Testing
@testable import AnimeGodCore

struct LibraryScannerTests {
    @Test func recursivelyFindsOnlySupportedMediaWithoutChangingFiles() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let showURL = rootURL.appending(path: "Example Show", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: showURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let episodeURL = showURL.appending(path: "01.mkv")
        let ignoredURL = showURL.appending(path: "notes.txt")
        try Data([0x01]).write(to: episodeURL)
        try Data("do not touch".utf8).write(to: ignoredURL)
        let original = try Data(contentsOf: episodeURL)

        let root = LibraryRoot(displayName: "Test", lastKnownPath: rootURL.path)
        let result = try await LibraryScanner().scan(root: root, resolvedURL: rootURL)

        #expect(result.files.count == 1)
        #expect(result.files[0].relativePath == "Example Show/01.mkv")
        #expect(result.files[0].parsed.title == "Example Show")
        #expect(try Data(contentsOf: episodeURL) == original)
        #expect(FileManager.default.fileExists(atPath: ignoredURL.path))
    }

    @Test func groupsExtrasByTopLevelReleaseFolder() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let releaseURL = rootURL.appending(path: "[Nekomoe kissaten][Penguin Highway]", directoryHint: .isDirectory)
        let extrasURL = releaseURL.appending(path: "SPs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extrasURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x01]).write(to: releaseURL.appending(path: "Penguin Highway.mkv"))
        try Data([0x02]).write(to: extrasURL.appending(path: "Penguin Highway SP01.mkv"))

        let root = LibraryRoot(displayName: "Test", lastKnownPath: rootURL.path)
        let result = try await LibraryScanner().scan(root: root, resolvedURL: rootURL)

        #expect(result.files.count == 2)
        #expect(Set(result.files.map(\.parsed.title)) == ["Penguin Highway"])
    }

    @Test func splitsPartMarkedWorksSharingOneFolder() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        // Real-world layout from a T7 release: one folder, two compilation films.
        let releaseURL = rootURL.appending(
            path: "[DBD-Raws][剧场版 BanG Dream! It's MyGO!!!!!][前篇+后篇][1080P][BDRip][HEVC-10bit][简繁内封][FLAC][MKV]",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: releaseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x01]).write(to: releaseURL.appending(
            path: "[DBD-Raws][MyGO!!!!! The Movie - Part 1 Spring Sunshine, Lost Cat][1080P][BDRip][HEVC-10bit][FLAC].mkv"
        ))
        try Data([0x02]).write(to: releaseURL.appending(
            path: "[DBD-Raws][MyGO!!!!! The Movie - Part 2 Sing, Songs That Become Us & Film Live][1080P][BDRip][HEVC-10bit][FLAC].mkv"
        ))

        let root = LibraryRoot(displayName: "Test", lastKnownPath: rootURL.path)
        let result = try await LibraryScanner().scan(root: root, resolvedURL: rootURL)

        #expect(result.files.count == 2)
        #expect(Set(result.files.map(\.parsed.title)) == [
            "MyGO!!!!! The Movie - Part 1 Spring Sunshine, Lost Cat",
            "MyGO!!!!! The Movie - Part 2 Sing, Songs That Become Us & Film Live"
        ])
    }

    @Test func splitsChinesePartMarkedWorksSharingOneFolder() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let releaseURL = rootURL.appending(path: "Gekijouban Hibike Euphonium", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: releaseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x01]).write(to: releaseURL.appending(path: "Gekijouban Hibike Euphonium 前篇.mkv"))
        try Data([0x02]).write(to: releaseURL.appending(path: "Gekijouban Hibike Euphonium 後篇.mkv"))

        let root = LibraryRoot(displayName: "Test", lastKnownPath: rootURL.path)
        let result = try await LibraryScanner().scan(root: root, resolvedURL: rootURL)

        #expect(result.files.count == 2)
        #expect(Set(result.files.map(\.parsed.title)) == [
            "Gekijouban Hibike Euphonium 前篇",
            "Gekijouban Hibike Euphonium 後篇"
        ])
    }

    @Test func splitsTwoDistinctMoviesSharingOneFolder() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let collectionURL = rootURL.appending(path: "Makoto Shinkai Collection", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: collectionURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x01]).write(to: collectionURL.appending(path: "Kimi no Na wa.mkv"))
        try Data([0x02]).write(to: collectionURL.appending(path: "Tenki no Ko.mkv"))

        let root = LibraryRoot(displayName: "Test", lastKnownPath: rootURL.path)
        let result = try await LibraryScanner().scan(root: root, resolvedURL: rootURL)

        #expect(Set(result.files.map(\.parsed.title)) == ["Kimi no Na wa", "Tenki no Ko"])
    }

    @Test func discMenuJunkStaysOutOfTheLibrary() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let releaseURL = rootURL.appending(path: "[DBD-Raws] Summer Wars", directoryHint: .isDirectory)
        let menuURL = releaseURL.appending(path: "menu", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: menuURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x01]).write(to: releaseURL.appending(path: "Summer Wars.mkv"))
        try Data([0x02]).write(to: menuURL.appending(path: "Summer Wars menu.mkv"))

        let root = LibraryRoot(displayName: "Test", lastKnownPath: rootURL.path)
        let result = try await LibraryScanner().scan(root: root, resolvedURL: rootURL)

        // Only the movie itself becomes library content.
        #expect(result.files.count == 1)
        #expect(result.files[0].parsed.title == "Summer Wars")
    }

    @Test func specialsNeverSplitIntoTheirOwnWorks() async throws {
        // Real-world layout: one movie plus a pile of numbered SPs.
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let releaseURL = rootURL.appending(path: "[Nekomoe kissaten][Penguin Highway]", directoryHint: .isDirectory)
        let spURL = releaseURL.appending(path: "SPs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: spURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x01]).write(to: releaseURL.appending(
            path: "[Nekomoe kissaten][Penguin Highway][Movie][Ma10p_1080p][x265_flac].mkv"
        ))
        try Data([0x02]).write(to: spURL.appending(
            path: "[Nekomoe kissaten][Penguin Highway][SP01][Special Trailer 01][Ma10p_1080p][x265_flac].mkv"
        ))
        try Data([0x03]).write(to: spURL.appending(
            path: "[Nekomoe kissaten][Penguin Highway][SP04][Tokuhou][Ma10p_1080p][x265_flac].mkv"
        ))
        try Data([0x04]).write(to: spURL.appending(
            path: "[Nekomoe kissaten][Penguin Highway][SP10][Honpen mi shiyo eizoshu 02][Ma10p_1080p][x265_flac].mkv"
        ))

        let root = LibraryRoot(displayName: "Test", lastKnownPath: rootURL.path)
        let result = try await LibraryScanner().scan(root: root, resolvedURL: rootURL)

        // One work only: the movie plus its specials, nothing scattered.
        #expect(Set(result.files.map(\.parsed.title)) == ["Penguin Highway"])
        #expect(result.files.filter { $0.parsed.episodeKind == .regular }.count == 1)
        let specials = result.files.filter { $0.parsed.episodeKind != .regular }
        #expect(specials.count == 3)
        // Special release numbers survive for the grouped episode list.
        #expect(specials.compactMap(\.parsed.episodeText).sorted() == ["01", "04", "10"])
    }

    @Test func numberedPVsStayWithTheirRelease() async throws {
        // Real-world layout: bare PV1/SP1 files beside the movie, no SPs folder.
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let releaseURL = rootURL.appending(
            path: "[J.X&MGRT]Sakasama no Patema[GB][BDrip][1080P_Hi10_FLAC](Scans&OST&Special)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: releaseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x01]).write(to: releaseURL.appending(path: "[J.X&MGRT]Sakasama no Patema.1080p.10bit.mkv"))
        for (index, name) in ["PV1.mkv", "PV2.mkv", "PV3.mkv", "SP1.mkv", "SP2.mkv", "menu.mkv"].enumerated() {
            try Data([UInt8(index + 2)]).write(to: releaseURL.appending(path: name))
        }

        let root = LibraryRoot(displayName: "Test", lastKnownPath: rootURL.path)
        let result = try await LibraryScanner().scan(root: root, resolvedURL: rootURL)

        #expect(result.files.count == 7)
        #expect(Set(result.files.map(\.parsed.title)).count == 1)
        #expect(result.files.filter { $0.parsed.episodeKind == .regular }.count == 1)
        #expect(result.files.filter { $0.parsed.episodeKind == .trailer }.count == 3)
    }

    @Test func excludesAVCatalogueReleases() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let avURL = rootURL.appending(path: "SONE-615", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: avURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x01]).write(to: avURL.appending(path: "SONE-615.mp4"))
        try Data([0x02]).write(to: rootURL.appending(path: "IPX-177.mp4"))
        try Data([0x03]).write(to: rootURL.appending(path: "Penguin Highway.mkv"))

        let root = LibraryRoot(displayName: "Test", lastKnownPath: rootURL.path)
        let result = try await LibraryScanner().scan(root: root, resolvedURL: rootURL)

        #expect(result.files.map(\.parsed.title) == ["Penguin Highway"])
    }

    @Test func mergesSameMovieVersionsAndCategorizesBonusFolders() async throws {
        // Real-world layout: a release subfolder holding two encodes of the
        // movie (DoVi + SDR) plus a bonus SPs folder.
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let releaseURL = rootURL.appending(
            path: "[VCB-Studio] Gekijouban Violet Evergarden/[VCB-Studio] Gekijouban Violet Evergarden [Ma10p_2160p]",
            directoryHint: .isDirectory
        )
        let spsURL = releaseURL.appending(path: "SPs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: spsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x01]).write(to: releaseURL.appending(
            path: "[VCB-Studio] Gekijouban Violet Evergarden [Ma10p_2160p_DoVi_P8.1][x265_flac].mkv"
        ))
        try Data([0x02]).write(to: releaseURL.appending(
            path: "[VCB-Studio] Gekijouban Violet Evergarden [Ma10p_2160p_SDR][x265_flac].mkv"
        ))
        try Data([0x03]).write(to: spsURL.appending(
            path: "[VCB-Studio] Gekijouban Violet Evergarden [Menu01][Ma10p_2160p_DoVi_P8.1][x265_flac].mkv"
        ))
        try Data([0x04]).write(to: spsURL.appending(
            path: "[VCB-Studio] Gekijouban Violet Evergarden [Tokuhou Eizou][Ma10p_2160p][x265_flac].mkv"
        ))

        let root = LibraryRoot(displayName: "Test", lastKnownPath: rootURL.path)
        let result = try await LibraryScanner().scan(root: root, resolvedURL: rootURL)

        // One work; the two movie encodes stay regular, SPs content never does.
        #expect(Set(result.files.map(\.parsed.title)) == ["Gekijouban Violet Evergarden"])
        #expect(result.files.filter { $0.parsed.episodeKind == .regular }.count == 2)
        #expect(result.files.filter { $0.parsed.episodeKind != .regular }.count == 2)
    }

    @Test func detectsReleasePartMarkers() {
        #expect(AnimeFilenameParser.partLabel(in: "Show 前篇") != nil)
        #expect(AnimeFilenameParser.partLabel(in: "Show 後篇") != nil)
        #expect(AnimeFilenameParser.partLabel(in: "Show 下巻") != nil)
        #expect(AnimeFilenameParser.partLabel(in: "Show Part 2") != nil)
        #expect(AnimeFilenameParser.partLabel(in: "Plain Movie Title") == nil)
        #expect(AnimeFilenameParser.partLabel(in: "Kimi no Na wa") == nil)
    }
}
