import AnimeGodCore
import Foundation
import Security

/// Provider credentials (DeepL, dandanplay, Bilibili, subtitle sites).
///
/// Stored in a JSON file inside the app's own sandbox container, readable
/// only by the user's account — not in the Keychain. AnimeGod is ad-hoc
/// signed, so every new build is a new code identity to the Keychain and
/// each stored item asked for the login password again after every
/// reinstall. The file is never part of the repository and values are never
/// logged. `importFromKeychain()` moves items saved by earlier builds over,
/// only when the user asks for it in Settings.
enum CredentialStore {
    private static let defaultService = "com.uhmmu.AnimeGod.translation"
    private static let danmakuService = "com.uhmmu.AnimeGod.danmaku"
    private static let subtitleService = "com.uhmmu.AnimeGod.subtitles"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AnimeGod/credentials.json")
    }

    private static func key(_ account: String, _ service: String) -> String { "\(service)/\(account)" }

    /// Callers hold `lock`.
    private static func values() -> [String: String] {
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }

    private static func write(_ values: [String: String]) {
        cache = values
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func save(_ value: String, account: String, service: String = defaultService) {
        lock.lock()
        defer { lock.unlock() }
        var stored = values()
        stored[key(account, service)] = value.isEmpty ? nil : value
        write(stored)
    }

    static func load(account: String, service: String = defaultService) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values()[key(account, service)]
    }

    /// Every item earlier builds kept in the Keychain.
    private static var legacyItems: [(account: String, service: String)] {
        [(TranslationCoordinator.apiKeyAccount, defaultService),
         (Danmaku.appIDAccount, danmakuService),
         (Danmaku.appSecretAccount, danmakuService),
         (Danmaku.bilibiliSessDataAccount, danmakuService)]
            + Subtitles.Account.allCases.map { ($0.rawValue, subtitleService) }
    }

    /// Copies credentials saved by earlier builds out of the Keychain (each
    /// item may ask for the login password one last time), then deletes
    /// them there. Values already in the file are kept. Returns how many
    /// were imported.
    @discardableResult
    static func importFromKeychain() -> Int {
        var imported = 0
        for item in legacyItems {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.service,
                kSecAttrAccount as String: item.account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let value = String(data: data, encoding: .utf8), !value.isEmpty else { continue }
            if load(account: item.account, service: item.service)?.isEmpty ?? true {
                save(value, account: item.account, service: item.service)
                imported += 1
            }
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.service,
                kSecAttrAccount as String: item.account
            ] as CFDictionary)
        }
        return imported
    }

    /// Credentials for the dandanplay Open Danmaku API. Secrets never leave
    /// this type except into provider construction — and are never logged.
    enum Danmaku {
        static let appIDAccount = "dandanplay-app-id"
        static let appSecretAccount = "dandanplay-app-secret"

        static func loadAppID() -> String? {
            CredentialStore.load(account: appIDAccount, service: danmakuService)
        }

        static func loadAppSecret() -> String? {
            CredentialStore.load(account: appSecretAccount, service: danmakuService)
        }

        static func save(appID: String, appSecret: String) {
            CredentialStore.save(appID, account: appIDAccount, service: danmakuService)
            CredentialStore.save(appSecret, account: appSecretAccount, service: danmakuService)
        }

        /// The optional Bilibili login cookie. Anonymous access is the
        /// default and works for most titles; a `SESSDATA` only widens what
        /// the account may see. It is a session credential, stored beside
        /// the other secrets and never logged.
        static let bilibiliSessDataAccount = "bilibili-sessdata"

        static func loadBilibiliSessData() -> String? {
            CredentialStore.load(account: bilibiliSessDataAccount, service: danmakuService)
        }

        static func saveBilibiliSessData(_ value: String) {
            CredentialStore.save(value, account: bilibiliSessDataAccount, service: danmakuService)
        }
    }
}

extension CredentialStore {
    /// Online subtitle provider credentials. Each value can also come from
    /// an environment variable (for development builds launched from a
    /// terminal); the stored value wins when both exist. Nothing here is
    /// ever logged or written to the repository.
    enum Subtitles {
        enum Account: String, CaseIterable {
            case assrtToken = "assrt-token"
            case subDLAPIKey = "subdl-api-key"
            case openSubtitlesAPIKey = "opensubtitles-api-key"
            case openSubtitlesUsername = "opensubtitles-username"
            case openSubtitlesPassword = "opensubtitles-password"
            case jimakuAPIKey = "jimaku-api-key"

            var environmentVariable: String {
                switch self {
                case .assrtToken: "ANIMEGOD_ASSRT_TOKEN"
                case .subDLAPIKey: "ANIMEGOD_SUBDL_API_KEY"
                case .openSubtitlesAPIKey: "ANIMEGOD_OPENSUBTITLES_API_KEY"
                case .openSubtitlesUsername: "ANIMEGOD_OPENSUBTITLES_USERNAME"
                case .openSubtitlesPassword: "ANIMEGOD_OPENSUBTITLES_PASSWORD"
                case .jimakuAPIKey: "ANIMEGOD_JIMAKU_API_KEY"
                }
            }
        }

        static func load(_ account: Account) -> String {
            if let stored = CredentialStore.load(account: account.rawValue, service: subtitleService), !stored.isEmpty {
                return stored
            }
            return environment(account)
        }

