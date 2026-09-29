import AnimeGodCore
import Foundation

/// The phone's hub.
///
/// Phase 2 of `docs/IOS_COMPANION_PLAN.md`: the phone keeps a **read-through
/// mirror** of the Mac's library — the same `LibraryDatabase`, the same
/// migrations, the same queries. Nothing here reimplements a query the Mac
/// already has; that reuse is the whole point of the core being portable.
///
/// What is not here yet is the link. The mirror is currently seeded by hand
/// (see `README-PREVIEW.md`); Phase 1 replaces that with `GET /library`.
@MainActor
final class MobileModel: ObservableObject {
    @Published private(set) var library: [LibraryAnime] = []
    @Published private(set) var continueWatching: [EpisodeMedia] = []
    @Published private(set) var metadataByAnimeID: [UUID: AnimeMetadata] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var loadError: String?
    @Published var sortOrder: MobileSortOrder = .watchStatus

    private var database: LibraryDatabase?

    /// Where the mirror lives. The real app writes this from the link; for now
    /// it is copied in beside the app.
    static var mirrorURL: URL {
        URL.documentsDirectory.appending(path: "library.sqlite")
    }

    var isPaired: Bool { database != nil }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard FileManager.default.fileExists(atPath: Self.mirrorURL.path) else {
            loadError = nil
            return
        }
        do {
            let db = try database ?? LibraryDatabase(url: Self.mirrorURL)
            database = db
            library = try await db.library()
            continueWatching = try await db.continueWatching(limit: 12)
            // Bangumi first so a reachable CDN wins over an unreachable one —
            // the same preference `AppModel.posterCandidates` makes.
            var best: [UUID: AnimeMetadata] = [:]
            for entry in try await db.metadata() {
                if let existing = best[entry.animeID], existing.provider == .bangumi { continue }
                best[entry.animeID] = entry
            }
            metadataByAnimeID = best
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func episodes(for animeID: UUID) async -> [EpisodeMedia] {
        guard let database else { return [] }
        return (try? await database.episodes(animeID: animeID)) ?? []
    }

    // MARK: - Display

    /// The title the card shows. The Mac sorts the grid over *this*, not over
    /// `anime.sortTitle` (which is the folder's romaji name) — if the phone
    /// sorted on `sortTitle` the two grids would come out in different orders.
    func displayTitle(for entry: LibraryAnime) -> String {
        let title = metadataByAnimeID[entry.id]?.title
        return (title?.isEmpty == false ? title! : entry.anime.title)
    }

    func posterURL(for animeID: UUID) -> URL? {
        metadataByAnimeID[animeID]?.posterURL
    }

    func score(for animeID: UUID) -> Double? {
        metadataByAnimeID[animeID]?.score
    }

    func title(forAnimeID animeID: UUID) -> String {
        if let entry = library.first(where: { $0.id == animeID }) { return displayTitle(for: entry) }
        return metadataByAnimeID[animeID]?.title ?? ""
    }

    /// Latin-leading titles sort ahead of the rest: `localizedStandardCompare`
    /// in a Chinese locale orders Han by pinyin, which is right, but puts
    /// every Latin title after every Chinese one.
    private func precedes(_ a: String, _ b: String) -> Bool {
        func isLatin(_ s: String) -> Bool {
            guard let first = s.unicodeScalars.first(where: { !$0.properties.isWhitespace }) else { return false }
            return first.value < 0x2E80
        }
        let la = isLatin(a), lb = isLatin(b)
        if la != lb { return la }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    var sortedLibrary: [LibraryAnime] {
        switch sortOrder {
        case .title:
            return library.sorted { precedes(displayTitle(for: $0), displayTitle(for: $1)) }
        case .recentlyAdded:
            return library.sorted { $0.anime.createdAt > $1.anime.createdAt }
        case .rating:
            return library.sorted { (score(for: $0.id) ?? -1) > (score(for: $1.id) ?? -1) }
        case .watchStatus:
            // Finished / Still Watching / Not Started, newest-first in the
            // first two — the Mac's `LibrarySortOrder.watchStatus`.
            func rank(_ e: LibraryAnime) -> Int { e.isFinished ? 0 : (e.isInProgress ? 1 : 2) }
            return library.sorted { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                if ra == 2 { return precedes(displayTitle(for: a), displayTitle(for: b)) }
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
        case .watchStatus: "Watch Status"
        case .title: "Title"
        case .recentlyAdded: "Recently Added"
        case .rating: "Rating"
        }
    }
}
