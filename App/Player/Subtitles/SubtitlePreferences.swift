import AnimeGodCore
import Foundation

/// App-wide online subtitle settings and the services every player window
/// shares: the disk cache, the anime ID mapping, the OpenSubtitles login
/// token, and a per-anime cache of resolved IDs. Settings persist in
/// UserDefaults; credentials live in the local credential file (`CredentialStore`).
@MainActor
final class SubtitlePreferences: ObservableObject {
    private let defaults: UserDefaults

    /// "Automatically search Chinese subtitles when no Chinese subtitle
    /// exists."
    @Published var autoSearch: Bool {
        didSet { defaults.set(autoSearch, forKey: "subtitles.autoSearch") }
    }

    /// A release tagged "[CHT]" / "[简日内嵌]" with no Chinese subtitle
    /// track has the subtitles burned into the picture; searching would
    /// stack a second set on top.
    @Published var skipHardsubbedReleases: Bool {
        didSet { defaults.set(skipHardsubbedReleases, forKey: "subtitles.skipHardsubbed") }
    }

    @Published var ranking: SubtitleRankingPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(ranking) { defaults.set(data, forKey: "subtitles.ranking") }
        }
    }

    @Published var enabledProviders: Set<SubtitleProviderID> {
        didSet { defaults.set(enabledProviders.map(\.rawValue).sorted(), forKey: "subtitles.providers") }
    }

    /// Credential fields bound by Settings; saved to the credential file on demand.
    @Published var credentials: [CredentialStore.Subtitles.Account: String]

    let cache: SubtitleCacheStore
    let idMapping: AnimeIDMappingStore
    let openSubtitlesTokens = OpenSubtitlesTokenStore()
    /// AniList/TMDB IDs already resolved for a library anime this run, so
    /// the next episode of the same show asks nobody.
    var resolvedIDs: [UUID: SubtitleAnimeIDs] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoSearch = defaults.object(forKey: "subtitles.autoSearch") as? Bool ?? true
        skipHardsubbedReleases = defaults.object(forKey: "subtitles.skipHardsubbed") as? Bool ?? true
        if let data = defaults.data(forKey: "subtitles.ranking"),
           let decoded = try? JSONDecoder().decode(SubtitleRankingPreferences.self, from: data) {
            ranking = decoded
        } else {
            ranking = .default
        }
        let stored = defaults.stringArray(forKey: "subtitles.providers")?.compactMap(SubtitleProviderID.init(rawValue:))
        enabledProviders = Set(stored ?? SubtitleProviderID.allCases)
        credentials = Dictionary(uniqueKeysWithValues: CredentialStore.Subtitles.Account.allCases.map {
            ($0, CredentialStore.Subtitles.load($0))
        })

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AnimeGod/Subtitles", directoryHint: .isDirectory)
        cache = SubtitleCacheStore(root: base)
        idMapping = AnimeIDMappingStore(cacheURL: cache.idMappingURL)
        MPVPlayerController.subtitleFontsDirectory = cache.fontsDirectory
    }

    func credential(_ account: CredentialStore.Subtitles.Account) -> String {
        (credentials[account] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-reads the stored credentials (after an import).
    func reloadCredentials() {
        credentials = Dictionary(uniqueKeysWithValues: CredentialStore.Subtitles.Account.allCases.map {
            ($0, CredentialStore.Subtitles.load($0))
        })
    }

    func saveCredentials() {
        for account in CredentialStore.Subtitles.Account.allCases {
            let value = credential(account)
            credentials[account] = value
            // An environment-provided value is not copied into the credential file.
            if value != CredentialStore.Subtitles.environment(account) || value.isEmpty {
                CredentialStore.Subtitles.save(value, for: account)
            }
        }
        objectWillChange.send()
    }

    /// Whether a provider has what it needs to run.
    func isConfigured(_ provider: SubtitleProviderID) -> Bool {
        switch provider {
        case .assrt: !credential(.assrtToken).isEmpty
        case .subdl: !credential(.subDLAPIKey).isEmpty
        case .openSubtitles: !credential(.openSubtitlesAPIKey).isEmpty
        case .jimaku: !credential(.jimakuAPIKey).isEmpty
        }
    }

    /// Enabled and configured providers, Chinese-first sources first.
    func makeProviders() -> [any SubtitleProvider] {
        SubtitleProviderID.allCases.compactMap { id -> (any SubtitleProvider)? in
            guard enabledProviders.contains(id), isConfigured(id) else { return nil }
            switch id {
            case .assrt:
                return AssrtSubtitleProvider(token: credential(.assrtToken))
            case .subdl:
                return SubDLSubtitleProvider(apiKey: credential(.subDLAPIKey))
            case .openSubtitles:
                let username = credential(.openSubtitlesUsername)
                let password = credential(.openSubtitlesPassword)
                return OpenSubtitlesProvider(
                    apiKey: credential(.openSubtitlesAPIKey),
                    credentials: username.isEmpty || password.isEmpty ? nil : .init(username: username, password: password),
                    tokens: openSubtitlesTokens
                )
            case .jimaku:
                return JimakuSubtitleProvider(apiKey: credential(.jimakuAPIKey))
            }
        }
    }

    func makeManager() -> SubtitleManager {
        SubtitleManager(providers: makeProviders(), preferences: ranking)
    }

    var hasUsableProvider: Bool { !makeProviders().isEmpty }

    // MARK: - Ranking edits (Settings)

    func setLanguage(_ language: SubtitleLanguage, enabled: Bool) {
        var languages = ranking.languages
        if enabled, !languages.contains(language) { languages.append(language) }
        if !enabled { languages.removeAll { $0 == language } }
        ranking.languages = languages
    }

    func moveLanguage(_ language: SubtitleLanguage, by offset: Int) {
        ranking.languages = Self.moving(language, by: offset, in: ranking.languages)
    }

    func moveFormat(_ format: SubtitleFormat, by offset: Int) {
        ranking.formats = Self.moving(format, by: offset, in: ranking.formats)
    }

    private static func moving<Element: Equatable>(_ element: Element, by offset: Int, in list: [Element]) -> [Element] {
        guard let index = list.firstIndex(of: element) else { return list }
        let target = min(max(index + offset, 0), list.count - 1)
        var result = list
        result.remove(at: index)
        result.insert(element, at: target)
        return result
    }

    /// Deletes every cached subtitle file and its database record.
    func clearCache(database: LibraryDatabase?) async {
        cache.removeAll()
        try? await database?.removeAllSubtitleDownloads()
        objectWillChange.send()
    }
}
