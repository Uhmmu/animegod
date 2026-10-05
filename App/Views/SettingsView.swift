import AnimeGodCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var translation: TranslationCoordinator
    @ObservedObject var danmaku: DanmakuPreferences
    @ObservedObject var torrentSources: TorrentSourcePreferences
    @ObservedObject var subtitles: SubtitlePreferences
    @ObservedObject var downloads: TorrentDownloadManager
    @ObservedObject var subscriptions: TorrentSubscriptionManager
    @ObservedObject var link: LinkServer
    let database: LibraryDatabase?
    @State private var savedFeedback = false
    @State private var danmakuSavedFeedback = false
    @State private var subtitleSavedFeedback = false
    @State private var subtitleCacheBytes: Int64 = 0
    @State private var keychainImportResult: String?
    @State private var discogsKey = ""
    @State private var discogsSecret = ""
    @State private var setlistFMKey = ""
    @State private var concertKeysSaved = false
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @State private var language = AppLanguage.saved

    /// Explains what each source costs the viewer, since "both" doubles the
    /// requests per episode and can double-show a popular comment.
    private var sourceExplanation: String {
        switch danmaku.source {
        case .dandanplay: String(localized: "dandanplay identifies the file by hash — the most accurate match when the release is known.")
        case .bilibili: String(localized: "Bilibili matches by title and episode number, and reads the official danmaku pool for that episode.")
        case .both: String(localized: "Both pools are fetched and merged; comments that appear in both are shown once, keeping the dandanplay copy.")
        }
    }

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, mode in AppearanceMode.apply(mode) }
                Text("The player window always stays dark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.title).tag(language)
                    }
                }
                .onChange(of: language) { _, language in AppLanguage.save(language) }
                if language != AppLanguage.atLaunch {
                    HStack {
                        Label("Relaunch AnimeGod to switch the language.", systemImage: "arrow.clockwise.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Now") { AppLanguage.relaunch() }
                    }
                }
            }
            LinkSettingsSection(link: link)
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

            downloadsSection
            subscriptionsSection
            concertSourcesSection

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

    // MARK: - Concerts

    /// The two keys the concert section needs, and what each one buys.
    ///
    /// Both are here rather than only in a file because the empty state of the
    /// Concerts section says "add a key in Settings", and because a key is a
    /// thing people replace — revoked, rotated, pasted wrong the first time.
    private var concertSourcesSection: some View {
        Section("Concert Sources") {
            Text("A concert Blu-ray has no episodes and no anime index lists it, so its page is built from music catalogues instead. MusicBrainz and Bangumi need no key; the other two do.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Discogs") {
                VStack(alignment: .trailing, spacing: 4) {
                    SecureField("Consumer key", text: $discogsKey)
                        .frame(width: 260)
                    SecureField("Consumer secret", text: $discogsSecret)
                        .frame(width: 260)
                }
            }
            Text("The catalogue number, the label, the barcode and the shape of the box. Without a key its search answers 200 with nothing at all, which looks exactly like “no such release”.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("setlist.fm") {
                SecureField("API key", text: $setlistFMKey)
                    .frame(width: 260)
            }
            Text("What was played on each night, in order, with the encore marked — the only source that is about the concert rather than a disc of it. No song lengths, and Japanese titles come back romanised.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save Keys") {
                    CredentialStore.Concert.save(discogsKey: discogsKey, secret: discogsSecret)
                    CredentialStore.Concert.save(setlistFMKey: setlistFMKey)
                    concertKeysSaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { concertKeysSaved = false }
                }
                if concertKeysSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Spacer()
                Text("Stored in AnimeGod's own local settings, outside the library and outside the project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            // The standing credit. A page whose setlist came from them also
            // links to that night's own entry.
            HStack(spacing: 4) {
                Text("Setlists powered by")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("setlist.fm", destination: URL(string: "https://www.setlist.fm/")!)
                    .font(.caption)
            }
        }
        .onAppear {
            let discogs = CredentialStore.Concert.loadDiscogsCredentials()
            discogsKey = discogs?.consumerKey ?? ""
            discogsSecret = discogs?.consumerSecret ?? ""
            setlistFMKey = CredentialStore.Concert.loadSetlistFMKey() ?? ""
        }
    }

    // MARK: - Downloads

    /// Speed limits live here *and* in the Downloads list's own menu: the
    /// ceiling is the one setting somebody reaches for while a download is
    /// running, and making them walk to Settings for it is the reason people
    /// leave it unlimited and wonder why nothing else on the network works.
    private var downloadsSection: some View {
        Section("Downloads") {
            Picker("Download Speed Limit", selection: $downloads.downloadRateLimitKB) {
                ForEach(TorrentDownloadManager.rateLimitChoices, id: \.self) { limit in
                    Text(TorrentDownloadManager.rateLimitText(limit)).tag(limit)
                }
            }
            Picker("Upload Speed Limit", selection: $downloads.uploadRateLimitKB) {
                ForEach(TorrentDownloadManager.rateLimitChoices, id: \.self) { limit in
                    Text(TorrentDownloadManager.rateLimitText(limit)).tag(limit)
                }
            }
            Text("BitTorrent uses every byte of a connection it is given, so a ceiling is what keeps everything else on the network usable. The upload limit applies to what a download gives back while it runs, and to finished releases when sharing is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Downloads at Once", selection: $downloads.maximumActiveDownloads) {
                ForEach(TorrentDownloadManager.activeDownloadChoices, id: \.self) { count in
                    Text(verbatim: "\(count)").tag(count)
                }
            }
            .help("A whole season started at once is queued: this many run, the rest wait their turn")
            Toggle("Unpack Archives When Finished", isOn: $downloads.extractsArchives)
            Toggle("Share Finished Downloads", isOn: $downloads.seedsAfterDownloading)
                .help("Keep uploading a release after it has finished downloading. Switching it off stops every task that has already finished.")
            Text("Off by default. Sharing is how a swarm stays alive — every episode here came from someone who left theirs running — but it uses upload bandwidth for as long as AnimeGod is open, so it is yours to switch on. What is being shared, and how much, is in the Seeding section.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Subscriptions

    private var subscriptionsSection: some View {
        Section("Subscriptions") {
            Picker("Check for New Episodes", selection: $subscriptions.checkIntervalHours) {
                ForEach(TorrentSubscriptionManager.intervalChoices, id: \.self) { hours in
                    Text(SubscriptionsView.intervalLabel(hours)).tag(hours)
                }
            }
            .help("How often the anime indexes are searched for the next episode of each followed show")
            Picker("Automatic Download Speed Limit", selection: $downloads.automaticRateLimitKB) {
                ForEach(TorrentDownloadManager.rateLimitChoices, id: \.self) { limit in
                    Text(TorrentDownloadManager.rateLimitText(limit)).tag(limit)
                }
            }
            Text("An episode a subscription fetches starts without anyone waiting for it, so it is held to its own ceiling — separate from, and on top of, the general limit above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                    keychainImportResult = count == 0 ? String(localized: "Nothing to import.") : String(localized: "Imported \(count) keys.")
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
        case .assrt: String(localized: "Chinese fansub archive · ASS · 20 requests/min")
        case .subdl: String(localized: "TMDB-matched · 简/繁 · 2,000 searches/day")
        case .openSubtitles: String(localized: "Exact-file hash match · SRT only · 5 downloads/day without a login")
        case .jimaku: String(localized: "Japanese only · used when Japanese is a preferred language")
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
