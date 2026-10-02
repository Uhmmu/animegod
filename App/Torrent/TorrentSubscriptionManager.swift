import AnimeGodCore
import Combine
import Foundation

/// Runs the standing subscription rules: searches the indexes on a timer,
/// downloads the next episode of the line each rule follows, and offers the
/// ones it is not sure about.
///
/// Unattended downloading is held to a stricter standard than a manual
/// search: one release per episode, only the line the season was started
/// from, never something already in the library or downloaded before, never
/// a title that only loosely matches, and always under the speed ceiling for
/// automatic downloads. Anything that fits the show but not the line — the
/// next episode from a different fansub, a different resolution — is offered
/// on the Subscriptions page instead, because a season that changes fansub
/// halfway through is worse than a season that waits.
@MainActor
final class TorrentSubscriptionManager: ObservableObject {
    struct Activity: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let text: String
    }

    @Published private(set) var subscriptions: [TorrentSubscription] = []
    /// Releases waiting to be taken or dismissed, newest first.
    @Published private(set) var candidates: [TorrentSubscriptionCandidate] = []
    @Published private(set) var isChecking = false
    /// The rule being searched right now, so its row can show a spinner.
    @Published private(set) var checkingID: UUID?
    @Published private(set) var activity: [Activity] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    /// How often enabled rules are checked, in hours. Anime is published on
    /// weekly schedules, so a check twice a day catches an episode the day it
    /// appears without hammering the indexes.
    @Published var checkIntervalHours: Int {
        didSet { UserDefaults.standard.set(checkIntervalHours, forKey: Self.intervalKey) }
    }
    private static let intervalKey = "torrent.subscriptionIntervalHours"
    static let intervalChoices = [1, 3, 6, 12, 24, 48, 72, 168]
    static let defaultIntervalHours = 12

    /// How often the clock wakes to see whether any rule is due. Short enough
    /// that a 1-hour interval means roughly an hour, long enough to cost
    /// nothing.
    private static let heartbeat: TimeInterval = 15 * 60
    private static let activityLimit = 60

    private var database: LibraryDatabase?
    private weak var downloads: TorrentDownloadManager?
    private let preferences: TorrentSourcePreferences
    private let coordinator = TorrentSearchCoordinator()
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Episodes already in the library for an anime, so a rule never
    /// re-downloads what is on disk.
    var ownedEpisodesProvider: ((UUID) async -> Set<Double>)?
    /// How long the season is, from whatever metadata the library has. A rule
    /// whose season is complete stops searching.
    var expectedEpisodeCountProvider: ((UUID) -> Int?)?
    /// Called after a rule downloads something, so the library can pick the
    /// work up and the card can show it.
    var onAutomaticDownload: ((TorrentSubscription) -> Void)?

    init(preferences: TorrentSourcePreferences) {
        self.preferences = preferences
        checkIntervalHours = UserDefaults.standard.object(forKey: Self.intervalKey) as? Int
            ?? Self.defaultIntervalHours
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
            candidates = try await database.torrentSubscriptionCandidates()
        } catch {
            errorMessage = String(localized: "Could not read subscriptions: \(error.localizedDescription)")
        }
    }

    var enabledCount: Int { subscriptions.filter(\.isEnabled).count }

    /// Rules that still have something to wait for — what the sidebar badge
    /// counts, since a finished season is a record rather than a task.
    var followingCount: Int { subscriptions.filter { $0.isEnabled && !$0.isSeasonComplete }.count }

    func subscription(for animeID: UUID) -> TorrentSubscription? {
        subscriptions.first { $0.animeID == animeID }
    }

    func candidates(for subscriptionID: UUID) -> [TorrentSubscriptionCandidate] {
        candidates.filter { $0.subscriptionID == subscriptionID }
            .sorted { ($0.episode ?? 0, $0.foundAt) < ($1.episode ?? 0, $1.foundAt) }
    }

    /// When a rule is next due a look.
    func nextCheckAt(_ subscription: TorrentSubscription) -> Date? {
        guard subscription.isEnabled, !subscription.isSeasonComplete else { return nil }
        guard let last = subscription.lastCheckedAt else { return .now }
        return last.addingTimeInterval(TimeInterval(checkIntervalHours) * 3600)
    }

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

    /// Follows the season that has just been started as a set.
    ///
    /// This is the one-click path from Find Releases: the rule is built from
    /// the set itself, so there is no form to fill in — the team, the encode,
    /// the folder and the episode floor all come from what was downloaded.
    @discardableResult
    func follow(
        set: TorrentEpisodeSet,
        schedule: TorrentReleaseSchedule,
        anime: Anime?,
        title: String,
        queries: [String],
        folderName: String?
    ) async -> TorrentSubscription {
        var rule = TorrentSubscription.following(
            set: set,
            schedule: schedule,
            animeID: anime?.id,
            title: title,
            queries: queries,
            folderName: folderName
        )
        // Following the same show twice would download every episode twice.
        if let existing = subscriptions.first(where: { $0.matchesSameWork(as: rule) }) {
            rule = merge(rule, into: existing)
        }
        await save(rule)
        note(String(localized: "Following “\(rule.title)” — checking every \(intervalText)."))
        return rule
    }

    /// An existing rule updated to follow what was just downloaded: the floor
    /// moves forward and the line is re-learned, but its identity, its history
    /// and whether it is enabled are kept.
    private func merge(_ fresh: TorrentSubscription, into existing: TorrentSubscription) -> TorrentSubscription {
        var merged = existing
        merged.queries = fresh.queries.isEmpty ? existing.queries : fresh.queries
        merged.animeID = fresh.animeID ?? existing.animeID
        merged.group = fresh.group
        merged.resolution = fresh.resolution
        merged.subtitleLanguages = fresh.subtitleLanguages
        merged.videoCodec = fresh.videoCodec
        merged.videoSource = fresh.videoSource
        merged.season = fresh.season
        merged.titleSignature = fresh.titleSignature
        merged.folderName = fresh.folderName ?? existing.folderName
        merged.includesExistingReleases = fresh.includesExistingReleases
        merged.minimumEpisode = max(fresh.minimumEpisode ?? 0, existing.minimumEpisode ?? 0)
        merged.expectedEpisodeCount = fresh.expectedEpisodeCount ?? existing.expectedEpisodeCount
        merged.averageIntervalSeconds = fresh.averageIntervalSeconds ?? existing.averageIntervalSeconds
        merged.lastReleaseAt = fresh.lastReleaseAt ?? existing.lastReleaseAt
        merged.latestEpisode = max(fresh.latestEpisode ?? 0, existing.latestEpisode ?? 0)
        merged.isEnabled = true
        return merged
    }

    var intervalText: String {
        checkIntervalHours % 24 == 0 && checkIntervalHours >= 24
            ? String(localized: "\(checkIntervalHours / 24) days")
            : String(localized: "\(checkIntervalHours) hours")
    }

    // MARK: - Candidates

    /// Takes a release the rule was unsure about: it downloads like any other
    /// automatic episode, into the season's own folder, and the rule's line is
    /// *not* changed — one borrowed episode does not redefine the season.
    func accept(_ candidate: TorrentSubscriptionCandidate) async {
        guard let database, let downloads,
              let rule = subscriptions.first(where: { $0.id == candidate.subscriptionID }) else { return }
        let started = downloads.add(
            magnet: candidate.magnet,
            infoHash: candidate.infoHash,
            title: candidate.title,
            trackers: candidate.trackers,
            animeID: rule.animeID,
            animeTitle: rule.title,
            episodeLabel: candidate.episode.map { TorrentEpisodeGuess.text(for: $0) },
            folderName: rule.folderName,
            isAutomatic: true,
            subscriptionID: rule.id,
            reportsDuplicates: false
        )
        try? await database.recordTorrentSubscriptionMatch(TorrentSubscriptionMatch(
            subscriptionID: rule.id,
            infoHash: candidate.infoHash,
            title: candidate.title,
            episode: candidate.episode
        ))
        try? await database.removeTorrentSubscriptionCandidate(
            subscriptionID: candidate.subscriptionID, infoHash: candidate.infoHash
        )
        if started {
            var updated = rule
            updated.lastMatchedAt = .now
            if let episode = candidate.episode {
                updated.minimumEpisode = max(updated.minimumEpisode ?? 0, episode)
                updated.latestEpisode = max(updated.latestEpisode ?? 0, episode)
            }
            await save(updated)
            note(String(localized: "“\(rule.title)” → \(episodeText(candidate.episode)): \(candidate.title)"))
            onAutomaticDownload?(updated)
        } else {
            await reload()
        }
    }

    /// Turning one down is permanent: it is recorded as handled, so the next
    /// check does not offer the same release again in twelve hours.
    func dismiss(_ candidate: TorrentSubscriptionCandidate) async {
        guard let database else { return }
        try? await database.recordTorrentSubscriptionMatch(TorrentSubscriptionMatch(
            subscriptionID: candidate.subscriptionID,
            infoHash: candidate.infoHash,
            title: candidate.title,
            episode: candidate.episode
        ))
        try? await database.removeTorrentSubscriptionCandidate(
            subscriptionID: candidate.subscriptionID, infoHash: candidate.infoHash
        )
        await reload()
    }

    // MARK: - Checking

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.heartbeat, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // A first pass shortly after launch catches what appeared while the
        // app was closed, without slowing startup.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            await self?.checkDue()
        }
    }

    /// Checks the rules whose interval has elapsed. This is what the timer
    /// runs; "Check Now" ignores the interval.
    func checkDue() async {
        let now = Date.now
        let due = subscriptions.filter { rule in
            guard rule.isEnabled, !rule.isSeasonComplete else { return false }
            guard let last = rule.lastCheckedAt else { return true }
            return now.timeIntervalSince(last) >= TimeInterval(checkIntervalHours) * 3600
        }
        await check(due, isManual: false)
    }

    func checkAll() async {
        await check(subscriptions.filter { $0.isEnabled && !$0.isSeasonComplete }, isManual: true)
    }

    private func check(_ rules: [TorrentSubscription], isManual: Bool) async {
        guard !isChecking, !rules.isEmpty else { return }
        isChecking = true
        defer {
            isChecking = false
            checkingID = nil
        }
        for rule in rules {
            checkingID = rule.id
            await check(rule, isManual: isManual)
        }
    }

    @discardableResult
    func check(_ subscription: TorrentSubscription, isManual: Bool) async -> Int {
        guard let database, let downloads else { return 0 }
        let sources = subscription.sources.isEmpty
            ? TorrentSourceID.allCases.filter(preferences.enabledSources.contains)
            : TorrentSourceID.allCases.filter(subscription.sources.contains)
        let queries = subscription.searchQueries()
        guard !sources.isEmpty, !queries.isEmpty else { return 0 }

        var snapshot: TorrentSearchSnapshot?
        for await update in coordinator.search(queries: queries, sources: sources) {
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
        let offered = Set(candidates(for: subscription.id).map(\.infoHash))

        // What the indexes say about the show now: how far it has got, how
        // often an episode appears, and therefore when the next one is due.
        let expected = subscription.animeID.flatMap { expectedEpisodeCountProvider?($0) }
            ?? subscription.expectedEpisodeCount
        let schedule = TorrentReleaseSchedule.analyse(
            results: results,
            expectedEpisodeCount: expected,
            ownedEpisodes: owned
        )

        let selection = TorrentSubscriptionMatcher.select(
            from: results,
            rule: subscription,
            alreadyMatched: matched,
            ownedEpisodes: owned,
            alreadyOffered: offered
        )

        var updated = subscription
        updated.apply(schedule: schedule)
        var started = 0
        for pick in selection.automatic {
            let didStart = downloads.add(
                magnet: pick.magnet.uri,
                infoHash: pick.infoHash.hex,
                title: pick.title,
                trackers: pick.trackers,
                animeID: subscription.animeID,
                animeTitle: subscription.title,
                episodeLabel: pick.release.episodeLabel,
                folderName: subscription.folderName,
                isAutomatic: true,
                subscriptionID: subscription.id,
                reportsDuplicates: false
            )
            try? await database.recordTorrentSubscriptionMatch(TorrentSubscriptionMatch(
                subscriptionID: subscription.id,
                infoHash: pick.infoHash.hex,
                title: pick.title,
                episode: pick.release.firstEpisode
            ))
            guard didStart else { continue }
            started += 1
            if let episode = pick.release.firstEpisode {
                // The floor moves with what was taken, so the same episode is
                // never considered again even if its download is removed.
                updated.minimumEpisode = max(updated.minimumEpisode ?? 0, episode)
                updated.latestEpisode = max(updated.latestEpisode ?? 0, episode)
            }
            note(String(localized: "“\(subscription.title)” → \(episodeText(pick.release.firstEpisode)): \(pick.title)"))
        }

        for (result, reason) in selection.needsConfirmation {
            try? await database.saveTorrentSubscriptionCandidate(TorrentSubscriptionCandidate(
                subscriptionID: subscription.id,
                infoHash: result.infoHash.hex,
                title: result.title,
                magnet: result.magnet.uri,
                trackers: result.trackers,
                episode: result.release.firstEpisode,
                group: result.group,
                resolution: result.release.resolution,
                size: result.size,
                seeders: result.seeders,
                publishedAt: result.publishedAt,
                reason: reason
            ))
        }
        if !selection.needsConfirmation.isEmpty {
            note(String(localized: "“\(subscription.title)”: \(selection.needsConfirmation.count) releases need a look — another fansub or another encode."))
        }
        if selection.isEmpty, isManual {
            note(String(localized: "“\(subscription.title)”: nothing new (\(results.count) releases checked)"))
        }

        updated.lastCheckedAt = .now
        if started > 0 { updated.lastMatchedAt = .now }
        await save(updated)
        if started > 0 { onAutomaticDownload?(updated) }
        return started
    }

    private func episodeText(_ episode: Double?) -> String {
        guard let episode else { return String(localized: "new release") }
        return String(localized: "EP \(TorrentEpisodeGuess.text(for: episode))")
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

extension TorrentSubscription {
    /// Two rules follow the same thing when they are bound to the same anime,
    /// or — before either has been matched — when they name the same work.
    ///
    /// Named by the same rule the folders use, so a second press of Subscribe
    /// updates the rule it already has rather than adding one that downloads
    /// every episode a second time.
    func matchesSameWork(as other: TorrentSubscription) -> Bool {
        if let mine = animeID, let theirs = other.animeID { return mine == theirs }
        return TorrentWorkIdentity.namesSameWork(title, other.title)
    }
}
