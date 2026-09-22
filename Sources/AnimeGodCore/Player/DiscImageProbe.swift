import Foundation

/// What a `.iso` actually contains.
///
/// A disc image is not a container the demuxer can open: it is a filesystem
/// with a disc structure inside it. mpv plays a Blu-ray image through
/// libbluray (which reads UDF images directly, no mounting), so the player
/// has to know which kind it is holding before it loads anything.
public enum DiscImageKind: String, Sendable, Equatable {
    /// A Blu-ray: `BDMV/` with playlists and `.m2ts` streams.
    case blurayDisc
    /// A DVD-Video: `VIDEO_TS/` with `.vob` files.
    case dvdVideo
    /// A data image — no disc structure AnimeGod can play.
    case data
}

/// Recognises what a disc image holds by looking for the directory names
/// the disc standards mandate.
///
/// Both ISO 9660 and UDF store file identifiers as plain bytes, and the
/// descriptors that name the top-level directories sit near the front of the
/// image — so a bounded scan of the head decides it without parsing either
/// filesystem, and without reading 40 GB off a slow external drive.
public enum DiscImageProbe {
    /// How far into the image to look. Real Blu-ray and DVD images name
    /// their root directories well inside this.
    static let scanLimit = 64 * 1024 * 1024
    static let chunkSize = 4 * 1024 * 1024

    public static func isDiscImage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "iso"
    }

    /// Blocking: reads from disk. Call it off the main actor.
    ///
    /// Nil means the image could not be read at all — a drive that is gone,
    /// a path that no longer exists. That is not the same as an image with
    /// no video on it, and the caller has to be able to tell them apart.
    public static func inspect(url: URL) -> DiscImageKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let bluray = Array("BDMV".utf8)
        let dvd = Array("VIDEO_TS".utf8)
        // Identifiers can straddle a chunk boundary, so each read keeps the
        // tail of the previous one in front of it.
        let overlap = dvd.count - 1
        var carry: [UInt8] = []
        var read = 0
        while read < scanLimit {
            guard let data = try? handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            read += data.count
            let window = carry + data
            if contains(window, bluray) { return .blurayDisc }
            if contains(window, dvd) { return .dvdVideo }
            carry = Array(window.suffix(overlap))
        }
        return .data
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        let first = needle[0]
        for start in 0...(haystack.count - needle.count) where haystack[start] == first {
            var matched = true
            for offset in 1..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }
}
