import AnimeGodCore
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Which anime indexes release searches use. Shared by Settings and every
/// search window, persisted in UserDefaults.
@MainActor
final class TorrentSourcePreferences: ObservableObject {
    private let defaults: UserDefaults
    private static let sourcesKey = "torrent.enabledSources"
    private static let historyKey = "torrent.searchHistory"
    static let historyLimit = 50

    @Published var enabledSources: Set<TorrentSourceID> {
        didSet { defaults.set(enabledSources.map(\.rawValue).sorted(), forKey: Self.sourcesKey) }
    }

    /// Most recent first, case-insensitively unique.
    @Published private(set) var history: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.stringArray(forKey: Self.sourcesKey) {
            enabledSources = Set(stored.compactMap(TorrentSourceID.init(rawValue:)))
        } else {
            enabledSources = Set(TorrentSourceID.allCases)
        }
        history = defaults.stringArray(forKey: Self.historyKey) ?? []
    }

    func set(_ source: TorrentSourceID, enabled: Bool) {
        if enabled { enabledSources.insert(source) } else { enabledSources.remove(source) }
    }

    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        history.insert(trimmed, at: 0)
        history = Array(history.prefix(Self.historyLimit))
        defaults.set(history, forKey: Self.historyKey)
    }

    func clearHistory() {
        history = []
        defaults.removeObject(forKey: Self.historyKey)
    }
}

