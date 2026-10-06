import Foundation

/// A folder that came in the box beside the video — `CDs`, `OST`, `Scans`,
/// `menu` — and how much is in it.
public struct ConcertExtra: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let itemCount: Int
    public var id: String { name }

    public init(name: String, itemCount: Int) {
        self.name = name
        self.itemCount = itemCount
    }
}

/// What a release says about itself, read off the folder it arrived in.
///
/// This exists because of what a real download turned out to contain. A concert
/// BDRip is not two video files: beside them sat `Scans/` with 27 jacket scans,
/// `OST/` with the live album as FLAC, `CDs/` with the bonus discs, and
/// `menu/`. And in `OST/` was **`BRMM-10876.cue`** — the catalogue number, in a
/// filename, which is the one key the whole lookup turns on. The folder was
/// named `[DBD-Raws][MyGO!!!!! 6th LIVE…][1080P][BDRip][HEVC-10bit][FLAC][MKV]`
/// and carried no number at all, so looking only at the folder's own name found
/// nothing, while MusicBrainz answers that number with the release and both
/// nights' setlists.
///
/// So the files are read before any service is asked. They are also better than
/// a service at one thing outright: the scans are the real artwork at three
/// megabytes each, where Discogs offers a 445×600 photograph of the case.
public struct ConcertReleaseFiles: Hashable, Sendable {
    /// Catalogue numbers found in any file or folder name under the release.
    public var catalogNumbers: [ConcertCatalogNumber] = []
    /// From a cue sheet's `CATALOG` line, which is the disc's barcode.
    public var barcode: String?
    public var performer: String?
    public var albumTitle: String?
    /// Jacket scans and cover images, best first.
    public var coverImageURLs: [URL] = []
    /// The track list a cue sheet carries, with the durations its indexes imply.
    public var cueTracks: [ConcertTrack] = []
    /// What else came in the box, as the folders it arrived in: `CDs`, `OST`,
    /// `Scans`, `menu`. Worth showing — it is the difference between a page
    /// that says what you have and one that only says what a catalogue knows.
    public var extras: [ConcertExtra] = []

    public init() {}

    public var isEmpty: Bool {
        catalogNumbers.isEmpty && barcode == nil && coverImageURLs.isEmpty
            && cueTracks.isEmpty && extras.isEmpty
    }
}

public enum ConcertReleaseFileReader {
    /// Folders whose images are the release's artwork.
    ///
    /// A hint, not the rule. Every group names this folder differently — `Scans`
    /// here, `BK` or `Covers` or `特典` elsewhere — so a folder holding several
    /// images counts as artwork whatever it is called, and this list only
    /// decides which artwork comes first.
    static let artworkFolders: Set<String> = [
        "scans", "scan", "scan_bk", "bk", "booklet", "cover", "covers", "jacket",
        "artwork", "art", "pic", "pics", "picture", "pictures", "photo", "photos",
        "封面", "扫图", "扫描", "書影", "特典"
    ]

    /// How many images a folder has to hold before it is artwork rather than a
    /// stray thumbnail sitting next to a video.
    static let imagesThatMakeAFolderArtwork = 3

    /// Audio extensions whose filenames are a track list when there is no cue.
    static let audioExtensions: Set<String> = ["flac", "wav", "ape", "tak", "tta", "m4a", "mp3", "dsf", "wv"]
    /// Images sitting loose beside the video that are the cover by convention.
    static let coverFileStems: Set<String> = ["cover", "folder", "front", "poster", "封面"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "bmp", "tif", "tiff"]

    /// How deep to look. A release puts its extras one level under itself, and
    /// walking a forty-gigabyte folder to its leaves to find a cue sheet would
    /// cost more than the lookup it feeds.
    static let maximumDepth = 2

