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

    /// What one provider contributed to the current episode.
    struct SourceSummary: Equatable, Identifiable {
        let providerID: String
        let displayName: String
        let animeTitle: String
        let episodeTitle: String
        let episodeID: Int64
        let commentCount: Int
        let cache: CacheState

        var id: String { providerID }
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
    /// The current episode's comments with the provider shift applied,
    /// sorted by time — the manager panel's data source.
    @Published private(set) var comments: [DanmakuComment] = []
    /// One entry per provider that contributed to the loaded episode. With
    /// a single source this has one element; with merged sources it shows
    /// what each side supplied, before deduplication.
    @Published private(set) var loadedSources: [SourceSummary] = []
    /// Providers that are active but could not identify this file. Surfaced
    /// as a hint, never as a failure: one source missing must not take the
    /// others down with it.
    @Published private(set) var unmatchedSources: [String] = []

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
                guard !preferences.makeProviders().isEmpty else {
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
        guard !preferences.makeProviders().isEmpty else {
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

    /// Manual episode selection from the match sheet. The binding is saved
    /// for that episode's own provider, then the whole pipeline re-runs so
    /// the other active sources keep their existing matches.
    func matchManually(to episodeRef: DanmakuEpisodeRef) {
        guard let request = currentRequest else { return }
        generation = UUID()
        let token = generation
        isReloading = true
        phase = .loading
        Task { [weak self] in
            guard let self else { return }
            defer { if token == self.generation { self.isReloading = false } }
            if let database = self.database {
                try? await database.saveDanmakuMatch(DanmakuMatchBinding(
                    mediaFileID: request.mediaFileID, episodeRef: episodeRef, isManual: true
                ))
            }
            guard token == self.generation else { return }
            await self.identifyThenPresent(request: request, forceRefresh: false, token: token)
        }
    }

    /// Searches every active source and returns the results together; each
    /// result carries the provider that can serve it.
    func search(query: String) async -> [DanmakuSearchedAnime] {
        var results: [DanmakuSearchedAnime] = []
        for provider in preferences?.makeProviders() ?? [] {
            guard !Task.isCancelled else { break }
            results += (try? await provider.searchAnime(query: query)) ?? []
        }
        return results
    }

    /// Searches with clean local aliases and returns directly selectable
    /// episodes ordered by title and episode relevance, across every active
    /// source.
    func automaticSuggestions() async -> [DanmakuEpisodeSuggestion] {
        guard let request = currentRequest else { return [] }
        let context = searchContext(for: request)
        let queries = DanmakuAutoMatcher.searchQueries(for: context)
        var responses: [DanmakuSearchResponse] = []
        for provider in preferences?.makeProviders() ?? [] {
            for (index, query) in queries.enumerated() {
                guard !Task.isCancelled else { return [] }
                if let anime = try? await provider.searchAnime(query: query) {
                    responses.append(DanmakuSearchResponse(query: query, queryIndex: index, anime: anime))
                }
            }
        }
        return DanmakuAutoMatcher.rank(responses: responses, context: context)
    }

    /// The provider ids the current preferences activate, in priority order.
    var activeProviderIDs: [String] {
        (preferences?.makeProviders() ?? []).map(\.metadata.id)
    }

    var activeProviderDisplayNames: [String] {
        (preferences?.makeProviders() ?? []).map(\.metadata.displayName)
    }

    // MARK: - Flow

    private func run(request: EpisodeRequest, forceRefresh: Bool) {
        // Another file's per-source breakdown must not linger on screen
        // while this one is identified.
        loadedSources = []
        unmatchedSources = []
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
        let providers = preferences?.makeProviders() ?? []
        guard !providers.isEmpty else {
            phase = .needsConfiguration
            return
        }
        phase = .matching

        // dandanplay identifies by file hash; Bilibili has no such API and
        // matches on metadata instead, so the hash is computed at most once
        // and only when a provider can use it.
        var fileHash: String?
        if providers.contains(where: { $0.metadata.id == "dandanplay" }) {
            let fileURL = request.fileURL
            fileHash = await Task.detached(priority: .utility) {
                try? DanmakuFileHasher.hashFile(at: fileURL)
            }.value
        }
        guard token == generation else { return }

        var refs: [(provider: any DanmakuProvider, ref: DanmakuEpisodeRef)] = []
        var unmatched: [String] = []
        for provider in providers {
            guard token == generation else { return }
            if let ref = await resolveRef(
                provider: provider, request: request, fileHash: fileHash, token: token
            ) {
                refs.append((provider, ref))
            } else {
                unmatched.append(provider.metadata.displayName)
            }
        }
        guard token == generation else { return }
        unmatchedSources = unmatched
        guard !refs.isEmpty else {
            phase = .noMatch
            return
        }
        await presentComments(for: refs, request: request, forceRefresh: forceRefresh, token: token)
    }

    /// Finds the episode one provider should serve: an existing binding
    /// first — the common path after the first watch — then identification.
    private func resolveRef(
        provider: any DanmakuProvider,
        request: EpisodeRequest,
        fileHash: String?,
        token: UUID
    ) async -> DanmakuEpisodeRef? {
        let providerID = provider.metadata.id
        if let database,
           let binding = try? await database.danmakuMatch(mediaFileID: request.mediaFileID, providerID: providerID) {
            return binding.episodeRef
        }
        guard token == generation else { return nil }
        do {
            let result = try await provider.match(
                fileName: request.fileName,
                fileHash: fileHash,
                fileSize: request.fileSize,
                videoDuration: request.duration > 0 ? request.duration : nil,
                searchContext: searchContext(for: request)
            )
            // An unconfident result is offered in the match sheet but only
            // bound automatically by providers whose ambiguity means
            // "the same episode, listed twice".
            guard let best = result.best,
                  result.isMatched || provider.bindsAmbiguousMatches else { return nil }
            let ref = DanmakuEpisodeRef(
                providerID: providerID,
                episodeID: best.episodeID,
                animeTitle: best.animeTitle,
                episodeTitle: best.episodeTitle,
                shift: best.shift,
                providerContext: best.providerContext
            )
            if let database {
                try? await database.saveDanmakuMatch(
                    DanmakuMatchBinding(mediaFileID: request.mediaFileID, episodeRef: ref, isManual: false)
                )
            }
            return ref
        } catch {
            // Automatic identification is best-effort: a provider that
            // errors out simply contributes nothing this time.
            return nil
        }
    }

    /// Loads every resolved source (cache first) and hands the merged list
    /// to the renderer.
    private func presentComments(
        for refs: [(provider: any DanmakuProvider, ref: DanmakuEpisodeRef)],
        request: EpisodeRequest,
        forceRefresh: Bool,
        token: UUID
    ) async {
        guard token == generation else { return }
        phase = .loading

        var summaries: [SourceSummary] = []
        var lists: [[DanmakuComment]] = []
        var lastError: Error?

        for (provider, ref) in refs {
            guard token == generation else { return }
            let loaded = await load(provider: provider, ref: ref, request: request, forceRefresh: forceRefresh)
            switch loaded {
            case let .success(comments, cache, animeTitle, episodeTitle):
                lists.append(shifted(comments, by: ref.shift))
                summaries.append(SourceSummary(
                    providerID: ref.providerID,
                    displayName: provider.metadata.displayName,
                    animeTitle: animeTitle,
                    episodeTitle: episodeTitle,
                    episodeID: ref.episodeID,
                    commentCount: comments.count,
                    cache: cache
                ))
            case let .failure(error):
                lastError = error
            }
        }
        guard token == generation else { return }

        guard let primary = summaries.first else {
            show([])
            loadedSources = []
            phase = .failed(lastError?.localizedDescription ?? String(localized: "Danmaku could not be loaded."))
            return
        }
        loadedSources = summaries
        // Sources are merged in preference order, so the first provider's
        // copy of a duplicated comment is the one that survives.
        show(DanmakuCommentMerger.merge(lists))
        markReady(
            anime: primary.animeTitle,
            episode: primary.episodeTitle,
            episodeID: primary.episodeID,
            cache: summaries.allSatisfy { $0.cache == .hit } ? .hit : .miss
        )
    }

    private enum SourceLoad {
        case success(comments: [DanmakuComment], cache: CacheState, animeTitle: String, episodeTitle: String)
        case failure(Error)
    }

    private func load(
        provider: any DanmakuProvider,
        ref: DanmakuEpisodeRef,
        request: EpisodeRequest,
        forceRefresh: Bool
    ) async -> SourceLoad {
        // Cache first: offline replays work, and ordinary playback never
        // hits the API twice for the same episode.
        if !forceRefresh, let database,
           let cached = try? await database.danmakuCache(providerID: ref.providerID, episodeID: ref.episodeID) {
            return .success(
                comments: cached.comments, cache: .hit,
                animeTitle: cached.animeTitle, episodeTitle: cached.episodeTitle
            )
        }
        do {
            let comments = try await provider.fetchComments(
                for: ref,
                mediaDuration: request.duration > 0 ? request.duration : nil
            )
            if let database {
                try? await database.saveDanmakuCache(DanmakuCacheEntry(
                    providerID: ref.providerID,
                    episodeID: ref.episodeID,
                    animeTitle: ref.animeTitle,
                    episodeTitle: ref.episodeTitle,
                    comments: comments
                ))
            }
            return .success(
                comments: comments, cache: .miss,
                animeTitle: ref.animeTitle, episodeTitle: ref.episodeTitle
            )
        } catch {
            // A stale cache still beats nothing when the network is down.
            if let database,
               let cached = try? await database.danmakuCache(providerID: ref.providerID, episodeID: ref.episodeID) {
                return .success(
                    comments: cached.comments, cache: .hit,
                    animeTitle: cached.animeTitle, episodeTitle: cached.episodeTitle
                )
            }
            return .failure(error)
        }
    }

    /// Applies a provider's reported time shift before merging, so every
    /// source is on the same timeline.
    private func shifted(_ comments: [DanmakuComment], by shift: Double) -> [DanmakuComment] {
        guard shift != 0 else { return comments }
        return comments.map { comment in
            DanmakuComment(
                id: comment.id, time: comment.time + shift, text: comment.text,
                mode: comment.mode, color: comment.color,
                senderID: comment.senderID, timestamp: comment.timestamp, source: comment.source
            )
        }
    }

    /// Hands the same sorted list to the renderer and the manager panel.
    /// Provider shifts are already baked in by `shifted(_:by:)`, because
    /// merging requires every source to share one timeline.
    private func show(_ comments: [DanmakuComment]) {
        var baked = comments
        baked.sort { (lhs: DanmakuComment, rhs: DanmakuComment) -> Bool in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            return lhs.id < rhs.id
        }
        self.comments = baked
        canvas.setComments(baked, shift: 0)
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
