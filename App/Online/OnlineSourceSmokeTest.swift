import AnimeGodCore
import Foundation

/// `AnimeGod -smokeOnlineSource "<keyword>"` — the rule pipeline's test,
/// standing in for a test target the app does not have.
///
/// The core's own tests cover the selectors against captured pages, which is
/// where they belong. What they cannot cover is the half that only exists
/// against a live site: whether the catalog is reachable, whether a rule
/// written weeks ago still matches the page it was written for, and whether
/// a headless browser gets a URL that **serves video**. So this runs the
/// whole chain and checks the end of it with a range request:
///
///     catalog → install → search → episode list → resolve → 206 video/*
///
/// The last step is the one that matters. One episode page here publishes a
/// complete media URL in its own JSON that answers **401** to every request,
/// while the URL its player JavaScript builds answers `206 video/mp4` — so a
/// resolution that is merely *plausible* is indistinguishable from one that
/// works until playback fails. Checking the bytes is the only honest check.
///
/// The chain does not stop at the bytes, because watching from a site is
/// still watching: the last step files the episode under the library's own
/// tables, records the session the player would record, and reads it back
/// out of the diary. It writes to a **copy** of the library in the
/// container's `tmp/`, never the real one — a probe must not put a work in
/// anybody's history.
///
/// Options: `AG_ONLINE_RULES=name,name` picks which rules to use (default:
/// the first three the catalog lists), `AG_ONLINE_MIRROR=1` uses the mirror
/// catalog.
@MainActor
enum OnlineSourceSmokeTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-smokeOnlineSource")
    }

    private static var keyword: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-smokeOnlineSource"),
              arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("-")
        else { return "药师少女" }
        return arguments[index + 1]
    }

    private static func say(_ text: String) {
        FileHandle.standardError.write(Data("SMOKE online: \(text)\n".utf8))
    }

    static func run() async {
        var failures: [String] = []

        let environment = ProcessInfo.processInfo.environment
        let catalog = OnlineSourceCatalog(
            baseURL: environment["AG_ONLINE_MIRROR"] == "1"
                ? OnlineSourceCatalog.mirrorIndexURL
                : OnlineSourceCatalog.defaultIndexURL
        )

        // 1. The catalog.
        var listed: [OnlineSourceCatalogItem] = []
        do {
            listed = try await catalog.index()
            say("catalog: \(listed.count) rule(s) — \(listed.prefix(6).map(\.name).joined(separator: ", "))…")
        } catch {
            say("catalog FAILED: \(error.localizedDescription)")
            exit(1)
        }
        if listed.isEmpty { failures.append("catalog is empty") }

        // 2. Downloading rules.
        let wanted: [String]
        if let requested = environment["AG_ONLINE_RULES"], !requested.isEmpty {
            wanted = requested.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        } else {
            wanted = listed.prefix(3).map(\.name)
        }
        var rules: [OnlineSourceRule] = []
        for name in wanted {
            do {
                let rule = try await catalog.rule(named: name)
                let modes = "search=\(rule.searchMode.rawValue) chapters=\(rule.chapterMode.rawValue)"
                say("rule \(rule.name) v\(rule.version) api=\(rule.api) \(modes) legacy=\(rule.useLegacyParser)")
                if rule.requiresNewerClient {
                    say("rule \(name): needs schema \(rule.api), this build reads \(OnlineSourceRule.supportedAPILevel)")
                } else {
                    rules.append(rule)
                }
            } catch {
                failures.append("downloading rule \(name): \(error.localizedDescription)")
            }
        }
        if rules.isEmpty {
            say("no usable rules; nothing further to check")
            exit(1)
        }

        // 3. Searching every rule at once.
        let coordinator = OnlineSourceCoordinator()
        let answers = await coordinator.search(keyword: keyword, rules: rules)
        for answer in answers {
            say("search \(answer.ruleName): \(describe(answer.status))")
        }
        let withResults = answers.filter { !$0.items.isEmpty }
        if withResults.isEmpty {
            say("no source found “\(keyword)”. Sources move and rules go stale; this is a real answer, not a crash.")
            exit(1)
        }

        // 4. The episode list of the first work a source found.
        var picked: (rule: OnlineSourceRule, item: OnlineSearchItem, roads: [OnlineRoad])?
        for answer in withResults {
            guard let rule = rules.first(where: { $0.name == answer.ruleName }),
                  let item = answer.items.first else { continue }
            do {
                let chapters = try await coordinator.chapters(pageURL: item.pageURL, rule: rule)
                let shape = chapters.roads.map { "\($0.name)=\($0.episodes.count)" }.joined(separator: " ")
                say("episodes \(rule.name) “\(item.name)”: \(chapters.roads.count) line(s) — \(shape)")
                if !chapters.skipped.isEmpty { say("  skipped: \(chapters.skipped.prefix(3).joined(separator: "; "))") }
                picked = (rule, item, chapters.roads)
                break
            } catch {
                failures.append("episode list from \(rule.name): \(OnlineSourceCoordinator.describe(error))")
            }
        }
        guard let picked, let road = picked.roads.first, let episode = road.episodes.first else {
            say("no source produced an episode list")
            for failure in failures { say("FAIL \(failure)") }
            exit(1)
        }

        // 5. The stream, out of a headless browser.
        let resolver = OnlineStreamResolver()
        let started = Date()
        var stream: ResolvedStream?
        do {
            stream = try await resolver.resolve(episodePageURL: episode.pageURL, rule: picked.rule)
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
            say("resolved \(episode.label) in \(elapsed) by \(stream!.method.rawValue): \(stream!.url.absoluteString)")
        } catch {
            failures.append("resolving \(episode.pageURL): \(error.localizedDescription)")
            for line in resolver.log.suffix(12) { say("  log: \(line)") }
        }

        // 6. Does it actually serve video? This is the step that separates a
        //    URL that looks right from one that plays.
        if let stream {
            let probe = await probeStream(stream)
            say("stream probe: \(probe.summary)")
            if !probe.servesVideo { failures.append("resolved URL does not serve video: \(probe.summary)") }
        }
        resolver.dispose()

        // 7. The watch record. An online episode has no file, so its identity
        //    is the rule's name plus the page URL — never the stream, which is
        //    re-resolved every time and comes back signed or cache-busted.
        await checkWatchRecord(
            work: picked.item, road: road, episode: episode, failures: &failures
        )

        for failure in failures { say("FAIL \(failure)") }
        say("ok=\(failures.isEmpty)")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// Plays the episode through the library's books without playing it:
    /// the rows a first play creates, the progress the player autosaves, the
    /// event its window writes on the way out — then asks the diary.
    private static func checkWatchRecord(
        work: OnlineSearchItem,
        road: OnlineRoad,
        episode: OnlineEpisode,
        failures: inout [String]
    ) async {
        guard let database = scratchDatabase() else {
            failures.append("could not open a scratch library")
            return
        }
        let reference = OnlineEpisodeRef(
            ruleName: work.ruleName,
            workPageURL: work.pageURL,
            workName: work.name,
            roadName: road.name,
            label: episode.label,
            index: episode.index,
            pageURL: episode.pageURL
        )
        do {
            let record = try await database.onlineEpisode(for: reference)
            say("filed \(episode.label) as episode \(record.episode.id) of work \(record.animeID)")

            // Where the player's tail rule says a 24-minute episode is done.
            let duration = 1_440.0
            let position = 1_430.0
            let watched = WatchedWorkKind.isWatched(position: position, duration: duration, kind: .series)
            try await database.save(progress: PlaybackProgress(
                episodeID: record.episode.id, position: position, duration: duration, isWatched: watched
            ))
            let ended = Date.now
            try await database.record(event: WatchEvent(
                animeID: record.animeID,
                episodeID: record.episode.id,
                animeTitle: record.workName,
                episodeLabel: record.episode.displayLabel,
                startedAt: ended.addingTimeInterval(-position),
                endedAt: ended,
                watchedDuration: position,
                completion: position / duration,
                completedEpisode: watched
            ))

            // And now the three things the viewer asked for.
            let states = try await database.onlineWatchStates(
                ruleName: work.ruleName, pageURLs: road.episodes.map(\.pageURL)
            )
            let resumed = try await database.onlineEpisode(for: reference)
            let diary = try await database.watchEvents(limit: 5)
            let summary = try await database.diarySummary()
            let grid = try await database.library()
            let shelf = try await database.continueWatching()

            say("grid: \(states.filter(\.value.isWatched).count)/\(road.episodes.count) watched on this line")
            say("resume: \(Int(resumed.progress?.position ?? -1))s of \(Int(resumed.progress?.duration ?? 0))s, watched=\(resumed.progress?.isWatched == true)")
            say("diary: “\(diary.first?.animeTitle ?? "—")” \(diary.first?.episodeLabel ?? "—"), \(Int(summary.totalWatchTime))s over \(summary.sessionCount) session(s)")
            say("library untouched: grid=\(grid.count) works, continue shelf=\(shelf.count) — neither lists the online work")

            if states[episode.pageURL]?.isWatched != true { failures.append("the grid does not show it as watched") }
            if resumed.progress?.isWatched != true { failures.append("it does not resume as watched") }
            if diary.first?.episodeID != record.episode.id { failures.append("it did not reach the diary") }
            if grid.contains(where: { $0.id == record.animeID }) { failures.append("an online work reached the library grid") }
            if shelf.contains(where: { $0.episode.animeID == record.animeID }) { failures.append("an online work reached the continue shelf") }
        } catch {
            failures.append("watch record: \(error.localizedDescription)")
        }
    }

    /// A copy of the real library in the container's `tmp/`, so the migration
    /// runs over real rows and the probe's own history is thrown away with it.
    private static func scratchDatabase() -> LibraryDatabase? {
        let manager = FileManager.default
        guard let support = try? manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "AnimeGod", directoryHint: .isDirectory) else { return nil }
        let scratch = manager.temporaryDirectory.appending(path: "online-watch-probe.sqlite")
        try? manager.removeItem(at: scratch)
        let live = support.appending(path: "library.sqlite")
        if manager.fileExists(atPath: live.path) {
            // `.backup` would be the careful way; a probe only needs rows to
            // migrate over, and a copy that misses the WAL still has those.
            try? manager.copyItem(at: live, to: scratch)
            say("scratch library: a copy of the real one at \(scratch.lastPathComponent)")
        } else {
            say("scratch library: new, the real one is not there")
        }
        return try? LibraryDatabase(url: scratch)
    }

    private static func describe(_ status: OnlineSourceStatus) -> String {
        switch status {
        case .searching: "still running"
        case let .found(count): "\(count) result(s)"
        case .noResults: "nothing found"
        case let .failed(message): "failed — \(message)"
        case .needsNewerClient: "needs a newer AnimeGod"
        }
    }

    /// Asks the resolved URL for its first 64 KB, with the rule's own
    /// headers — exactly what mpv will send.
    private static func probeStream(_ stream: ResolvedStream) async -> (servesVideo: Bool, summary: String) {
        var request = URLRequest(url: stream.url, timeoutInterval: 25)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "no HTTP response")
            }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? "none"
            let summary = "HTTP \(http.statusCode), \(type), \(data.count) bytes"
            guard (200..<300).contains(http.statusCode), !data.isEmpty else { return (false, summary) }
            // An HLS playlist is text and is served as the manifest; a
            // progressive file is video bytes. Both are playable, and
            // neither is an HTML error page, which is what a hotlink check
            // hands back when it refuses.
            let head = String(decoding: data.prefix(256), as: UTF8.self)
            if head.contains("#EXTM3U") { return (true, summary + " (HLS manifest)") }
            if type.lowercased().contains("video") || type.lowercased().contains("octet-stream") {
                return (true, summary)
            }
            if head.lowercased().contains("<html") { return (false, summary + " (an HTML page, not video)") }
            return (true, summary + " (unrecognized type, bytes served)")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
