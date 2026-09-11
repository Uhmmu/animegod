import AnimeGodCore
import Foundation

/// App-level danmaku preferences: the master switch plus presentation
/// settings, persisted in UserDefaults; dandanplay credentials live in the
/// Keychain (see KeychainStore.Danmaku).
@MainActor
final class DanmakuPreferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "danmaku.enabled") }
    }

    @Published var settings: DanmakuDisplaySettings {
        didSet { persistSettings() }
    }

    /// AppId/AppSecret fields bound by the Settings UI; saved to the
    /// Keychain on demand.
    @Published var appID: String
    @Published var appSecret: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "danmaku.enabled") as? Bool ?? true
        if let data = defaults.data(forKey: "danmaku.displaySettings"),
           let decoded = try? JSONDecoder().decode(DanmakuDisplaySettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
        appID = KeychainStore.Danmaku.loadAppID() ?? ""
        appSecret = KeychainStore.Danmaku.loadAppSecret() ?? ""
    }

    var isConfigured: Bool {
        !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveCredentials() {
        appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        appSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.Danmaku.save(appID: appID, appSecret: appSecret)
        objectWillChange.send()
    }

    /// Builds the live dandanplay provider from Keychain credentials.
    /// Signature mode is the documented client-app recommendation.
    func makeProvider() -> (any DanmakuProvider)? {
        guard isConfigured else { return nil }
        return DandanplayDanmakuProvider(credentials: .signature(appID: appID, appSecret: appSecret))
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: "danmaku.displaySettings")
        }
    }
}
