import AnimeGodCore
import Foundation

/// Headless dry run of a subscription rule against the live indexes:
///
///     AnimeGod -smokeSubscription "<queries>" [fansub] [resolution]
///
/// Prints what the rule would download, and why the rest was rejected.
/// Nothing is downloaded and nothing is written to the database.
enum SubscriptionSmokeTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-smokeSubscription")
    }

    static func run() -> Never {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-smokeSubscription"), flag + 1 < arguments.count else {
            print("SMOKE usage: -smokeSubscription \"<queries>\" [fansub] [resolution]")
            exit(2)
        }
        let queries = TorrentSearchCoordinator.splitQueries(arguments[flag + 1])
        let group = flag + 2 < arguments.count ? arguments[flag + 2] : nil
        let resolution = flag + 3 < arguments.count ? arguments[flag + 3] : nil

        // Dated a week back so the dry run shows what a subscription made
        // last week would have fetched since; a rule created "now" correctly
        // matches nothing, which says nothing useful.
        let daysBack = Double(ProcessInfo.processInfo.environment["AG_SUBSCRIPTION_DAYS"] ?? "") ?? 7
        let rule = TorrentSubscription(
            title: queries.first ?? "",
            queries: queries,
            group: group?.isEmpty == true ? nil : group,
            resolution: resolution?.isEmpty == true ? nil : resolution,
            createdAt: Date(timeIntervalSinceNow: -daysBack * 86_400)
        )
        print("SMOKE rule queries=\(queries) \(rule.ruleSummary) · created \(Int(daysBack))d ago")

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var exitCode: Int32 = 1
        Task {
            let coordinator = TorrentSearchCoordinator()
            var snapshot: TorrentSearchSnapshot?
            for await update in coordinator.search(queries: queries, sources: TorrentSourceID.allCases) {
                snapshot = update
            }
            let results = snapshot?.results ?? []
            let accepted = results.filter { TorrentSubscriptionMatcher.accepts($0, rule: rule) }
            let picks = TorrentSubscriptionMatcher.select(
                from: results, rule: rule, alreadyMatched: [], ownedEpisodes: []
            )
            let unnumbered = accepted.filter { $0.release.firstEpisode == nil }.count
            print("SMOKE found=\(results.count) accepted=\(accepted.count) wouldDownload=\(picks.count)")
            if unnumbered > 0 {
                print("SMOKE note: \(unnumbered) accepted release(s) have no episode number; a rule without a fansub or keyword does not download those unattended")
            }
            for rejected in accepted where !picks.contains(where: { $0.infoHash == rejected.infoHash }) {
                print("SMOKE skipped EP=\(rejected.release.episodeLabel ?? "-") seeds=\(rejected.seeders.map(String.init) ?? "-") \(rejected.title)")
            }
            for pick in picks.prefix(20) {
                print("SMOKE pick EP=\(pick.release.episodeLabel ?? "-") seeds=\(pick.seeders.map(String.init) ?? "-") \(pick.title)")
            }
            // A subscription that would grab dozens of releases at once is a
            // rule too loose to run unattended; say so loudly.
            // Roughly one or two episodes a week per show; much more than
            // that from one rule means it is too loose to run unattended.
            let expected = Int(daysBack / 7 * 3) + 2
            print("SMOKE verdict=\(picks.count <= expected ? "reasonable" : "too broad (\(picks.count) > \(expected))")")
            exitCode = picks.isEmpty ? 1 : 0
            semaphore.signal()
        }
        semaphore.wait()
        exit(exitCode)
    }
}
