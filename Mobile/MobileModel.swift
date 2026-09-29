import AnimeGodCore
import Foundation

/// The phone's hub.
///
/// Reads come from the cache first and are refreshed behind it, so the app
/// opens instantly and still browses with the Mac asleep. Writes never touch
/// the cache: they go to the outbox, are sent to the Mac, and what comes back
/// is what counts — the Mac's database is the single source of truth.
@MainActor
final class MobileModel: ObservableObject {
    @Published private(set) var works: [LinkWork] = []
    @Published private(set) var continueWatching: [LinkEpisode] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isReachable = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var macName: String?
    @Published var sortOrder: MobileSortOrder = .watchStatus
    /// Stored rather than computed off `LinkCredentials`: a computed property
    /// reading the Keychain publishes nothing, so the first screen stayed on
    /// "Not Paired" after a pairing that had in fact succeeded.
    @Published private(set) var isPaired = false

    let resolver = LinkResolver()
    /// Episodes copied onto this phone, playable with no network at all.
    let offline = MobileOfflineStore()
    private var client: LinkClient?
    private var detailCache: [UUID: LinkAnimeDetail] = [:]

    init() {
        works = LinkCache.load(LinkLibrary.self, "library")?.works ?? []
        continueWatching = LinkCache.load([LinkEpisode].self, "continue") ?? []
        macName = LinkCredentials.macName
        isPaired = LinkCredentials.isPaired
        if let host = LinkCredentials.host, let token = LinkCredentials.token {
            client = LinkClient(host: host, token: token)
        }
    }

    // MARK: - Pairing

    func pair(host: String, code: String) async throws {
        let name = await UIDeviceName.current
        let response = try await LinkClient.pair(host: host, code: code, deviceName: name)
        LinkCredentials.token = response.token
        LinkCredentials.host = host
        var book = LinkCredentials.addresses
        book.remember(host, network: resolver.networkName)
        LinkCredentials.addresses = book
        LinkCredentials.macName = response.macName
        macName = response.macName
        client = LinkClient(host: host, token: response.token)
        isPaired = true
        await refresh()
    }

    func unpair() {
        LinkCredentials.forget()
        LinkCache.clear()
        client = nil
        works = []
        continueWatching = []
        detailCache = [:]
        macName = nil
        isReachable = false
        isPaired = false
        cancelReconnect()
    }

    // MARK: - Reconnecting

    private var reconnectTask: Task<Void, Never>?
    /// How long to keep looking before giving up until something changes.
    private static let reconnectWindow: Duration = .seconds(180)

