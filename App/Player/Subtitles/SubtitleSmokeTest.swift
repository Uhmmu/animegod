import AnimeGodCore
import Foundation

/// Headless check of online subtitle search against the live providers:
///
///     ANIMEGOD_ASSRT_TOKEN=… ANIMEGOD_SUBDL_API_KEY=… \
///     AnimeGod -smokeSubtitles "<video file name or path>" [title …] [-download] [-anilist <id>]
///
/// Prints the identity, each provider's outcome and the ranked results;
/// with `-download` it also downloads the best result into a temporary
/// folder. Keys come from environment variables only — like the other
/// smoke tests it never reads the saved credentials. Nothing is written to the library database.
enum SubtitleSmokeTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-smokeSubtitles")
    }

    static func run() -> Never {
        var arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-smokeSubtitles"), flag + 1 < arguments.count else {
            print("SMOKE usage: -smokeSubtitles \"<video file>\" [title …] [-download] [-anilist <id>]")
            exit(2)
        }
        let shouldDownload = arguments.contains("-download")
        var aniListID: Int?
        if let index = arguments.firstIndex(of: "-anilist"), index + 1 < arguments.count {
            aniListID = Int(arguments[index + 1])
            arguments.removeSubrange(index...(index + 1))
        }
        let rest = arguments[(flag + 1)...].filter { !$0.hasPrefix("-") }
        let path = rest.first ?? ""
        let titles = Array(rest.dropFirst())
        let url = URL(fileURLWithPath: path)

        func env(_ account: CredentialStore.Subtitles.Account) -> String { CredentialStore.Subtitles.environment(account) }
        var providers: [any SubtitleProvider] = []
        if !env(.assrtToken).isEmpty { providers.append(AssrtSubtitleProvider(token: env(.assrtToken))) }
        if !env(.subDLAPIKey).isEmpty { providers.append(SubDLSubtitleProvider(apiKey: env(.subDLAPIKey))) }
        if !env(.openSubtitlesAPIKey).isEmpty {
            let username = env(.openSubtitlesUsername)
            let password = env(.openSubtitlesPassword)
            providers.append(OpenSubtitlesProvider(
                apiKey: env(.openSubtitlesAPIKey),
                credentials: username.isEmpty ? nil : .init(username: username, password: password)
            ))
        }
        if !env(.jimakuAPIKey).isEmpty { providers.append(JimakuSubtitleProvider(apiKey: env(.jimakuAPIKey))) }
        print("SMOKE providers=\(providers.map(\.id.rawValue))")

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var exitCode: Int32 = 0
        Task {
            var identity = SubtitleVideoIdentity.fromFileName(url.lastPathComponent, titles: titles)
            if FileManager.default.fileExists(atPath: url.path) {
                identity.fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                identity.openSubtitlesHash = OpenSubtitlesHash.compute(url: url)
            }
            if let aniListID {
                let mapping = AnimeIDMappingStore(cacheURL: FileManager.default.temporaryDirectory.appending(path: "animegod-anime-list-mini.json"))
                identity.ids = (await mapping.ids(aniListID: aniListID, malID: nil)) ?? SubtitleAnimeIDs(aniListID: aniListID)
            }
            print("SMOKE identity titles=\(identity.titles) \(identity.episodeLabel) group=\(identity.releaseGroup ?? "-") source=\(identity.source ?? "-") res=\(identity.resolution ?? "-") hash=\(identity.openSubtitlesHash ?? "-")")
            print("SMOKE ids anilist=\(identity.ids.aniListID.map(String.init) ?? "-") tmdb=\(identity.ids.tmdbID.map(String.init) ?? "-")/S\(identity.ids.tmdbSeason.map(String.init) ?? "-") anidb=\(identity.ids.aniDBID.map(String.init) ?? "-") mal=\(identity.ids.malID.map(String.init) ?? "-")")

            let manager = SubtitleManager(providers: providers)
            let report = await manager.search(SubtitleQuery(identity: identity, languages: SubtitleRankingPreferences.default.languages))
            for (provider, outcome) in report.outcomes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("SMOKE outcome \(provider.rawValue): \(outcome)")
            }
            for scored in report.ranked.prefix(25) {
                let result = scored.result
                print("SMOKE \(scored.score.percent)% \(result.languages.map(\.rawValue).joined(separator: "/")) \(result.format?.rawValue ?? "?") \(result.provider.rawValue) group=\(result.displayGroup ?? "-") ep=\(result.episode.map { String($0) } ?? "-") warn=\(scored.score.warnings.map(\.rawValue)) \(result.releaseName ?? result.fileName ?? result.title)")
            }
            print("SMOKE automatic=\(report.automaticChoice.map { "\($0.result.id) \($0.score.percent)%" } ?? "none (would ask the user)")")

            if shouldDownload, let best = report.automaticChoice ?? report.ranked.first {
                do {
                    let prepared = try await manager.download(best.result, for: identity)
                    let folder = FileManager.default.temporaryDirectory.appending(path: "animegod-subtitle-smoke")
                    let store = SubtitleCacheStore(root: folder)
                    let record = try store.store(prepared, for: best, video: identity, videoKey: "smoke", animeID: nil, isAutomatic: true)
                    print("SMOKE downloaded \(prepared.fileName) as \(prepared.format.rawValue) \(prepared.language?.rawValue ?? "?") from \(prepared.sourceEncoding.rawValue) → \(store.url(for: record).path) fonts=\(prepared.fonts.count)")
                    for line in prepared.text.split(separator: "\n").filter({ $0.hasPrefix("Dialogue") || $0.contains("-->") }).prefix(3) {
                        print("SMOKE   \(line.prefix(160))")
                    }
                } catch {
                    print("SMOKE download failed: \(SubtitleManager.message(for: error))")
                    exitCode = 1
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(exitCode)
    }
}
