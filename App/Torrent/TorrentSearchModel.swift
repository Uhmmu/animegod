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
    @Published var queryText: String
    @Published private(set) var snapshot: TorrentSearchSnapshot?
    @Published private(set) var isSearching = false
    @Published var filter: TorrentResultFilter
    @Published var sortOrder: TorrentResultMerger.SortOrder = .relevance
    @Published var statusMessage: String?

    let preferences: TorrentSourcePreferences
    private let coordinator: TorrentSearchCoordinator
    private let fetcher = TorrentFileFetcher()
    private var searchTask: Task<Void, Never>?
    private var generation = 0

    init(
        preferences: TorrentSourcePreferences,
        queries: [String] = [],
        ownedEpisodes: Set<Double> = [],
        coordinator: TorrentSearchCoordinator = TorrentSearchCoordinator()
    ) {
        self.preferences = preferences
        self.coordinator = coordinator
        queryText = queries.joined(separator: ", ")
        filter = TorrentResultFilter(ownedEpisodes: ownedEpisodes)
    }

    var hasOwnedEpisodes: Bool { !filter.ownedEpisodes.isEmpty }

    var displayedResults: [TorrentSearchResult] {
        TorrentResultMerger.sort(filter.apply(snapshot?.results ?? []), by: sortOrder)
    }

    var facets: TorrentResultFacets { TorrentResultFacets(results: snapshot?.results ?? []) }

    var hiddenCount: Int { (snapshot?.results.count ?? 0) - displayedResults.count }

    func search() {
        let queries = TorrentSearchCoordinator.splitQueries(queryText)
        guard !queries.isEmpty else { return }
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
        }
    }

    // MARK: - Result actions

    func copyMagnet(_ result: TorrentSearchResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.magnet.uri, forType: .string)
        statusMessage = String(localized: "Copied the magnet link for “\(result.title)”.")
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
