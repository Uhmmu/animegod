import AppKit
import Foundation

/// The interface language. macOS picks an app's language at launch from its
/// `AppleLanguages` default, so choosing one here writes that default (or
/// removes it to follow the system) and takes effect after a relaunch.
/// Switching live would leave AppKit panels, menus and formatters behind.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    /// Each language is named in itself, so it can be found from any other.
    var title: String {
        switch self {
        case .system: String(localized: "System Default")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .japanese: "日本語"
        }
    }

    private static let key = "AppleLanguages"

    /// The choice stored in AnimeGod's own defaults (not the global list).
    static var saved: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        guard let languages = domain?[key] as? [String], let first = languages.first else { return .system }
        return AppLanguage(rawValue: first) ?? .system
    }

    /// Fixed at launch: what the running interface actually uses.
    static let atLaunch = saved

    static func save(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    /// Quits and starts again. The new instance is launched only once this
    /// one has exited, so the two never hold the library database or the
    /// BitTorrent session at the same time.
    @MainActor static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, path]
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}
