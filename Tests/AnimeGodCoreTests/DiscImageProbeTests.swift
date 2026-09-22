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
