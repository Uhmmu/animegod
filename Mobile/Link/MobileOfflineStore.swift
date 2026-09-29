import AnimeGodCore
import Foundation

/// Episodes copied onto the phone.
///
/// The point of the whole companion, in the end: the link needs the Mac awake
/// and reachable, and a train does not provide either. A downloaded episode
/// plays from the container with no network at all — same libmpv, same file,
/// just a `file://` URL instead of an `http://` one.
///
/// Downloads run on a **background** `URLSession`, so they survive the app
/// being suspended and finish while it is not on screen. That is the only
/// reason this is a delegate-based `NSObject` rather than a few `await`s.
@MainActor
final class MobileOfflineStore: NSObject, ObservableObject {
    struct Entry: Codable, Identifiable, Sendable {
        let episodeID: UUID
        let mediaFileID: UUID
        let animeID: UUID
        let title: String
        let label: String
        let fileName: String
        let byteCount: Int64
        let downloadedAt: Date

        var id: UUID { episodeID }
    }

    struct Progress: Sendable {
        var received: Int64
        var expected: Int64
        var fraction: Double { expected > 0 ? Double(received) / Double(expected) : 0 }
    }

    @Published private(set) var entries: [UUID: Entry] = [:]
    @Published private(set) var active: [UUID: Progress] = [:]
    @Published private(set) var lastError: String?

    private var session: URLSession!
    /// Which episode each task is fetching. A background session hands tasks
    /// back after a relaunch, so this is rebuilt from the session on start.
    private var episodeForTask: [Int: UUID] = [:]
    private var pending: [UUID: Entry] = [:]

    private static let indexName = "offline-index"

    static var directory: URL {
        URL.documentsDirectory.appending(path: "Offline", directoryHint: .isDirectory)
    }

    override init() {
        super.init()
        entries = Dictionary(
            uniqueKeysWithValues: (LinkCache.load([Entry].self, Self.indexName) ?? []).map { ($0.episodeID, $0) }
        )
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.uhmmu.AnimeGod.offline")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        pruneMissingFiles()
    }

    // MARK: - Queries

    func isDownloaded(_ episodeID: UUID) -> Bool { entries[episodeID] != nil }
    func isDownloading(_ episodeID: UUID) -> Bool { active[episodeID] != nil }

    /// The local file, when it is really there. An index entry whose file has
    /// gone is worse than no entry: playback would fail instead of streaming.
    func localURL(for episodeID: UUID) -> URL? {
        guard let entry = entries[episodeID] else { return nil }
        let url = Self.directory.appending(path: entry.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var totalBytes: Int64 {
        entries.values.reduce(0) { $0 + $1.byteCount }
    }

    // MARK: - Commands

    func download(episode: LinkEpisode, title: String, target: (url: URL, authorization: String)) {
        guard entries[episode.id] == nil, active[episode.id] == nil else { return }
        var request = URLRequest(url: target.url)
        request.setValue(target.authorization, forHTTPHeaderField: LinkProtocol.authorizationHeader)
        let task = session.downloadTask(with: request)
        // The extension matters: mpv picks its demuxer partly by it, and a
        // Matroska file named `.tmp` is a worse guess than none.
        let ext = target.url.pathExtension.isEmpty ? "mkv" : target.url.pathExtension
        pending[episode.id] = Entry(
            episodeID: episode.id,
            mediaFileID: episode.mediaFileID,
            animeID: episode.animeID,
            title: title,
            label: episode.label,
            fileName: "\(episode.mediaFileID.uuidString).\(ext)",
            byteCount: episode.fileSize,
            downloadedAt: .now
        )
        episodeForTask[task.taskIdentifier] = episode.id
        active[episode.id] = Progress(received: 0, expected: episode.fileSize)
        task.resume()
    }

    func cancel(episodeID: UUID) {
        for (taskID, id) in episodeForTask where id == episodeID {
            session.getAllTasks { tasks in
                tasks.first { $0.taskIdentifier == taskID }?.cancel()
            }
        }
        active.removeValue(forKey: episodeID)
        pending.removeValue(forKey: episodeID)
    }

    func remove(episodeID: UUID) {
        if let entry = entries[episodeID] {
            try? FileManager.default.removeItem(at: Self.directory.appending(path: entry.fileName))
        }
        entries.removeValue(forKey: episodeID)
        persist()
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: Self.directory)
        entries.removeAll()
        persist()
    }

    // MARK: - Internals

    private func persist() {
        LinkCache.save(Array(entries.values), Self.indexName)
    }

    /// An entry whose file is gone — cleared by the system, or a restore that
    /// did not bring the container's caches — must not look downloaded.
    private func pruneMissingFiles() {
        var changed = false
        for (id, entry) in entries {
            let url = Self.directory.appending(path: entry.fileName)
            if !FileManager.default.fileExists(atPath: url.path) {
                entries.removeValue(forKey: id)
                changed = true
            }
        }
        if changed { persist() }
    }

    fileprivate func taskProgressed(taskID: Int, received: Int64, expected: Int64) {
        guard let episodeID = episodeForTask[taskID] else { return }
        active[episodeID] = Progress(received: received, expected: max(expected, 0))
    }

    fileprivate func taskFinished(taskID: Int, movedTo temporary: URL) {
        guard let episodeID = episodeForTask[taskID], let entry = pending[episodeID] else { return }
        let destination = Self.directory.appending(path: entry.fileName)
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            // Excluded from backup: these are copies of files that live on the
            // Mac, and nobody wants a 1.4 GB episode in their iCloud backup.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = destination
            try? mutable.setResourceValues(values)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? entry.byteCount
            entries[episodeID] = Entry(
                episodeID: entry.episodeID, mediaFileID: entry.mediaFileID, animeID: entry.animeID,
                title: entry.title, label: entry.label, fileName: entry.fileName,
                byteCount: size, downloadedAt: .now
            )
            persist()
        } catch {
            lastError = error.localizedDescription
        }
        active.removeValue(forKey: episodeID)
        pending.removeValue(forKey: episodeID)
        episodeForTask.removeValue(forKey: taskID)
    }

    fileprivate func taskFailed(taskID: Int, error: (any Error)?) {
        guard let episodeID = episodeForTask[taskID] else { return }
        // A cancel is not a failure and must not be reported as one.
        if let error = error as? URLError, error.code != .cancelled {
            lastError = error.localizedDescription
        }
        active.removeValue(forKey: episodeID)
        pending.removeValue(forKey: episodeID)
        episodeForTask.removeValue(forKey: taskID)
    }
}

/// The delegate callbacks arrive on the session's own queue, so each one hops
/// to the main actor before touching published state.
extension MobileOfflineStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let id = downloadTask.taskIdentifier
        Task { @MainActor in
            self.taskProgressed(taskID: id, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temporary file is deleted the moment this returns, so it is
        // moved out synchronously here rather than on the main actor.
        let id = downloadTask.taskIdentifier
        let staged = FileManager.default.temporaryDirectory
            .appending(path: "animegod-\(UUID().uuidString)")
        try? FileManager.default.moveItem(at: location, to: staged)
        Task { @MainActor in
            self.taskFinished(taskID: id, movedTo: staged)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard error != nil else { return }
        let id = task.taskIdentifier
        Task { @MainActor in self.taskFailed(taskID: id, error: error) }
    }
}