    /// Reads a release folder. Never throws: a folder that cannot be read
    /// contributes nothing, which is the same as a folder with nothing in it.
    public static func read(folder: URL, fileManager: FileManager = .default) -> ConcertReleaseFiles {
        var files = ConcertReleaseFiles()
        var seenNumbers = Set<String>()
        var namedArtwork: [URL] = []
        var otherFolderImages: [String: [URL]] = [:]
        var looseCovers: [URL] = []
        var cueURL: URL?
        var audioByFolder: [String: [URL]] = [:]
        var extras: [ConcertExtra] = []

        func visit(_ directory: URL, depth: Int, inArtworkFolder: Bool) {
            guard depth <= maximumDepth,
                  let entries = try? fileManager.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  )
            else { return }
            for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let name = entry.lastPathComponent
                // A catalogue number reaches a folder on a cue sheet, a log, a
                // subfolder's name — **never on a scan**. A scan is named by
                // whoever ran the scanner, and `IMG-01.png` is the commonest
                // filename there is: reading those as numbers matched two of
                // this library's concerts to a compilation Discogs files under
                // `IMG015`. Four digits for the rest, because a file that is
                // not a scan can still be `Disc 2`.
                if !imageExtensions.contains(entry.pathExtension.lowercased()) {
                    for number in ConcertCatalogNumber.all(in: name, minimumDigits: 4)
                    where seenNumbers.insert(number.description).inserted {
                        files.catalogNumbers.append(number)
                    }
                }

                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDirectory {
                    // Only what sits directly beside the video. The discs
                    // inside `CDs/` are part of `CDs`, not five more things in
                    // the box.
                    if depth == 1, let contents = try? fileManager.contentsOfDirectory(
                        at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                    ), !contents.isEmpty {
                        extras.append(.init(name: name, itemCount: contents.count))
                    }
                    visit(entry, depth: depth + 1,
                          inArtworkFolder: inArtworkFolder || artworkFolders.contains(name.lowercased()))
                    continue
                }

                let ext = entry.pathExtension.lowercased()
                if ext == "cue", cueURL == nil { cueURL = entry }
                if audioExtensions.contains(ext) {
                    audioByFolder[directory.path, default: []].append(entry)
                }
                if imageExtensions.contains(ext) {
                    if inArtworkFolder {
                        namedArtwork.append(entry)
                    } else if coverFileStems.contains(entry.deletingPathExtension().lastPathComponent.lowercased()) {
                        looseCovers.append(entry)
                    } else if depth == 0 {
                        // An image sitting directly beside the video, whatever
                        // it is called: somebody put it there, and the release
                        // root is not where a stray screenshot lands. Measured
                        // on a real one — `EXPO_ZUTOMAYO_KV.jpg`, dropped in by
                        // hand — which matched no rule and so did nothing.
                        looseCovers.append(entry)
                    } else {
                        // Whatever this folder is called, several images in it
                        // are the release's artwork. Groups do not agree on the
                        // name and there is no reason to make them.
                        otherFolderImages[directory.path, default: []].append(entry)
                    }
                }
            }
        }
        visit(folder, depth: 0, inArtworkFolder: false)

        // A loose `cover.jpg` was put there to be the cover; the first scan is
        // the front of the jacket, by the order a scanner works in.
        let unnamed = otherFolderImages.values
            .filter { $0.count >= imagesThatMakeAFolderArtwork }
            .sorted { ($0.first?.path ?? "") < ($1.first?.path ?? "") }
            .flatMap { $0 }
        files.coverImageURLs = looseCovers + namedArtwork + unnamed
        files.extras = extras.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if let cueURL, let sheet = CueSheet.read(at: cueURL) {
            files.barcode = sheet.catalog
            files.performer = sheet.performer
            files.albumTitle = sheet.title
            files.cueTracks = sheet.tracks
        }
        if files.cueTracks.isEmpty {
            files.cueTracks = trackList(fromAudio: audioByFolder)
        }
        return files
    }

    /// A track list read off audio filenames, for a rip with no cue sheet.
    ///
    /// `01. 歩拾道.flac` is a numbered track and so is `1-02 Song.flac`; the
    /// numbering is what makes it a list rather than a folder of audio, so the
    /// longest run from one is taken exactly as a prose setlist is.
    static func trackList(fromAudio audioByFolder: [String: [URL]]) -> [ConcertTrack] {
        let best = audioByFolder.values.max { $0.count < $1.count } ?? []
        guard best.count >= 3 else { return [] }
        let names = best
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ConcertSetlistTextParser.songs(in: names.joined(separator: "\n"))
    }
}