/// One release search: the query, the streaming snapshot, filters, and the
/// actions on a result. The sidebar keeps one alive across navigation; the
/// anime detail sheet makes its own, pre-filled with the title's aliases.
@MainActor
final class TorrentSearchModel: ObservableObject {
    /// How the same results are presented: one row per release, or one row
    /// per fansub's season.
    enum Layout: String, CaseIterable, Identifiable {
        case releases
        case episodeSets

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .releases: String(localized: "Releases")
            case .episodeSets: String(localized: "Episode Sets")
            }
        }
    }

    @Published var queryText: String
    @Published private(set) var snapshot: TorrentSearchSnapshot? {
        didSet {
            episodeSetsCache = nil
            scheduleCache = nil
        }
    }
    @Published private(set) var isSearching = false
    @Published var filter: TorrentResultFilter {
        didSet {
            guard filter != oldValue else { return }
            episodeSetsCache = nil
            // The schedule reads the library's episodes out of the filter, so
            // it goes stale with it even though the filters themselves must
            // not change the answer to "has anybody published episode 11".
            if filter.ownedEpisodes != oldValue.ownedEpisodes { scheduleCache = nil }
        }
    }
    @Published var sortOrder: TorrentResultMerger.SortOrder = .relevance
    /// Seasons, not single releases, is where a search starts. What is wanted
    /// from a search is almost always "get me this show", and the set answers
    /// that in one press; the release table is for picking a particular
    /// encode, which is the rarer question.
    @Published var layout: Layout = .episodeSets {
        didSet { if !isChoosingLayout { layoutWasChosen = true } }
    }
    /// The user has picked a side themselves, so stop choosing for them.
    private var layoutWasChosen = false
    private var isChoosingLayout = false
    /// Fill an episode a fansub never published from the closest other
    /// team, rather than leaving a hole in the season.
    @Published var fillsGapsFromOtherGroups = true {
        didSet { if fillsGapsFromOtherGroups != oldValue { episodeSetsCache = nil } }
    }
    @Published var statusMessage: String?

    let preferences: TorrentSourcePreferences
    private let coordinator: TorrentSearchCoordinator
    private let fetcher = TorrentFileFetcher()
    private var searchTask: Task<Void, Never>?
    private var generation = 0
    private var episodeSetsCache: [TorrentEpisodeSet]?
    private var scheduleCache: TorrentReleaseSchedule?
    /// What the caller handed over, kept so a fresh search falls back to it
    /// rather than to whatever the last title resolved to.
    private let suppliedEpisodeCount: Int?
    private var lastResolvedQueries: [String] = []

    init(
        preferences: TorrentSourcePreferences,
        queries: [String] = [],
        ownedEpisodes: Set<Double> = [],
        expectedEpisodeCount: Int? = nil,
        coordinator: TorrentSearchCoordinator = TorrentSearchCoordinator()
    ) {
        self.preferences = preferences
        self.coordinator = coordinator
        queryText = queries.joined(separator: ", ")
        filter = TorrentResultFilter(ownedEpisodes: ownedEpisodes)
        suppliedEpisodeCount = expectedEpisodeCount
        self.expectedEpisodeCount = expectedEpisodeCount
    }

    /// Looks the season length up once per query, after the results are in.
    /// Quiet on failure: this only sharpens the "still airing" answer, and a
    /// provider being down must not hold a search up.
    private func resolveEpisodeCount(for queries: [String]) async {
        guard expectedEpisodeCount == nil, let provider = episodeCountProvider else { return }
        let asked = generation
        for query in queries.prefix(2) {
            guard let count = await provider(query) else { continue }
            guard generation == asked else { return }
            expectedEpisodeCount = count
            return
        }
    }

    var hasOwnedEpisodes: Bool { !filter.ownedEpisodes.isEmpty }

    /// How long the season is. Set from the anime's own metadata when the
    /// search was opened from one, and otherwise looked up from the title
    /// once a search finishes — the sidebar search has no anime behind it,
    /// and without this a twelve-episode season that ended last Thursday
    /// reads as unfinished until the silence is long enough to notice.
    @Published private(set) var expectedEpisodeCount: Int? {
        didSet { if expectedEpisodeCount != oldValue { scheduleCache = nil } }
    }

    /// Answers "how many episodes does this season have" for a bare title.
    /// Supplied by AppModel, which owns the metadata providers.
    var episodeCountProvider: ((String) async -> Int?)?

    /// What the whole result set says about the show's release rhythm: how far
    /// it has got, how often an episode appears, and whether it is still
    /// running. Read from every result rather than the filtered ones — "has
    /// anybody published episode 11" is not a question the current filters
    /// should be able to change the answer to.
    var schedule: TorrentReleaseSchedule {
        if let scheduleCache { return scheduleCache }
        let built = TorrentReleaseSchedule.analyse(
            results: snapshot?.results ?? [],
            expectedEpisodeCount: expectedEpisodeCount,
            ownedEpisodes: filter.ownedEpisodes
        )
        scheduleCache = built
        return built
    }

    var displayedResults: [TorrentSearchResult] {
        TorrentResultMerger.sort(filter.apply(snapshot?.results ?? []), by: sortOrder)
    }

    var facets: TorrentResultFacets { TorrentResultFacets(results: snapshot?.results ?? []) }

    /// One assembled season per fansub line, best first.
    ///
    /// Built from the same filtered results the table shows, minus batches —
    /// avoiding a 40 GB batch is the whole point — and never narrowed to
    /// missing episodes, because a set shows the episodes on disk too. The
    /// result is cached: a search streams ~80 snapshots and SwiftUI
    /// re-evaluates the list far more often than either changes.
    var episodeSets: [TorrentEpisodeSet] {
        if let episodeSetsCache { return episodeSetsCache }
        var setFilter = filter
        setFilter.batchMode = .episodesOnly
        setFilter.missingEpisodesOnly = false
        let built = TorrentEpisodeSetBuilder.build(
            from: setFilter.apply(snapshot?.results ?? []),
            options: TorrentEpisodeSetOptions(
                ownedEpisodes: filter.ownedEpisodes,
                allowsSubstitutes: fillsGapsFromOtherGroups
            )
        )
        episodeSetsCache = built
        return built
    }

    var hiddenCount: Int { (snapshot?.results.count ?? 0) - displayedResults.count }

    func search() {
        let queries = TorrentSearchCoordinator.splitQueries(queryText)
        guard !queries.isEmpty else { return }
        // A new title needs its own answer; the previous one's would be worse
        // than none.
        if !queries.elementsEqual(lastResolvedQueries) {
            expectedEpisodeCount = suppliedEpisodeCount
            lastResolvedQueries = queries
        }
        let sources = TorrentSourceID.allCases.filter(preferences.enabledSources.contains)
        guard !sources.isEmpty else {
            statusMessage = String(localized: "Turn on at least one release source in Settings.")
            return
        }
        preferences.record(queryText)
        // Group filters refer to the previous result set.
        filter.groups = []
        run(coordinator.search(queries: queries, sources: sources))
    }

    func retryFailed() {
        guard let snapshot, snapshot.canRetry else { return }
        run(coordinator.retry(snapshot))
    }

    func cancel() {
        searchTask?.cancel()
        generation += 1
        snapshot = snapshot?.cancelled()
        isSearching = false
    }

    private func run(_ stream: AsyncStream<TorrentSearchSnapshot>) {
        searchTask?.cancel()
        generation += 1
        let current = generation
        statusMessage = nil
        isSearching = true
        searchTask = Task { [weak self] in
            for await snapshot in stream {
                // A cancelled search can still deliver its final snapshot
                // after a newer one started.
                guard let self, self.generation == current else { return }
                self.snapshot = snapshot
            }
            guard let self, self.generation == current else { return }
            self.isSearching = false
            self.chooseLayout()
            await self.resolveEpisodeCount(for: TorrentSearchCoordinator.splitQueries(self.queryText))
        }
    }

    /// Which side a finished search lands on, until the user says otherwise.
    ///
    /// Sets whenever there are any, because that is the answer to "get me
    /// this show". There are none when a season is in its first week — a line
    /// needs two episodes to be a season — and an empty screen is no answer
    /// at all when the one episode that exists is right there in the results,
    /// so that search shows the releases instead. Decided once a search ends,
    /// never while it streams: the sets are rebuilt from every snapshot, and
    /// a view that swapped under the pointer eighty times would be unusable.
    private func chooseLayout() {
        guard !layoutWasChosen, !(snapshot?.results.isEmpty ?? true) else { return }
        let wanted: Layout = episodeSets.isEmpty ? .releases : .episodeSets
        guard wanted != layout else { return }
        isChoosingLayout = true
        layout = wanted
        isChoosingLayout = false
    }

    // MARK: - Result actions

    func copyMagnet(_ result: TorrentSearchResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.magnet.uri, forType: .string)
        statusMessage = String(localized: "Copied the magnet link for “\(result.title)”.")
    }

    /// Every release in a set, so it can be handed to another client.
    func copyMagnets(of set: TorrentEpisodeSet, includingOwned: Bool = false) {
        let entries = includingOwned ? set.entries.filter { !$0.isExtra } : set.downloadableEntries
        copyMagnets(entries.map(\.result))
    }

    func copyMagnets(_ results: [TorrentSearchResult]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(results.map(\.magnet.uri).joined(separator: "\n"), forType: .string)
        statusMessage = String(localized: "Copied \(results.count) magnet links.")
    }

    /// Hands the magnet to whichever app handles `magnet:` links.
    func openMagnet(_ result: TorrentSearchResult) {
        guard let url = URL(string: result.magnet.uri) else { return }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            copyMagnet(result)
            statusMessage = String(localized: "No app on this Mac opens magnet links, so the link was copied instead.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openPage(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func saveTorrent(_ result: TorrentSearchResult) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Torrent File")
        panel.nameFieldStringValue = Self.fileName(for: result)
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        statusMessage = String(localized: "Fetching the torrent file…")
        Task {
            do {
                let (data, _) = try await fetcher.fetch(result)
                try data.write(to: destination, options: .atomic)
                statusMessage = String(localized: "Saved “\(destination.lastPathComponent)”.")
            } catch {
                statusMessage = String(localized: "No verified torrent file is available for this release. Use its magnet link instead.")
            }
        }
    }

    private static func fileName(for result: TorrentSearchResult) -> String {
        let cleaned = result.title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return String(cleaned.prefix(180)) + ".torrent"
    }
}
