import AnimeGodCore
import Foundation

/// Dry run of episode-set assembly against the live indexes:
///
///     AnimeGod -smokeEpisodeSets "<queries>" [owned episodes, e.g. 1-5]
///
/// Prints the seasons Find Releases would offer, which episodes each one
/// borrows from another fansub, and what nobody published. Nothing is
/// downloaded and nothing is written to the database.
///
/// Synthetic titles in the unit tests cannot cover how differently the
/// indexes actually spell things; this is where a parsing surprise shows up.
enum EpisodeSetSmokeTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-smokeEpisodeSets")
    }

    static func run() -> Never {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-smokeEpisodeSets"), flag + 1 < arguments.count else {
            print("SMOKE usage: -smokeEpisodeSets \"<queries>\" [owned, e.g. 1-5]")
            exit(2)
        }
        let queries = TorrentSearchCoordinator.splitQueries(arguments[flag + 1])
        let owned = flag + 2 < arguments.count ? episodes(in: arguments[flag + 2]) : []
        print("SMOKE queries=\(queries) owned=\(owned.sorted().map { Int($0) })")

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var exitCode: Int32 = 1
        Task {
            let coordinator = TorrentSearchCoordinator()
            var snapshot: TorrentSearchSnapshot?
            for await update in coordinator.search(queries: queries, sources: TorrentSourceID.allCases) {
                snapshot = update
            }
            var filter = TorrentResultFilter()
            filter.batchMode = .episodesOnly
            let results = filter.apply(snapshot?.results ?? [])
            let sets = TorrentEpisodeSetBuilder.build(
                from: results,
                options: TorrentEpisodeSetOptions(ownedEpisodes: owned)
            )
            print("SMOKE releases=\(snapshot?.results.count ?? 0) singles=\(results.count) sets=\(sets.count)")
            for (index, season) in sets.enumerated() {
                let name = season.isMixed ? "MIXED" : (season.group ?? "?")
                let tags = ([name] + season.variant.attributeTags).joined(separator: " · ")
                let size = season.downloadSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) } ?? "-"
                print("SMOKE set \(tags) — \(season.downloadableEntries.count)/\(season.neededEpisodes.count) to fetch,"
                      + " owned=\(season.ownedEpisodes.count) borrowed=\(season.substituteCount)"
                      + " missing=\(season.missingEpisodes.map { Int($0) })"
                      + " seeds≥\(season.minimumSeeders.map(String.init) ?? "-") size=\(size)")
                // Only the leading sets are worth listing episode by episode.
                for entry in (index < 3 ? season.entries.prefix(40) : []) {
                    let marks = [
                        entry.isOwned ? "owned" : nil,
                        entry.isSubstitute ? "from \(entry.group ?? "?")" : nil,
                        entry.isExtra ? "extra" : nil
                    ].compactMap { $0 }.joined(separator: ",")
                    print("SMOKE   EP\(entry.episode) \(marks.isEmpty ? "" : "[\(marks)] ")\(entry.result.title)")
                }
            }
            // A season nobody can assemble is the failure this feature is
            // meant to remove, so say plainly whether one came out.
            let complete = sets.filter(\.isComplete).count
            print("SMOKE verdict=\(complete > 0 ? "\(complete) complete set(s)" : "no complete set")")
            exitCode = sets.isEmpty ? 1 : 0
            semaphore.signal()
        }
        semaphore.wait()
        exit(exitCode)
    }

    /// "1-5", "1,2,3" or "1-5,8".
    private static func episodes(in text: String) -> Set<Double> {
        var result: Set<Double> = []
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 2, bounds[1] >= bounds[0] {
                result.formUnion(stride(from: bounds[0], through: bounds[1], by: 1))
            } else if let single = bounds.first {
                result.insert(single)
            }
        }
        return result
    }
}
