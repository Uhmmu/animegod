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
    }

    // MARK: - Sync

    func refresh() async {
        guard let client else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // The stored address may be stale — a different network, a new DHCP
        // lease. Racing the ladder costs nothing when the pinned one works.
        let candidates = resolver.candidates(pinned: LinkCredentials.host)
        if let host = await resolver.resolve(candidates: candidates) {
            if host != LinkCredentials.host { LinkCredentials.host = host }
            await client.update(host: host)
            isReachable = true
        } else {
            isReachable = false
            lastError = String(localized: "Could not reach your Mac. Is AnimeGod open on it?")
            return
        }

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
    func playbackTarget(for episode: LinkEpisode) -> (url: URL, authorization: String)? {
        guard let host = LinkCredentials.host,
              let token = LinkCredentials.token,
              let url = URL(string: "http://\(host)")?
                  .appending(path: LinkProtocol.Route.mediaPrefix + episode.mediaFileID.uuidString)
        else { return nil }
        return (url, LinkProtocol.bearerPrefix + token)
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
