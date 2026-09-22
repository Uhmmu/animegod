import Foundation
import Testing
@testable import AnimeGodCore

struct ArchiveExtractorTests {
    @Test func recognisesOnlyTheFirstVolumeOfASet() {
        #expect(ArchiveExtractor.isPrimaryArchive("Show [BDRip].rar"))
        #expect(ArchiveExtractor.isPrimaryArchive("Show [BDRip].part1.rar"))
        #expect(ArchiveExtractor.isPrimaryArchive("Show [BDRip].part01.rar"))
        #expect(ArchiveExtractor.isPrimaryArchive("Show.7z.001"))
        #expect(ArchiveExtractor.isPrimaryArchive("Show.zip"))
        #expect(ArchiveExtractor.isPrimaryArchive("Show.tar.gz"))

        #expect(!ArchiveExtractor.isPrimaryArchive("Show [BDRip].part2.rar"))
        #expect(!ArchiveExtractor.isPrimaryArchive("Show [BDRip].part10.rar"))
        #expect(!ArchiveExtractor.isPrimaryArchive("Show.r00"))
        #expect(!ArchiveExtractor.isPrimaryArchive("Show.z01"))
        #expect(!ArchiveExtractor.isPrimaryArchive("Show.7z.002"))
        #expect(!ArchiveExtractor.isPrimaryArchive("Show - 01.mkv"))
        #expect(!ArchiveExtractor.isPrimaryArchive("Show"))
    }

    @Test func continuationVolumesKnowTheirPlaceInTheSet() {
        #expect(ArchiveExtractor.isContinuationVolume("Show.part3.rar"))
        #expect(ArchiveExtractor.isContinuationVolume("Show.r00"))
        #expect(!ArchiveExtractor.isContinuationVolume("Show.rar"))
        #expect(!ArchiveExtractor.isContinuationVolume("Show - 01.mkv"))
    }

    @Test func namesTheDestinationAfterTheReleaseNotTheVolume() {
        #expect(ArchiveExtractor.destinationName(for: "Show [BDRip].part1.rar") == "Show [BDRip]")
        #expect(ArchiveExtractor.destinationName(for: "Show [BDRip].rar") == "Show [BDRip]")
        #expect(ArchiveExtractor.destinationName(for: "Show.7z.001") == "Show")
        #expect(ArchiveExtractor.destinationName(for: "Show.tar.gz") == "Show")
        #expect(ArchiveExtractor.destinationName(for: "Show.r00") == "Show")
    }

    @Test func entryPathsCannotClimbOutOfTheDestination() {
        #expect(ArchiveExtractor.safeRelativePath("a/b.mkv") == "a/b.mkv")
        #expect(ArchiveExtractor.safeRelativePath("/etc/passwd") == "etc/passwd")
        #expect(ArchiveExtractor.safeRelativePath("../../escape.mkv") == "escape.mkv")
        #expect(ArchiveExtractor.safeRelativePath("a/../../b.mkv") == "a/b.mkv")
        #expect(ArchiveExtractor.safeRelativePath("..") == nil)
        #expect(ArchiveExtractor.safeRelativePath("") == nil)
    }

    @Test func unpacksAZipIntoAFolderNamedAfterItAndLeavesTheArchiveAlone() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let payload = Data("episode bytes".utf8)
        let archive = try makeZip(named: "Show [BDRip]", entries: ["01.mkv": payload], in: folder)

        let outcome = ArchiveExtractor.extractAll(in: folder)

        #expect(outcome.failures.isEmpty)
        #expect(outcome.extracted.count == 1)
        let extracted = folder.appending(path: "Show [BDRip]/01.mkv")
        #expect(try Data(contentsOf: extracted) == payload)
        // Non-destructive, like scanning: the archive itself is untouched.
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    @Test func doesNothingOnASecondPassOverTheSameDownload() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try makeZip(named: "Show", entries: ["01.mkv": Data("a".utf8)], in: folder)

        #expect(ArchiveExtractor.extractAll(in: folder).extracted.count == 1)
        #expect(ArchiveExtractor.extractAll(in: folder).isEmpty)
    }

    @Test func reportsAnUnreadableArchiveWithoutLeavingAFolderBehind() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not an archive at all".utf8).write(to: folder.appending(path: "Broken.zip"))

        let outcome = ArchiveExtractor.extractAll(in: folder)

        #expect(outcome.extracted.isEmpty)
        #expect(outcome.failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Broken").path))
    }

    // MARK: - Helpers

    private func makeTemporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a real zip with the system tool, so the extractor is tested
    /// against a file some other program wrote rather than one of its own.
    private func makeZip(named name: String, entries: [String: Data], in folder: URL) throws -> URL {
        let staging = folder.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (path, data) in entries { try data.write(to: staging.appending(path: path)) }
        let archive = folder.appending(path: "\(name).zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", archive.path, "."]
        zip.currentDirectoryURL = staging
        try zip.run()
        zip.waitUntilExit()
        try FileManager.default.removeItem(at: staging)
        return archive
    }
}
