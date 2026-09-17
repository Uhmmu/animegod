import AnimeGodCore
import AppKit
import Combine
import Foundation

/// One row of the Downloads list: what the library remembers plus what the
/// engine currently reports.
struct TorrentDownloadItem: Identifiable, Hashable {
    var record: TorrentDownloadRecord
    var snapshot: AGTorrentSnapshot?

    var id: String { record.infoHash }

    /// The engine's name once metadata arrives, else the searched title.
    var title: String {
        if let name = snapshot?.name, !name.isEmpty { return name }
        return record.title
    }

    var progress: Double { snapshot?.progress ?? (record.completedAt != nil ? 1 : 0) }
    var isComplete: Bool {
        if let state = snapshot?.state { return state == .finished || state == .seeding }
        return record.completedAt != nil
    }
    var isPaused: Bool { snapshot?.state == .paused }
    var totalBytes: Int64 { snapshot?.totalBytes ?? record.totalBytes }
    var downloadedBytes: Int64 { snapshot?.downloadedBytes ?? 0 }

    var statusText: String {
        guard let snapshot else { return record.completedAt != nil ? "Completed" : "Not running" }
        if let error = snapshot.errorMessage, !error.isEmpty { return error }
        switch snapshot.state {
        case .queued: return "Queued"
        case .fetchingMetadata: return "Fetching details from the swarm…"
        case .checking: return "Checking existing files…"
        case .downloading:
            let rate = ByteCountFormatter.string(fromByteCount: Int64(snapshot.downloadRate), countStyle: .binary)
            let peers = "\(snapshot.connectedSeeds) seeds · \(snapshot.connectedPeers) peers"
            return "\(rate)/s · \(peers)"
        case .finished, .seeding:
            let uploaded = ByteCountFormatter.string(fromByteCount: snapshot.uploadedBytes, countStyle: .binary)
            return snapshot.state == .seeding ? "Seeding · \(uploaded) shared" : "Completed"
        case .paused: return "Paused"
        case .errored: return snapshot.errorMessage ?? "Failed"
        @unknown default: return ""
        }
    }

    var remainingText: String? {
        guard let seconds = snapshot?.estimatedSecondsRemaining, seconds > 0, !isComplete, !isPaused else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds > 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds)
    }
}

/// Owns the embedded BitTorrent engine and the library's view of downloads.
///
/// The engine is started lazily — a user who never downloads anything never
/// joins the DHT — and it keeps its own resume state, so tasks survive a
/// quit. Downloads are an enhancement: if the engine cannot start, searching
/// and playback are unaffected and the failure is reported here.
@MainActor
final class TorrentDownloadManager: ObservableObject {
    @Published private(set) var items: [TorrentDownloadItem] = []
    @Published private(set) var sessionInfo: AGTorrentSessionInfo?
    @Published var errorMessage: String?

    let folders: DownloadFolderStore
    private var database: LibraryDatabase?
    private var engine: AGTorrentEngine?
    private var records: [String: TorrentDownloadRecord] = [:]
    private var refreshTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Preferred listen port; libtorrent picks another if it is taken.
    private static let listenPort: Int32 = 6881

    init(folders: DownloadFolderStore = DownloadFolderStore()) {
        self.folders = folders
        folders.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Called once the library database is open. Existing downloads bring the
    /// engine up so they resume where they stopped.
    func attach(database: LibraryDatabase) async {
        self.database = database
        await reloadRecords()
        if !records.isEmpty {
            folders.restoreAccess()
            startEngineIfNeeded()
        }
    }

    var isEngineRunning: Bool { engine != nil && sessionInfo?.isRunning == true }

    var activeCount: Int {
        items.filter { !$0.isComplete && !$0.isPaused }.count
    }

    // MARK: - Engine lifecycle

    private static var stateDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AnimeGod/Torrents")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func startEngineIfNeeded() -> AGTorrentEngine? {
        if let engine { return engine }
        let engine = AGTorrentEngine(
            stateDirectory: Self.stateDirectory,
            listenPort: Self.listenPort,
            preferTCP: false
        )
        if let failure = engine.startupError {
            errorMessage = "The download engine could not start: \(failure)"
            return nil
        }
        self.engine = engine
        startRefreshing()
        return engine
    }