        static func environment(_ account: Account) -> String {
            ProcessInfo.processInfo.environment[account.environmentVariable]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        static func save(_ value: String, for account: Account) {
            CredentialStore.save(value, account: account.rawValue, service: subtitleService)
        }
    }
}

/// Owns translation settings and orchestrates batch translations with a
/// persistent cache. Original community text is never replaced — translations
/// are stored beside it (spec §11).
@MainActor
final class TranslationCoordinator: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case none
        case deepl

        var displayName: String {
            switch self {
            case .none: String(localized: "None")
            case .deepl: "DeepL"
            }
        }

        var id: String { rawValue }
    }

    nonisolated static let apiKeyAccount = "deepl-api-key"
    private let defaults = UserDefaults.standard

    @Published var provider: Provider
    @Published var targetLanguage: TranslationLanguage
    @Published var apiKey: String
    @Published private(set) var isTranslating = false

    init() {
        let raw = defaults.string(forKey: "translation.provider") ?? Provider.none.rawValue
        provider = Provider(rawValue: raw) ?? .none
        let language = defaults.string(forKey: "translation.targetLanguage")
            .flatMap(TranslationLanguage.init(rawValue:))
        targetLanguage = language ?? .simplifiedChinese
        apiKey = CredentialStore.load(account: Self.apiKeyAccount) ?? ""
    }

    var isConfigured: Bool {
        switch provider {
        case .none: false
        case .deepl: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Re-reads the stored key (after an import).
    func reloadCredentials() {
        apiKey = CredentialStore.load(account: Self.apiKeyAccount) ?? ""
    }

    func saveSettings() {
        defaults.set(provider.rawValue, forKey: "translation.provider")
        defaults.set(targetLanguage.rawValue, forKey: "translation.targetLanguage")
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        CredentialStore.save(trimmed, account: Self.apiKeyAccount)
        apiKey = trimmed
        objectWillChange.send()
    }

    private func makeService() -> (any TranslationService, String)? {
        switch provider {
        case .none:
            return nil
        case .deepl:
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (DeepLTranslationService(apiKey: trimmed), "deepl")
        }
    }

    /// Translates the given posts' title and body in one batched request,
    /// reusing cached results. Returns the updated posts.
    func translate(posts: [CommunityPost], animeID: UUID, database: LibraryDatabase?) async -> [CommunityPost]? {
        guard isConfigured, let database, let (service, providerID) = makeService() else { return nil }
        let pending = posts.filter { ($0.body != nil && $0.translatedBody == nil) || ($0.title != $0.translatedTitle && $0.translatedTitle == nil) }
        guard !pending.isEmpty else { return posts }
        isTranslating = true
        defer { isTranslating = false }

        // Pair each request text with its post and field so batched results
        // can be mapped back precisely.
        struct Request {
            let postIndex: Int
            let isTitle: Bool
            let text: String
        }
        var requests: [Request] = []
        for (index, post) in pending.enumerated() {
            if post.translatedTitle == nil, !post.title.isEmpty {
                requests.append(Request(postIndex: index, isTitle: true, text: post.title))
            }
            if let body = post.body, !body.isEmpty, post.translatedBody == nil {
                requests.append(Request(postIndex: index, isTitle: false, text: body))
            }
        }
        guard !requests.isEmpty else { return posts }
        let texts = requests.map(\.text)

        var results: [Int: String] = [:]
        if let cached = try? await database.cachedTranslations(provider: providerID, targetLanguage: targetLanguage.rawValue, texts: texts) {
            results = cached
        }
        let missingIndices = texts.indices.filter { results[$0] == nil }
        if !missingIndices.isEmpty {
            let missingTexts = missingIndices.map { texts[$0] }
            do {
                let translated = try await service.translate(missingTexts, to: targetLanguage.rawValue)
                for (offset, index) in missingIndices.enumerated() where offset < translated.count {
                    results[index] = translated[offset]
                }
                let newPairs = missingIndices.enumerated().compactMap { offset, index -> (String, String)? in
                    guard offset < translated.count else { return nil }
                    return (texts[index], translated[offset])
                }
                try? await database.saveTranslations(
                    provider: providerID,
                    targetLanguage: targetLanguage.rawValue,
                    pairs: newPairs
                )
            } catch {
                return nil
            }
        }

        var updated = posts
        var byProvider: [MetadataProviderID: [String: (title: String?, body: String?)]] = [:]
        for (index, request) in requests.enumerated() {
            guard let translated = results[index] else { continue }
            let post = pending[request.postIndex]
            if request.isTitle {
                byProvider[post.provider, default: [:]][post.postID, default: (nil, nil)].title = translated
            } else {
                byProvider[post.provider, default: [:]][post.postID, default: (nil, nil)].body = translated
            }
        }
        for (provider, translations) in byProvider {
            try? await database.saveCommunityPostTranslations(
                animeID: animeID,
                provider: provider,
                translationsByPostID: translations
            )
        }
        for post in pending {
            guard let translation = byProvider[post.provider]?[post.postID],
                  let index = posts.firstIndex(where: { $0.id == post.id }) else { continue }
            updated[index].translatedTitle = translation.title ?? updated[index].translatedTitle
            updated[index].translatedBody = translation.body ?? updated[index].translatedBody
        }
        return updated
    }
}
