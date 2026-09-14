import AnimeGodCore
import Combine
import Foundation

/// Drives danmaku for one playback window: identifies the episode, pulls
/// comments (cache first), and feeds the renderer. Danmaku is strictly an
/// enhancement — every failure lands in a non-intrusive status and
/// playback itself is never touched.
@MainActor
final class DanmakuSession: ObservableObject {
    enum CacheState: Equatable {
        case hit, miss
    }

    enum Phase: Equatable {
        case idle
        case disabled
        case needsConfiguration
        case matching
        case loading
        case ready(anime: String, episode: String, episodeID: Int64, cache: CacheState)
        case noMatch
        case failed(String)

        var isActionable: Bool {
            switch self {
            case .noMatch, .failed, .needsConfiguration: true
            default: false
            }
        }
    }

    struct EpisodeRequest {
        let fileURL: URL
        let mediaFileID: UUID
        let fileName: String
        let fileSize: Int64
        var duration: Double
        var titleCandidates: [String] = []
        var episodeNumber: Double?
        var episodeKind: EpisodeKind = .regular
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var renderer = DanmakuRendererSnapshot()
    @Published private(set) var isReloading = false

    let canvas = DanmakuCanvas(frame: .zero)
    private var preferences: DanmakuPreferences?
    private var database: LibraryDatabase?
    private var generation = UUID()
    private var currentRequest: EpisodeRequest?
    private var preferencesCancellable: AnyCancellable?
    /// The last successfully presented episode, so toggling danmaku off and
    /// on again restores the status without refetching.
    private var lastReady: (anime: String, episode: String, episodeID: Int64, cache: CacheState)?

    var isAttached: Bool { preferences != nil }
    var currentMediaFileID: UUID? { currentRequest?.mediaFileID }

    init() {
        canvas.onDiagnostics = { [weak self] snapshot in
            self?.renderer = snapshot
        }
    }

    // MARK: - Wiring

    /// Connects preferences; every settings change flows straight to the
    /// canvas without rebuilding the pipeline.
    func attach(preferences: DanmakuPreferences) {
        guard self.preferences == nil else { return }
        self.preferences = preferences
        preferencesCancellable = preferences.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPreferences() }
        applyPreferences()
    }

    func applyPreferences() {
        guard let preferences else { return }
        canvas.apply(settings: preferences.settings)
        canvas.setVisible(preferences.enabled)
        guard preferences.enabled else {
            phase = .disabled
            return
        }
        if case .disabled = phase {
            if let ready = lastReady {
                phase = .ready(anime: ready.anime, episode: ready.episode, episodeID: ready.episodeID, cache: ready.cache)
            } else if let request = currentRequest {
                // Danmaku was off before this file's pipeline ever ran.
                guard preferences.makeProvider() != nil else {
                    phase = .needsConfiguration
                    return
                }
                run(request: request, forceRefresh: false)
            }
        }
    }

    /// Entry point whenever playback starts on (or switches to) a file.
    /// Re-loading the same file is a no-op (use reload() to refetch).
    func load(_ request: EpisodeRequest, database: LibraryDatabase? = nil) {
        if let database { self.database = database }
        if currentRequest?.mediaFileID == request.mediaFileID { return }
        currentRequest = request
        guard let preferences, preferences.enabled else {
            phase = preferences == nil ? .idle : .disabled
            return
        }
        canvas.setVisible(true)
        guard preferences.makeProvider() != nil else {
            phase = .needsConfiguration
            return
        }
        run(request: request, forceRefresh: false)
    }

    /// The real media duration arrives after loading has begun; recorded
    /// for any match request that has not run yet.
    func updateDuration(_ duration: Double) {
        guard duration > 0, var request = currentRequest, request.duration <= 0 else { return }
        request.duration = duration
        currentRequest = request
    }

    /// Enriches filename-derived matching with the titles already known by
    /// the local library and metadata providers. This affects suggestions but
    /// never invalidates an existing, user-confirmed binding.
    func updateSearchContext(titleCandidates: [String], episodeNumber: Double?, episodeKind: EpisodeKind) {
        guard var request = currentRequest else { return }
        request.titleCandidates = titleCandidates
        request.episodeNumber = episodeNumber
        request.episodeKind = episodeKind
        currentRequest = request
    }

    /// User-triggered refetch: bypasses the comment cache.
    func reload() {
        guard let request = currentRequest, preferences?.enabled == true else { return }
        run(request: request, forceRefresh: true)
    }

    /// Manual episode selection from the match sheet.
    func matchManually(to episodeRef: DanmakuEpisodeRef) {
        guard let request = currentRequest, let database else { return }
        generation = UUID()
        let token = generation
        isReloading = true
        phase = .loading
        Task { [weak self] in
            guard let self else { return }
            defer { if token == self.generation { self.isReloading = false } }
            try? await database.saveDanmakuMatch(DanmakuMatchBinding(
                mediaFileID: request.mediaFileID, episodeRef: episodeRef, isManual: true
            ))
            await self.presentComments(for: episodeRef, forceRefresh: false, token: token)
        }
    }

    func search(query: String) async -> [DanmakuSearchedAnime] {
        guard let provider = preferences?.makeProvider() else { return [] }
        return (try? await provider.searchAnime(query: query)) ?? []
    }

