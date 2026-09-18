import AnimeGodCore
import Foundation
import Security

/// Stores provider credentials in the macOS Keychain rather than
/// plain-text preferences.
enum KeychainStore {
    private static let defaultService = "com.uhmmu.AnimeGod.translation"
    private static let danmakuService = "com.uhmmu.AnimeGod.danmaku"
    private static let subtitleService = "com.uhmmu.AnimeGod.subtitles"

    static func save(_ value: String, account: String, service: String = defaultService) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(account: String, service: String = defaultService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Credentials for the dandanplay Open Danmaku API, kept in a separate
    /// keychain service. Secrets never leave this type except into
    /// provider construction — and are never logged.
    enum Danmaku {
        static let appIDAccount = "dandanplay-app-id"
        static let appSecretAccount = "dandanplay-app-secret"

        static func loadAppID() -> String? {
            KeychainStore.load(account: appIDAccount, service: danmakuService)
        }

        static func loadAppSecret() -> String? {
            KeychainStore.load(account: appSecretAccount, service: danmakuService)
        }

        static func save(appID: String, appSecret: String) {
            KeychainStore.save(appID, account: appIDAccount, service: danmakuService)
            KeychainStore.save(appSecret, account: appSecretAccount, service: danmakuService)
        }

        /// The optional Bilibili login cookie. Anonymous access is the
        /// default and works for most titles; a `SESSDATA` only widens what
        /// the account may see. It is a session credential, so it lives in
        /// the Keychain beside the other secrets and is never logged.
        static let bilibiliSessDataAccount = "bilibili-sessdata"

        static func loadBilibiliSessData() -> String? {
            KeychainStore.load(account: bilibiliSessDataAccount, service: danmakuService)
        }

        static func saveBilibiliSessData(_ value: String) {
            KeychainStore.save(value, account: bilibiliSessDataAccount, service: danmakuService)
        }
    }
}

extension KeychainStore {
    /// Online subtitle provider credentials. Each value can also come from
    /// an environment variable (for development builds launched from a
    /// terminal); the Keychain entry wins when both exist. Nothing here is
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
            if let stored = KeychainStore.load(account: account.rawValue, service: subtitleService), !stored.isEmpty {
                return stored
            }
            return environment(account)
        }

        static func environment(_ account: Account) -> String {
            ProcessInfo.processInfo.environment[account.environmentVariable]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        static func save(_ value: String, for account: Account) {
            KeychainStore.save(value, account: account.rawValue, service: subtitleService)
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
            case .none: "None"
            case .deepl: "DeepL"
            }
        }

        var id: String { rawValue }
    }

    static let apiKeyAccount = "deepl-api-key"
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
        apiKey = KeychainStore.load(account: Self.apiKeyAccount) ?? ""
    }

    var isConfigured: Bool {
        switch provider {
        case .none: false
        case .deepl: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func saveSettings() {
        defaults.set(provider.rawValue, forKey: "translation.provider")
        defaults.set(targetLanguage.rawValue, forKey: "translation.targetLanguage")
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.save(trimmed, account: Self.apiKeyAccount)
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
