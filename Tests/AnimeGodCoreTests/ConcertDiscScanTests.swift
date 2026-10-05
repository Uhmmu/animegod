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

    // MARK: - Two nights are one work

    /// A two-night tour shipped as two subfolders of one work.
    @Test func twoNightsInOneFolderAreOneWork() async throws {
        let paths = (1...2).flatMap { day in
            ["Aqours 6th LoveLive/Day\(day)/BDMV/index.bdmv",
             "Aqours 6th LoveLive/Day\(day)/BDMV/STREAM/00001.m2ts"]
        }
        let files = try await scan(paths)
        #expect(files.count == 2)
        #expect(Set(files.map(\.parsed.title)).count == 1)
        #expect(files.map(\.parsed.episode) == [1, 2])
    }

    /// The harder shape, and the one a download actually arrives in: two
    /// folders side by side, each carrying its own night *and its own
    /// subtitle*. Dropping just `DAY1` would leave `:Returns` against
    /// `:Sing a Song`, which is two works again — the name has to be cut at
    /// the label.
    @Test func twoNightsInTwoFoldersAreOneWork() async throws {
        let paths = [
            "BanG Dream! 10th☆LIVE DAY1:Returns/BDMV/index.bdmv",
            "BanG Dream! 10th☆LIVE DAY2:Sing a Song/BDMV/index.bdmv"
        ]
        let files = try await scan(paths)
        #expect(files.count == 2)
        #expect(Set(files.map(\.parsed.title)) == ["BanG Dream! 10th☆LIVE"])
        #expect(files.map(\.parsed.episode).sorted { ($0 ?? 0) < ($1 ?? 0) } == [1, 2])
    }

    /// And the same thing with the day written the Japanese way.
    @Test func readsAJapaneseDayMarker() async throws {
        let paths = [
            "ヨルシカ LIVE TOUR 1日目/BDMV/index.bdmv",
            "ヨルシカ LIVE TOUR 2日目/BDMV/index.bdmv"
        ]
        let files = try await scan(paths)
        #expect(Set(files.map(\.parsed.title)) == ["ヨルシカ LIVE TOUR"])
        #expect(files.map(\.parsed.episode).sorted { ($0 ?? 0) < ($1 ?? 0) } == [1, 2])
    }

    /// A disc image is a disc too, so two nights shipped as two `.iso` files
    /// group the same way an unpacked pair does.
    @Test func twoNightsAsDiscImagesAreOneWork() async throws {
        let paths = [
            "Roselia Rausch Day1/Roselia Rausch Day1.iso",
            "Roselia Rausch Day2/Roselia Rausch Day2.iso"
        ]
        let files = try await scan(paths)
        #expect(files.count == 2)
        #expect(Set(files.map(\.parsed.title)) == ["Roselia Rausch"])
        #expect(files.map(\.parsed.episode).sorted { ($0 ?? 0) < ($1 ?? 0) } == [1, 2])
    }

    /// And an ordinary film on an image is untouched.
    @Test func anOrdinaryDiscImageKeepsItsName() async throws {
        let files = try await scan(["SENNEN_JYOYU/SENNEN_JYOYU.iso"])
        #expect(files.first?.parsed.title == "SENNEN_JYOYU")
        #expect(files.first?.parsed.episode == nil)
    }

    /// A work whose name really is a day keeps it, because cutting there would
    /// leave nothing.
    @Test func doesNotCutANameDownToNothing() {
        #expect(AnimeFilenameParser.withoutDiscLabel("Day 1") == "Day 1")
        #expect(AnimeFilenameParser.withoutDiscLabel("Day Break Illusion") == "Day Break Illusion")
    }

    @Test(arguments: [
        ("BanG Dream! 10th☆LIVE DAY1:Returns", "BanG Dream! 10th☆LIVE"),
        ("Aqours 6th LoveLive ～KU-RU-KU-RU Rock 'n' Roll～ Day2", "Aqours 6th LoveLive ～KU-RU-KU-RU Rock 'n' Roll～"),
        ("ヨルシカ LIVE TOUR 2日目", "ヨルシカ LIVE TOUR"),
        ("Kalafina Arena LIVE Disc_2", "Kalafina Arena LIVE"),
        ("結束バンドLIVE-恒星-", "結束バンドLIVE-恒星-")
    ])
    func cutsTheNameDownToTheWork(_ pair: (String, String)) {
        #expect(AnimeFilenameParser.withoutDiscLabel(pair.0) == pair.1)
    }

    @Test(arguments: [("DISC2", 2), ("Disc_3", 3), ("disc 1", 1), ("BD2", 2), ("ディスク3", 3),
                      ("Day1", 1), ("DAY.2", 2), ("Day 3", 3), ("2日目", 2), ("第1日", 1)])
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

/// The shape a two-night live actually arrives in, taken from a real download:
/// one release folder, two MKVs, the night in the *filename*. Both files were
/// becoming separate works, and neither carried an episode number — so merging
/// the works alone would have collapsed two nights into one entry holding two
/// "versions" of the same thing.
struct ConcertRemuxDayTests {
    private let parser = AnimeFilenameParser()

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
        let root = LibraryRoot(displayName: "Video", lastKnownPath: rootURL.path)
        return try await LibraryScanner(parser: parser).scan(root: root, resolvedURL: rootURL).files
    }

    @Test func twoNightsInOneReleaseFolderAreOneWork() async throws {
        let work = "MyGO!!!!! 6th LIVE「見つけた景色、たずさえて」"
        let release = "[DBD-Raws][\(work)][1080P][BDRip][HEVC-10bit][FLAC][MKV]"
        let files = try await scan([
            "\(work)/\(release)/[DBD-Raws][\(work)][DAY1][1080P][BDRip][HEVC-10bit][FLAC].mkv",
            "\(work)/\(release)/[DBD-Raws][\(work)][DAY2][1080P][BDRip][HEVC-10bit][FLAC].mkv"
        ])

        #expect(files.count == 2)
        #expect(Set(files.map(\.parsed.title)).count == 1, "one work, not two")
        // And two entries inside it rather than two versions of one.
        #expect(files.map(\.parsed.episode).sorted { ($0 ?? 0) < ($1 ?? 0) } == [1, 2])
    }

    /// An ordinary episode that mentions a disc already has a number of its
    /// own, and that number is the one that means something.
    @Test func doesNotRenumberAnOrdinaryEpisode() async throws {
        let files = try await scan([
            "[Sakurato] Ave Mujica [Disc 1]/[Sakurato] Ave Mujica [01][1080p].mkv",
            "[Sakurato] Ave Mujica [Disc 1]/[Sakurato] Ave Mujica [02][1080p].mkv"
        ])
        #expect(files.map(\.parsed.episode) == [1, 2])
        #expect(Set(files.map(\.parsed.title)).count == 1)
    }
}
