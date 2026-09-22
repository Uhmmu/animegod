import CLibArchive
import Foundation

/// Unpacking downloaded archives.
///
/// Release groups still ship batches as `.rar`/`.zip`/`.7z` sets, so a
/// finished download can be a folder of archives with no video in it. This
/// unpacks them where they landed, so the library scan that follows sees
/// real episodes.
///
/// Extraction is **non-destructive**, like scanning: the archive is left
/// exactly where it was, and nothing outside the destination folder is
/// touched. Failures are reported, never fatal — a download that cannot be
/// unpacked is still a finished download.
public enum ArchiveExtractor {
    /// Extensions worth opening. `.rar` covers the whole multi-volume set:
    /// libarchive follows the continuation volumes by itself once it is
    /// given the first one.
    public static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "cbz", "cbr"
    ]

    public struct Outcome: Sendable, Equatable {
        /// The archives that were unpacked, in the order they were found.
        public var extracted: [URL]
        /// Archives that failed, with the reason, so the UI can say which.
        public var failures: [String]

        public init(extracted: [URL] = [], failures: [String] = []) {
            self.extracted = extracted
            self.failures = failures
        }

        public var isEmpty: Bool { extracted.isEmpty && failures.isEmpty }
    }

    public enum ExtractionError: LocalizedError, Sendable {
        case failed(archive: String, detail: String)

        public var errorDescription: String? {
            switch self {
            case let .failed(archive, detail):
                String(localized: "Could not unpack “\(archive)”: \(detail)", bundle: .module)
            }
        }
    }

    // MARK: - Recognising archives

    /// Whether this name is an archive AnimeGod should try to open.
    ///
    /// Only the *first* volume of a multi-volume set qualifies: handing
    /// libarchive `part2.rar` on its own produces a broken half-file, and it
    /// picks the continuation volumes up from `part1.rar` anyway.
    public static func isPrimaryArchive(_ name: String) -> Bool {
        guard let parts = split(name) else { return false }
        return parts.volume == nil || parts.volume == 1
    }

    /// A volume that only makes sense as part of a set already named by its
    /// first volume: `…part2.rar`, `….r00`, `….z01`, `….7z.002`.
    public static func isContinuationVolume(_ name: String) -> Bool {
        guard let parts = split(name) else { return false }
        return (parts.volume ?? 1) != 1
    }

    /// An archive name taken apart: what to call the unpacked folder, which
    /// format it is, and which volume of the set this file is.
    struct NameParts: Equatable {
        var stem: String
        var format: String
        /// nil when the name carries no volume number at all.
        var volume: Int?
    }

    /// Splits an archive name, or returns nil when it is not an archive.
    static func split(_ name: String) -> NameParts? {
        var stem = name
        var volume: Int?

        // `.7z.001` / `.zip.002`: a numeric suffix under the format.
        let last = (stem as NSString).pathExtension.lowercased()
        if !last.isEmpty, last.allSatisfy(\.isNumber), let number = Int(last) {
            let under = (stem as NSString).deletingPathExtension
            guard archiveExtensions.contains((under as NSString).pathExtension.lowercased()) else { return nil }
            stem = under
            volume = number
        }

        let format = (stem as NSString).pathExtension.lowercased()
        switch format {
        case _ where archiveExtensions.contains(format):
            stem = (stem as NSString).deletingPathExtension
        case _ where format.range(of: #"^r\d{2,3}$"#, options: .regularExpression) != nil:
            // RAR 2 naming: the set is `.rar` plus `.r00`, `.r01`, … — the
            // `.rar` is volume 1, so `.r00` is volume 2.
            return NameParts(stem: (stem as NSString).deletingPathExtension, format: "rar", volume: (Int(format.dropFirst()) ?? 0) + 2)
        case _ where format.range(of: #"^z\d{2,3}$"#, options: .regularExpression) != nil:
            // Split zip: `.zip` plus `.z01`, `.z02`, …
            return NameParts(stem: (stem as NSString).deletingPathExtension, format: "zip", volume: (Int(format.dropFirst()) ?? 0) + 1)
        default:
            return nil
        }

        // `.tar` under a compression suffix is part of the format, not the name.
        if (stem as NSString).pathExtension.lowercased() == "tar" {
            stem = (stem as NSString).deletingPathExtension
        }
        // RAR 3+ naming: `…part1.rar`, `…part2.rar`, …
        if let range = stem.range(of: #"(?i)\.part0*(\d+)$"#, options: .regularExpression) {
            let digits = stem[range].drop { !$0.isNumber }
            volume = Int(digits) ?? volume
            stem.removeSubrange(range)
        }
        return NameParts(stem: stem.isEmpty ? name : stem, format: format, volume: volume)
    }

    /// The folder an archive should unpack into: a sibling named after the
    /// archive, with the volume and compression suffixes stripped, so
    /// `Show [BDRip].part1.rar` becomes `Show [BDRip]/`.
    public static func destinationName(for archiveName: String) -> String {
        split(archiveName)?.stem ?? archiveName
    }

    // MARK: - Finding

    /// Every primary archive under `folder`, deepest-last, skipping anything
    /// inside a folder this extractor already produced.
    public static func archives(in folder: URL) -> [URL] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            guard isPrimaryArchive(url.lastPathComponent) else { continue }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: - Extracting

    /// Unpacks every archive under `folder`. Already-unpacked archives are
    /// skipped, so a second pass over the same download does nothing.
    ///
    /// Blocking: call it off the main actor.
    public static func extractAll(in folder: URL) -> Outcome {
        var outcome = Outcome()
        for archive in archives(in: folder) {
            do {
                if let destination = try extract(archive) {
                    outcome.extracted.append(destination)
                }
            } catch {
                outcome.failures.append(error.localizedDescription)
            }
        }
        return outcome
    }

    /// Unpacks one archive into a sibling folder named after it. Returns the
    /// destination, or nil when it had already been unpacked.
    @discardableResult
    public static func extract(_ archive: URL) throws -> URL? {
        let manager = FileManager.default
        let destination = archive.deletingLastPathComponent()
            .appending(path: destinationName(for: archive.lastPathComponent))
        // A non-empty destination means this archive was unpacked before — a
        // resumed or re-checked download must not redo the work.
        if let existing = try? manager.contentsOfDirectory(atPath: destination.path), !existing.isEmpty {
            return nil
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try unpack(archive, into: destination)
        } catch {
            // Leave no empty folder behind when nothing came out of it.
            if let contents = try? manager.contentsOfDirectory(atPath: destination.path), contents.isEmpty {
                try? manager.removeItem(at: destination)
            }
            throw error
        }
        return destination
    }

    /// Reads every entry and writes it under `destination`.
    ///
    /// Entry names come from the archive, which means they come from a
    /// stranger: an absolute path or one climbing out with `..` would write
    /// anywhere on disk. Each name is checked here *and* libarchive's own
    /// secure-extract flags are set, so neither alone has to be right.
    private static func unpack(_ archive: URL, into destination: URL) throws {
        guard let reader = archive_read_new() else {
            throw ExtractionError.failed(archive: archive.lastPathComponent, detail: outOfMemory)
        }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        guard let writer = archive_write_disk_new() else {
            archive_read_free(reader)
            throw ExtractionError.failed(archive: archive.lastPathComponent, detail: outOfMemory)
        }
        // Not `SECURE_NOABSOLUTEPATHS`: every entry is rewritten to an
        // absolute path under the destination below, which is how the
        // destination is chosen without `chdir`ing the whole process.
        // `safeRelativePath` is what rejects the archive's own absolute and
        // climbing names, before they are joined to the destination.
        archive_write_disk_set_options(
            writer,
            AG_ARCHIVE_EXTRACT_TIME
                | AG_ARCHIVE_EXTRACT_SECURE_SYMLINKS
                | AG_ARCHIVE_EXTRACT_SECURE_NODOTDOT
        )
        archive_write_disk_set_standard_lookup(writer)
        defer {
            archive_read_close(reader)
            archive_read_free(reader)
            archive_write_close(writer)
            archive_write_free(writer)
        }

        guard archive_read_open_filename(reader, archive.path, 1 << 20) == AG_ARCHIVE_OK else {
            throw ExtractionError.failed(archive: archive.lastPathComponent, detail: message(reader))
        }
        // libarchive's secure extraction refuses to write through a symlink
        // anywhere in the path — and the destination's own path may contain
        // one (`/var`, a symlinked volume). Resolving it first leaves that
        // check guarding what it is for: symlinks the archive itself plants.
        let base = realPath(of: destination)

        while true {
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == AG_ARCHIVE_EOF { break }
            guard status >= AG_ARCHIVE_WARN, let entry else {
                throw ExtractionError.failed(archive: archive.lastPathComponent, detail: message(reader))
            }
            guard let raw = archive_entry_pathname(entry).map({ String(cString: $0) }),
                  let relative = safeRelativePath(raw) else { continue }
            archive_entry_set_pathname(entry, base + "/" + relative)
            guard archive_write_header(writer, entry) >= AG_ARCHIVE_WARN else {
                throw ExtractionError.failed(archive: archive.lastPathComponent, detail: message(writer))
            }
            try copyData(from: reader, to: writer, archive: archive.lastPathComponent)
            guard archive_write_finish_entry(writer) >= AG_ARCHIVE_WARN else {
                throw ExtractionError.failed(archive: archive.lastPathComponent, detail: message(writer))
            }
        }
    }

    private static func copyData(
        from reader: OpaquePointer, to writer: OpaquePointer, archive: String
    ) throws {
        while true {
            var buffer: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            let status = archive_read_data_block(reader, &buffer, &size, &offset)
            if status == AG_ARCHIVE_EOF { return }
            guard status >= AG_ARCHIVE_WARN else {
                throw ExtractionError.failed(archive: archive, detail: message(reader))
            }
            // Zip ends a file with an empty block rather than with EOF.
            guard let buffer, size > 0 else { return }
            guard archive_write_data_block(writer, buffer, size, offset) >= AG_ARCHIVE_WARN else {
                throw ExtractionError.failed(archive: archive, detail: message(writer))
            }
        }
    }

    /// An entry name reduced to something that can only land inside the
    /// destination, or nil when there is nothing left of it.
    static func safeRelativePath(_ raw: String) -> String? {
        let components = raw.split(separator: "/").map(String.init).filter {
            $0 != "." && $0 != ".." && !$0.isEmpty
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    /// The destination with every symlink resolved. Foundation's own
    /// `resolvingSymlinksInPath` deliberately puts `/private` back, which is
    /// exactly the symlink libarchive then refuses to write through.
    private static func realPath(of url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static var outOfMemory: String {
        String(localized: "there was not enough memory to open it", bundle: .module)
    }

    private static func message(_ handle: OpaquePointer) -> String {
        guard let text = archive_error_string(handle).map({ String(cString: $0) }),
              !text.isEmpty else {
            return String(localized: "the archive could not be read", bundle: .module)
        }
        return text
    }
}
