import AnimeGodCore
import Combine
import Foundation

/// Runs the standing subscription rules: checks the indexes on a timer,
/// downloads episodes that fit, and records what it did.
///
/// Unattended downloading is held to a stricter standard than a manual
/// search: one release per episode, never something already in the library
/// or downloaded before, and never a title that only loosely matches. Every
/// action is listed in the UI so an unwanted rule is easy to spot and stop.
@MainActor
final class TorrentSubscriptionManager: ObservableObject {
    struct Activity: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let text: String
    }

    @Published private(set) var subscriptions: [TorrentSubscription] = []
    @Published private(set) var isChecking = false
    @Published private(set) var activity: [Activity] = []
    @Published var errorMessage: String?

    /// How often enabled rules are checked. Anime indexes update on release
    /// schedules, so half-hourly is plenty and stays polite.
    static let checkInterval: TimeInterval = 30 * 60
    private static let activityLimit = 50

    private var database: LibraryDatabase?
    private weak var downloads: TorrentDownloadManager?
    private let preferences: TorrentSourcePreferences
    private let coordinator = TorrentSearchCoordinator()
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Episodes already in the library for an anime, so a rule never
    /// re-downloads what is on disk.
    var ownedEpisodesProvider: ((UUID) async -> Set<Double>)?

    init(preferences: TorrentSourcePreferences) {
        self.preferences = preferences
    }

    func attach(database: LibraryDatabase, downloads: TorrentDownloadManager) async {
        self.database = database
        self.downloads = downloads
        await reload()
        startTimer()
    }

    func reload() async {
        guard let database else { return }
        do {
            subscriptions = try await database.torrentSubscriptions()
        } catch {
            errorMessage = String(localized: "Could not read subscriptions: \(error.localizedDescription)")
        }
    }

    var enabledCount: Int { subscriptions.filter(\.isEnabled).count }

    // MARK: - Editing

    func save(_ subscription: TorrentSubscription) async {
        guard let database else { return }
        do {
            try await database.saveTorrentSubscription(subscription)
            await reload()
        } catch {
            errorMessage = String(localized: "Could not save the subscription: \(error.localizedDescription)")
        }
    }

    func remove(_ subscription: TorrentSubscription) async {
        guard let database else { return }
        do {
            try await database.removeTorrentSubscription(id: subscription.id)
            await reload()
        } catch {
            errorMessage = String(localized: "Could not remove the subscription: \(error.localizedDescription)")
        }
    }

    func setEnabled(_ isEnabled: Bool, for subscription: TorrentSubscription) async {
        var updated = subscription
        updated.isEnabled = isEnabled
        await save(updated)
    }

    // MARK: - Checking

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkAll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // A first pass shortly after launch catches what appeared while the
        // app was closed, without slowing startup.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await self?.checkAll()
        }
    }

    func checkAll() async {
        guard !isChecking else { return }
        let enabled = subscriptions.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        for subscription in enabled {
            await check(subscription, isManual: false)
        }
    }

    @discardableResult
    func check(_ subscription: TorrentSubscription, isManual: Bool) async -> Int {
        guard let database, let downloads else { return 0 }
        let sources = subscription.sources.isEmpty
            ? TorrentSourceID.allCases.filter(preferences.enabledSources.contains)
            : TorrentSourceID.allCases.filter(subscription.sources.contains)
        guard !sources.isEmpty, !subscription.queries.isEmpty else { return 0 }

        var snapshot: TorrentSearchSnapshot?
        for await update in coordinator.search(queries: subscription.queries, sources: sources) {
            snapshot = update
        }
        guard let results = snapshot?.results else { return 0 }

        let matched: Set<String>
        do {
            matched = Set(try await database.torrentSubscriptionMatches(subscriptionID: subscription.id).map(\.infoHash))
        } catch {
            errorMessage = String(localized: "Could not read what “\(subscription.title)” already downloaded: \(error.localizedDescription)")
            return 0
        }
        var owned: Set<Double> = []
        if let animeID = subscription.animeID, let provider = ownedEpisodesProvider {
            owned = await provider(animeID)
        }

        let picks = TorrentSubscriptionMatcher.select(
            from: results,
            rule: subscription,
            alreadyMatched: matched,
            ownedEpisodes: owned
        )

        for pick in picks {
            downloads.add(
                magnet: pick.magnet.uri,
                infoHash: pick.infoHash.hex,
                title: pick.title,
                trackers: pick.trackers,
                animeID: subscription.animeID,
                animeTitle: subscription.title,
                episodeLabel: pick.release.episodeLabel
            )
            try? await database.recordTorrentSubscriptionMatch(TorrentSubscriptionMatch(
                subscriptionID: subscription.id,
                infoHash: pick.infoHash.hex,
                title: pick.title,
                episode: pick.release.firstEpisode
            ))
            note("“\(subscription.title)” → \(pick.release.episodeLabel.map { "EP \($0)" } ?? String(localized: "new release")): \(pick.title)")
        }
        if picks.isEmpty, isManual {
            note(String(localized: "“\(subscription.title)”: nothing new (\(results.count) releases checked)"))
        }

        var updated = subscription
        updated.lastCheckedAt = .now
        if !picks.isEmpty { updated.lastMatchedAt = .now }
        await save(updated)
        return picks.count
    }

    private func note(_ text: String) {
        activity.insert(Activity(date: .now, text: text), at: 0)
        activity = Array(activity.prefix(Self.activityLimit))
    }

    /// Builds a rule out of what a release search is currently showing, so a
    /// user who has already narrowed the filters can follow that exact shape.
    static func subscription(
        from search: TorrentSearchModel,
        anime: Anime?,
        title: String
    ) -> TorrentSubscription {
        let filter = search.filter
        return TorrentSubscription(
            animeID: anime?.id,
            title: title,
            queries: TorrentSearchCoordinator.splitQueries(search.queryText),
            sources: [],
            group: filter.groups.count == 1 ? filter.groups.first : nil,
            resolution: filter.resolutions.count == 1 ? filter.resolutions.first : nil,
            subtitleLanguages: filter.subtitleLanguages,
            includesBatches: filter.batchMode == .batchesOnly
        )
    }
}
