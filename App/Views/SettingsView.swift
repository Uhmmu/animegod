import AnimeGodCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var translation: TranslationCoordinator
    @ObservedObject var danmaku: DanmakuPreferences
    @State private var savedFeedback = false
    @State private var danmakuSavedFeedback = false

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
                    Text("A free DeepL API key works with the free endpoint; keys ending in “:fx” are detected automatically. The key is stored in your macOS Keychain.")
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
                    Text("dandanplay uses the official Open Danmaku API — create a (free) app at dev.dandanplay.com and paste its AppId and AppSecret. Bilibili needs no account: it is read anonymously, and a SESSDATA cookie only widens what your account may see. Everything here is stored in your macOS Keychain, never in plain text.")
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
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 560)
    }
}
