import Foundation
import Testing
@testable import AnimeGodCore

struct DiscImageProbeTests {
    @Test func onlyIsoFilesAreDiscImages() {
        #expect(DiscImageProbe.isDiscImage(URL(fileURLWithPath: "/x/Movie.iso")))
        #expect(DiscImageProbe.isDiscImage(URL(fileURLWithPath: "/x/Movie.ISO")))
        #expect(!DiscImageProbe.isDiscImage(URL(fileURLWithPath: "/x/Movie.mkv")))
    }

    @Test func aDiscImageIsScannedForLibraryMedia() {
        #expect(AnimeFilenameParser().isSupportedMediaFile(URL(fileURLWithPath: "/x/SENNEN_JYOYU.iso")))
    }

    @Test func recognisesEachKindOfImageByItsDirectoryNames() throws {
        #expect(try kind(ofImageContaining: "BDMV") == .blurayDisc)
        #expect(try kind(ofImageContaining: "VIDEO_TS") == .dvdVideo)
        #expect(try kind(ofImageContaining: "readme.txt") == .data)
    }

    /// UDF writes a file identifier in one of two encodings and says which in
    /// its first byte. Both are in this library: `SENNEN_JYOYU.iso` spells
    /// `BDMV` in four bytes and the 37 GB `ROAD GAME…iso` spells it in eight,
    /// and the second was reported as an image with no Blu-ray video on it.
    /// Neither carries `CD001`, so there is no ISO 9660 spelling to fall back
    /// on.
    @Test func recognisesADiscThatNamesItsFoldersInUTF16() throws {
        let utf16 = try #require("BDMV".data(using: .utf16BigEndian))
        let url = try write(Data(repeating: 0, count: 2048) + utf16)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DiscImageProbe.inspect(url: url) == .blurayDisc)

        let dvd = try #require("VIDEO_TS".data(using: .utf16BigEndian))
        let dvdURL = try write(Data(repeating: 0, count: 2048) + dvd)
        defer { try? FileManager.default.removeItem(at: dvdURL) }
        #expect(DiscImageProbe.inspect(url: dvdURL) == .dvdVideo)
    }

    /// The longest spelling is sixteen bytes, so the tail carried between
    /// reads has to be fifteen — one short and a `VIDEO_TS` written in UTF-16
    /// across the boundary is missed.
    @Test func findsAUTF16MarkerThatStraddlesAReadBoundary() throws {
        let marker = try #require("VIDEO_TS".data(using: .utf16BigEndian))
        let head = Data(repeating: 0, count: DiscImageProbe.chunkSize - 8)
        let url = try write(head + marker)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DiscImageProbe.inspect(url: url) == .dvdVideo)
    }

    @Test func anUnreadableImageIsNotMistakenForOneWithoutVideo() {
        #expect(DiscImageProbe.inspect(url: URL(fileURLWithPath: "/nope/gone.iso")) == nil)
    }

    @Test func findsAMarkerThatStraddlesAReadBoundary() throws {
        // The identifier is split across two reads; the probe carries the
        // tail of each chunk forward so it is still found.
        let head = Data(repeating: 0, count: DiscImageProbe.chunkSize - 4)
        let url = try write(head + Data("VIDEO_TS".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DiscImageProbe.inspect(url: url) == .dvdVideo)
    }

    private func kind(ofImageContaining marker: String) throws -> DiscImageKind? {
        let url = try write(Data(repeating: 0, count: 2048) + Data(marker.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        return DiscImageProbe.inspect(url: url)
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).iso")
        try data.write(to: url)
        return url
    }
}
