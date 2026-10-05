import Foundation
import Testing
@testable import AnimeGodCore

/// An unpacked Blu-ray is one disc.
///
/// Before this it was nothing at all, and the reason is worth keeping: macOS
/// reports a `BDMV` directory as a *package*, and the scan is created with
/// `.skipsPackageDescendants` so it does not wander into `.app` bundles — so
/// the enumerator stopped at the folder and never saw a single stream. An
/// original disc dropped into the library silently added no entry.
struct ConcertDiscScanTests {
    private let parser = AnimeFilenameParser()

    /// Lays a tree of empty files out in a temp directory and scans it. Real
    /// files rather than a stubbed file manager: the scanner reads
    /// `resourceValues` off every URL, and a made-up one cannot answer.
    private func scan(_ paths: [String]) async throws -> [ScannedMediaFile] {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        for path in paths {
            let fileURL = rootURL.appending(path: path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data([0x01]).write(to: fileURL)
        }
        let root = LibraryRoot(displayName: "Concerts", lastKnownPath: rootURL.path)
        return try await LibraryScanner(parser: parser).scan(root: root, resolvedURL: rootURL).files
    }

    /// The whole point: a structure the walk cannot even enter comes out as a
    /// single playable entry.
    @Test func aBluRayFolderIsOneDisc() async throws {
        var paths = ["結束バンドLIVE-恒星-/BDMV/index.bdmv", "結束バンドLIVE-恒星-/BDMV/MovieObject.bdmv"]
        paths += (1...30).map { "結束バンドLIVE-恒星-/BDMV/STREAM/\(String(format: "%05d", $0)).m2ts" }
        paths += ["結束バンドLIVE-恒星-/BDMV/PLAYLIST/00000.mpls",
                  "結束バンドLIVE-恒星-/CERTIFICATE/id.bdmv"]

        let files = try await scan(paths)
        #expect(files.count == 1)
        #expect(files.first?.relativePath == "結束バンドLIVE-恒星-/BDMV/index.bdmv")
        // The folder reader trims trailing punctuation, as it does for every
        // release folder; the disc's real title comes from the release once it
        // is matched.
        #expect(files.first?.parsed.title == "結束バンドLIVE-恒星")
        // One disc is one programme, so it carries no episode number.
        #expect(files.first?.parsed.episode == nil)
    }

    /// A box set puts each disc in its own folder, and each needs an identity
    /// of its own or three discs collapse into one entry holding three
    /// "versions" of the same thing.
    @Test func eachDiscOfABoxIsItsOwnEntry() async throws {
        let paths = (1...3).flatMap { disc in
            ["結束バンドLIVE-恒星-/DISC\(disc)/BDMV/index.bdmv",
             "結束バンドLIVE-恒星-/DISC\(disc)/BDMV/STREAM/00001.m2ts"]
        }
        let files = try await scan(paths)
        #expect(files.count == 3)
        #expect(files.map(\.parsed.episode) == [1, 2, 3])
        // They are all one work: the outermost folder names it.
        #expect(Set(files.map(\.parsed.title)).count == 1)
    }

    @Test func readsTheDiscNumberOutOfADecoratedFolderName() async throws {
        let paths = ["Kalafina Arena LIVE/Kalafina Arena LIVE Disc_2/BDMV/index.bdmv"]
        let files = try await scan(paths)
        #expect(files.first?.parsed.episode == 2)
    }

    /// A disc image is a single file and already worked; it must keep working
    /// beside a folder of the same work.
    @Test func anISOStaysOneEntryBesideAFolder() async throws {
        let paths = ["SENNEN_JYOYU/SENNEN_JYOYU.iso",
                     "結束バンドLIVE-恒星-/BDMV/index.bdmv"]
        let files = try await scan(paths)
        #expect(files.count == 2)
        #expect(files.contains { $0.relativePath.hasSuffix(".iso") })
    }

    /// An `index.bdmv` that is not inside a `BDMV` folder is not a disc, and a
    /// `BDMV` folder with no `index.bdmv` is not one either — an incomplete rip
    /// must contribute nothing rather than thirty streams.
    @Test func refusesHalfADisc() async throws {
        #expect(try await scan(["Work/index.bdmv"]).isEmpty)
        #expect(try await scan(["Work/BDMV/STREAM/00001.m2ts", "Work/BDMV/STREAM/00002.m2ts"]).isEmpty)
    }

    /// An ordinary anime release is not a disc folder and must be unaffected.
    @Test func leavesOrdinaryEpisodesAlone() async throws {
        let paths = ["[Group] Ave Mujica/[Group] Ave Mujica - 01 [1080p].mkv",
                     "[Group] Ave Mujica/[Group] Ave Mujica - 02 [1080p].mkv"]
        let files = try await scan(paths)
        #expect(files.count == 2)
        #expect(files.map(\.parsed.episode) == [1, 2])
    }

    @Test(arguments: [("DISC2", 2), ("Disc_3", 3), ("disc 1", 1), ("BD2", 2), ("ディスク3", 3)])
    func readsEveryWayADiscIsNumbered(_ pair: (String, Int)) {
        #expect(AnimeFilenameParser.discNumber(in: pair.0) == pair.1)
    }

    @Test(arguments: ["結束バンドLIVE-恒星-", "Kalafina Arena LIVE 2016", "BDMV"])
    func doesNotInventADiscNumber(_ name: String) {
        #expect(AnimeFilenameParser.discNumber(in: name) == nil)
    }
}

/// The two forms a Blu-ray reaches the player in.
struct ConcertDiscRootTests {
    /// What the library stores for an unpacked disc, and what libbluray wants
    /// instead: the folder holding `BDMV`, two levels up.
    @Test func findsTheDiscRootOfAnUnpackedBluRay() {
        let stored = URL(fileURLWithPath: "/Volumes/T7/結束バンドLIVE-恒星-/BDMV/index.bdmv")
        #expect(DiscImageProbe.discRoot(forStructureFile: stored)?.path
            == "/Volumes/T7/結束バンドLIVE-恒星-")
        #expect(DiscImageProbe.isDisc(stored))
    }

    @Test func isCaseInsensitiveTheWayTheFileSystemIs() {
        let upper = URL(fileURLWithPath: "/x/Live/bdmv/INDEX.BDMV")
        #expect(DiscImageProbe.discRoot(forStructureFile: upper)?.path == "/x/Live")
    }

    /// An `index.bdmv` that is not inside a `BDMV` folder is not a disc, and
    /// neither is anything else that happens to be in one.
    @Test(arguments: [
        "/x/Live/index.bdmv",
        "/x/Live/BDMV/MovieObject.bdmv",
        "/x/Live/BDMV/STREAM/00001.m2ts",
        "/x/Live/Live.mkv"
    ])
    func refusesWhatIsNotADiscRoot(_ path: String) {
        #expect(DiscImageProbe.discRoot(forStructureFile: URL(fileURLWithPath: path)) == nil)
    }

    /// A disc image is still a disc, and still not a folder.
    @Test func anImageIsADiscWithNoRootToWalkTo() {
        let iso = URL(fileURLWithPath: "/Volumes/T7/video/SENNEN_JYOYU/SENNEN_JYOYU.iso")
        #expect(DiscImageProbe.isDisc(iso))
        #expect(DiscImageProbe.discRoot(forStructureFile: iso) == nil)
    }
}
