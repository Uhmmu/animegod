import AnimeGodCore
import Foundation
import SwiftUI

/// The Online section's state: which rules are installed, what a search
/// found, and which episode is being resolved.
///
/// Its own object rather than part of `AppModel` because none of it is
/// library data — nothing here is scanned, matched or stored in the
/// database. A work found this way is a page on somebody's site, and it
/// stops existing the moment that site does.
@MainActor
final class OnlineCoordinator: ObservableObject {
    /// Installed rules, in the user's own order.
    @Published private(set) var rules: [OnlineSourceRule] = []
    /// What the shared catalog offers, once asked.
    @Published private(set) var catalogItems: [OnlineSourceCatalogItem] = []
    @Published private(set) var isLoadingCatalog = false
    /// Rules in the file that would not parse, so the user is told rather
    /// than left wondering where a source went.
    @Published private(set) var unreadableRules = 0

    @Published var keyword = ""
    @Published private(set) var isSearching = false
    @Published private(set) var statuses: [String: OnlineSourceStatus] = [:]
    @Published private(set) var results: [OnlineSearchItem] = []

    /// The work whose episode lines are open.
    @Published private(set) var openWork: OnlineSearchItem?
    @Published private(set) var roads: [OnlineRoad] = []
    @Published private(set) var isLoadingEpisodes = false
    @Published var selectedRoad = 0

    /// The episode currently being resolved, so its row can say so.
    @Published private(set) var resolvingEpisode: String?
    @Published var errorMessage: String?
    /// The last resolution's log, for when a source stops working.
    @Published private(set) var lastResolutionLog: [String] = []

    private let store: OnlineSourceStore
    private let coordinator = OnlineSourceCoordinator()
    private var catalog = OnlineSourceCatalog()
    private let resolver = OnlineStreamResolver()
    private var searchTask: Task<Void, Never>?
    private var episodesTask: Task<Void, Never>?

    init(supportDirectory: URL) {
        store = OnlineSourceStore(
            fileURL: OnlineSourceStore.defaultFileURL(supportDirectory: supportDirectory)
        )
    }

