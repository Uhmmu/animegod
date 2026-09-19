import AnimeGodCore
import AppKit
import Combine
import Foundation

/// Owns local copies of episodes that live on an external drive.
///
/// - Auto caches appear transparently while an external-drive episode plays
///   and are removed once that episode counts as watched (≥90% on close).
/// - Manual caches are explicit user copies that persist until removed.
///
/// Copies run one at a time through a small serial queue so a "cache whole
/// series" action cannot hammer the source drive with parallel reads.
@MainActor
final class EpisodeCacheStore: ObservableObject {
    @Published private(set) var entries: [EpisodeCacheEntry] = []
    @Published var errorMessage: String?
    @Published var autoCachingEnabled: Bool {
        didSet { UserDefaults.standard.set(autoCachingEnabled, forKey: Self.autoCachingKey) }
    }
    @Published var autoDeleteEnabled: Bool {
        didSet { UserDefaults.standard.set(autoDeleteEnabled, forKey: Self.autoDeleteKey) }
    }

    private static let autoCachingKey = "cache.autoCachingEnabled"
    private static let autoDeleteKey = "cache.autoDeleteEnabled"
    private static let chunkSize = 8 * 1024 * 1024
    /// Reserve on the local volume before promising a copy, so the system
    /// never ends up squeezed by its own cache.
    private static let freeSpaceMargin: Int64 = 512 * 1024 * 1024
    private static let publishInterval: TimeInterval = 0.3
    private static let persistInterval: TimeInterval = 3

    private var database: LibraryDatabase?
    private(set) var cacheDirectory: URL
    private var queue: [PendingCopy] = []
    private var activeJob: PendingCopy?
    private var activeProgress: [UUID: CopyProgress] = [:]

    private struct PendingCopy {
        let mediaFile: MediaFile
        let policy: EpisodeCachePolicy
        let access: ScopedLibraryAccess?
        let sourceURL: URL
    }

