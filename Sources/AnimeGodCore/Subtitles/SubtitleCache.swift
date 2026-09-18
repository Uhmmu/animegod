import Foundation

/// A downloaded subtitle, as remembered in the library database. The file
/// itself lives under the subtitle cache directory at `relativePath`.
public struct SubtitleDownloadRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Which video this subtitle belongs to (`SubtitleCacheStore.videoKey`).
    public var videoKey: String
    public var animeID: UUID?
    public var provider: SubtitleProviderID
    public var providerSubtitleID: String
    public var language: SubtitleLanguage?
    public var format: SubtitleFormat
    public var releaseGroup: String?
    public var source: String?
    public var releaseName: String?
    /// The subtitle's own file name, as the provider shipped it.
    public var fileName: String
    public var relativePath: String
    /// 0...1 match score at download time.
    public var matchScore: Double
    /// Loaded by the automatic flow rather than picked by the user.
    public var isAutomatic: Bool
    /// The subtitle to load when the video plays again.
    public var isActive: Bool
    /// The video file this subtitle was matched against.
    public var videoFileName: String
    public var downloadedAt: Date

    public init(
        id: UUID = UUID(),
        videoKey: String,
        animeID: UUID?,
        provider: SubtitleProviderID,
        providerSubtitleID: String,
        language: SubtitleLanguage?,
        format: SubtitleFormat,
        releaseGroup: String?,
        source: String?,
        releaseName: String?,
        fileName: String,
        relativePath: String,
        matchScore: Double,
        isAutomatic: Bool,
        isActive: Bool,
        videoFileName: String,
        downloadedAt: Date = .now
    ) {
        self.id = id
        self.videoKey = videoKey
        self.animeID = animeID
        self.provider = provider
        self.providerSubtitleID = providerSubtitleID
        self.language = language
        self.format = format
        self.releaseGroup = releaseGroup
        self.source = source
        self.releaseName = releaseName
        self.fileName = fileName
        self.relativePath = relativePath
        self.matchScore = matchScore
        self.isAutomatic = isAutomatic
        self.isActive = isActive
        self.videoFileName = videoFileName
        self.downloadedAt = downloadedAt
    }

    /// "简体中文 · ASS · 射手网(伪)" — also the track title in the player.
    public var displayTitle: String {
        [language?.displayName ?? "Subtitle", format.displayName, provider.displayName].joined(separator: " · ")
    }
}

/// Subtitle files on disk:
///
///     Application Support/AnimeGod/Subtitles/
///         {anime-id or "unlinked"}/{S01E14}/{provider}-{id}.ass
///         Fonts/                       (fonts shipped in subtitle packs)
///         anime-list-mini.json         (the ID mapping cache)
///
/// Files are always UTF-8. Metadata lives in the library database so a
/// replay finds the subtitle without touching the network.
public struct SubtitleCacheStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var fontsDirectory: URL { root.appending(path: "Fonts", directoryHint: .isDirectory) }
    public var idMappingURL: URL { root.appending(path: "anime-list-mini.json") }

    /// Stable identity of a video for cache lookups: the library file when
    /// there is one; the file name for direct playback of a download, whose
    /// size keeps changing until it finishes.
    public static func videoKey(mediaFileID: UUID?, fileName: String) -> String {
        if let mediaFileID { return "media:\(mediaFileID.uuidString)" }
        return "file:\(fileName.lowercased())"
    }

    public func url(for record: SubtitleDownloadRecord) -> URL {
        root.appending(path: record.relativePath)
    }

    /// Writes a prepared subtitle (and any fonts it came with) and returns
    /// the record describing it; the caller persists the record.
    public func store(
        _ prepared: PreparedSubtitle,
        for scored: ScoredSubtitle,
        video: SubtitleVideoIdentity,
        videoKey: String,
        animeID: UUID?,
        isAutomatic: Bool
    ) throws -> SubtitleDownloadRecord {
        let result = scored.result
        let folder = [animeID?.uuidString ?? "unlinked", Self.sanitize(video.episodeLabel)].joined(separator: "/")
        let name = "\(result.provider.rawValue)-\(Self.sanitize(result.providerSubtitleID).suffix(60)).\(prepared.format.rawValue)"
        let relativePath = "\(folder)/\(name)"
        let destination = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(prepared.text.utf8).write(to: destination, options: .atomic)
        storeFonts(prepared.fonts)

        let timed = result.timedRelease
        return SubtitleDownloadRecord(
            videoKey: videoKey,
            animeID: animeID,
            provider: result.provider,
            providerSubtitleID: result.providerSubtitleID,
            language: prepared.language ?? (result.languages.count == 1 ? result.languages.first : nil),
            format: prepared.format,
            releaseGroup: result.displayGroup,
            source: timed.videoSource,
            releaseName: result.releaseName,
            fileName: prepared.fileName,
            relativePath: relativePath,
            matchScore: scored.score.total,
            isAutomatic: isAutomatic,
            isActive: true,
            videoFileName: video.fileName
        )
    }

    /// Fonts are shared by every subtitle: libass looks them up by family
    /// name, so one directory serves all cached subtitles.
    func storeFonts(_ fonts: [SubtitleDownloadedFile]) {
        guard !fonts.isEmpty else { return }
        try? FileManager.default.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
        for font in fonts {
            let name = Self.sanitize((font.name as NSString).lastPathComponent)
            let destination = fontsDirectory.appending(path: name)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? font.data.write(to: destination, options: .atomic)
        }
    }

    public func remove(_ record: SubtitleDownloadRecord) {
        try? FileManager.default.removeItem(at: url(for: record))
    }

    /// Deletes every cached subtitle and font. The ID mapping is kept: it is
    /// reference data, not a download.
    public func removeAll() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent != idMappingURL.lastPathComponent {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Bytes used by cached subtitles and fonts.
    public func diskUsage() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator where url.lastPathComponent != idMappingURL.lastPathComponent {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    static func sanitize(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: #"[/\\:*?"<>|\x00-\x1F]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "_" : cleaned
    }
}