    func load() async {
        do {
            let installed = try await store.load()
            rules = installed.rules
            unreadableRules = installed.unreadable
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Searching

    func search() {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !rules.isEmpty else { return }
        searchTask?.cancel()
        closeWork()
        results = []
        statuses = Dictionary(uniqueKeysWithValues: rules.map { ($0.name, OnlineSourceStatus.searching) })
        isSearching = true
        let rules = rules
        searchTask = Task { [weak self] in
            guard let self else { return }
            // Answers are published one source at a time: one slow site must
            // not hold up the eleven that already replied.
            await coordinator.search(keyword: keyword, rules: rules) { answer in
                Task { @MainActor [weak self] in self?.apply(answer) }
            }
            guard !Task.isCancelled else { return }
            isSearching = false
        }
    }

    private func apply(_ answer: OnlineSourceCoordinator.Answer) {
        statuses[answer.ruleName] = answer.status
        guard !answer.items.isEmpty else { return }
        results.append(contentsOf: answer.items)
        // Grouped by source, in the order the rules are listed, so the list
        // does not reshuffle under the pointer as sources reply.
        let position = Dictionary(uniqueKeysWithValues: rules.enumerated().map { ($1.id, $0) })
        results.sort {
            (position[OnlineSourceRule.identityKey($0.ruleName)] ?? 0)
                < (position[OnlineSourceRule.identityKey($1.ruleName)] ?? 0)
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    // MARK: - Episodes

    func open(_ item: OnlineSearchItem) {
        guard let rule = rules.first(where: { $0.name == item.ruleName }) else { return }
        episodesTask?.cancel()
        openWork = item
        roads = []
        selectedRoad = 0
        isLoadingEpisodes = true
        errorMessage = nil
        episodesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await coordinator.chapters(pageURL: item.pageURL, rule: rule)
                guard !Task.isCancelled, openWork?.id == item.id else { return }
                roads = result.roads
            } catch {
                guard !Task.isCancelled, openWork?.id == item.id else { return }
                errorMessage = OnlineSourceCoordinator.describe(error)
            }
            isLoadingEpisodes = false
        }
    }

    func closeWork() {
        episodesTask?.cancel()
        openWork = nil
        roads = []
        selectedRoad = 0
    }

    // MARK: - Playing

    /// Resolves an episode's stream and hands it to the player.
    ///
    /// Resolution is a browser loading a page, so it takes seconds rather
    /// than milliseconds — the row says which episode is being worked on
    /// instead of the window appearing to hang.
    func play(_ episode: OnlineEpisode, in model: AppModel) {
        guard let work = openWork,
              let rule = rules.first(where: { $0.name == work.ruleName })
        else { return }
        guard resolvingEpisode == nil else { return }
        resolvingEpisode = episode.id
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            defer { resolvingEpisode = nil }
            do {
                let stream = try await resolver.resolve(episodePageURL: episode.pageURL, rule: rule)
                lastResolutionLog = resolver.log
                model.playFile(
                    at: stream.url,
                    title: "\(work.name) · \(episode.label)",
                    headers: stream.headers
                )
            } catch is CancellationError {
                return
            } catch {
                lastResolutionLog = resolver.log
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelResolution() {
        resolver.cancel()
        resolvingEpisode = nil
    }

    // MARK: - Rules

    func refreshCatalog(useMirror: Bool = false) async {
        isLoadingCatalog = true
        catalog = OnlineSourceCatalog(
            baseURL: useMirror ? OnlineSourceCatalog.mirrorIndexURL : OnlineSourceCatalog.defaultIndexURL
        )
        do {
            catalogItems = try await catalog.index()
        } catch {
            errorMessage = String(
                localized: "The rule catalog could not be reached: \(OnlineSourceCoordinator.describe(error))"
            )
        }
        isLoadingCatalog = false
    }

    func install(_ item: OnlineSourceCatalogItem) async {
        do {
            let rule = try await catalog.rule(named: item.name)
            guard !rule.requiresNewerClient else {
                errorMessage = String(localized: "“\(item.name)” needs a newer version of AnimeGod.")
                return
            }
            try await store.install(rule)
            rules = await store.all()
        } catch {
            errorMessage = String(
                localized: "“\(item.name)” could not be installed: \(OnlineSourceCoordinator.describe(error))"
            )
        }
    }

    /// Updates every installed rule the catalog is ahead of.
    func updateAll() async -> (updated: Int, failed: Int) {
        if catalogItems.isEmpty { await refreshCatalog() }
        let candidates = await store.updatable(against: catalogItems)
        var updated = 0
        var failed = 0
        for item in candidates {
            do {
                let rule = try await catalog.rule(named: item.name)
                if try await store.installIfNewer(rule) { updated += 1 }
            } catch {
                failed += 1
            }
        }
        rules = await store.all()
        return (updated, failed)
    }

    func isInstalled(_ item: OnlineSourceCatalogItem) -> Bool {
        rules.contains { $0.id == item.id }
    }

    func hasUpdate(_ item: OnlineSourceCatalogItem) -> Bool {
        guard let installed = rules.first(where: { $0.id == item.id }) else { return false }
        return OnlineSourceCatalog.isNewer(item.version, than: installed.version)
    }

    func remove(_ rule: OnlineSourceRule) async {
        do {
            try await store.remove(named: rule.name)
            rules = await store.all()
            statuses[rule.name] = nil
            results.removeAll { $0.ruleName == rule.name }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        Task {
            try? await store.move(from: Array(offsets), to: destination)
            rules = await store.all()
        }
    }

    /// Takes a rule out of whatever was pasted or dropped in.
    func importRules(from text: String) async {
        do {
            let imported = try OnlineSourceImport.rules(from: text)
            try await store.install(contentsOf: imported)
            rules = await store.all()
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "That is not a source rule AnimeGod can read.")
        }
    }

    func exportRules() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(rules)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