    /// Thread-safe progress + cancellation shared with the detached copy
    /// loop; plain Task cancellation cannot reach a detached task's body.
    final class CopyProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var _bytes: Int64 = 0
        private var _cancelled = false
        private var _lastReport = Date.distantPast

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return _cancelled
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            _cancelled = true
        }

        /// Records cumulative bytes; returns them only often enough for a
        /// smooth progress UI (the copy thread may produce thousands of
        /// chunks per second).
        func report(_ cumulative: Int64, throttle: TimeInterval) -> Int64? {
            lock.lock(); defer { lock.unlock() }
            _bytes = cumulative
            let now = Date()
            guard now.timeIntervalSince(_lastReport) >= throttle else { return nil }
            _lastReport = now
            return cumulative
        }
    }

    init() {
        autoCachingEnabled = UserDefaults.standard.object(forKey: Self.autoCachingKey) as? Bool ?? true
        autoDeleteEnabled = UserDefaults.standard.object(forKey: Self.autoDeleteKey) as? Bool ?? true
        cacheDirectory = Self.defaultCacheDirectory()
    }

    private static func defaultCacheDirectory() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
        return support
            .appending(path: "AnimeGod", directoryHint: .isDirectory)
            .appending(path: "Episode Cache", directoryHint: .isDirectory)
    }

    // MARK: - Lifecycle

    func prepare(database: LibraryDatabase) async {
        self.database = database
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            errorMessage = String(localized: "Could not create the episode cache folder: \(error.localizedDescription)")
        }
        await reconcile()
        await reload()
    }

    /// Brings DB rows, files on disk, and in-flight reality back in sync.
    /// Called at launch (where every copying row is a crashed copy) and after
    /// library rescans (where removed source files cascade their rows away
    /// and leave orphaned files behind).
    func reconcile() async {
        guard let database else { return }
        do {
            let rows = try await database.cacheEntries()
            var keepableIDs = Set<UUID>()
            for row in rows {
                switch row.state {
                case .copying:
                    // A copy this session still owns is alive, not stale.
                    guard !isQueuedOrCopying(mediaFileID: row.mediaFileID) else { continue }
                    try? FileManager.default.removeItem(at: partialURL(for: row))
                    try await database.removeCacheEntry(mediaFileID: row.mediaFileID)
                case .complete:
                    if FileManager.default.fileExists(atPath: finalURL(for: row).path) {
                        keepableIDs.insert(row.mediaFileID)
                    } else {
                        try await database.removeCacheEntry(mediaFileID: row.mediaFileID)
                    }
                }
            }
            if let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path) {
                for name in names {
                    let id = name.split(separator: ".").first.flatMap { UUID(uuidString: String($0)) }
                    if let id, keepableIDs.contains(id) { continue }
                    try? FileManager.default.removeItem(at: cacheDirectory.appending(path: name))
                }
            }
        } catch {
            errorMessage = String(localized: "Could not reconcile the episode cache: \(error.localizedDescription)")
        }
    }

    func reload() async {
        guard let database else { return }
        do {
            entries = try await database.cacheEntries()
        } catch {
            errorMessage = String(localized: "Could not load the episode cache list: \(error.localizedDescription)")
        }
    }

    // MARK: - Queries

    var entriesByMediaFileID: [UUID: EpisodeCacheEntry] {
        Dictionary(entries.map { ($0.mediaFileID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Total bytes the cache occupies right now (complete files plus partials).
    var totalBytes: Int64 {
        entries.reduce(0) { sum, entry in
            sum + (entry.state == .complete ? entry.fileSize : entry.bytesCopied)
        }
    }

    /// The playable local copy for an episode, if a finished one exists.
    func cachedFileURL(for mediaFileID: UUID) -> URL? {
        guard let entry = entriesByMediaFileID[mediaFileID], entry.state == .complete else { return nil }
        let url = finalURL(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isQueuedOrCopying(mediaFileID: UUID) -> Bool {
        queue.contains { $0.mediaFile.id == mediaFileID }
            || activeJob?.mediaFile.id == mediaFileID
    }

    // MARK: - Creating caches

    /// Called by the player whenever an episode plays from its source drive.
    /// External volumes get a transparent auto cache; internal ones never do.
    func startAutoCacheIfNeeded(mediaFile: MediaFile, root: LibraryRoot) {
        guard autoCachingEnabled else { return }
        enqueue(mediaFile: mediaFile, root: root, policy: .auto)
    }

    /// Explicit user copy from an episode row or the "cache all" action.
    func cacheManually(mediaFile: MediaFile, root: LibraryRoot) {
        enqueue(mediaFile: mediaFile, root: root, policy: .manual)
    }

    private func enqueue(mediaFile: MediaFile, root: LibraryRoot, policy: EpisodeCachePolicy) {
        if let existing = entriesByMediaFileID[mediaFile.id] {
            if existing.state == .complete { return }
            if policy == .manual, existing.policy == .auto {
                // The user asked to keep this one; a running auto copy simply
                // changes owner instead of restarting.
                upgradePolicy(mediaFileID: mediaFile.id)
            }
            if isQueuedOrCopying(mediaFileID: mediaFile.id) { return }
            // A copying row with no live job is stale; fall through and restart.
        }

        let access = try? ScopedLibraryAccess(root: root)
        let rootURL = access?.url ?? URL(fileURLWithPath: root.lastKnownPath, isDirectory: true)
        let sourceURL = rootURL.appending(path: mediaFile.relativePath)
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            access?.stop()
            if policy == .manual {
                errorMessage = String(localized: "“\(mediaFile.relativePath)” is not readable — connect its drive before caching.")
            }
            return
        }
        if policy == .auto, !Self.isOnExternalVolume(sourceURL) {
            access?.stop()
            return
        }
        let pendingBytes = queue.map(\.mediaFile.fileSize).reduce(0, +) + (activeJob?.mediaFile.fileSize ?? 0)
        guard hasLocalFreeSpace(for: mediaFile.fileSize, pendingBytes: pendingBytes) else {
            access?.stop()
            errorMessage = String(localized: "Not enough free space on this Mac to cache “\(mediaFile.relativePath)”.")
            return
        }

        queue.append(PendingCopy(mediaFile: mediaFile, policy: policy, access: access, sourceURL: sourceURL))
        persistNewEntry(mediaFile: mediaFile, root: root, policy: policy)
        pumpQueue()
    }

    private func upgradePolicy(mediaFileID: UUID) {
        guard let database else { return }
        Task {
            try? await database.setCachePolicy(mediaFileID: mediaFileID, policy: .manual)
            await reload()
        }
    }

    private func persistNewEntry(mediaFile: MediaFile, root: LibraryRoot, policy: EpisodeCachePolicy) {
        guard let database else { return }
        Task {
            try? await database.saveCacheEntry(EpisodeCacheEntry(
                mediaFileID: mediaFile.id,
                libraryRootID: root.id,
                relativePath: mediaFile.relativePath,
                fileName: (mediaFile.relativePath as NSString).lastPathComponent,
                fileSize: mediaFile.fileSize,
                state: .copying,
                policy: policy
            ))
            await reload()
        }
    }

    private func pumpQueue() {
        guard activeJob == nil, let job = queue.first else { return }
        queue.removeFirst()
        activeJob = job
        let progress = CopyProgress()
        activeProgress[job.mediaFile.id] = progress
        Task { [weak self] in
            await self?.performCopy(job, progress: progress)
            self?.activeProgress[job.mediaFile.id] = nil
            self?.activeJob = nil
            self?.pumpQueue()
        }
    }

    private func performCopy(_ job: PendingCopy, progress: CopyProgress) async {
        defer { job.access?.stop() }
        guard let database else { return }
        let destination = partialURL(mediaFileID: job.mediaFile.id, fileName: job.mediaFile.relativePath)
        try? FileManager.default.removeItem(at: destination)

        // Progress flows copy-thread → AsyncStream → this MainActor loop; the
        // detached task captures nothing but Sendable values, so no actor
        // isolation crosses with the store itself.
        let (stream, continuation) = AsyncStream<Int64>.makeStream()
        let sourceURL = job.sourceURL
        let progressRef = progress
        let chunkSize = Self.chunkSize
        let copyTask = Task.detached(priority: .utility) { () throws -> Int64 in
            defer { continuation.finish() }
            return try Self.copyFile(from: sourceURL, to: destination, chunkSize: chunkSize) { cumulative in
                if let snapshot = progressRef.report(cumulative, throttle: 0.25) {
                    continuation.yield(snapshot)
                }
                if progressRef.isCancelled { throw CancellationError() }
            }
        }

        var lastPublish = Date.distantPast
        var lastPersist = Date.distantPast
        for await bytes in stream {
            let now = Date()
            if now.timeIntervalSince(lastPublish) >= Self.publishInterval {
                lastPublish = now
                publishProgress(mediaFileID: job.mediaFile.id, bytes: bytes)
            }
            if now.timeIntervalSince(lastPersist) >= Self.persistInterval {
                lastPersist = now
                try? await database.updateCacheProgress(mediaFileID: job.mediaFile.id, bytesCopied: bytes)
            }
        }

        do {
            let copiedSize = try await copyTask.value
            let finalURL = finalURL(mediaFileID: job.mediaFile.id, fileName: job.mediaFile.relativePath)
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: destination, to: finalURL)
            try await database.markCacheComplete(mediaFileID: job.mediaFile.id, fileSize: copiedSize)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            // A user cancel already removed the row; other failures explain
            // themselves in the cache manager instead of vanishing silently.
            if !progress.isCancelled {
                try? await database.removeCacheEntry(mediaFileID: job.mediaFile.id)
                errorMessage = String(localized: "Could not cache “\(job.mediaFile.relativePath)”: \(error.localizedDescription)")
            }
        }
        await reload()
    }

    /// Chunked copy so progress can be surfaced and cancellation honored
    /// mid-file. Returns the number of bytes written.
    nonisolated private static func copyFile(
        from source: URL,
        to destination: URL,
        chunkSize: Int,
        onChunk: (Int64) throws -> Void
    ) throws -> Int64 {
        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let destHandle = try FileHandle(forWritingTo: destination)
        defer { try? destHandle.close() }
        var copied: Int64 = 0
        while let chunk = try sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty {
            try destHandle.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            try onChunk(copied)
        }
        try destHandle.synchronize()
        return copied
    }

    private func publishProgress(mediaFileID: UUID, bytes: Int64) {
        guard let index = entries.firstIndex(where: { $0.mediaFileID == mediaFileID }) else { return }
        entries[index].bytesCopied = min(bytes, entries[index].fileSize)
    }

    private func hasLocalFreeSpace(for bytes: Int64, pendingBytes: Int64) -> Bool {
        let values = try? cacheDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return free > bytes + pendingBytes + Self.freeSpaceMargin
    }

    /// A drive qualifies as "external" when it is a different volume than the
    /// one hosting the cache; a missing volume UUID falls back to the mount
    /// path, since removable media mounts under /Volumes.
    nonisolated static func isOnExternalVolume(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey]
        let volume = (try? url.resourceValues(forKeys: keys))?.volumeUUIDString
        let home = (try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: keys))?.volumeUUIDString
        if let volume, let home, !volume.isEmpty, !home.isEmpty {
            return volume != home
        }
        return url.path.hasPrefix("/Volumes/")
    }

    // MARK: - Playback-driven removal

    /// The "watched it, drop the buffer" rule: an auto cache for an episode
    /// closed at ≥90% disappears the moment playback ends. Manual copies are
    /// the user's to delete.
    func handlePlaybackFinished(episode: EpisodeMedia, completion: Double) {
        guard autoDeleteEnabled, completion >= 0.90 else { return }
        guard let entry = entriesByMediaFileID[episode.mediaFile.id], entry.policy == .auto else { return }
        removeEntry(mediaFileID: episode.mediaFile.id)
    }

    // MARK: - Manual removal

    func removeEntry(mediaFileID: UUID) {
        queue.removeAll { $0.mediaFile.id == mediaFileID }
        activeProgress[mediaFileID]?.cancel()
        if let entry = entriesByMediaFileID[mediaFileID] {
            try? FileManager.default.removeItem(at: finalURL(for: entry))
            try? FileManager.default.removeItem(at: partialURL(for: entry))
        }
        // An in-flight job owns files whose names derive from its source path.
        if let job = activeJob, job.mediaFile.id == mediaFileID {
            try? FileManager.default.removeItem(at: finalURL(mediaFileID: mediaFileID, fileName: job.mediaFile.relativePath))
            try? FileManager.default.removeItem(at: partialURL(mediaFileID: mediaFileID, fileName: job.mediaFile.relativePath))
        }
        Task { [database] in
            try? await database?.removeCacheEntry(mediaFileID: mediaFileID)
            await reload()
        }
    }

    func clearAll() {
        for entry in entries { removeEntry(mediaFileID: entry.mediaFileID) }
    }

    /// Drops every cached file belonging to one library root; used when that
    /// root is removed from the app (its DB rows cascade away on their own).
    func purgeEntries(libraryRootID: UUID) {
        for entry in entries where entry.libraryRootID == libraryRootID {
            removeEntry(mediaFileID: entry.mediaFileID)
        }
    }

    func revealInFinder(mediaFileID: UUID) {
        guard let entry = entriesByMediaFileID[mediaFileID], entry.state == .complete else { return }
        NSWorkspace.shared.activateFileViewerSelecting([finalURL(for: entry)])
    }

    // MARK: - Paths

    /// Cached files are keyed by the media-file UUID with the original
    /// extension preserved, so the container format still reads correctly.
    private func finalURL(mediaFileID: UUID, fileName: String) -> URL {
        let ext = (fileName as NSString).pathExtension
        let name = ext.isEmpty ? mediaFileID.uuidString : "\(mediaFileID.uuidString).\(ext)"
        return cacheDirectory.appending(path: name)
    }

    private func finalURL(for entry: EpisodeCacheEntry) -> URL {
        finalURL(mediaFileID: entry.mediaFileID, fileName: entry.fileName)
    }

    private func partialURL(mediaFileID: UUID, fileName: String) -> URL {
        finalURL(mediaFileID: mediaFileID, fileName: fileName).appendingPathExtension("partial")
    }

    private func partialURL(for entry: EpisodeCacheEntry) -> URL {
        partialURL(mediaFileID: entry.mediaFileID, fileName: entry.fileName)
    }
}
