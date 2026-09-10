import AnimeGodCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var translation: TranslationCoordinator
    @State private var savedFeedback = false

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
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 560)
    }
}
