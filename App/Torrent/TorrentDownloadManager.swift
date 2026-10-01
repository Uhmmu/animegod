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

    /// What the torrent calls itself once metadata arrives, else the name
    /// the magnet or the search gave it.
    ///
    /// The torrent's own name is preferred because an indexer's magnet often
    /// names every alias of the work at once — "尼古喵喵 / ヤニねこ / Yani Neko
    /// / Chainsmoker Cat" — and anything reading a series title back out of
    /// that picks an alias at random.
    var title: String {
        if let name = snapshot?.contentName, !name.isEmpty { return name }
        if let name = snapshot?.name, !name.isEmpty { return name }
        return record.title
    }

    var progress: Double { snapshot?.progress ?? (record.completedAt != nil ? 1 : 0) }
    /// Once the library has stamped a download complete it stays complete:
    /// the live state keeps moving (seeding, held back by the seed queue,
    /// paused by hand) and none of that undoes the fact that the file is on
    /// disk.
    var isComplete: Bool {
        if record.completedAt != nil { return true }
        if let state = snapshot?.state { return state == .finished || state == .seeding }
        return false
    }
    var isPaused: Bool { snapshot?.state == .paused }
    var totalBytes: Int64 { snapshot?.totalBytes ?? record.totalBytes }
    var downloadedBytes: Int64 { snapshot?.downloadedBytes ?? 0 }

    /// Everything this task has ever given back. libtorrent's all-time
    /// figure, which rides along in the resume data, so it survives a quit
    /// instead of resetting to zero every launch.
    var uploadedBytes: Int64 { snapshot?.uploadedBytes ?? 0 }
    var uploadRate: Int { Int(snapshot?.uploadRate ?? 0) }
    /// Uploading right now, as opposed to finished and stopped.
    var isSeeding: Bool { snapshot?.state == .seeding && !isPaused }
    /// Given back over taken: 1.0 is having returned the episode once. Nil
    /// until the size is known, because dividing by it is the whole point.
    var shareRatio: Double? {
        let total = totalBytes
        guard total > 0 else { return nil }
        return Double(uploadedBytes) / Double(total)
    }

    /// The episode this download is of, for showing a season in order before
    /// any of it is on disk. Read off the release name rather than the label,
    /// because a download added by hand has no label.
    var episodeNumber: Double? {
        if let label = record.episodeLabel, let value = Double(label) { return value }
        return TorrentEpisodeGuess.number(in: title)
    }

    /// What to call this row in a list of episodes: "EP 05", else the name.
    var episodeText: String? {
        episodeNumber.map { TorrentEpisodeGuess.text(for: $0) }
    }

    var statusText: String {
        guard let snapshot else { return record.completedAt != nil ? String(localized: "Completed") : String(localized: "Not running") }
        if let error = snapshot.errorMessage, !error.isEmpty { return error }
        switch snapshot.state {
        case .queued: return String(localized: "Queued")
        case .fetchingMetadata: return String(localized: "Fetching details from the swarm…")
        case .checking: return String(localized: "Checking existing files…")
        case .downloading:
            let rate = ByteCountFormatter.string(fromByteCount: Int64(snapshot.downloadRate), countStyle: .binary)
            let peers = String(localized: "\(snapshot.connectedSeeds) seeds · \(snapshot.connectedPeers) peers")
            return "\(rate)/s · \(peers)"
        case .finished, .seeding:
            let uploaded = ByteCountFormatter.string(fromByteCount: snapshot.uploadedBytes, countStyle: .binary)
            return snapshot.state == .seeding ? String(localized: "Seeding · \(uploaded) shared") : String(localized: "Completed")
        case .paused: return String(localized: "Paused")
        case .errored: return snapshot.errorMessage ?? String(localized: "Failed")
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
    /// Short-lived note about what just happened (a move, a folder change).
    @Published var statusMessage: String?
    /// Called once per download when it completes, so the library can pick
    /// the files up.
    var onDownloadFinished: ((TorrentDownloadRecord) -> Void)?
    /// Called with the work a newly started download is of, so it can be
    /// matched to an anime while it downloads rather than afterwards. Fires
    /// once per work: a set is one show, not twelve.
    var onWorkStarted: ((String) -> Void)?

    /// Unpack `.rar`/`.zip`/`.7z` releases once they finish. On by default:
    /// an archive that is not opened is a download with no episode in it.
    @Published var extractsArchives: Bool {
        didSet { UserDefaults.standard.set(extractsArchives, forKey: Self.extractsArchivesKey) }
    }
    private static let extractsArchivesKey = "torrent.extractArchives"

    /// Whether a finished download goes on sharing itself.
    ///
    /// **Off by default.** Seeding is giving back, not a feature of watching
    /// anime: it costs upload bandwidth for as long as the app is open, and
    /// on a metered or shared connection — a dorm, a phone hotspot — that is
    /// the user's cost, not ours to assume. Switching it off stops every
    /// task that has already finished, not just the next one.
    @Published var seedsAfterDownloading: Bool {
        didSet {
            UserDefaults.standard.set(seedsAfterDownloading, forKey: Self.seedsAfterDownloadingKey)
            engine?.seedsWhenComplete = seedsAfterDownloading
            refresh()
        }
    }
    private static let seedsAfterDownloadingKey = "torrent.seedsAfterDownloading"

    /// How many tasks download at once; the rest wait their turn in the
    /// engine's queue. Four, not twelve: a whole season started together
    /// would split one connection budget twelve ways and finish nothing,
    /// and episodes are watched in order anyway.
    @Published var maximumActiveDownloads: Int {
        didSet {
            UserDefaults.standard.set(maximumActiveDownloads, forKey: Self.maximumActiveDownloadsKey)
            engine?.maximumActiveDownloads = Int32(maximumActiveDownloads)
        }
    }
    private static let maximumActiveDownloadsKey = "torrent.maxActiveDownloads"
    static let activeDownloadChoices = [1, 2, 3, 4, 6, 8]
    static let defaultActiveDownloads = 4

    /// Ceiling for everything downloading, in KiB/s; 0 is unlimited.
    ///
    /// BitTorrent will use every byte of a connection it is given, which is
    /// why a download in the background makes everything else on the network
    /// unusable. The ceiling is the cure, and it belongs next to the
    /// downloads rather than buried in Settings — hence here *and* there.
    @Published var downloadRateLimitKB: Int {
        didSet {
            UserDefaults.standard.set(downloadRateLimitKB, forKey: Self.downloadRateLimitKey)
            engine?.downloadRateLimit = Self.bytesPerSecond(downloadRateLimitKB)
        }
    }
    /// Ceiling for seeding, in KiB/s; 0 is unlimited. Uploading is how a
    /// swarm stays alive, so this defaults to unlimited too.
    @Published var uploadRateLimitKB: Int {
        didSet {
            UserDefaults.standard.set(uploadRateLimitKB, forKey: Self.uploadRateLimitKey)
            engine?.uploadRateLimit = Self.bytesPerSecond(uploadRateLimitKB)
        }
    }
    /// Ceiling for one download a subscription started on its own, in KiB/s;
    /// 0 is unlimited. Separate from the general one because an unattended
    /// download is the one nobody is waiting for.
    @Published var automaticRateLimitKB: Int {
        didSet {
            UserDefaults.standard.set(automaticRateLimitKB, forKey: Self.automaticRateLimitKey)
            applyAutomaticRateLimits()
        }
    }
    private static let downloadRateLimitKey = "torrent.downloadRateLimitKB"
    private static let uploadRateLimitKey = "torrent.uploadRateLimitKB"
    private static let automaticRateLimitKey = "torrent.automaticRateLimitKB"
    /// 0 is "unlimited"; the rest are the speeds a home connection actually
    /// has, so the menu is short enough to pick from.
    static let rateLimitChoices = [0, 256, 512, 1024, 2048, 5120, 10240, 20480]

    static func bytesPerSecond(_ kilobytes: Int) -> Int32 {
        kilobytes <= 0 ? 0 : Int32(clamping: kilobytes * 1024)
    }

    /// "Unlimited", "1 MB/s", "512 KB/s" — used by both places that show it.
    static func rateLimitText(_ kilobytes: Int) -> String {
        guard kilobytes > 0 else { return String(localized: "Unlimited") }
        return ByteCountFormatter.string(fromByteCount: Int64(kilobytes) * 1024, countStyle: .binary) + "/s"
    }

    let folders: DownloadFolderStore
    private var database: LibraryDatabase?
    private var engine: AGTorrentEngine?
    private var records: [String: TorrentDownloadRecord] = [:]
    private var refreshTimer: Timer?
    /// Tasks already stopped for missing files, so one moved folder does not
    /// re-report itself every second.
    private var hashesWithMissingFiles: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    /// Preferred listen port; libtorrent picks another if it is taken.
    private static let listenPort: Int32 = 6881

    init(folders: DownloadFolderStore = DownloadFolderStore()) {
        self.folders = folders
        extractsArchives = UserDefaults.standard.object(forKey: Self.extractsArchivesKey) as? Bool ?? true
        seedsAfterDownloading = UserDefaults.standard.object(forKey: Self.seedsAfterDownloadingKey) as? Bool ?? false
        maximumActiveDownloads = UserDefaults.standard.object(forKey: Self.maximumActiveDownloadsKey) as? Int
            ?? Self.defaultActiveDownloads
        downloadRateLimitKB = UserDefaults.standard.object(forKey: Self.downloadRateLimitKey) as? Int ?? 0
        uploadRateLimitKB = UserDefaults.standard.object(forKey: Self.uploadRateLimitKey) as? Int ?? 0
        // An unattended download is capped by default: it starts while the
        // Mac is being used for something else.
        automaticRateLimitKB = UserDefaults.standard.object(forKey: Self.automaticRateLimitKey) as? Int ?? 2048
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
            // One-shot maintenance: relocate existing tasks into the folder
            // now configured, without interrupting them.
            if ProcessInfo.processInfo.arguments.contains("-moveDownloadsToCurrentFolder") {
                moveAllToCurrentFolder()
            }
        }
    }

    var isEngineRunning: Bool { engine != nil && sessionInfo?.isRunning == true }

    var activeCount: Int {
        items.filter { !$0.isComplete && !$0.isPaused }.count
    }

    // MARK: - Seeding

    /// The finished downloads — the rows the Seeding section lists. One that
    /// is still arriving has nothing to share yet, so it stays in Downloads.
    var completedItems: [TorrentDownloadItem] {
        items.filter(\.isComplete)
    }

    /// How many finished downloads are uploading this second. The sidebar
    /// badge, and the honest answer to "is it actually sharing?" — a task can
    /// be finished, listed and stopped all at once.
    var seedingCount: Int {
        guard seedsAfterDownloading else { return 0 }
        return items.filter(\.isSeeding).count
    }

    /// Everything this Mac has ever given back, across the tasks the engine
    /// still knows about. A removed download takes its share with it, which
    /// is the right answer for a figure that is about what is being shared.
    var sharedBytes: Int64 {
        items.reduce(0) { $0 + $1.uploadedBytes }
    }

    /// Stops one finished download sharing, leaving the rest alone.
    ///
    /// This is the user's own stop, so it clears the auto-managed flag and
    /// the task reads as Paused: turning the switch off and on again must not
    /// quietly restart something they stopped by hand.
    func stopSeeding(_ item: TorrentDownloadItem) {
        engine?.pause(item.record.infoHash)
        refresh()
    }

    /// Shares one finished download again. Only offered while the switch is
    /// on — with the seed queue shut, resuming a task would last exactly one
    /// of the queue's ticks, and a button that undoes itself is worse than no
    /// button.
    func startSeeding(_ item: TorrentDownloadItem) {
        guard seedsAfterDownloading else { return }
        startEngineIfNeeded()?.resume(item.record.infoHash)
        refresh()
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
            preferTCP: false,
            // Handed over at construction, not set afterwards: the engine
            // resumes last session's tasks inside its initializer, and a
            // finished season must not share a byte before the switch is
            // read.
            seedsWhenComplete: seedsAfterDownloading
        )
        if let failure = engine.startupError {
            errorMessage = String(localized: "The download engine could not start: \(failure)")
            return nil
        }
        engine.maximumActiveDownloads = Int32(maximumActiveDownloads)
        engine.downloadRateLimit = Self.bytesPerSecond(downloadRateLimitKB)
        engine.uploadRateLimit = Self.bytesPerSecond(uploadRateLimitKB)
        self.engine = engine
        startRefreshing()
        // Per-task ceilings do not survive a restart reliably, so the
        // automatic ones are re-applied every time the engine comes up.
        applyAutomaticRateLimits()
        return engine
    }

    // MARK: - New episodes nobody has looked at yet

    /// Automatic downloads the user has already been shown, so the "a new
    /// episode arrived" marker on a library card clears when they open it.
    ///
    /// The *seen* side is stored rather than the unseen side: it is what the
    /// user did, it never needs recomputing after a scan, and a download that
    /// is removed takes its entry with it on the next launch.
    private var seenAutomaticHashes: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "torrent.seenAutomaticDownloads") ?? []
    )
    private static let seenAutomaticKey = "torrent.seenAutomaticDownloads"

    /// A subscription has finished an episode of this anime that the user has
    /// not been shown yet — what fills the subscription badge on its card.
    func hasUnseenAutomaticDownload(animeID: UUID) -> Bool {
        items.contains { item in
            item.record.animeID == animeID
                && item.record.isAutomatic
                && item.isComplete
                && !seenAutomaticHashes.contains(item.record.infoHash)
        }
    }

    /// Called when the work's page is opened: the marker has done its job.
    func markAutomaticDownloadsSeen(animeID: UUID) {
        let finished = items.filter {
            $0.record.animeID == animeID && $0.record.isAutomatic && $0.isComplete
        }.map(\.record.infoHash)
        let unseen = finished.filter { !seenAutomaticHashes.contains($0) }
        guard !unseen.isEmpty else { return }
        seenAutomaticHashes.formUnion(unseen)
        // Only hashes still in the list are worth remembering.
        let live = Set(records.keys)
        seenAutomaticHashes = seenAutomaticHashes.intersection(live)
        UserDefaults.standard.set(Array(seenAutomaticHashes), forKey: Self.seenAutomaticKey)
        objectWillChange.send()
    }

    /// Holds every subscription-started download to the automatic ceiling.
    private func applyAutomaticRateLimits() {
        guard let engine else { return }
        let limit = Self.bytesPerSecond(automaticRateLimitKB)
        for record in records.values where record.isAutomatic {
            engine.setRateLimit(limit, forInfoHash: record.infoHash)
        }
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
        sequential: Bool = false,
        folderName: String? = nil
    ) {
        // A download started from an anime's own page belongs in that
        // anime's folder even on its own: the next episode grabbed the same
        // way joins it instead of starting a folder of its own.
        var folder = folderName
        if folder == nil, let title = anime?.title {
            let sanitised = TorrentDownloadFolder.sanitised(title)
            folder = sanitised.isEmpty ? nil : sanitised
        }
        add(
            magnet: result.magnet.uri,
            infoHash: result.infoHash.hex,
            title: result.title,
            trackers: result.trackers,
            animeID: anime?.id,
            animeTitle: anime?.title,
            episodeLabel: result.release.episodeLabel,
            sequential: sequential,
            folderName: folder
        )
        // Only a download that arrived without an anime needs asking about:
        // one started from an anime's own page is already linked. The
        // listener answers per work, so a whole set asks once.
        //
        // The folder is the key rather than the series title read off this one
        // release: it is what every episode of the set shares, and what the
        // library will name the work when the files land. Keying on the
        // per-release title instead is how a season ended up matched under a
        // name the scan never used — an anime page with no episodes in it.
        if anime == nil, let key = folder ?? TorrentDownloadFolder.sharedSeriesTitle(of: [result.title]) {
            onWorkStarted?(key)
        }
    }

    /// Starts several releases picked out of one search.
    ///
    /// Choosing twelve rows and pressing Download is the same intent as
    /// pressing Download Set, so they are treated the same: if the releases
    /// turn out to be of one work, they share its folder.
    func download(
        _ results: [TorrentSearchResult],
        anime: Anime? = nil,
        sequential: Bool = false
    ) {
        let folderName = TorrentDownloadFolder.name(
            animeTitle: anime?.title,
            releaseNames: results.map(\.title)
        )
        for result in results {
            download(result, anime: anime, sequential: sequential, folderName: folderName)
        }
    }

    /// Starts every episode of an assembled set, in episode order.
    ///
    /// All of them are handed to the engine at once and its queue keeps
    /// `maximumActiveDownloads` running, so the season arrives episode by
    /// episode rather than as twelve part-files creeping forward together.
    /// Episodes already in Downloads are skipped, not reported as errors —
    /// re-running a set to pick up what a fansub published since is the
    /// normal way to use this.
    /// What starting a set did: how many episodes went to the engine, and the
    /// one folder they share. The folder is what a subscription made from the
    /// same set records, so the episode it fetches next month lands beside
    /// them instead of starting a folder of its own.
    struct SetDownload {
        var started: Int
        var skipped: Int
        var folderName: String?
    }

    @discardableResult
    func download(
        set: TorrentEpisodeSet,
        anime: Anime? = nil,
        includingOwned: Bool = false,
        sequential: Bool = false,
        announces: Bool = true
    ) -> SetDownload {
        let entries = (includingOwned ? set.entries.filter { !$0.isExtra } : set.downloadableEntries)
            .sorted { $0.episode < $1.episode }
        let folderName = set.suggestedFolderName(animeTitle: anime?.title)
        var started = 0
        var skipped = 0
        for entry in entries {
            guard records[entry.result.infoHash.hex.lowercased()] == nil else {
                skipped += 1
                continue
            }
            download(entry.result, anime: anime, sequential: sequential, folderName: folderName)
            started += 1
        }
        let name = set.group ?? anime?.title ?? String(localized: "this search")
        if announces {
            if started == 0 {
                statusMessage = skipped > 0
                    ? String(localized: "Every episode of \(name) is already in Downloads.")
                    : String(localized: "There is nothing left to download in \(name).")
            } else {
                statusMessage = String(localized: "Queued \(started) episodes of \(name) · \(maximumActiveDownloads) download at a time.")
            }
        }
        return SetDownload(started: started, skipped: skipped, folderName: folderName)
    }

    @discardableResult
    func add(
        magnet: String,
        infoHash: String,
        title: String,
        trackers: [String] = [],
        animeID: UUID? = nil,
        animeTitle: String? = nil,
        episodeLabel: String? = nil,
        sequential: Bool = false,
        folderName: String? = nil,
        isAutomatic: Bool = false,
        subscriptionID: UUID? = nil,
        reportsDuplicates: Bool = true
    ) -> Bool {
        guard let engine = startEngineIfNeeded() else { return false }
        if records[infoHash.lowercased()] != nil {
            // A subscription re-offering a release it already took is
            // ordinary, not an error worth a banner.
            if reportsDuplicates {
                errorMessage = String(localized: "“\(title)” is already in Downloads.")
            }
            return false
        }
        // An episode joining a season already on disk goes where that season
        // is, even if the download folder has been changed since.
        let folder = folderName.flatMap(savePath(forFolderNamed:)) ?? folders.folderForNewDownload()
        do {
            let hash = try engine.addMagnet(
                magnet,
                savePath: folder,
                sequential: sequential,
                folderName: folderName
            )
            if !trackers.isEmpty { engine.addTrackers(trackers, forInfoHash: hash) }
            if isAutomatic {
                engine.setRateLimit(Self.bytesPerSecond(automaticRateLimitKB), forInfoHash: hash)
            }
            let record = TorrentDownloadRecord(
                infoHash: hash,
                title: title,
                magnet: magnet,
                savePath: folder.path,
                animeID: animeID,
                animeTitle: animeTitle,
                episodeLabel: episodeLabel,
                folderName: folderName,
                isAutomatic: isAutomatic,
                subscriptionID: subscriptionID,
                isSequential: sequential
            )
            records[record.infoHash] = record
            Task { try? await database?.saveTorrentDownload(record) }
            refresh()
            return true
        } catch {
            errorMessage = String(localized: "Could not start the download: \(error.localizedDescription)")
            return false
        }
    }

    /// Where a folder this library already downloaded into lives, so a later
    /// episode of the same season joins it rather than starting a second copy
    /// of the folder somewhere else.
    private func savePath(forFolderNamed name: String) -> URL? {
        let existing = records.values
            .filter { $0.folderName == name }
            .max { $0.addedAt < $1.addedAt }
        guard let existing else { return nil }
        // A path alone is not writable inside the sandbox: the scope granted
        // for that folder has to be open, which only the folder store can do.
        // Without this the episode would land in the container instead, and
        // the season would be split across two places.
        return folders.accessibleURL(forPath: existing.savePath)
    }

    // MARK: - Controlling

    func pause(_ item: TorrentDownloadItem) {
        engine?.pause(item.record.infoHash)
        refresh()
    }

    func resume(_ item: TorrentDownloadItem) {
        // Resuming is the user saying "fetch it again", so the stop for
        // missing files is lifted and can be applied afresh next time.
        hashesWithMissingFiles.remove(item.record.infoHash.lowercased())
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

    /// Moves a task's files into the current download folder, keeping it
    /// seeding. Used when the folder changes after a download started.
    func moveToCurrentFolder(_ item: TorrentDownloadItem) {
        let destination = folders.folderForNewDownload()
        guard destination.path != (item.snapshot?.savePath ?? item.record.savePath) else { return }
        guard let engine else {
            errorMessage = String(localized: "The download engine is not running, so files cannot be moved.")
            return
        }
        engine.moveStorage(item.record.infoHash, toFolder: destination)
        var record = item.record
        record.savePath = destination.path
        records[record.infoHash] = record
        let saved = record
        Task { try? await database?.saveTorrentDownload(saved) }
        statusMessage = String(localized: "Moving “\(item.title)” to \(destination.lastPathComponent)…")
        refresh()
    }

    /// Moves every task that is not already in the current folder.
    func moveAllToCurrentFolder() {
        for item in items { moveToCurrentFolder(item) }
    }

    /// Links every download of one work to the anime it turned out to be.
    ///
    /// Called when a work is matched while it is still downloading, so the
    /// rows stop being anonymous magnets: the library can draw their cover,
    /// open their page, and count them as one show.
    func link(seriesTitle: String, toAnimeID animeID: UUID, title: String) async {
        let key = TorrentDownloadFolder.sanitised(seriesTitle)
        let matching = records.values.filter { record in
            guard record.animeID == nil else { return false }
            // The folder every episode of the work was put into is the
            // reliable key: it is chosen when the download starts, shared by
            // the whole season, and does not depend on metadata having
            // arrived. A download that predates folders falls back to the
            // series title read off its name.
            if let folder = record.folderName {
                return folder == key || folder.hasPrefix(key + " S")
            }
            return seriesTitle == TorrentDownloadFolder.sharedSeriesTitle(of: [displayName(of: record)])
        }
        guard !matching.isEmpty else { return }
        for var record in matching {
            record.animeID = animeID
            record.animeTitle = title
            records[record.infoHash] = record
            let saved = record
            try? await database?.saveTorrentDownload(saved)
        }
        refresh()
    }

    /// The name a record is known by right now — the torrent's own once
    /// metadata has arrived, which is what grouping keys on everywhere else.
    private func displayName(of record: TorrentDownloadRecord) -> String {
        engine?.snapshot(forInfoHash: record.infoHash)?.contentName ?? record.title
    }

    /// The one work a download belongs to, as a key to group by.
    ///
    /// The anime it is linked to when it has one, else the folder its files
    /// were put into — which a whole season shares from the moment it starts,
    /// with no metadata and no engine needed. The series title read off the
    /// release name is the last resort, for downloads added before folders
    /// existed; on its own it split a season into twelve cards whenever one
    /// episode's name parsed a little differently from the rest.
    func seriesKey(of item: TorrentDownloadItem) -> String {
        if let animeID = item.record.animeID { return "anime:\(animeID.uuidString)" }
        if let folder = item.record.folderName, !folder.isEmpty { return "folder:\(folder)" }
        if let series = TorrentDownloadFolder.sharedSeriesTitle(of: [item.title]) { return "series:\(series)" }
        return "hash:\(item.record.infoHash)"
    }

    /// Every download of one work, newest episode last — what a work's page
    /// lists while its episodes are still arriving.
    func items(ofWorkLike item: TorrentDownloadItem) -> [TorrentDownloadItem] {
        let key = seriesKey(of: item)
        return items.filter { seriesKey(of: $0) == key }
    }

    /// Every download bound to one anime, complete or not.
    func items(forAnimeID animeID: UUID) -> [TorrentDownloadItem] {
        items.filter { $0.record.animeID == animeID }
    }

    /// What the work being downloaded is called before it has been matched:
    /// the folder its episodes share, else the series title off its name.
    func workTitle(of item: TorrentDownloadItem) -> String {
        if let title = item.record.animeTitle, !title.isEmpty { return title }
        if let folder = item.record.folderName, !folder.isEmpty { return folder }
        return TorrentDownloadFolder.sharedSeriesTitle(of: [item.title]) ?? item.title
    }

    /// Every download of the same work as `item`, itself included — what
    /// "gather this into one folder" acts on.
    ///
    /// A download started from an anime's own page goes by what it is bound
    /// to. One started from a plain search is bound to nothing, so the
    /// series title read out of the release names stands in: that is how the
    /// twelve episodes of a set are recognised as one season.
    func siblings(of item: TorrentDownloadItem) -> [TorrentDownloadItem] {
        items(ofWorkLike: item)
    }

    /// The folder these downloads would be gathered into. Nil when there is
    /// nothing to name it after, when they are all in it already, or when
    /// there is only one — moving a lone download achieves nothing.
    func gatherFolderName(for items: [TorrentDownloadItem]) -> String? {
        guard items.count > 1 else { return nil }
        guard let name = TorrentDownloadFolder.name(
            animeTitle: items.compactMap(\.record.animeTitle).first,
            releaseNames: items.map(\.title)
        ) else { return nil }
        let alreadyThere = items.allSatisfy {
            $0.record.folderName == name || engine?.contentFolderName(forInfoHash: $0.record.infoHash) == name
        }
        return alreadyThere ? nil : name
    }

    /// Puts downloads that arrived one at a time into a single folder, the
    /// way a set started in one go already arrives. The engine moves the
    /// files — so seeding carries on from the new location — and removes the
    /// folders it empties doing so.
    func gatherIntoOneFolder(_ items: [TorrentDownloadItem], named name: String) {
        guard let engine else {
            errorMessage = String(localized: "The download engine is not running, so files cannot be moved.")
            return
        }
        for item in items {
            engine.gather(item.record.infoHash, intoFolder: name)
            var record = item.record
            record.folderName = name
            records[record.infoHash] = record
            let saved = record
            Task { try? await database?.saveTorrentDownload(saved) }
        }
        statusMessage = String(localized: "Moving \(items.count) downloads into “\(name)”…")
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
        if let target = contentFolder(for: item), FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    /// Where a task's files actually are: the folder the torrent brought,
    /// or the one the engine created for a single-file download.
    func contentFolder(for item: TorrentDownloadItem) -> URL? {
        let root = URL(fileURLWithPath: item.snapshot?.savePath ?? item.record.savePath)
        let name = engine?.contentFolderName(forInfoHash: item.record.infoHash)
            ?? item.record.folderName
        guard let name, !name.isEmpty else {
            let fallback = item.snapshot?.name ?? ""
            return fallback.isEmpty ? nil : root.appending(path: fallback)
        }
        return root.appending(path: name)
    }

    /// The video file worth offering a Play button for: the largest one,
    /// once `TorrentPlaybackReadiness` says enough of its beginning is on
    /// disk.
    func playableVideoFile(for item: TorrentDownloadItem) -> AGTorrentFileEntry? {
        guard let file = videoFiles(for: item).first else { return nil }
        return TorrentPlaybackReadiness.isPlayable(
            fileLength: file.length,
            downloadedBytes: file.downloadedBytes,
            isSequential: item.record.isSequential || item.snapshot?.sequential == true,
            isComplete: item.isComplete
        ) ? file : nil
    }

    /// Opens a file from a download in the player. The engine is told to
    /// fetch that file's pieces in order and first, so playback stays ahead
    /// of the download.
    func play(_ file: AGTorrentFileEntry, of item: TorrentDownloadItem, using model: AppModel) {
        let url = URL(fileURLWithPath: item.snapshot?.savePath ?? item.record.savePath)
            .appending(path: file.path)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            errorMessage = String(localized: "That file is not on disk yet.")
            return
        }
        if !item.isComplete {
            engine?.prioritiseFile(forPlayback: file.index, forInfoHash: item.record.infoHash)
            setSequential(true, for: item)
        }
        model.playFile(at: url, title: file.path, infoHash: item.record.infoHash)
    }

    /// Video files inside a task, largest first — what the user would play.
    func videoFiles(for item: TorrentDownloadItem) -> [AGTorrentFileEntry] {
        let extensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts", "iso"]
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
            errorMessage = String(localized: "Could not read saved downloads: \(error.localizedDescription)")
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
        pauseTasksWhoseFilesAreGone(snapshots)
    }

    /// A finished download whose files are no longer where the engine left
    /// them is paused, not fetched all over again.
    ///
    /// Moving a finished episode in the Finder is an ordinary thing to do,
    /// and libtorrent's answer to a file that is not there is to download it
    /// from scratch — which is how one episode of a season came back as a
    /// second 600 MB copy in a folder of its own. Stopping and saying so
    /// costs the user a click; the alternative costs them the download.
    private func pauseTasksWhoseFilesAreGone(_ snapshots: [AGTorrentSnapshot]) {
        for snapshot in snapshots {
            let hash = snapshot.infoHash.lowercased()
            guard !hashesWithMissingFiles.contains(hash) else { continue }
            guard let record = records[hash], record.completedAt != nil else { continue }
            guard snapshot.hasMetadata, snapshot.progress < 1 else { continue }
            guard snapshot.state != .paused, snapshot.state != .checking else { continue }
            let files = fileURLs(forInfoHash: hash)
            guard !files.isEmpty else { continue }
            guard files.contains(where: { !FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            hashesWithMissingFiles.insert(hash)
            engine?.pause(hash)
            errorMessage = String(localized: "“\(record.title)” has finished, but its files are no longer where it left them. It is paused rather than downloaded again — move them back, or resume it to fetch them afresh.")
        }
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
            let name = snapshot.contentName ?? (snapshot.name.isEmpty ? nil : snapshot.name)
            let changedTitle = name != nil && name != record.title ? name : nil
            let changedSize = snapshot.totalBytes > 0 && snapshot.totalBytes != record.totalBytes ? snapshot.totalBytes : nil
            let completedAt: Date? = (isComplete && record.completedAt == nil) ? .now : nil
            guard changedTitle != nil || changedSize != nil || completedAt != nil else { continue }

            if let changedTitle { record.title = changedTitle }
            if let changedSize { record.totalBytes = changedSize }
            if let completedAt { record.completedAt = completedAt }
            records[hash] = record
            if completedAt != nil { finish(record, files: fileURLs(forInfoHash: hash)) }
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

    /// Every file of a task, where it sits on disk.
    private func fileURLs(forInfoHash hash: String) -> [URL] {
        guard let record = records[hash], let files = engine?.files(forInfoHash: hash) else { return [] }
        let root = URL(fileURLWithPath: record.savePath)
        return files.map { root.appending(path: $0.path) }
    }

    /// What happens the moment a download completes: archives are unpacked
    /// where they landed, and only then is the library told to look, so the
    /// scan that follows sees episodes rather than `.rar` files.
    ///
    /// Only this task's own files are opened. A set shares one folder, so
    /// unpacking the folder would reach into episodes that are still
    /// arriving.
    ///
    /// Unpacking is best-effort. A release that cannot be opened is reported
    /// and the download still counts as finished.
    private func finish(_ record: TorrentDownloadRecord, files: [URL]) {
        guard extractsArchives, !files.isEmpty else {
            onDownloadFinished?(record)
            return
        }
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                ArchiveExtractor.extractAll(files: files)
            }.value
            guard let self else { return }
            if !outcome.extracted.isEmpty {
                let names = outcome.extracted.map(\.lastPathComponent).joined(separator: ", ")
                self.statusMessage = String(localized: "Unpacked “\(record.title)” into \(names).")
            }
            if let failure = outcome.failures.first {
                self.errorMessage = failure
            }
            self.onDownloadFinished?(record)
        }
    }
}