    /// Keeps looking for the Mac on its own, then stops.
    ///
    /// Not finding it usually means the wrong network, and each attempt races
    /// every known address — a burst of connections, Bonjour included. Hunting
    /// on that schedule all day in a pocket would be rude to the battery and
    /// to the network, and pointless: if it has not answered in three minutes
    /// it is not about to. So the interval widens, the window closes, and
    /// bringing the app forward opens a fresh one — which is the moment
    /// something has plausibly changed.
    private func scheduleReconnect() {
        guard isPaired, !isReachable, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.reconnectWindow)
            var delay = Duration.seconds(2)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.isPaired, !self.isReachable else { break }
                await self.refresh()
                if self.isReachable { break }
                delay = min(delay * 2, .seconds(30))
            }
            self?.reconnectTask = nil
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// The app came forward: worth another window, whatever the last one
    /// concluded.
    func resumeFromBackground() async {
        cancelReconnect()
        await refresh()
    }

    // MARK: - Sync

    func refresh() async {
        guard let client else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Every known address is raced, not just the last one that worked:
        // the phone does not know which network it is on, and a Tailscale
        // name is the only thing that answers from outside.
        var book = LinkCredentials.addresses
        let candidates = resolver.candidates(from: book)
        if let host = await resolver.resolve(candidates: candidates) {
            book.remember(host, network: resolver.networkName)
            LinkCredentials.addresses = book
            LinkCredentials.host = host
            resolver.noteActive(host: host)
            await client.update(host: host)
            isReachable = true
        } else {
            resolver.noteActive(host: nil)
            isReachable = false
            lastError = book.tailscale == nil
                ? String(localized: "Could not reach your Mac. Is AnimeGod open on it? Off your own network, add its Tailscale address in Settings.")
                : String(localized: "Could not reach your Mac. Is AnimeGod open on it?")
            scheduleReconnect()
            return
        }
        cancelReconnect()

        await flushOutbox()

        do {
            let library = try await client.library()
            works = library.works
            LinkCache.save(library, "library")

            let items = try await client.continueWatching()
            continueWatching = items
            LinkCache.save(items, "continue")

            lastSyncedAt = .now
            lastError = nil
        } catch {
            lastError = describe(error)
        }
    }

    /// Sends anything the phone wrote while the Mac was unreachable. An entry
    /// that fails stays queued; one the Mac rejects outright is dropped, or it
    /// would be retried for ever.
    private func flushOutbox() async {
        guard let client else { return }
        for entry in LinkOutbox.pending() {
            do {
                try await client.putProgress(episodeID: entry.episodeID, entry.update)
                LinkOutbox.remove(id: entry.id)
            } catch let error as LinkError where error.code == .notFound || error.code == .badRequest {
                LinkOutbox.remove(id: entry.id)
            } catch {
                break
            }
        }
    }

    // MARK: - Reads

    func detail(for animeID: UUID) async -> LinkAnimeDetail? {
        if let cached = LinkCache.load(LinkAnimeDetail.self, "anime-\(animeID.uuidString)") {
            detailCache[animeID] = cached
        }
        guard let client else { return detailCache[animeID] }
        do {
            let detail = try await client.detail(animeID: animeID)
            detailCache[animeID] = detail
            LinkCache.save(detail, "anime-\(animeID.uuidString)")
            return detail
        } catch {
            return detailCache[animeID]
        }
    }

    func cachedDetail(for animeID: UUID) -> LinkAnimeDetail? { detailCache[animeID] }

    /// Posters are fetched through the Mac and kept on the phone, so a work
    /// that has been opened once still shows its cover offline.
    func posterData(for animeID: UUID) async -> Data? {
        if let cached = LinkCache.poster(animeID: animeID) { return cached }
        guard let client else { return nil }
        guard let data = try? await client.poster(animeID: animeID), !data.isEmpty else { return nil }
        LinkCache.savePoster(data, animeID: animeID)
        return data
    }

    // MARK: - Playback

    /// Where the phone streams an episode from, and the header that gets it in.
    ///
    /// The token goes in a header rather than the URL: a URL lands in logs and
    /// history, and `-smokeLink` proves libmpv honours `http-header-fields`.
    /// A downloaded copy, when there is one. Preferred over the link: it
    /// needs no Mac, no network, and no claim.
    func offlineURL(for episode: LinkEpisode) -> URL? {
        offline.localURL(for: episode.id)
    }

    func playbackTarget(for episode: LinkEpisode) -> (url: URL, authorization: String)? {
        guard let host = LinkCredentials.host,
              let token = LinkCredentials.token,
              let url = URL(string: "http://\(host)")?
                  .appending(path: LinkProtocol.Route.mediaPrefix + episode.mediaFileID.uuidString)
        else { return nil }
        return (url, LinkProtocol.bearerPrefix + token)
    }

    /// The danmaku pool for a file, cached on the phone.
    ///
    /// Everything hard already happened on the Mac: the dandanplay file hash,
    /// Bilibili's WBI signing, the per-part cid, the cross-source merge with
    /// each provider's shift baked in. The phone asks for comments and gets
    /// comments, holds no credentials, and cannot disagree with the Mac about
    /// which pool belongs to which file.
    func danmaku(mediaFileID: UUID) async -> LinkDanmakuPool? {
        let name = "danmaku-\(mediaFileID.uuidString)"
        if let cached = LinkCache.load(LinkDanmakuPool.self, name), !cached.comments.isEmpty {
            return cached
        }
        guard let client, let pool = try? await client.danmaku(mediaFileID: mediaFileID) else { return nil }
        if !pool.comments.isEmpty { LinkCache.save(pool, name) }
        return pool
    }

    /// The address that reaches the Mac from outside this network. Typed
    /// rather than discovered, and never overwritten by a resolution.
    var tailscaleAddress: String {
        get { LinkCredentials.addresses.tailscale ?? "" }
        set {
            var book = LinkCredentials.addresses
            book.setTailscale(newValue)
            LinkCredentials.addresses = book
            objectWillChange.send()
        }
    }

    // MARK: - The More tab

    /// These screens are read on demand rather than kept in the main sync:
    /// nobody opens the diary often, and statistics are expensive to build.
    /// Each caches its last answer so the screen is not empty offline.
    func diary() async -> LinkDiary? {
        await fetch("diary", LinkDiary.self) { try await $0.diary() }
    }

    func rankings() async -> [LinkRankedWork]? {
        await fetch("rankings", [LinkRankedWork].self) { try await $0.rankings() }
    }

    func statistics(year: Int?) async -> StatisticsReport? {
        await fetch("statistics-\(year.map(String.init) ?? "current")", StatisticsReport.self) {
            try await $0.statistics(year: year)
        }
    }

    func downloads() async -> [LinkDownload]? {
        guard let client else { return nil }
        return try? await client.downloads()
    }

    func subscriptions() async -> [LinkSubscription]? {
        guard let client else { return nil }
        return try? await client.subscriptions()
    }

    /// Charts are never cached: they are somebody else's live data, and a
    /// stale ranking is worse than an honest "could not reach".
    func charts(channel: String, page: Int) async throws -> LinkCharts {
        guard let client else {
            throw LinkError(code: .unavailable, message: String(localized: "Not paired with a Mac."))
        }
        return try await client.charts(channel: channel, page: page)
    }

    func downloadAction(infoHash: String, _ action: String) async {
        guard let client else { return }
        try? await client.downloadAction(infoHash: infoHash, action)
    }

    func setSubscriptionEnabled(id: UUID, _ isEnabled: Bool) async {
        guard let client else { return }
        try? await client.setSubscriptionEnabled(id: id, isEnabled)
    }

    private func fetch<T: Codable & Sendable>(
        _ name: String,
        _ type: T.Type,
        _ load: (LinkClient) async throws -> T
    ) async -> T? {
        guard let client else { return LinkCache.load(type, name) }
        guard let value = try? await load(client) else { return LinkCache.load(type, name) }
        LinkCache.save(value, name)
        return value
    }

    /// Sidecar subtitles the Mac has for a file. Cached, so an offline
    /// episode still lists what it has.
    func subtitles(mediaFileID: UUID) async -> LinkSubtitleList? {
        guard let client, let list = try? await client.subtitles(mediaFileID: mediaFileID) else {
            return MobileSubtitleStore.remembered(mediaFileID: mediaFileID)
        }
        MobileSubtitleStore.remember(list)
        return list
    }

    func subtitleText(mediaFileID: UUID, id: UUID) async -> String? {
        guard let client else { return nil }
        return try? await client.subtitleText(mediaFileID: mediaFileID, id: id)
    }

    // MARK: - Handoff

    /// Takes an episode from the Mac: it pauses, writes where it got to, and
    /// closes its player. What comes back is the session, not just a
    /// timestamp — the position here is fresher than any row, because the
    /// Mac's autosave only runs every ten seconds.
    func claim(_ episode: LinkEpisode, force: Bool = false) async -> Result<LinkHandoffState, LinkHandoffConflict>? {
        guard let client else { return nil }
        let name = UIDeviceName.current
        return try? await client.claim(episodeID: episode.id, deviceName: name, force: force)
    }

    /// Gives it back. Symmetric with the claim, so phone to Mac is the same
    /// transaction run the other way.
    func release(episodeID: UUID, position: Double, duration: Double, resumeOnMac: Bool) async {
        guard let client else { return }
        try? await client.release(
            LinkHandoffRelease(
                episodeID: episodeID,
                position: position,
                duration: duration,
                resumeOnMac: resumeOnMac
            )
        )
    }

    /// Starts copying an episode onto the phone, subtitles included.
    ///
    /// An episode downloaded for a train with no subtitle is half a download,
    /// and the sidecar is tens of kilobytes against a gigabyte of video.
    func downloadOffline(_ episode: LinkEpisode) {
        guard let target = playbackTarget(for: episode) else { return }
        offline.download(episode: episode, title: title(forAnimeID: episode.animeID), target: target)
        Task {
            guard let list = await subtitles(mediaFileID: episode.mediaFileID) else { return }
            for record in list.subtitles where record.isActive || list.active == nil {
                _ = await MobileSubtitleStore.fetch(mediaFileID: episode.mediaFileID, record: record, using: self)
            }
        }
    }

    // MARK: - Writes

    func saveProgress(episodeID: UUID, position: Double, duration: Double) async {
        let update = LinkProgressUpdate(position: position, duration: duration)
        guard let client else {
            LinkOutbox.enqueue(.init(episodeID: episodeID, update: update))
            return
        }
        do {
            try await client.putProgress(episodeID: episodeID, update)
        } catch {
            LinkOutbox.enqueue(.init(episodeID: episodeID, update: update))
        }
    }

    func setWatched(_ isWatched: Bool, episodeID: UUID) async {
        guard let client else { return }
        try? await client.setWatched(episodeID: episodeID, isWatched)
        await refresh()
    }

    // MARK: - Display

    private func describe(_ error: any Error) -> String {
        (error as? LinkError)?.message ?? error.localizedDescription
    }

    func work(id: UUID) -> LinkWork? { works.first { $0.id == id } }

    func title(forAnimeID animeID: UUID) -> String {
        work(id: animeID)?.displayTitle ?? ""
    }

    /// Latin-leading titles sort ahead of the rest: `localizedStandardCompare`
    /// in a Chinese locale orders Han by pinyin, which is right, but puts every
    /// Latin title after every Chinese one.
    private func precedes(_ a: String, _ b: String) -> Bool {
        func isLatin(_ s: String) -> Bool {
            guard let first = s.unicodeScalars.first(where: { !$0.properties.isWhitespace }) else { return false }
            return first.value < 0x2E80
        }
        let la = isLatin(a), lb = isLatin(b)
        if la != lb { return la }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    var sortedWorks: [LinkWork] {
        switch sortOrder {
        case .title:
            return works.sorted { precedes($0.sortKey, $1.sortKey) }
        case .recentlyAdded:
            return works.sorted { $0.createdAt > $1.createdAt }
        case .rating:
            return works.sorted { ($0.score ?? -1) > ($1.score ?? -1) }
        case .watchStatus:
            func rank(_ e: LinkWork) -> Int { e.isFinished ? 0 : (e.isInProgress ? 1 : 2) }
            return works.sorted { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                if ra == 2 { return precedes(a.sortKey, b.sortKey) }
                let da = (ra == 0 ? a.lastWatchedAt : a.lastPlayedAt) ?? .distantPast
                let db = (rb == 0 ? b.lastWatchedAt : b.lastPlayedAt) ?? .distantPast
                return da > db
            }
        }
    }
}

enum MobileSortOrder: String, CaseIterable, Identifiable {
    case watchStatus, title, recentlyAdded, rating
    var id: String { rawValue }
    var label: String {
        switch self {
        case .watchStatus: String(localized: "Watch Status")
        case .title: String(localized: "Title")
        case .recentlyAdded: String(localized: "Recently Added")
        case .rating: String(localized: "Rating")
        }
    }
}

enum UIDeviceName {
    @MainActor static var current: String {
        UIDeviceNameBridge.name
    }
}
