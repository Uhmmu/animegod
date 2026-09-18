import AnimeGodCore
import Foundation

/// What a subtitle session needs from the player it lives in.
@MainActor
protocol SubtitleTrackHost: AnyObject {
    func attachSubtitle(url: URL, title: String, language: String?, select: Bool)
    func detachSubtitle(url: URL)
    /// False on the native Dolby Vision path, which shows no subtitles.
    var rendersSubtitles: Bool { get }
    /// The user's last subtitle choice was "Off".
    var userTurnedSubtitlesOff: Bool { get }
}

/// The work being played, as the library knows it.
struct SubtitleWorkContext: Equatable {
    var titles: [String] = []
    var references: [ExternalAnimeReference] = []
    var airDate: String?
}

/// Online subtitles for one playback window: decides whether a search is
/// needed, runs it, loads the confident result, and remembers downloads so
/// a replay never searches twice. Like danmaku, it is an enhancement: every
/// failure ends in a status, and playback is never touched.
@MainActor
final class SubtitleSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Waiting for the file to load so its own tracks can be checked.
        case waitingForTracks
        /// A subtitle in a preferred language is already there.
        case existingSubtitle(String)
        /// The filename says Chinese subtitles are burned into the picture.
        case burnedIn
        /// The user's last choice was "no subtitles".
        case subtitlesOff
        /// Automatic search is off; manual search is available.
        case ready
        case notConfigured
        /// The native Dolby Vision pipeline renders no subtitles.
        case unavailableInPipeline
        case searching
        case downloading(String)
        case loaded(SubtitleDownloadRecord, fromCache: Bool)
        /// Results exist, but none is confident enough to load unasked.
        case needsChoice(Int)
        case noResults
        case failed(String)

        /// Worth a nudge on screen.
        var isActionable: Bool {
            switch self {
            case .needsChoice, .noResults, .failed, .notConfigured: true
            default: false
            }
        }
    }

    struct Request: Equatable {
        let videoURL: URL
        let mediaFileID: UUID?
        let animeID: UUID?
        let fileName: String
        let fileSize: Int64
        let episode: Double?
        let episodeKind: EpisodeKind
    }

    @Published private(set) var phase: Phase = .idle
    /// Cached downloads for the current video, the active one first.
    @Published private(set) var downloads: [SubtitleDownloadRecord] = []
    /// The most recent search, automatic or manual.
    @Published private(set) var lastReport: SubtitleSearchReport?
    @Published private(set) var isSearching = false
    @Published private(set) var identity: SubtitleVideoIdentity?
    /// Bumped whenever an automatic result is loaded, so the player can
    /// show a brief confirmation.
    @Published private(set) var announcement: String?

    weak var host: SubtitleTrackHost?
    private(set) var preferences: SubtitlePreferences?
    private var database: LibraryDatabase?
    private(set) var request: Request?
    private var context = SubtitleWorkContext()
    private var tracks: [MediaTrack] = []
    private var fileLoaded = false
    private var didEvaluate = false
    private var generation = UUID()

    var isAttached: Bool { preferences != nil }

    var videoKey: String? {
        request.map { SubtitleCacheStore.videoKey(mediaFileID: $0.mediaFileID, fileName: $0.fileName) }
    }

    func attach(preferences: SubtitlePreferences, database: LibraryDatabase?) {
        self.preferences = preferences
        if let database { self.database = database }
        evaluateIfReady()
    }

    func updateWorkContext(_ context: SubtitleWorkContext) {
        // A new context can change the titles and IDs a search uses.
        if context != self.context { identity = nil }
        self.context = context
    }

    /// Entry point whenever playback starts on (or switches to) a file.
    func load(_ request: Request) {
        guard request != self.request else { return }
        self.request = request
        generation = UUID()
        fileLoaded = false
        didEvaluate = false
        tracks = []
        identity = nil
        lastReport = nil
        downloads = []
        announcement = nil
        phase = .waitingForTracks
    }

    /// Called with every track-list update. The first update after the file
    /// has loaded decides whether online subtitles are needed.
    func tracksDidUpdate(_ tracks: [MediaTrack], isLoading: Bool) {
        self.tracks = tracks
        if !isLoading { fileLoaded = true }
        evaluateIfReady()
    }

    /// Keeps the "active" download in step with what the user picked from
    /// the subtitle menu, so a replay restores their choice.
    func userSelected(_ track: MediaTrack?) {
        guard let key = videoKey, let database else { return }
        let record = track.flatMap { track in downloads.first { isSame($0, track) } }
        Task {
            try? await database.setActiveSubtitleDownload(id: record?.id, videoKey: key)
            await self.reloadDownloads()
        }
        if let record { phase = .loaded(record, fromCache: true) }
    }

    // MARK: - Decision

    private func evaluateIfReady() {
        guard fileLoaded, !didEvaluate, request != nil, preferences != nil else { return }
        didEvaluate = true
        let token = generation
        Task { await evaluate(token: token) }
    }

    private func evaluate(token: UUID) async {
        guard let preferences, let host else { return }
        await reloadDownloads()
        guard token == generation else { return }

        guard host.rendersSubtitles else {
            phase = .unavailableInPipeline
            return
        }

        // Earlier downloads come back as tracks; the active one is selected
        // unless the user has switched subtitles off.
        let active = downloads.first(where: \.isActive)
        for record in downloads {
            host.attachSubtitle(
                url: preferences.cache.url(for: record), title: record.displayTitle,
                language: record.language?.rawValue,
                select: record.id == active?.id && !host.userTurnedSubtitlesOff
            )
        }
        if let active {
            phase = .loaded(active, fromCache: true)
            return
        }
        if host.userTurnedSubtitlesOff {
            phase = .subtitlesOff
            return
        }
        if let existing = existingPreferredTrack() {
            phase = .existingSubtitle(existing.displayName)
            return
        }
        if preferences.skipHardsubbedReleases, isBurnedIn() {
            phase = .burnedIn
            return
        }
        guard preferences.autoSearch else {
            phase = .ready
            return
        }
        guard preferences.hasUsableProvider else {
            phase = .notConfigured
            return
        }
        await runAutomaticSearch(token: token)
    }

    /// An embedded or sidecar track (not one of ours) in a preferred
    /// language. A script-less "Chinese" track counts for either script.
    func existingPreferredTrack() -> MediaTrack? {
        guard let preferences else { return nil }
        let wanted = preferences.ranking.languages
        return tracks.first { track in
            guard !isOwnDownload(track),
                  let language = SubtitleLanguage.fromTrack(language: track.language, title: track.title) else { return false }
            return wanted.contains(language) || (language == .chinese && wanted.contains(where: \.isChinese))
        }
    }

    /// "[CHT]", "[简日内嵌]": the release names Chinese subtitles, yet the
    /// file has no Chinese track — so they are part of the picture. Releases
    /// that ship subtitles separately ("外挂") are not burned in.
    private func isBurnedIn() -> Bool {
        guard let request else { return false }
        let release = TorrentReleaseInfo.parse(title: request.fileName)
        let namesChinese = release.subtitleLanguages.contains(.simplifiedChinese)
            || release.subtitleLanguages.contains(.traditionalChinese)
        return namesChinese && release.subtitleStyle != .external
    }

    // MARK: - Search

    /// "Auto-match Chinese subtitles" from the menu: runs the automatic
    /// flow even when the file already has subtitles.
    func autoMatchNow() {
        guard preferences != nil, request != nil else { return }
        let token = generation
        Task { await runAutomaticSearch(token: token) }
    }

    private func runAutomaticSearch(token: UUID) async {
        guard let preferences else { return }
        guard preferences.hasUsableProvider else {
            phase = .notConfigured
            return
        }
        phase = .searching
        guard let report = await search(customText: nil, allLanguages: false), token == generation else { return }
        if let choice = report.automaticChoice {
            await install(choice, automatic: true, token: token)
            return
        }
        let candidates = report.ranked.filter { scored in
            !scored.score.warnings.contains(.wrongEpisode) && !scored.score.warnings.contains(.unpreferredLanguage)
        }
        if !candidates.isEmpty {
            phase = .needsChoice(candidates.count)
        } else if report.ranked.isEmpty, !report.outcomes.isEmpty,
                  report.outcomes.values.allSatisfy({ if case .failed = $0 { true } else if case .skipped = $0 { true } else { false } }),
                  let message = report.outcomes.values.compactMap({ if case let .failed(message) = $0 { message } else { nil } }).first {
            phase = .failed(message)
        } else {
            phase = .noResults
        }
    }

    /// Searches every configured provider. `customText` replaces the
    /// automatic title queries; `allLanguages` widens beyond preferences.
    @discardableResult
    func search(customText: String?, allLanguages: Bool) async -> SubtitleSearchReport? {
        guard let preferences, request != nil else { return nil }
        let token = generation
        isSearching = true
        defer { if token == generation { isSearching = false } }
        let identity = await resolveIdentity()
        guard token == generation else { return nil }
        let languages = allLanguages ? SubtitleLanguage.rankable : preferences.ranking.languages
        let query = SubtitleQuery(identity: identity, languages: languages, customText: customText)
        let report = await preferences.makeManager().search(query)
        guard token == generation else { return nil }
        lastReport = report
        return report
    }

    /// Downloads, caches and loads a result the user picked.
    func choose(_ scored: ScoredSubtitle) async {
        await install(scored, automatic: false, token: generation)
    }

    private func install(_ scored: ScoredSubtitle, automatic: Bool, token: UUID) async {
        guard let preferences, let request, let key = videoKey else { return }
        let identity = await resolveIdentity()
        guard token == generation else { return }
        phase = .downloading(scored.result.provider.displayName)
        do {
            let prepared = try await preferences.makeManager().download(scored.result, for: identity)
            guard token == generation else { return }
            let record = try preferences.cache.store(
                prepared, for: scored, video: identity, videoKey: key,
                animeID: request.mediaFileID == nil ? nil : request.animeID,
                isAutomatic: automatic
            )
            try? await database?.saveSubtitleDownload(record)
            await reloadDownloads()
            guard token == generation else { return }
            let saved = downloads.first { $0.provider == record.provider && $0.providerSubtitleID == record.providerSubtitleID } ?? record
            if !downloads.contains(where: { $0.id == saved.id }) { downloads.insert(saved, at: 0) }
            host?.attachSubtitle(
                url: preferences.cache.url(for: saved), title: saved.displayTitle,
                language: saved.language?.rawValue, select: true
            )
            phase = .loaded(saved, fromCache: false)
            if automatic {
                announcement = "\(saved.displayTitle) · \(Int((saved.matchScore * 100).rounded()))%"
            }
        } catch {
            guard token == generation else { return }
            phase = .failed(SubtitleManager.message(for: error))
        }
    }

    /// Loads a previously downloaded subtitle.
    func selectDownloaded(_ record: SubtitleDownloadRecord) {
        guard let preferences, let key = videoKey else { return }
        host?.attachSubtitle(
            url: preferences.cache.url(for: record), title: record.displayTitle,
            language: record.language?.rawValue, select: true
        )
        phase = .loaded(record, fromCache: true)
        Task {
            try? await database?.setActiveSubtitleDownload(id: record.id, videoKey: key)
            await reloadDownloads()
        }
    }

    /// Forgets this video's downloads (files and records) and unloads them.
    func removeDownloads() async {
        guard let preferences, let key = videoKey else { return }
        for record in downloads {
            host?.detachSubtitle(url: preferences.cache.url(for: record))
            preferences.cache.remove(record)
        }
        try? await database?.removeSubtitleDownloads(videoKey: key)
        downloads = []
        phase = .ready
    }

    /// Removes this video's downloads and searches again from scratch.
    func researchFromScratch() {
        let token = generation
        Task {
            await removeDownloads()
            guard token == generation else { return }
            await runAutomaticSearch(token: token)
        }
    }

    func clearAnnouncement() { announcement = nil }

    // MARK: - Identity

    /// The video's identity with every external ID we can find. Resolved
    /// once per file; the AniList/TMDB part once per anime per run.
    func resolveIdentity() async -> SubtitleVideoIdentity {
        if let identity { return identity }
        guard let request, let preferences else {
            return SubtitleVideoIdentity(titles: [], fileName: "")
        }
        var identity = SubtitleVideoIdentity.fromFileName(
            request.fileName,
            titles: context.titles,
            episode: request.episode,
            episodeKind: request.episodeKind,
            fileSize: request.fileSize
        )
        var ids = SubtitleAnimeIDs()
        for reference in context.references {
            switch reference.provider {
            case .bangumi: ids.bangumiID = ids.bangumiID ?? Int(reference.externalID)
            case .anilist: ids.aniListID = ids.aniListID ?? Int(reference.externalID)
            case .myAnimeList: ids.malID = ids.malID ?? Int(reference.externalID)
            }
        }
        if let animeID = request.animeID, let cached = preferences.resolvedIDs[animeID] {
            ids = ids.merging(cached)
        } else {
            if ids.aniListID == nil, ids.malID == nil, !context.titles.isEmpty {
                ids.aniListID = await Self.lookUpAniListID(titles: context.titles, airDate: context.airDate)
            }
            if let mapped = await preferences.idMapping.ids(aniListID: ids.aniListID, malID: ids.malID) {
                ids = ids.merging(mapped)
            }
            if let animeID = request.animeID, request.mediaFileID != nil { preferences.resolvedIDs[animeID] = ids }
        }
        identity.ids = ids

        // The moviehash only matters to OpenSubtitles; it reads 128 KiB.
        if preferences.enabledProviders.contains(.openSubtitles), preferences.isConfigured(.openSubtitles) {
            let url = request.videoURL
            identity.openSubtitlesHash = await Task.detached(priority: .utility) {
                OpenSubtitlesHash.compute(url: url)
            }.value
        }
        if self.request == request { self.identity = identity }
        return identity
    }

    /// For works matched only on Bangumi: the AniList entry with a
    /// near-identical title and the same premiere year, or nothing.
    private static func lookUpAniListID(titles: [String], airDate: String?) async -> Int? {
        let provider = AniListMetadataProvider()
        for title in titles.prefix(2) {
            guard let candidates = try? await provider.search(title, limit: 8) else { continue }
            if let id = SubtitleIdentityResolver.bestAniListID(candidates: candidates, titles: titles, airDate: airDate) {
                return id
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func reloadDownloads() async {
        guard let preferences, let key = videoKey else { return }
        let records = (try? await database?.subtitleDownloads(videoKey: key)) ?? []
        guard key == videoKey else { return }
        // A record whose file was removed (cache cleared) is dropped.
        downloads = records.filter { FileManager.default.fileExists(atPath: preferences.cache.url(for: $0).path) }
    }

    func isOwnDownload(_ track: MediaTrack) -> Bool {
        guard let preferences, let file = track.externalFilename else { return false }
        return file.hasPrefix(preferences.cache.root.path)
    }

    private func isSame(_ record: SubtitleDownloadRecord, _ track: MediaTrack) -> Bool {
        guard let preferences, let file = track.externalFilename else { return false }
        return file == preferences.cache.url(for: record).path
    }

    /// The downloaded record behind a player track, if any.
    func download(for track: MediaTrack) -> SubtitleDownloadRecord? {
        downloads.first { isSame($0, track) }
    }
}