/// Enough of a cue sheet to read a track list off it.
struct CueSheet: Hashable, Sendable {
    var catalog: String?
    var performer: String?
    var title: String?
    var tracks: [ConcertTrack] = []

    /// Cue sheets are written in whatever encoding the ripper's machine used,
    /// and they do not say which. The one measured here is GBK; Japanese rips
    /// are Shift-JIS and modern ones are UTF-8, so each is tried and the first
    /// that decodes wins. Same problem, and same answer, as the downloaded
    /// subtitles.
    static let encodings: [String.Encoding] = [
        .utf8,
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))),
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue))),
        .isoLatin1
    ]

    static func read(at url: URL) -> CueSheet? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        for encoding in encodings {
            guard let text = String(data: data, encoding: encoding) else { continue }
            // A mis-decode produces replacement characters rather than failing,
            // so a sheet that decoded into nonsense is not accepted.
            guard !text.contains("\u{FFFD}") else { continue }
            let sheet = parse(text)
            if !sheet.tracks.isEmpty || sheet.catalog != nil { return sheet }
        }
        return nil
    }

    static func parse(_ text: String) -> CueSheet {
        var sheet = CueSheet()
        /// Titles seen before the first `TRACK` belong to the disc.
        var sawTrack = false
        var pendingTitle: String?
        var position = 0
        /// A track's length is where the *next* track's pregap begins, which the
        /// sheet writes as that track's `INDEX 00` inside the previous file.
        var lengths: [Int: TimeInterval] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let (keyword, rest) = split(line)
            switch keyword {
            case "CATALOG":
                sheet.catalog = unquoted(rest)
            case "PERFORMER":
                if !sawTrack { sheet.performer = unquoted(rest) }
            case "TITLE":
                if sawTrack { pendingTitle = unquoted(rest) } else { sheet.title = unquoted(rest) }
            case "TRACK":
                if let pendingTitle, position > 0 { append(&sheet, position: position, title: pendingTitle) }
                sawTrack = true
                pendingTitle = nil
                position = Int(rest.split(separator: " ").first.map(String.init) ?? "") ?? position + 1
            case "INDEX":
                // `INDEX 00` of track n+1 marks the end of track n.
                let parts = rest.split(separator: " ").map(String.init)
                guard parts.count >= 2, parts[0] == "00", let seconds = time(parts[1]) else { break }
                lengths[position - 1] = seconds
            default:
                break
            }
        }
        if let pendingTitle, position > 0 { append(&sheet, position: position, title: pendingTitle) }

        sheet.tracks = sheet.tracks.map { track in
            var track = track
            track.duration = lengths[track.position]
            return track
        }
        return sheet
    }

    private static func append(_ sheet: inout CueSheet, position: Int, title: String) {
        let classified = ConcertTrackClassifier.classify(title: title)
        sheet.tracks.append(ConcertTrack(
            position: position, title: classified.title,
            kind: classified.kind, isEncore: classified.isEncore
        ))
    }

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line.uppercased(), "") }
        return (String(line[..<space]).uppercased(),
                String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func unquoted(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text.isEmpty ? nil : text
    }

    /// `MM:SS:FF`, where the frames are seventy-fifths of a second.
    private static func time(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":").map { Int($0) }
        guard parts.count == 3, let minutes = parts[0], let seconds = parts[1], let frames = parts[2] else {
            return nil
        }
        return TimeInterval(minutes * 60 + seconds) + TimeInterval(frames) / 75
    }
}

public extension ConcertReleaseFiles {
    /// What the folder knows, as a source the merge can fold in beside the
    /// services.
    func release(fallbackTitle: String) -> ConcertRelease? {
        guard !isEmpty else { return nil }
        let title = albumTitle.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        return ConcertRelease(
            provider: .localFiles,
            externalID: catalogNumbers.first?.description ?? barcode ?? title,
            title: title,
            artistNames: [performer].compactMap { $0 },
            catalogNumbers: catalogNumbers.map(\.description),
            barcode: barcode,
            discs: cueTracks.isEmpty ? [] : [ConcertDisc(
                position: 1, title: albumTitle, format: "CD", tracks: cueTracks
            )],
            coverImageURLs: coverImageURLs,
            extras: extras
        )
    }
}