    /// Searches with clean local aliases and returns directly selectable
    /// episodes ordered by title and episode relevance.
    func automaticSuggestions() async -> [DanmakuEpisodeSuggestion] {
        guard let request = currentRequest,
              let provider = preferences?.makeProvider() else { return [] }
        let context = searchContext(for: request)
        let queries = DanmakuAutoMatcher.searchQueries(for: context)
        var responses: [DanmakuSearchResponse] = []
        for (index, query) in queries.enumerated() {
            guard !Task.isCancelled else { return [] }
            if let anime = try? await provider.searchAnime(query: query) {
                responses.append(DanmakuSearchResponse(query: query, queryIndex: index, anime: anime))
            }
        }
        return DanmakuAutoMatcher.rank(responses: responses, context: context)
    }

    // MARK: - Flow

    private func run(request: EpisodeRequest, forceRefresh: Bool) {
        generation = UUID()
        let token = generation
        isReloading = true
        Task { [weak self] in
            guard let self else { return }
            defer { if token == self.generation { self.isReloading = false } }
            await self.identifyThenPresent(request: request, forceRefresh: forceRefresh, token: token)
        }
    }

    private func searchContext(for request: EpisodeRequest) -> DanmakuSearchContext {
        DanmakuSearchContext(
            titleCandidates: request.titleCandidates,
            episodeNumber: request.episodeNumber,
            episodeKind: request.episodeKind
        )
    }

    private func identifyThenPresent(request: EpisodeRequest, forceRefresh: Bool, token: UUID) async {
        // An existing binding (this file, or its earlier match) short-circuits
        // identification entirely — the common path after the first watch.
        if let database,
           let binding = try? await database.danmakuMatch(mediaFileID: request.mediaFileID),
           token == generation {
            await presentComments(for: binding.episodeRef, forceRefresh: forceRefresh, token: token)
            return
        }
        guard token == generation else { return }
        guard let provider = preferences?.makeProvider() else {
            phase = .needsConfiguration
            return
        }

        phase = .matching
        // File identity per the official spec: MD5 of the first 16 MB,
        // computed off the main actor. Hashing is skipped for small files.
        let fileURL = request.fileURL
        let fileHash = await Task.detached(priority: .utility) {
            try? DanmakuFileHasher.hashFile(at: fileURL)
        }.value

        guard token == generation else { return }
        do {
            let result = try await provider.match(
                fileName: request.fileName,
                fileHash: fileHash,
                fileSize: request.fileSize,
                videoDuration: request.duration > 0 ? request.duration : nil
            )
            guard token == generation else { return }
            guard let best = result.best else {
                phase = .noMatch
                return
            }
            if let database {
                try? await database.saveDanmakuMatch(DanmakuMatchBinding(
                    mediaFileID: request.mediaFileID,
                    providerID: provider.metadata.id,
                    episodeID: best.episodeID,
                    animeTitle: best.animeTitle,
                    episodeTitle: best.episodeTitle,
                    shift: best.shift,
                    isManual: false
                ))
            }
            let ref = DanmakuEpisodeRef(
                providerID: provider.metadata.id,
                episodeID: best.episodeID,
                animeTitle: best.animeTitle,
                episodeTitle: best.episodeTitle,
                shift: best.shift
            )
            await presentComments(for: ref, forceRefresh: forceRefresh, token: token)
        } catch {
            guard token == generation else { return }
            // Automatic identification is best-effort: wrong or missing
            // matches fall back to manual selection, never to an error.
            phase = .noMatch
        }
    }

    private func presentComments(for ref: DanmakuEpisodeRef, forceRefresh: Bool, token: UUID) async {
        guard token == generation else { return }
        phase = .loading

        // Cache first: offline replays work, and ordinary playback never
        // hits the API twice for the same episode.
        if !forceRefresh, let database,
           let cached = try? await database.danmakuCache(providerID: ref.providerID, episodeID: ref.episodeID),
           token == generation {
            canvas.setComments(cached.comments, shift: ref.shift)
            markReady(anime: cached.animeTitle, episode: cached.episodeTitle, episodeID: ref.episodeID, cache: .hit)
            return
        }
        guard token == generation, let provider = preferences?.makeProvider() else {
            if token == generation { phase = .needsConfiguration }
            return
        }
        do {
            let comments = try await provider.fetchComments(episodeID: ref.episodeID)
            guard token == generation else { return }
            if let database {
                try? await database.saveDanmakuCache(DanmakuCacheEntry(
                    providerID: ref.providerID,
                    episodeID: ref.episodeID,
                    animeTitle: ref.animeTitle,
                    episodeTitle: ref.episodeTitle,
                    comments: comments
                ))
            }
            canvas.setComments(comments, shift: ref.shift)
            markReady(anime: ref.animeTitle, episode: ref.episodeTitle, episodeID: ref.episodeID, cache: .miss)
        } catch {
            guard token == generation else { return }
            // A stale cache still beats nothing when the network is down.
            if let database,
               let cached = try? await database.danmakuCache(providerID: ref.providerID, episodeID: ref.episodeID) {
                canvas.setComments(cached.comments, shift: ref.shift)
                markReady(anime: cached.animeTitle, episode: cached.episodeTitle, episodeID: ref.episodeID, cache: .hit)
                return
            }
            canvas.setComments([], shift: 0)
            phase = .failed(error.localizedDescription)
        }
    }

    private func markReady(anime: String, episode: String, episodeID: Int64, cache: CacheState) {
        lastReady = (anime, episode, episodeID, cache)
        phase = .ready(anime: anime, episode: episode, episodeID: episodeID, cache: cache)
    }

    // MARK: - Playback clock

    func playbackSample(position: Double, speed: Double, paused: Bool) {
        canvas.playbackSample(position: position, speed: speed, paused: paused)
    }
}
