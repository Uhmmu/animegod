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

    /// The disc root for the path the library stores for an *unpacked* Blu-ray.
    ///
    /// A folder-form Blu-ray is recorded as its `BDMV/index.bdmv`, because that
    /// file is mandatory on every disc and a directory is not a media file. What
    /// libbluray wants is the folder that *contains* `BDMV`, so playing one is a
    /// matter of walking two levels back up. Nil for anything else, including an
    /// `index.bdmv` that is not inside a `BDMV` folder.
    public static func discRoot(forStructureFile url: URL) -> URL? {
        guard url.lastPathComponent.caseInsensitiveCompare(
                AnimeFilenameParser.discStructureFileName) == .orderedSame else { return nil }
        let structure = url.deletingLastPathComponent()
        guard structure.lastPathComponent.caseInsensitiveCompare(
                AnimeFilenameParser.discStructureFolderName) == .orderedSame else { return nil }
        return structure.deletingLastPathComponent()
    }

    /// Whether this is a disc at all, in either form.
    public static func isDisc(_ url: URL) -> Bool {
        isDiscImage(url) || discRoot(forStructureFile: url) != nil
    }

    /// Blocking: reads from disk. Call it off the main actor.
    ///
    /// Nil means the image could not be read at all — a drive that is gone,
    /// a path that no longer exists. That is not the same as an image with
    /// no video on it, and the caller has to be able to tell them apart.
    public static func inspect(url: URL) -> DiscImageKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let bluray = spellings(of: "BDMV")
        let dvd = spellings(of: "VIDEO_TS")
        // Identifiers can straddle a chunk boundary, so each read keeps the
        // tail of the previous one in front of it — as much of it as the
        // longest spelling of the longest name.
        let overlap = (bluray + dvd).map(\.count).max().map { $0 - 1 } ?? 0
        var carry: [UInt8] = []
        var read = 0
        while read < scanLimit {
            guard let data = try? handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            read += data.count
            let window = carry + data
            if bluray.contains(where: { contains(window, $0) }) { return .blurayDisc }
            if dvd.contains(where: { contains(window, $0) }) { return .dvdVideo }
            carry = Array(window.suffix(overlap))
        }
        return .data
    }

    /// A directory name as both of the ways UDF is allowed to write it.
    ///
    /// **A UDF file identifier is OSTA compressed Unicode, and its first byte
    /// says which of two encodings follows: `8` for one byte a character, `16`
    /// for UTF-16BE.** Both are in this library, in two Blu-ray images of the
    /// same shape:
    ///
    /// | image | `BDMV` written as | at |
    /// |---|---|---|
    /// | `SENNEN_JYOYU.iso` | `42 44 4D 56` | `0xA18DB` |
    /// | `ROAD GAME『テクノプア』…iso` | `00 42 00 44 00 4D 00 56` | `0xA184F` |
    ///
    /// Looking only for the first spelling reported the second — 37 GB of
    /// perfectly good Blu-ray — as "no playable Blu-ray video on it". Neither
    /// image carries `CD001`, so there is no ISO 9660 side to fall back on:
    /// the identifier as the disc spells it is all there is to go on.
    static func spellings(of name: String) -> [[UInt8]] {
        [Array(name.utf8), Array(name.data(using: .utf16BigEndian) ?? Data())]
            .filter { !$0.isEmpty }
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
