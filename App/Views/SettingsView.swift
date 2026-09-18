import AnimeGodCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var translation: TranslationCoordinator
    @ObservedObject var danmaku: DanmakuPreferences
    @ObservedObject var torrentSources: TorrentSourcePreferences
    @ObservedObject var subtitles: SubtitlePreferences
    let database: LibraryDatabase?
    @State private var savedFeedback = false
    @State private var danmakuSavedFeedback = false
    @State private var subtitleSavedFeedback = false
    @State private var subtitleCacheBytes: Int64 = 0
    @State private var keychainImportResult: String?

    /// Explains what each source costs the viewer, since "both" doubles the
    /// requests per episode and can double-show a popular comment.
    private var sourceExplanation: String {
        switch danmaku.source {
        case .dandanplay: "dandanplay identifies the file by hash — the most accurate match when the release is known."
        case .bilibili: "Bilibili matches by title and episode number, and reads the official danmaku pool for that episode."
        case .both: "Both pools are fetched and merged; comments that appear in both are shown once, keeping the dandanplay copy."
        }
    }

    var body: some View {
        Form {
            Section("Translation") {
                Picker("Provider", selection: $translation.provider) {
                    ForEach(TranslationCoordinator.Provider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Picker("Translate Into", selection: $translation.targetLanguage) {
                    ForEach(TranslationLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                if translation.provider == .deepl {
                    SecureField("DeepL API Key", text: $translation.apiKey, prompt: Text("e.g. 8f2c…:fx"))
                    Text("A free DeepL API key works with the free endpoint; keys ending in “:fx” are detected automatically. The key is stored in AnimeGod's own local settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save") {
                        translation.saveSettings()
                        savedFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { savedFeedback = false }
                    }
                    .disabled(!translation.isConfigured && translation.provider != .none)
                    if savedFeedback {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Spacer()
                    Text(translation.provider == .deepl && !translation.isConfigured
                         ? "Enter an API key to enable translation."
                         : "Foreign-language reviews can then be translated without losing the original text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Danmaku") {
                Picker("Source", selection: $danmaku.source) {
                    ForEach(DanmakuSourceSelection.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Text(sourceExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("dandanplay AppId", text: $danmaku.appID, prompt: Text("from dev.dandanplay.com"))
                SecureField("dandanplay AppSecret", text: $danmaku.appSecret, prompt: Text("one of the two secrets issued to your app"))
                SecureField("Bilibili SESSDATA (optional)", text: $danmaku.bilibiliSessData, prompt: Text("only needed for members-only titles"))
                Picker("Bilibili endpoint", selection: $danmaku.bilibiliEndpoint) {
                    ForEach(BilibiliSession.SegmentEndpoint.allCases, id: \.self) { endpoint in
                        Text(endpoint.displayName).tag(endpoint)
                    }
                }
                HStack {
                    Button("Save") {
                        danmaku.saveCredentials()
                        danmakuSavedFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { danmakuSavedFeedback = false }
                    }
                    if danmakuSavedFeedback {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Spacer()
                    Text("dandanplay uses the official Open Danmaku API — create a (free) app at dev.dandanplay.com and paste its AppId and AppSecret. Bilibili needs no account: it is read anonymously, and a SESSDATA cookie only widens what your account may see. Everything here is stored in AnimeGod's own local settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if danmaku.source != .bilibili, !danmaku.isDandanplayConfigured {
                    Text(danmaku.source == .both
                         ? "Without dandanplay credentials only the Bilibili source runs."
                         : "Without credentials the player still works — danmaku simply stays unavailable until they are configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            onlineSubtitlesSection

            Section("Release Sources") {
                ForEach(TorrentSourceID.allCases) { source in
                    Toggle(isOn: Binding(
                        get: { torrentSources.enabledSources.contains(source) },
                        set: { torrentSources.set(source, enabled: $0) }
                    )) {
                        HStack {
                            Text(source.displayName)
                            Text(source.homepage.host() ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Find Releases searches the enabled anime indexes at once and merges listings of the same torrent. Only anime indexes are offered; adult, game and manga listings are filtered out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 560)
    }

    // MARK: - Online subtitles

    private var onlineSubtitlesSection: some View {
        Section("Online Subtitles") {
            Toggle("Automatically search Chinese subtitles when no Chinese subtitle exists", isOn: $subtitles.autoSearch)
            Toggle("Skip releases whose name says Chinese subtitles are burned in", isOn: $subtitles.skipHardsubbedReleases)
                .help("A release tagged [CHT] or [简日内嵌] with no Chinese subtitle track has the subtitles in the picture.")

            LabeledContent("Languages") {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(orderedLanguages, id: \.self) { language in
                        HStack(spacing: 6) {
                            Toggle(language.displayName, isOn: Binding(
                                get: { subtitles.ranking.languages.contains(language) },
                                set: { subtitles.setLanguage(language, enabled: $0) }
                            ))
                            .toggleStyle(.checkbox)
                            if subtitles.ranking.languages.contains(language) {
                                rankButtons(up: { subtitles.moveLanguage(language, by: -1) }, down: { subtitles.moveLanguage(language, by: 1) })
                            }
                        }
                    }
                }
            }
            LabeledContent("Formats") {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(subtitles.ranking.formats) { format in
                        HStack(spacing: 6) {
                            Text(format.displayName)
                            rankButtons(up: { subtitles.moveFormat(format, by: -1) }, down: { subtitles.moveFormat(format, by: 1) })
                        }
                    }
                }
            }
            LabeledContent("Load automatically at") {
                HStack {
                    Slider(value: $subtitles.ranking.autoLoadThreshold, in: 0.5...0.95, step: 0.05)
                        .frame(width: 180)
                    Text("\(Int((subtitles.ranking.autoLoadThreshold * 100).rounded()))% match")
                        .monospacedDigit()
                }
            }
            Text("Languages and formats are ranked top to bottom. Below the threshold — or when the episode, season, or BD/WEB source does not match — a subtitle is never loaded on its own; the player asks instead.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(SubtitleProviderID.allCases) { provider in
                providerRow(provider)
            }

            HStack {
                Button("Save Keys") {
                    subtitles.saveCredentials()
                    subtitleSavedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { subtitleSavedFeedback = false }
                }
                if subtitleSavedFeedback {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Spacer()
                Text("Keys are stored in AnimeGod's own local settings, not the Keychain. \(AssrtSubtitleProvider.attribution).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Button("Import Keys Saved in the Keychain") {
                    let count = CredentialStore.importFromKeychain()
                    translation.reloadCredentials()
                    danmaku.reloadCredentials()
                    subtitles.reloadCredentials()
                    keychainImportResult = count == 0 ? "Nothing to import." : "Imported \(count) key\(count == 1 ? "" : "s")."
                }
                if let keychainImportResult {
                    Text(keychainImportResult).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Only for keys saved by earlier builds. macOS may ask for your password once per key; they are then removed from the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("Subtitle cache: \(ByteCountFormatter.string(fromByteCount: subtitleCacheBytes, countStyle: .file))")
                Spacer()
                Button("Clear Subtitle Cache", role: .destructive) {
                    Task {
                        await subtitles.clearCache(database: database)
                        refreshSubtitleCacheSize()
                    }
                }
            }
            .onAppear(perform: refreshSubtitleCacheSize)
        }
    }

    /// Enabled languages in their ranked order, then the rest.
    private var orderedLanguages: [SubtitleLanguage] {
        subtitles.ranking.languages + SubtitleLanguage.rankable.filter { !subtitles.ranking.languages.contains($0) }
    }

    private func rankButtons(up: @escaping () -> Void, down: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Button(action: up) { Image(systemName: "chevron.up") }
            Button(action: down) { Image(systemName: "chevron.down") }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    @ViewBuilder
    private func providerRow(_ provider: SubtitleProviderID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { subtitles.enabledProviders.contains(provider) },
                set: { enabled in
                    if enabled { subtitles.enabledProviders.insert(provider) } else { subtitles.enabledProviders.remove(provider) }
                }
            )) {
                HStack {
                    Text(provider.displayName)
                    Text(providerSummary(provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if subtitles.enabledProviders.contains(provider) {
                switch provider {
                case .assrt:
                    SecureField("assrt.net API token", text: credentialBinding(.assrtToken), prompt: Text("from your assrt.net user panel"))
                case .subdl:
                    SecureField("SubDL API key", text: credentialBinding(.subDLAPIKey), prompt: Text("from subdl.com/panel/api"))
                case .openSubtitles:
                    SecureField("OpenSubtitles API key", text: credentialBinding(.openSubtitlesAPIKey), prompt: Text("the app's consumer key"))
                    TextField("OpenSubtitles username (optional)", text: credentialBinding(.openSubtitlesUsername))
                    SecureField("OpenSubtitles password (optional)", text: credentialBinding(.openSubtitlesPassword))
                case .jimaku:
                    SecureField("Jimaku API key", text: credentialBinding(.jimakuAPIKey), prompt: Text("from jimaku.cc/account"))
                }
            }
        }
    }

    private func providerSummary(_ provider: SubtitleProviderID) -> String {
        switch provider {
        case .assrt: "Chinese fansub archive · ASS · 20 requests/min"
        case .subdl: "TMDB-matched · 简/繁 · 2,000 searches/day"
        case .openSubtitles: "Exact-file hash match · SRT only · 5 downloads/day without a login"
        case .jimaku: "Japanese only · used when Japanese is a preferred language"
        }
    }

    private func credentialBinding(_ account: CredentialStore.Subtitles.Account) -> Binding<String> {
        Binding(
            get: { subtitles.credentials[account] ?? "" },
            set: { subtitles.credentials[account] = $0 }
        )
    }

    private func refreshSubtitleCacheSize() {
        let cache = subtitles.cache
        Task {
            let bytes = await Task.detached(priority: .utility) { cache.diskUsage() }.value
            subtitleCacheBytes = bytes
        }
    }
}
