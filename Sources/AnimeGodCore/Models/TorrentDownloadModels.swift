import Foundation

/// A download the user started, as the library remembers it.
///
/// BitTorrent state (pieces, peers, resume data) belongs to the engine, which
/// persists it beside the database; this row is what the app needs when the
/// engine is not running: what was downloaded, where it went, and which anime
/// it belongs to.
public struct TorrentDownloadRecord: Identifiable, Hashable, Sendable {
    /// 40 lowercase hex digits — the same identity the search results use.
    public let infoHash: String
    public var title: String
    public var magnet: String
    /// Folder the files are written into.
    public var savePath: String
    /// The library title this was downloaded for, when it started from an
    /// anime's page. Cleared if that anime is removed.
    public var animeID: UUID?
    public var animeTitle: String?
    public var episodeLabel: String?
    public var totalBytes: Int64
    public var addedAt: Date
    public var completedAt: Date?
    /// Sequential download: pieces in order, so the file can be played while
    /// it is still arriving.
    public var isSequential: Bool

    public var id: String { infoHash }

    public init(
        infoHash: String,
        title: String,
        magnet: String,
        savePath: String,
        animeID: UUID? = nil,
        animeTitle: String? = nil,
        episodeLabel: String? = nil,
        totalBytes: Int64 = 0,
        addedAt: Date = .now,
        completedAt: Date? = nil,
        isSequential: Bool = false
    ) {
        self.infoHash = infoHash.lowercased()
        self.title = title
        self.magnet = magnet
        self.savePath = savePath
        self.animeID = animeID
        self.animeTitle = animeTitle
        self.episodeLabel = episodeLabel
        self.totalBytes = totalBytes
        self.addedAt = addedAt
        self.completedAt = completedAt
        self.isSequential = isSequential
    }

    public var saveURL: URL { URL(fileURLWithPath: savePath) }
}