    private func startRefreshing() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh()
    }

    /// Writes resume data and stops the session. Called when the app quits.
    func shutdown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        engine?.shutdown()
        engine = nil
    }

    // MARK: - Adding

    /// Starts a download for a search result, optionally bound to the anime
    /// the search came from.
    func download(
        _ result: TorrentSearchResult,
        anime: Anime? = nil,
        sequential: Bool = false
    ) {
        add(
            magnet: result.magnet.uri,
            infoHash: result.infoHash.hex,
            title: result.title,
            trackers: result.trackers,
            anime: anime,
            episodeLabel: result.release.episodeLabel,
            sequential: sequential
        )
    }

    func add(
        magnet: String,
        infoHash: String,
        title: String,
        trackers: [String] = [],
        anime: Anime? = nil,
        episodeLabel: String? = nil,
        sequential: Bool = false
    ) {
        guard let engine = startEngineIfNeeded() else { return }
        if records[infoHash.lowercased()] != nil {
            errorMessage = "“\(title)” is already in Downloads."
            return
        }
        let folder = folders.folderForNewDownload()
        do {
            let hash = try engine.addMagnet(magnet, savePath: folder, sequential: sequential)
            if !trackers.isEmpty { engine.addTrackers(trackers, forInfoHash: hash) }
            let record = TorrentDownloadRecord(
                infoHash: hash,
                title: title,
                magnet: magnet,
                savePath: folder.path,
                animeID: anime?.id,
                animeTitle: anime?.title,
                episodeLabel: episodeLabel,
                isSequential: sequential
            )
            records[record.infoHash] = record
            Task { try? await database?.saveTorrentDownload(record) }
            refresh()
        } catch {
            errorMessage = "Could not start the download: \(error.localizedDescription)"
        }
    }

    // MARK: - Controlling

    func pause(_ item: TorrentDownloadItem) {
        engine?.pause(item.record.infoHash)
        refresh()
    }

    func resume(_ item: TorrentDownloadItem) {
        startEngineIfNeeded()?.resume(item.record.infoHash)
        refresh()
    }

    func setSequential(_ sequential: Bool, for item: TorrentDownloadItem) {
        engine?.setSequential(sequential, forInfoHash: item.record.infoHash)
        var record = item.record
        record.isSequential = sequential
        records[record.infoHash] = record
        Task {
            try? await database?.updateTorrentDownload(
                infoHash: record.infoHash, title: nil, totalBytes: nil, completedAt: nil, isSequential: sequential
            )
        }
        refresh()
    }

    func reannounce(_ item: TorrentDownloadItem) {
        engine?.forceReannounce(item.record.infoHash)
    }

    func remove(_ item: TorrentDownloadItem, deleteFiles: Bool) {
        engine?.remove(item.record.infoHash, deleteFiles: deleteFiles)
        records[item.record.infoHash] = nil
        let hash = item.record.infoHash
        Task { try? await database?.removeTorrentDownload(infoHash: hash) }
        refresh()
    }

    func revealInFinder(_ item: TorrentDownloadItem) {
        let folder = URL(fileURLWithPath: item.snapshot?.savePath ?? item.record.savePath)
        let name = item.snapshot?.name ?? ""
        let target = name.isEmpty ? folder : folder.appending(path: name)
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    /// Video files inside a task, largest first — what the user would play.
    func videoFiles(for item: TorrentDownloadItem) -> [AGTorrentFileEntry] {
        let extensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts"]
        return (engine?.files(forInfoHash: item.record.infoHash) ?? [])
            .filter { extensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
            .sorted { $0.length > $1.length }
    }

    // MARK: - Refreshing

    private func reloadRecords() async {
        guard let database else { return }
        do {
            let stored = try await database.torrentDownloads()
            records = Dictionary(uniqueKeysWithValues: stored.map { ($0.infoHash, $0) })
            rebuildItems(snapshots: engine?.snapshots() ?? [])
        } catch {
            errorMessage = "Could not read saved downloads: \(error.localizedDescription)"
        }
    }

    private func refresh() {
        guard let engine else {
            rebuildItems(snapshots: [])
            return
        }
        let snapshots = engine.snapshots()
        sessionInfo = engine.sessionInfo()
        rebuildItems(snapshots: snapshots)
        persistProgress(snapshots)
    }

    private func rebuildItems(snapshots: [AGTorrentSnapshot]) {
        let byHash = Dictionary(snapshots.map { ($0.infoHash.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        items = records.values
            .sorted { $0.addedAt > $1.addedAt }
            .map { TorrentDownloadItem(record: $0, snapshot: byHash[$0.infoHash]) }
    }

    /// Keeps the library's copy in step with the engine: the real name and
    /// size arrive with metadata, and completion is stamped once.
    private func persistProgress(_ snapshots: [AGTorrentSnapshot]) {
        for snapshot in snapshots {
            let hash = snapshot.infoHash.lowercased()
            guard var record = records[hash] else { continue }
            let isComplete = snapshot.state == .finished || snapshot.state == .seeding
            let name = snapshot.name.isEmpty ? nil : snapshot.name
            let changedTitle = name != nil && name != record.title ? name : nil
            let changedSize = snapshot.totalBytes > 0 && snapshot.totalBytes != record.totalBytes ? snapshot.totalBytes : nil
            let completedAt: Date? = (isComplete && record.completedAt == nil) ? .now : nil
            guard changedTitle != nil || changedSize != nil || completedAt != nil else { continue }

            if let changedTitle { record.title = changedTitle }
            if let changedSize { record.totalBytes = changedSize }
            if let completedAt { record.completedAt = completedAt }
            records[hash] = record
            Task { [database] in
                try? await database?.updateTorrentDownload(
                    infoHash: hash,
                    title: changedTitle,
                    totalBytes: changedSize,
                    completedAt: completedAt,
                    isSequential: nil
                )
            }
        }
    }
}
