import AnimeGodCore
import Foundation

/// App-level danmaku preferences: the master switch, which source(s) to
/// pull from, and presentation settings, persisted in UserDefaults.
/// Credentials (dandanplay AppId/AppSecret, the optional Bilibili
/// `SESSDATA`) live in the local credential file — see `CredentialStore.Danmaku`.
@MainActor
final class DanmakuPreferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "danmaku.enabled") }
    }

    @Published var settings: DanmakuDisplaySettings {
        didSet { persistSettings() }
    }

    /// Which provider(s) supply comments.
    @Published var source: DanmakuSourceSelection {
        didSet { defaults.set(source.rawValue, forKey: "danmaku.source") }
    }

    /// Which Bilibili danmaku endpoint to use. Automatic prefers the plain
    /// segment endpoint and falls back to the WBI-signed one.
    @Published var bilibiliEndpoint: BilibiliSession.SegmentEndpoint {
        didSet {
            defaults.set(bilibiliEndpoint.rawValue, forKey: "danmaku.bilibili.endpoint")
            applyBilibiliConfiguration()
        }
    }

    /// AppId/AppSecret fields bound by the Settings UI; saved to the
    /// credential file on demand.
    @Published var appID: String
    @Published var appSecret: String
    /// Optional Bilibili login cookie, bound by the Settings UI.
    @Published var bilibiliSessData: String

    /// One Bilibili session for the whole app: it carries the anonymous
    /// device cookie and the daily WBI keys, so sharing it means those are
    /// fetched once rather than per episode.
    private let bilibiliSession: BilibiliSession
    private let bilibiliCookies: BilibiliCookieStore

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "danmaku.enabled") as? Bool ?? true
        if let data = defaults.data(forKey: "danmaku.displaySettings"),
           let decoded = try? JSONDecoder().decode(DanmakuDisplaySettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
        source = (defaults.string(forKey: "danmaku.source").flatMap(DanmakuSourceSelection.init(rawValue:))) ?? .dandanplay
        bilibiliEndpoint = (defaults.string(forKey: "danmaku.bilibili.endpoint")
            .flatMap(BilibiliSession.SegmentEndpoint.init(rawValue:))) ?? .automatic
        appID = CredentialStore.Danmaku.loadAppID() ?? ""
        appSecret = CredentialStore.Danmaku.loadAppSecret() ?? ""
        let sessData = CredentialStore.Danmaku.loadBilibiliSessData() ?? ""
        bilibiliSessData = sessData

        bilibiliCookies = BilibiliCookieStore(
            user: BilibiliCookieStore.UserCredentials(sessData: sessData.isEmpty ? nil : sessData)
        )
        bilibiliSession = BilibiliSession(cookies: bilibiliCookies)
        applyBilibiliConfiguration()
    }

    /// dandanplay needs credentials; Bilibili works anonymously.
    var isDandanplayConfigured: Bool {
        !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when at least one selected source can actually run.
    var isConfigured: Bool { !makeProviders().isEmpty }

    /// Re-reads the stored credentials (after an import) and applies them.
    func reloadCredentials() {
        appID = CredentialStore.Danmaku.loadAppID() ?? ""
        appSecret = CredentialStore.Danmaku.loadAppSecret() ?? ""
        bilibiliSessData = CredentialStore.Danmaku.loadBilibiliSessData() ?? ""
        saveCredentials()
    }

    func saveCredentials() {
        appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        appSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        bilibiliSessData = bilibiliSessData.trimmingCharacters(in: .whitespacesAndNewlines)
        CredentialStore.Danmaku.save(appID: appID, appSecret: appSecret)
        CredentialStore.Danmaku.saveBilibiliSessData(bilibiliSessData)
        let sessData = bilibiliSessData
        let cookies = bilibiliCookies
        Task { await cookies.apply(user: BilibiliCookieStore.UserCredentials(sessData: sessData.isEmpty ? nil : sessData)) }
        applyBilibiliConfiguration()
        objectWillChange.send()
    }

    /// Builds every provider the current selection activates, in priority
    /// order. A source that is selected but unusable is simply absent, so
    /// choosing "both" with no dandanplay credentials still gives Bilibili.
    func makeProviders() -> [any DanmakuProvider] {
        source.providerIDs.compactMap { makeProvider(id: $0) }
    }

    func makeProvider(id: String) -> (any DanmakuProvider)? {
        switch id {
        case "dandanplay":
            // Signature mode is the documented client-app recommendation.
            guard isDandanplayConfigured else { return nil }
            return DandanplayDanmakuProvider(credentials: .signature(appID: appID, appSecret: appSecret))
        case BilibiliDanmakuProvider.providerID:
            return BilibiliDanmakuProvider(session: bilibiliSession)
        default:
            return nil
        }
    }

    /// The first active provider — the one manual search and single-source
    /// flows use.
    func makeProvider() -> (any DanmakuProvider)? { makeProviders().first }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: "danmaku.displaySettings")
        }
    }

    private func applyBilibiliConfiguration() {
        var configuration = BilibiliSession.Configuration()
        configuration.segmentEndpoint = bilibiliEndpoint
        let session = bilibiliSession
        Task { await session.update(configuration: configuration) }
    }
}
