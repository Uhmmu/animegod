import AnimeGodCore
import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var roots: [LibraryRoot] = []
    @Published private(set) var library: [LibraryAnime] = []
    @Published private(set) var continueWatching: [EpisodeMedia] = []
    @Published private(set) var metadataByAnimeID: [UUID: AnimeMetadata] = [:]
    @Published private(set) var metadataSourcesByAnimeID: [UUID: [AnimeMetadata]] = [:]
    @Published private(set) var matchLinksByAnimeID: [UUID: [MetadataProviderID: MatchLink]] = [:]
    @Published private(set) var communityByAnimeID: [UUID: [CommunityPost]] = [:]
    @Published private(set) var profilesByAnimeID: [UUID: AnimeProfile] = [:]
    @Published private(set) var watchHistory: [WatchEvent] = []
    @Published private(set) var diarySummary = DiarySummary(totalWatchTime: 0, sessionCount: 0, completedEpisodeCount: 0, animeCount: 0)
    @Published private(set) var pendingMatches: [PendingMetadataMatch] = []
    /// Set when an automatic pass ended with matches it could not make on its
    /// own. RootView shows the review sheet off this.
    @Published var wantsMatchReview = false
    @Published private(set) var statisticsReport: StatisticsReport?
    @Published private(set) var isScanning = false
    @Published private(set) var isEnrichingMetadata = false
    @Published private(set) var metadataProgress: String?
    @Published private(set) var availableRootIDs: Set<UUID> = []
    @Published var errorMessage: String?
    @Published var playerRequest: PlayerRequest?

    private var database: LibraryDatabase?
    private let scanner = LibraryScanner()
    let translation = TranslationCoordinator()
    /// App-wide danmaku preferences (enabled + presentation + provider
    /// credentials in the local credential file). Owned here so the player and Settings
    /// observe the same instance.
    let danmakuPreferences = DanmakuPreferences()
    /// Online subtitle settings, provider credentials and the
    /// subtitle cache, shared by every player window and Settings.
    let subtitlePreferences = SubtitlePreferences()
    /// Local episode copies: auto-cached while playing from an external
    /// drive, manually cacheable, playable when the drive is unplugged.
    let episodeCache = EpisodeCacheStore()
    /// The embedded BitTorrent engine and the downloads it is running.
    let downloads = TorrentDownloadManager()
    /// Standing rules that download new episodes on their own.
    let subscriptions: TorrentSubscriptionManager
    /// Which anime indexes release searches use, plus recent searches.
    let torrentSources: TorrentSourcePreferences
    /// The sidebar's release search, kept alive so results survive switching
    /// sections.
    let releaseSearch: TorrentSearchModel
    /// Read access for player-owned subsystems (danmaku cache/match).
    var libraryDatabase: LibraryDatabase? { database }
    private let metadataProviders: [MetadataProviderID: any MetadataProvider] = [
        .bangumi: BangumiMetadataProvider(),
        .anilist: AniListMetadataProvider()
    ]
    private let metadataMatcher = MetadataMatcher()
    /// Failures in a row before a provider is given up on for the rest of an
    /// enrichment pass.
    private static let providerFailureLimit = 3
    /// `-traceEnrichment` prints what each provider was asked and answered.
    private static let tracesEnrichment = ProcessInfo.processInfo.arguments.contains("-traceEnrichment")
    private var cancellables: Set<AnyCancellable> = []
    /// Older caches predate Bangumi shoutbox support. Attempt one transparent
    /// upgrade per title and app run without repeatedly hitting empty subjects.
    private var shoutboxUpgradeAttempts: Set<UUID> = []

    init() {
        let torrentSources = TorrentSourcePreferences()
        self.torrentSources = torrentSources
        releaseSearch = TorrentSearchModel(preferences: torrentSources)
        subscriptions = TorrentSubscriptionManager(preferences: torrentSources)
        // Republish translation and danmaku preference state so views
        // observing only AppModel update while batches/settings change.
        // `downloads` is deliberately not in this list: it publishes once a
        // second for as long as a task exists, and republishing that through
        // AppModel re-rendered every view in the app — including the library
        // grid mid-scroll. Its consumers observe it directly instead.
        translation.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        danmakuPreferences.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        subtitlePreferences.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        episodeCache.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        subscriptions.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Plugging a drive back in (or pulling it) changes which episodes can
        // play from source, so the library reflects mount state immediately.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in Task { await self?.refreshRootAvailability() } }
                .store(in: &cancellables)
        }
        Task { await prepare() }
    }

    func chooseLibraryRoot() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an anime library folder")
        panel.prompt = String(localized: "Add Library")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task {
            for url in panel.urls { await addLibraryRoot(url) }
        }
    }

    func addLibraryRoot(_ url: URL) async {
        guard let database else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let root = LibraryRoot(displayName: url.lastPathComponent, lastKnownPath: url.path, bookmarkData: bookmark)
            try await database.save(root: root)
            roots = try await database.libraryRoots()
            await scan(root)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scanAll() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        for root in roots { await scan(root, managesScanningState: false) }
        await reloadLibrary()
        enrichInBackground()
    }

    /// Looks up whatever the library is missing, without making anyone wait
    /// for it. Detached from the caller because a full pass takes minutes —
    /// AniList allows 30 requests a minute — and nothing on screen depends on
    /// it finishing.
    private func enrichInBackground() {
        guard !isEnrichingMetadata else { return }
        Task { [weak self] in
            // Let the scan's own work settle before adding network traffic.
            try? await Task.sleep(for: .seconds(2))
            await self?.enrichLibraryMetadata(isAutomatic: true)
        }
    }

    func scan(_ root: LibraryRoot, managesScanningState: Bool = true) async {
        guard let database else { return }
        if managesScanningState { isScanning = true }
        defer { if managesScanningState { isScanning = false } }
        do {
            let access = try ScopedLibraryAccess(root: root)
            defer { access.stop() }
            // An unplugged drive keeps its index untouched: scanning an
            // absent folder would read as "every file removed".
            guard FileManager.default.fileExists(atPath: access.url.path) else {
                await refreshRootAvailability()
                return
            }
            let result = try await scanner.scan(root: root, resolvedURL: access.url)
            try await database.importScan(result)
            await episodeCache.reconcile()
            roots = try await database.libraryRoots()
            await reloadLibrary()
            await refreshRootAvailability()
            // A full sweep calls this once at the end instead, so scanning
            // five roots does not queue five passes.
            if managesScanningState { enrichInBackground() }
        } catch {
            errorMessage = String(localized: "Could not scan \(root.displayName): \(error.localizedDescription)")
        }
    }

    /// Which library roots currently have their volume mounted. Unplugged
    /// roots keep their entries visible; they just cannot play uncached
    /// episodes or start new caches.
    func refreshRootAvailability() async {
        var available = Set<UUID>()
        for root in roots {
            guard let access = try? ScopedLibraryAccess(root: root) else { continue }
            let exists = FileManager.default.fileExists(atPath: access.url.path)
            access.stop()
            if exists { available.insert(root.id) }
        }
        availableRootIDs = available
    }

    func remove(_ root: LibraryRoot) async {
        guard let database else { return }
        episodeCache.purgeEntries(libraryRootID: root.id)
        do {
            try await database.removeLibraryRoot(id: root.id)
            roots = try await database.libraryRoots()
            await reloadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func episodes(for anime: Anime) async -> [EpisodeMedia] {
        do { return try await database?.episodes(animeID: anime.id) ?? [] }
        catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func play(_ episode: EpisodeMedia) async {
        guard let database else { return }
        guard roots.first(where: { $0.id == episode.mediaFile.libraryRootID }) != nil else {
            errorMessage = "The library folder for this episode is unavailable."
            return
        }
        // Load the full episode list so the player can navigate without
        // closing the window between episodes.
        let siblings = (try? await database.episodes(animeID: episode.episode.animeID)) ?? []
        let list = siblings.contains(where: { $0.id == episode.id }) ? siblings : [episode]
        guard let index = list.firstIndex(where: { $0.id == episode.id }) else { return }
        playerRequest = PlayerRequest(episodes: list, startIndex: index, roots: roots, cache: episodeCache)
    }

    /// Plays a file straight from disk — a download in progress or one that
    /// finished outside any library folder. The episode it carries is a
    /// stand-in for the player's UI only and is never saved.
    func playFile(at url: URL, title: String, infoHash: String? = nil) {
        let animeID = UUID()
        let episode = Episode(animeID: animeID, number: nil, title: title, sortIndex: 0)
        let file = MediaFile(
            libraryRootID: UUID(),
            episodeID: episode.id,
            relativePath: url.lastPathComponent,
            fileSize: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
            modifiedAt: .now
        )
        playerRequest = PlayerRequest(
            episodes: [EpisodeMedia(episode: episode, mediaFile: file, progress: nil)],
            startIndex: 0,
            roots: roots,
            cache: nil,
            directPlayback: PlayerRequest.DirectPlayback(url: url, title: title, infoHash: infoHash)
        )
    }

    /// The library root a path sits inside, if any.
    func libraryRoot(containing url: URL) -> LibraryRoot? {
        let target = url.standardizedFileURL.path
        return roots.first { root in
            guard let access = try? ScopedLibraryAccess(root: root) else { return false }
            defer { access.stop() }
            let rootPath = access.url.standardizedFileURL.path
            return target == rootPath || target.hasPrefix(rootPath + "/")
        }
    }

    /// A finished download inside a library folder is rescanned so it shows
    /// up as a normal episode; one outside stays where it is until the user
    /// adds that folder.
    func downloadFinished(savePath: String) async {
        guard let root = libraryRoot(containing: URL(fileURLWithPath: savePath)) else { return }
        await scan(root)
        await applyIncomingMatches()
    }

    // MARK: - Works that are still downloading

    /// What a work being downloaded looks like before any of its files exist.
    ///
    /// Nothing has an anime row until it finishes and its folder is scanned,
    /// so the home screen had only a magnet's own title to show — a season
    /// being fetched appeared as a grid of unreadable release names with no
    /// cover. Resolving the match while the download runs gives the card the
    /// work's real title and poster, and the same candidate is applied the
    /// moment the anime row appears, so nothing is left to match by hand.
    struct IncomingMatch: Sendable {
        var title: String
        /// The title the library files the work under — the folder's own name
        /// read the way the scanner reads it. Kept because the anime row is
        /// created from it before any file exists, and the scan that follows
        /// has to land on the same row.
        var libraryTitle: String
        var posterURL: URL?
        var candidate: AnimeMetadataCandidate
        var confidence: Double
    }

    /// Keyed by the work key its downloads share — the folder they were saved
    /// into, or the series title read off their names when there is no folder.
    @Published private(set) var incomingMatches: [String: IncomingMatch] = [:]

    /// Works that have been linked to an anime while they download, before
    /// any of their files exist. Keyed by anime id.
    ///
    /// The link is what makes a download an ordinary citizen of the library:
    /// its card draws the real cover, opens the anime's page with its
    /// comments, and the scan that follows finds the anime already matched
    /// instead of leaving it to be matched by hand afterwards.
    @Published private(set) var incomingAnime: [UUID: Anime] = [:]

    /// A work whose download has just started and that is not linked to
    /// anything yet, waiting for the user to say which anime it is.
    struct IncomingMatchPrompt: Identifiable {
        let id = UUID()
        /// The work key the answer is filed under — the folder the episodes
        /// share, which is also what the library will call the work.
        var seriesTitle: String
        var query: String
        var candidates: [RankedMatch]
        var isSearching = false
    }

    /// Non-nil while the sheet is up. One work at a time: a season started
    /// as a set asks once, not twelve times.
    @Published var incomingMatchPrompt: IncomingMatchPrompt?
    /// Works already offered this session, so restarting a download or
    /// adding a thirteenth episode does not ask again.
    private var promptedSeries: Set<String> = []
    /// Looked up already, whether or not it produced a match: a work nobody
    /// has heard of must not be searched for once a second.
    private var incomingMatchAttempts: Set<String> = []
    /// Reads a folder name the way the scanner does, so an anime row created
    /// for a download that has not landed yet is the row the scan will use.
    private let filenameParser = AnimeFilenameParser()

    /// The title the library files a work under, given the folder its
    /// episodes are in.
    ///
    /// This has to be exactly what the scanner will derive from that folder.
    /// When it was not, the work got two rows: one created up front and
    /// matched — the empty page whose episodes never appeared — and one
    /// created by the scan, unmatched, holding the actual files.
    func libraryTitle(forWorkKey key: String) -> String {
        let cleaned = filenameParser.collectionTitle(from: key).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? key : cleaned
    }

    /// Asks which anime a download that just started is of.
    ///
    /// The match used to happen after the files landed, which meant opening
    /// the library and matching by hand once the download was long finished.
    /// Asking at the start instead means the card has its cover while it
    /// downloads, and the anime is already linked the moment it appears.
    func offerIncomingMatch(seriesTitle: String) async {
        let key = seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !promptedSeries.contains(key), incomingMatches[key] == nil else { return }
        let title = libraryTitle(forWorkKey: key)
        // Already in the library under that name: link the downloads to the
        // row that exists rather than asking about a work already matched.
        if let existing = library.first(where: { $0.anime.title == title }) {
            promptedSeries.insert(key)
            incomingAnime[existing.anime.id] = existing.anime
            await downloads.link(seriesTitle: key, toAnimeID: existing.anime.id, title: existing.anime.title)
            return
        }
        promptedSeries.insert(key)
        incomingMatchPrompt = IncomingMatchPrompt(seriesTitle: key, query: title, candidates: [], isSearching: true)
        let ranked = await rankedCandidates(for: title)
        guard incomingMatchPrompt?.seriesTitle == key else { return }
        incomingMatchPrompt?.candidates = ranked
        incomingMatchPrompt?.isSearching = false
    }

    /// Re-runs the sheet's search when the user corrects the title.
    func searchIncomingMatch(_ query: String) async {
        guard incomingMatchPrompt != nil else { return }
        incomingMatchPrompt?.isSearching = true
        let ranked = await rankedCandidates(for: query)
        incomingMatchPrompt?.candidates = ranked
        incomingMatchPrompt?.isSearching = false
    }

    private func rankedCandidates(for query: String) async -> [RankedMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let ordered = MetadataProviderID.allCases.compactMap { metadataProviders[$0] }
        guard let provider = ordered.first else { return [] }
        guard let candidates = try? await provider.search(trimmed, limit: 12) else { return [] }
        return metadataMatcher.rank(localTitle: trimmed, candidates: candidates)
    }

    /// Files the user's answer: the work gets its anime row, its metadata
    /// and its cover straight away, and every download of it is linked to
    /// that row.
    func confirmIncomingMatch(_ match: RankedMatch) async {
        guard let prompt = incomingMatchPrompt else { return }
        incomingMatchPrompt = nil
        incomingMatchAttempts.insert(prompt.seriesTitle)
        await linkIncomingWork(
            seriesTitle: prompt.seriesTitle,
            to: match.candidate,
            confidence: 1,
            isManual: true
        )
    }

    /// Asks again about a work whose match was skipped, or whose match was
    /// wrong — the button on a downloading card that has no cover.
    func offerIncomingMatchAgain(workKey: String) async {
        promptedSeries.remove(workKey)
        incomingMatchAttempts.remove(workKey)
        await offerIncomingMatch(seriesTitle: workKey)
    }

    /// Gives a work being downloaded its anime row, its metadata and its
    /// link to the downloads themselves.
    @discardableResult
    private func linkIncomingWork(
        seriesTitle: String,
        to candidate: AnimeMetadataCandidate,
        confidence: Double,
        isManual: Bool
    ) async -> Anime? {
        guard let database, let provider = metadataProviders[candidate.provider] else { return nil }
        let title = libraryTitle(forWorkKey: seriesTitle)
        do {
            let anime = try await database.findOrCreateAnime(title: title)
            let metadata = try await provider.metadata(externalID: candidate.externalID, animeID: anime.id)
            let posts = (try? await provider.communityPosts(externalID: candidate.externalID)) ?? []
            try await database.save(
                metadata: metadata,
                communityPosts: posts,
                matchConfidence: confidence,
                isManualMatch: isManual
            )
            incomingAnime[anime.id] = anime
            incomingMatches[seriesTitle] = IncomingMatch(
                title: candidate.title.isEmpty ? title : candidate.title,
                libraryTitle: title,
                posterURL: candidate.posterURL,
                candidate: candidate,
                confidence: confidence
            )
            await downloads.link(seriesTitle: seriesTitle, toAnimeID: anime.id, title: anime.title)
            await bindSubscriptions(toAnimeID: anime.id, workKey: seriesTitle, title: title)
            await reloadMetadata()
            await reloadLibrary()
            return anime
        } catch {
            errorMessage = String(localized: "Could not link “\(seriesTitle)”: \(error.localizedDescription)")
            return nil
        }
    }

    /// A rule created before the work was matched has no anime to point at.
    /// Matching the work is when it gets one, so its page opens and its
    /// episodes are counted.
    private func bindSubscriptions(toAnimeID animeID: UUID, workKey: String, title: String) async {
        for rule in subscriptions.subscriptions where rule.animeID == nil {
            let follows = rule.folderName == workKey
                || rule.title.caseInsensitiveCompare(title) == .orderedSame
                || rule.title.caseInsensitiveCompare(workKey) == .orderedSame
            guard follows else { continue }
            var updated = rule
            updated.animeID = animeID
            updated.title = title
            await subscriptions.save(updated)
        }
    }

    /// How many episodes the season searched for has, from whichever provider
    /// answers first.
    ///
    /// This is what tells a finished twelve-episode season from one twelve
    /// episodes into a longer run, and a release search started from the
    /// sidebar has no anime behind it to ask. Only a confident match counts:
    /// a wrong subject's episode count is worse than not knowing, because it
    /// would offer to follow a season that ended.
    func episodeCount(forTitle title: String) async -> Int? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let cached = episodeCountsByTitle[trimmed] { return cached }
        let ordered = MetadataProviderID.allCases.compactMap { metadataProviders[$0] }
        for provider in ordered {
            guard let candidates = try? await provider.search(trimmed, limit: 8) else { continue }
            guard case let .automatic(best) = metadataMatcher.decide(localTitle: trimmed, candidates: candidates),
                  let count = best.candidate.totalEpisodes, count > 0 else { continue }
            episodeCountsByTitle[trimmed] = count
            return count
        }
        return nil
    }

    /// Looked up already, so retyping a search does not ask again.
    private var episodeCountsByTitle: [String: Int] = [:]

    /// `<animeID>:<provider>` pairs the user has said no to. Persisted,
    /// because an automatic pass runs at every launch and a question already
    /// answered with "not this one" must not come back every time.
    private var dismissedMatches: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.dismissedMatchesKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.dismissedMatchesKey) }
    }
    private static let dismissedMatchesKey = "metadata.dismissedMatches"

    /// Anime rows for downloads that were linked in an earlier run, so their
    /// cards still open and still show a cover after a relaunch.
    func loadIncomingAnime(ids: [UUID]) async {
        guard let database else { return }
        for id in ids where incomingAnime[id] == nil {
            guard let anime = try? await database.anime(id: id) else { continue }
            incomingAnime[id] = anime
        }
    }

    /// "Not now": the download carries on and the automatic lookup still
    /// gets its chance, it is just no longer this screen's problem.
    func skipIncomingMatch() {
        incomingMatchPrompt = nil
    }

    /// Looks up the works being downloaded that have not been looked up yet.
    /// Quiet on failure — a download must never be held up by metadata.
    func resolveIncomingMatches(seriesTitles: [String]) async {
        let pending = seriesTitles.filter { !$0.isEmpty && !incomingMatchAttempts.contains($0) }
        guard !pending.isEmpty else { return }
        incomingMatchAttempts.formUnion(pending)
        let ordered = MetadataProviderID.allCases.compactMap { metadataProviders[$0] }
        guard let provider = ordered.first else { return }
        for key in pending {
            let title = libraryTitle(forWorkKey: key)
            guard let candidates = try? await provider.search(title, limit: 8) else { continue }
            guard case let .automatic(best) = metadataMatcher.decide(localTitle: title, candidates: candidates) else {
                continue
            }
            await linkIncomingWork(
                seriesTitle: key,
                to: best.candidate,
                confidence: best.score,
                isManual: false
            )
        }
    }

    /// A subscription has started an episode on its own. The work it belongs
    /// to may never have been on this screen before, so its anime row is
    /// loaded and its files are looked for once they land.
    private func automaticDownloadStarted(for rule: TorrentSubscription) async {
        guard let animeID = rule.animeID else { return }
        await loadIncomingAnime(ids: [animeID])
    }

    /// Links an anime a finished download just created to the source that was
    /// resolved while it was downloading.
    private func applyIncomingMatches() async {
        guard let database, !incomingMatches.isEmpty else { return }
        var settled: [String] = []
        for (key, match) in incomingMatches {
            guard let entry = library.first(where: { $0.anime.title == match.libraryTitle }) else { continue }
            let alreadyLinked = metadataSourcesByAnimeID[entry.anime.id]?
                .contains { $0.provider == match.candidate.provider } == true
            if alreadyLinked { settled.append(key); continue }
            guard let provider = metadataProviders[match.candidate.provider] else { continue }
            do {
                let metadata = try await provider.metadata(
                    externalID: match.candidate.externalID,
                    animeID: entry.anime.id
                )
                let posts = (try? await provider.communityPosts(externalID: match.candidate.externalID)) ?? []
                try await database.save(
                    metadata: metadata,
                    communityPosts: posts,
                    matchConfidence: match.confidence,
                    isManualMatch: false
                )
                settled.append(key)
            } catch {
                continue
            }
        }
        guard !settled.isEmpty else { return }
        for key in settled { incomingMatches[key] = nil }
        await reloadMetadata()
    }

    /// Adds a download folder to the library and scans it.
    func addDownloadFolderToLibrary(_ url: URL) async {
        if let existing = libraryRoot(containing: url) {
            await scan(existing)
        } else {
            await addLibraryRoot(url)
        }
    }

    func searchMetadata(_ query: String, provider providerID: MetadataProviderID) async -> [AnimeMetadataCandidate] {
        guard let provider = metadataProviders[providerID] else { return [] }
        do {
            return try await provider.search(query, limit: 12)
        } catch {
            errorMessage = String(localized: "Could not search \(providerID.displayName): \(error.localizedDescription)")
            return []
        }
    }

    func match(_ anime: Anime, to candidate: AnimeMetadataCandidate) async -> Bool {
        guard let database else { return false }
        guard let provider = metadataProviders[candidate.provider] else { return false }
        do {
            let metadata = try await provider.metadata(externalID: candidate.externalID, animeID: anime.id)
            let posts = (try? await provider.communityPosts(externalID: candidate.externalID)) ?? []
            try await database.save(metadata: metadata, communityPosts: posts, matchConfidence: 1, isManualMatch: true)
            await reloadMetadata()
            return true
        } catch {
            errorMessage = String(localized: "Could not load \(candidate.provider.displayName) metadata: \(error.localizedDescription)")
            return false
        }
    }

    /// Fills in the metadata sources the library is missing.
    ///
    /// Runs on its own after a scan and at launch — nobody should have to know
    /// that a second source exists, let alone press a button for it. An
    /// automatic pass stays quiet about failures and, when it ends up with
    /// questions it cannot answer, offers them rather than burying them.
    func enrichLibraryMetadata(isAutomatic: Bool = false) async {
        guard !isEnrichingMetadata, let database else { return }
        let providers = MetadataProviderID.allCases.filter { metadataProviders[$0] != nil }
        let work = library.flatMap { anime in
            providers.compactMap { provider in
                metadataSourcesByAnimeID[anime.id]?.contains(where: { $0.provider == provider }) == true
                    ? nil : (anime, provider)
            }
        }
        guard !work.isEmpty else { return }
        isEnrichingMetadata = true
        defer {
            isEnrichingMetadata = false
            metadataProgress = nil
        }

        var matchedCount = 0
        var failedCount = 0
        var reviewQueue: [PendingMetadataMatch] = []
        var unavailableProviders = Set<MetadataProviderID>()
        /// Names learned from a provider that already answered, used to ask
        /// the next one. Held here rather than read back from
        /// `metadataSourcesByAnimeID`, which is only reloaded once the whole
        /// pass is over.
        var learnedTitles: [UUID: [String]] = [:]
        var consecutiveFailures: [MetadataProviderID: Int] = [:]
        var lastFailure: [MetadataProviderID: any Error] = [:]
        for (index, task) in work.enumerated() {
            guard !Task.isCancelled else { break }
            let (item, providerID) = task
            guard !unavailableProviders.contains(providerID), let provider = metadataProviders[providerID] else { continue }
            metadataProgress = String(localized: "\(providerID.displayName) \(index + 1) of \(work.count)")
            do {
                var best: RankedMatch?
                var fallback: [RankedMatch] = []
                // Every name the work is known by, not just the one the folder
                // uses. AniList indexes romaji and Japanese and holds no
                // Chinese titles at all, so a library whose folders are named
                // in Chinese got zero candidates from it — for every title,
                // silently, which is why it never appeared beside Bangumi on
                // an anime's page.
                let tried = searchTitles(for: item.anime, learned: learnedTitles[item.id] ?? [])
                if Self.tracesEnrichment {
                    FileHandle.standardError.write(Data("TRACE \(providerID.rawValue) '\(item.anime.title)' queries=\(tried)\n".utf8))
                }
                for query in tried {
                    let candidates = try await provider.search(query, limit: 8)
                    if Self.tracesEnrichment {
                        FileHandle.standardError.write(Data("TRACE   '\(query)' -> \(candidates.count) candidates, top=\(metadataMatcher.rank(localTitle: query, candidates: candidates).first.map { "\($0.candidate.title) \(String(format: "%.2f", $0.score))" } ?? "-")\n".utf8))
                    }
                    guard !candidates.isEmpty else { continue }
                    // Scored against the name that was asked for: a perfect
                    // AniList hit measured against the Chinese title scores
                    // nothing, because they share no characters.
                    switch metadataMatcher.decide(localTitle: query, candidates: candidates) {
                    case let .automatic(match):
                        best = match
                    case let .review(ranked):
                        if fallback.isEmpty { fallback = ranked }
                    case .none:
                        continue
                    }
                    // Only a confident match ends the search. Getting results
                    // back does not mean they are the right work: asking
                    // AniList for 「春宵苦短，少女前进吧！」 returns the film
                    // under its English name and scores it zero, and stopping
                    // there threw away the Japanese title that would have
                    // matched it outright.
                    if best != nil { break }
                }

                if let best {
                    // Best-effort default: link the strongest candidate now;
                    // the user fixes a wrong link from the anime page.
                    let metadata = try await provider.metadata(externalID: best.candidate.externalID, animeID: item.id)
                    let posts = (try? await provider.communityPosts(externalID: best.candidate.externalID)) ?? []
                    try await database.save(
                        metadata: metadata,
                        communityPosts: posts,
                        matchConfidence: best.score,
                        isManualMatch: false
                    )
                    // What this provider calls the work is what the next one
                    // is asked for.
                    learnedTitles[item.id, default: []].append(contentsOf: [metadata.title, metadata.originalTitle])
                    matchedCount += 1
                    consecutiveFailures[providerID] = 0
                } else if !dismissedMatches.contains("\(item.id.uuidString):\(providerID.rawValue)") {
                    // Dubious hits — and works this provider has never heard
                    // of — wait for one quick human pass. The second case used
                    // to be dropped silently, which is how a title could sit
                    // there for months with one source instead of two and
                    // nothing anywhere saying so.
                    reviewQueue.append(PendingMetadataMatch(
                        anime: item.anime,
                        provider: providerID,
                        candidates: fallback
                    ))
                }
            } catch {
                failedCount += 1
                // One failure used to disable a provider for the whole run.
                // That is right for a service that is down and wrong for
                // everything else — a rate limit is the provider working
                // normally, and one odd subject should not cost the rest of
                // the library its second source. Three failures in a row is
                // the signal that asking again is pointless.
                if (error as? MetadataProviderError)?.isTemporary == true {
                    consecutiveFailures[providerID] = 0
                } else {
                    let failures = (consecutiveFailures[providerID] ?? 0) + 1
                    consecutiveFailures[providerID] = failures
                    if failures >= Self.providerFailureLimit {
                        unavailableProviders.insert(providerID)
                    }
                }
                lastFailure[providerID] = error
            }
        }
        // Drop queue entries the user already resolved from an earlier run.
        pendingMatches = reviewQueue.filter { pending in
            metadataSourcesByAnimeID[pending.anime.id]?.contains(where: { $0.provider == pending.provider }) != true
        }
        await reloadMetadata()
        // An automatic pass is the only one that offers itself: pressing the
        // button already puts the user in front of the result.
        if isAutomatic, !pendingMatches.isEmpty { wantsMatchReview = true }

        // Only worth reporting when a provider was actually given up on: a
        // handful of titles it has never heard of is not a failure of the run,
        // and saying so after every pass taught the message to be ignored.
        if isAutomatic {
            // Nothing to say: a background pass that could not reach a source
            // is not an event, and the same titles are tried again next time.
        } else if !unavailableProviders.isEmpty {
            let names = unavailableProviders.map(\.displayName).sorted().joined(separator: ", ")
            let reason = unavailableProviders.compactMap { lastFailure[$0]?.localizedDescription }.first
            errorMessage = reason.map {
                String(localized: "Matched \(matchedCount) source(s). \(names) stopped answering: \($0)")
            } ?? String(localized: "Matched \(matchedCount) source(s). \(names) could not be reached; cached metadata and the local library remain available.")
        } else if failedCount > 0, matchedCount == 0 {
            errorMessage = String(localized: "Nothing new was matched. \(failedCount) lookup(s) failed; cached metadata and the local library remain available.")
        }
    }

    /// Every name to try when asking a provider about a work: the library's
    /// own title first, then the names another provider already gave it.
    ///
    /// The providers do not overlap on titles — Bangumi files 「アイの歌声を
    /// 聴かせて」 under its Chinese name, AniList under its romaji one — so
    /// asking each of them for the folder's name only ever works for one of
    /// them.
    private func searchTitles(for anime: Anime, learned: [String]) -> [String] {
        // Names a provider gave in an earlier run count too: by the time
        // AniList is asked, Bangumi's answer is usually months old and
        // already on disk, so its Japanese title never needs fetching again.
        let stored = (metadataSourcesByAnimeID[anime.id] ?? []).flatMap { [$0.title, $0.originalTitle] }
        let names = [anime.title] + learned + stored
        var seen = Set<String>()
        return (names + names.compactMap(Self.withoutFormatWords))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// A title with the words that describe the *release* taken out, or nil
    /// when there were none.
    ///
    /// AniList files a two-part film under `BanG Dream! It's MyGO!!!!! 春の陽
    /// だまり、迷い猫`, while the library — and Bangumi — call it 「劇場版 …
    /// 前編 春の陽だまり、迷い猫」. Searched whole it matches nothing; with
    /// those two words gone it is an exact hit.
    ///
    /// Deliberately not 総集編 / 合集 / 特別編: a recap is a different work
    /// from the series it recaps, and dropping the word would confidently
    /// match the wrong one.
    private static func withoutFormatWords(_ title: String) -> String? {
        var stripped = title
        for word in ["劇場版", "剧场版", "劇場", "前編", "後編", "前篇", "后篇", "上巻", "下巻"] {
            stripped = stripped.replacingOccurrences(of: word, with: " ")
        }
        stripped = stripped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A title that was *only* a format word says nothing about the work.
        guard stripped != title, stripped.count >= 2 else { return nil }
        return stripped
    }

    func confirmPendingMatch(_ pending: PendingMetadataMatch, candidate: AnimeMetadataCandidate) async {
        guard let index = pendingMatches.firstIndex(where: { $0.id == pending.id }) else { return }
        pendingMatches.remove(at: index)
        dismissedMatches.remove(pending.id)
        _ = await match(pending.anime, to: candidate)
    }

    func skipPendingMatch(_ pending: PendingMetadataMatch) {
        pendingMatches.removeAll { $0.id == pending.id }
        dismissedMatches.insert(pending.id)
    }

    /// Searches again for one pending match, with whatever the user typed.
    /// This is the way in for a work the provider has never heard of under
    /// any of the names the library knows it by.
    func searchPendingMatch(_ pending: PendingMetadataMatch, query: String) async {
        guard let index = pendingMatches.firstIndex(where: { $0.id == pending.id }) else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let provider = metadataProviders[pending.provider] else { return }
        pendingMatches[index].query = trimmed
        pendingMatches[index].isSearching = true
        let candidates = (try? await provider.search(trimmed, limit: 12)) ?? []
        guard let current = pendingMatches.firstIndex(where: { $0.id == pending.id }) else { return }
        pendingMatches[current].candidates = metadataMatcher.rank(localTitle: trimmed, candidates: candidates)
        pendingMatches[current].isSearching = false
    }

    func loadCommunity(for anime: Anime, provider providerID: MetadataProviderID? = nil, refresh: Bool = false) async {
        guard let database else { return }
        do {
            if !refresh {
                let cached = try await database.communityPosts(animeID: anime.id)
                if !cached.isEmpty {
                    communityByAnimeID[anime.id] = cached
                    let hasBangumiSource = (metadataSourcesByAnimeID[anime.id] ?? []).contains { $0.provider == .bangumi }
                    let needsShoutboxUpgrade = hasBangumiSource
                        && !cached.contains { $0.provider == .bangumi && $0.kind == .shoutbox }
                        && shoutboxUpgradeAttempts.insert(anime.id).inserted
                    if !needsShoutboxUpgrade { return }
                }
            }
            let sources = metadataSourcesByAnimeID[anime.id] ?? []
            guard let metadata = providerID.flatMap({ id in sources.first { $0.provider == id } })
                ?? sources.first(where: { $0.provider == .bangumi })
                ?? sources.first,
                  let provider = metadataProviders[metadata.provider] else { return }
            let posts = try await provider.communityPosts(externalID: metadata.externalID)
            let refreshed = try await provider.metadata(externalID: metadata.externalID, animeID: anime.id)
            // Refreshing content must not turn an auto-matched link into a
            // manual one or rewrite its recorded confidence.
            let link = matchLinksByAnimeID[anime.id]?[metadata.provider]
            try await database.save(
                metadata: refreshed,
                communityPosts: posts,
                matchConfidence: link?.confidence ?? 1,
                isManualMatch: link?.isManual ?? true
            )
            await reloadMetadata()
        } catch {
            errorMessage = String(localized: "Could not refresh community content: \(error.localizedDescription)")
        }
    }

    /// Translates cached community posts via the configured independent
    /// translation service; originals stay intact and results are cached.
    func translateCommunity(for anime: Anime, posts: [CommunityPost]) async {
        guard let updated = await translation.translate(posts: posts, animeID: anime.id, database: database) else { return }
        communityByAnimeID[anime.id] = (communityByAnimeID[anime.id] ?? []).map { cached in
            updated.first { $0.id == cached.id } ?? cached
        }
    }

    func saveProgress(episodeID: UUID, position: Double, duration: Double) async {        guard duration > 0, let database else { return }
        // Mark watched only near the real end, never merely because playback started.
        let isWatched = duration >= 2 * 60 && position / duration >= 0.90
        do {
            try await database.save(progress: .init(
                episodeID: episodeID,
                position: position,
                duration: duration,
                isWatched: isWatched
            ))
            await reloadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func profile(for animeID: UUID) -> AnimeProfile {
        profilesByAnimeID[animeID] ?? AnimeProfile(animeID: animeID)
    }

    /// Poster candidates from every matched source, Bangumi first so a
    /// reachable CDN wins over an unreachable one.
    func posterCandidates(for animeID: UUID) -> [URL] {
        let sources = metadataSourcesByAnimeID[animeID] ?? []
        let ordered = sources.sorted {
            if $0.provider == .bangumi && $1.provider != .bangumi { return true }
            if $1.provider == .bangumi && $0.provider != .bangumi { return false }
            return true
        }
        return ordered.compactMap(\.posterURL)
    }

    func saveProfile(_ profile: AnimeProfile) async -> Bool {
        guard let database else { return false }
        var profile = profile
        profile.score = profile.score.map { min(max($0, 0), 10) }
        profile.ranking = profile.ranking.flatMap { $0 > 0 ? $0 : nil }
        profile.rewatchCount = max(profile.rewatchCount, 0)
        profile.updatedAt = .now
        if profile.status == .completed { profile.completedAt = profile.completedAt ?? .now }
        do {
            try await database.save(profile: profile)
            await reloadPersonalLibrary()
            return true
        } catch {
            errorMessage = String(localized: "Could not save your anime entry: \(error.localizedDescription)")
            return false
        }
    }

    func moveRanking(animeID: UUID, by offset: Int) async {
        guard offset != 0 else { return }
        let ranked = profilesByAnimeID.values
            .filter { $0.ranking != nil }
            .sorted {
                if $0.ranking != $1.ranking { return ($0.ranking ?? .max) < ($1.ranking ?? .max) }
                return $0.updatedAt < $1.updatedAt
            }
        guard let source = ranked.firstIndex(where: { $0.animeID == animeID }) else { return }
        let destination = source + offset
        guard ranked.indices.contains(destination) else { return }
        var first = ranked[source]
        first.ranking = ranked[destination].ranking
        _ = await saveProfile(first)
    }

    func finishPlaybackSession(
        episode: EpisodeMedia,
        startedAt: Date,
        watchedDuration: Double,
        position: Double,
        duration: Double
    ) async {
        guard duration > 0, let database else { return }
        let completion = min(max(position / duration, 0), 1)
        let completed = duration >= 2 * 60 && completion >= 0.90
        // Closing playback at ≥90% retires the transparent auto cache for
        // this episode; manual copies always stay until removed by hand.
        episodeCache.handlePlaybackFinished(episode: episode, completion: completion)
        await saveProgress(episodeID: episode.id, position: position, duration: duration)
        let animeTitle = metadataByAnimeID[episode.episode.animeID]?.title
            ?? library.first(where: { $0.id == episode.episode.animeID })?.anime.title
            ?? String(localized: "Unknown Anime")
        do {
            try await database.record(event: WatchEvent(
                animeID: episode.episode.animeID,
                episodeID: episode.id,
                animeTitle: animeTitle,
                episodeLabel: Self.episodeLabel(episode.episode),
                startedAt: startedAt,
                watchedDuration: watchedDuration,
                completion: completion,
                completedEpisode: completed
            ))
            await reloadPersonalLibrary()
        } catch {
            errorMessage = String(localized: "Could not save watch history: \(error.localizedDescription)")
        }
    }

    private func prepare() async {
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "AnimeGod", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            let database = try LibraryDatabase(url: applicationSupport.appending(path: "library.sqlite"))
            self.database = database
            roots = try await database.libraryRoots()
            downloads.folders.updateLibraryRoots(roots)
            await episodeCache.prepare(database: database)
            await downloads.attach(database: database)
            // A finished download inside a library folder becomes a normal
            // episode without the user doing anything.
            downloads.onDownloadFinished = { [weak self] record in
                Task { await self?.downloadFinished(savePath: record.savePath) }
            }
            downloads.onWorkStarted = { [weak self] workKey in
                Task { await self?.offerIncomingMatch(seriesTitle: workKey) }
            }
            subscriptions.ownedEpisodesProvider = { [weak self] animeID in
                guard let self, let database = self.database else { return [] }
                let episodes = (try? await database.episodes(animeID: animeID)) ?? []
                return Set(episodes.filter { $0.episode.kind == .regular }.compactMap(\.episode.number))
            }
            subscriptions.expectedEpisodeCountProvider = { [weak self] animeID in
                // The smallest of what the providers say, because a provider
                // that counts specials among the episodes would leave a
                // finished season permanently short of its own finale.
                self?.metadataSourcesByAnimeID[animeID]?.compactMap(\.totalEpisodes).min()
            }
            releaseSearch.episodeCountProvider = { [weak self] title in
                await self?.episodeCount(forTitle: title)
            }
            // A rule that has just downloaded something is a work the home
            // screen should be showing, matched and covered.
            subscriptions.onAutomaticDownload = { [weak self] rule in
                Task { await self?.automaticDownloadStarted(for: rule) }
            }
            await subscriptions.attach(database: database, downloads: downloads)
            await refreshRootAvailability()
            await reloadLibrary()
            enrichInBackground()
        } catch {
            errorMessage = String(localized: "Could not open the local library: \(error.localizedDescription)")
        }
    }

    private func reloadLibrary() async {
        guard let database else { return }
        do {
            async let loadedLibrary = database.library()
            async let loadedContinue = database.continueWatching()
            async let loadedMetadata = database.metadata()
            async let loadedProfiles = database.profiles()
            async let loadedHistory = database.watchEvents()
            async let loadedDiary = database.diarySummary()
            let (library, continueWatching, metadata, profiles, history, diary) = try await (
                loadedLibrary, loadedContinue, loadedMetadata, loadedProfiles, loadedHistory, loadedDiary
            )
            self.library = library
            self.continueWatching = continueWatching
            apply(metadata: metadata)
            profilesByAnimeID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.animeID, $0) })
            watchHistory = history
            diarySummary = diary
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadMetadata() async {
        guard let database else { return }
        do {
            let metadata = try await database.metadata()
            apply(metadata: metadata)
            let animeIDs = Set(metadata.map(\.animeID))
            var community: [UUID: [CommunityPost]] = [:]
            var links: [UUID: [MetadataProviderID: MatchLink]] = [:]
            for animeID in animeIDs {
                community[animeID] = try await database.communityPosts(animeID: animeID)
                links[animeID] = try await database.matchLinks(animeID: animeID)
            }
            communityByAnimeID = community
            matchLinksByAnimeID = links
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(metadata: [AnimeMetadata]) {
        let grouped = Dictionary(grouping: metadata, by: \.animeID)
        metadataSourcesByAnimeID = grouped
        metadataByAnimeID = grouped.compactMapValues { sources in
            sources.first(where: { $0.provider == .bangumi }) ?? sources.first
        }
    }

    private func reloadPersonalLibrary() async {
        guard let database else { return }
        do {
            async let profiles = database.profiles()
            async let history = database.watchEvents()
            async let summary = database.diarySummary()
            let loaded = try await (profiles, history, summary)
            profilesByAnimeID = Dictionary(uniqueKeysWithValues: loaded.0.map { ($0.animeID, $0) })
            watchHistory = loaded.1
            diarySummary = loaded.2
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rebuilds the yearly statistics report from the full watch history.
    func loadStatistics(year: Int? = nil) async {
        guard let database else { return }
        do {
            let events = try await database.allWatchEvents()
            let report = StatisticsBuilder().report(
                year: year ?? Calendar.current.dateComponents([.year], from: .now).year!,
                events: events,
                metadataByAnimeID: metadataSourcesByAnimeID,
                profilesByAnimeID: profilesByAnimeID
            )
            statisticsReport = report
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stored with the history event in canonical English; views show it
    /// through `Episode.localizedLabel`.
    private static func episodeLabel(_ episode: Episode) -> String {
        Episode.displayLabel(kind: episode.kind, numberText: episode.numberText)
    }
}

struct PlayerRequest: Identifiable {
    /// Playing a file that is not in the library — a download still in
    /// progress. It has no episode row, so nothing about it is written to
    /// the database: no watch progress, no auto-cache, no danmaku match
    /// (an unfinished file has no stable identity to match on).
    struct DirectPlayback {
        let url: URL
        let title: String
        let infoHash: String?
    }

    let id = UUID()
    let episodes: [EpisodeMedia]
    let startIndex: Int
    let roots: [LibraryRoot]
    /// Local episode copies, so playback survives an unplugged drive.
    let cache: EpisodeCacheStore?
    var directPlayback: DirectPlayback?

    var episode: EpisodeMedia { episodes[startIndex] }
}

/// A plausible-but-ambiguous metadata match waiting for the user's decision.
struct PendingMetadataMatch: Identifiable {
    let anime: Anime
    let provider: MetadataProviderID
    /// What the automatic pass came up with. Empty when the provider knew
    /// nothing at all under any of the names the work goes by — which is
    /// still worth asking about, because a person can spell it a way the
    /// heuristics cannot.
    var candidates: [RankedMatch]
    /// The name the sheet last searched for, so the field survives a redraw.
    var query: String
    var isSearching = false
    var id: String { "\(anime.id.uuidString):\(provider.rawValue)" }

    init(anime: Anime, provider: MetadataProviderID, candidates: [RankedMatch], query: String? = nil) {
        self.anime = anime
        self.provider = provider
        self.candidates = candidates
        self.query = query ?? anime.title
    }
}

final class ScopedLibraryAccess: @unchecked Sendable {
    let url: URL
    private let active: Bool

    init(root: LibraryRoot) throws {
        if let bookmark = root.bookmarkData {
            var stale = false
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } else {
            url = URL(fileURLWithPath: root.lastKnownPath, isDirectory: true)
        }
        active = url.startAccessingSecurityScopedResource()
    }

    func stop() {
        if active { url.stopAccessingSecurityScopedResource() }
    }
}
