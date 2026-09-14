import Foundation

public struct ScannedMediaFile: Hashable, Sendable {
    public let relativePath: String
    public let fileSize: Int64
    public let modifiedAt: Date
    public var parsed: ParsedAnimeFilename

    public init(relativePath: String, fileSize: Int64, modifiedAt: Date, parsed: ParsedAnimeFilename) {
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.parsed = parsed
    }
}

public struct LibraryScanResult: Sendable {
    public let root: LibraryRoot
    public let files: [ScannedMediaFile]
    public let skippedUnreadableCount: Int

    public init(root: LibraryRoot, files: [ScannedMediaFile], skippedUnreadableCount: Int) {
        self.root = root
        self.files = files
        self.skippedUnreadableCount = skippedUnreadableCount
    }
}

/// A file whose title carries a part marker (前篇 / 後篇 / 上巻 / Part 2 …)
/// belongs to its own work even when it shares a folder with the base title.
struct PendingScannedFile {
    var scanned: ScannedMediaFile
    var fileTitle: String
    var topLevelFolder: String?
}

public actor LibraryScanner {
    private let parser: AnimeFilenameParser
    private let fileManager: FileManager

    public init(parser: AnimeFilenameParser = .init(), fileManager: FileManager = .default) {
        self.parser = parser
        self.fileManager = fileManager
    }

    public func scan(root: LibraryRoot, resolvedURL: URL) throws -> LibraryScanResult {
        let canonicalRoot = resolvedURL.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = canonicalRoot.pathComponents
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        guard let enumerator = fileManager.enumerator(
            at: resolvedURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var pending: [PendingScannedFile] = []
        var skipped = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard parser.isSupportedMediaFile(url) else { continue }
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { continue }
                let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
                let components = canonicalURL.pathComponents
                guard components.starts(with: rootComponents), components.count > rootComponents.count else {
                    skipped += 1
                    continue
                }
                let relativePath = components.dropFirst(rootComponents.count).joined(separator: "/")
                // Disc-navigation junk (menu screens, logos) is not watchable
                // anime and must not pollute a work's episode list.
                if let parent = components.dropLast().last,
                   Self.junkFolders.contains(parent.lowercased()) {
                    continue
                }
                var parsed = parser.parse(url: url, libraryRoot: resolvedURL)
                // Files inside a bonus folder are extras of the release even
                // without an SP marker in their name.
                if parsed.episodeKind == .regular,
                   components.dropFirst(rootComponents.count).dropLast()
                       .contains(where: { Self.specialFolders.contains($0.lowercased()) }) {
                    parsed.episodeKind = .special
                }
                // Keep the filename's own title before the folder override:
                // diverging titles inside one folder mean multiple works.
                let fileTitle = parsed.title
                var topLevelFolder: String?
                if let folder = components.dropFirst(rootComponents.count).dropLast().first {
                    topLevelFolder = folder
                    let collectionTitle = parser.collectionTitle(from: folder)
                    if !collectionTitle.isEmpty { parsed.title = collectionTitle }
                }
                pending.append(PendingScannedFile(
                    scanned: ScannedMediaFile(
                        relativePath: relativePath,
                        fileSize: Int64(values.fileSize ?? 0),
                        modifiedAt: values.contentModificationDate ?? .distantPast,
                        parsed: parsed
                    ),
                    fileTitle: fileTitle,
                    topLevelFolder: topLevelFolder
                ))
            } catch {
                skipped += 1
            }
        }

        let files = Self.resolveWorkTitles(pending)
            // Adult-video catalogue codes stay out of the anime library.
            .filter { !AnimeFilenameParser.isAVCodeTitle($0.parsed.title) }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
        return LibraryScanResult(root: root, files: files, skippedUnreadableCount: skipped)
    }

    /// Disc-navigation junk folders whose videos are not watchable content.
    private static let junkFolders: Set<String> = ["menu", "menus", "logologo", "kbd"]

    /// Bonus folders: their contents are always extras of the release, even
    /// when the filename itself carries no SP marker.
    private static let specialFolders: Set<String> = ["sps", "sp", "sp集", "特典", "特典映像", "extras", "bonus", "bonusdisc"]

    /// Extra discs and bonus folders whose names carry no work identity must
    /// never split a release apart.
    private static let nonWorkTitles: Set<String> = [
        "menu", "menus", "extras", "bonus", "bonusdisc", "special", "specials",
        "ncop", "nced", "nc", "pv", "cm", "spot", "trailer", "trailers", "logologo"
    ]

    /// Files sharing a top-level folder normally form one work. Only regular
    /// (main-content) files can split a folder apart — 前篇/後篇 released
    /// together, or two movies bundled into one folder. Specials, trailers,
    /// and creditless clips always belong to the folder's work and attach to
    /// its largest regular cluster.
    static func resolveWorkTitles(_ pending: [PendingScannedFile]) -> [ScannedMediaFile] {
        let byFolder = Dictionary(grouping: pending, by: { $0.topLevelFolder ?? "" })
        var results: [ScannedMediaFile] = []
        for group in byFolder.values {
            guard let first = group.first, first.topLevelFolder != nil, group.count > 1 else {
                results.append(contentsOf: group.map(\.scanned))
                continue
            }
            let folderTitle = first.scanned.parsed.title
            guard let split = workTitles(for: group, folderTitle: folderTitle) else {
                results.append(contentsOf: group.map(\.scanned))
                continue
            }
            // Specials attach to the biggest regular cluster so they never
            // scatter into their own entries.
            let clusterCounts = Dictionary(
                grouping: group.filter { $0.scanned.parsed.episodeKind == .regular }
            ) { entry in
                split[normalize(entry.fileTitle)] ?? folderTitle
            }.mapValues(\.count)
            // On a tie the folder's own work wins, so a stray misparsed clip
            // can never pull the release's extras away from it.
            let fallbackTitle = clusterCounts.max { a, b in
                if a.value != b.value { return a.value < b.value }
                if (a.key == folderTitle) != (b.key == folderTitle) { return b.key == folderTitle }
                return a.key > b.key
            }?.key ?? folderTitle
            for var entry in group {
                let key = normalize(entry.fileTitle)
                if entry.scanned.parsed.episodeKind == .regular, !key.isEmpty,
                   let title = split[key] {
                    entry.scanned.parsed.title = title
                } else if entry.scanned.parsed.episodeKind != .regular {
                    entry.scanned.parsed.title = fallbackTitle
                }
                results.append(entry.scanned)
            }
        }
        return results
    }

    /// Returns a per-work-key title map when the folder's regular files form
    /// more than one work, nil when everything belongs together. Keys absent
    /// from the map keep the folder title.
    private static func workTitles(
        for group: [PendingScannedFile],
        folderTitle: String
    ) -> [String: String]? {
        let folderKey = normalize(folderTitle)
        let regulars = group.filter { $0.scanned.parsed.episodeKind == .regular }
        let keys = Array(Set(regulars.map { normalize($0.fileTitle) }.filter { !$0.isEmpty }))
        guard keys.count > 1 else { return nil }

        // Union-find over the distinct title keys.
        var parent: [String: String] = [:]
        func root(_ key: String) -> String {
            var current = key
            while let up = parent[current] { current = up }
            return current
        }
        func union(_ a: String, _ b: String) {
            let rootA = root(a), rootB = root(b)
            if rootA != rootB { parent[rootA] = rootB }
        }

        for key in keys where key == folderKey || Self.nonWorkTitles.contains(key) {
            union(key, folderKey)
        }
        for index in keys.indices {
            for other in keys.indices where index < other {
                let a = keys[index], b = keys[other]
                // Part-marked titles (base + 前篇) are separate works and must
                // not merge back into the bare base via containment.
                if hasPartMarker(a) || hasPartMarker(b) { continue }
                if a.contains(b) || b.contains(a) { union(a, b) }
            }
        }

        let folderCluster = root(folderKey)
        guard Set(keys.map(root)).count > 1 else { return nil }

        // One display title per non-folder cluster: the file title whose
        // normalized form is the shortest (most canonical) in that cluster.
        var titleByCluster: [String: (title: String, length: Int)] = [:]
        for entry in regulars {
            let key = normalize(entry.fileTitle)
            guard !key.isEmpty else { continue }
            let cluster = root(key)
            guard cluster != folderCluster else { continue }
            let length = normalize(entry.fileTitle).count
            if length > 0, length < (titleByCluster[cluster]?.length ?? .max) {
                titleByCluster[cluster] = (entry.fileTitle, length)
            }
        }
        guard !titleByCluster.isEmpty else { return nil }

        var mapping: [String: String] = [:]
        for key in keys {
            let cluster = root(key)
            if cluster != folderCluster, let title = titleByCluster[cluster]?.title {
                mapping[key] = title
            }
        }
        return mapping
    }

    static func hasPartMarker(_ title: String) -> Bool {
        AnimeFilenameParser.partLabel(in: title) != nil
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }
}
