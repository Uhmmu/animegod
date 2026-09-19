import AppKit
import SwiftUI

/// The app-wide light/dark choice. Applied through `NSApp.appearance`
/// rather than `.preferredColorScheme` so sheets, menus, alerts and open
/// panels follow it too, and so a change restyles open windows in place.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearanceMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var saved: AppearanceMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppearanceMode.init) ?? .system
    }

    @MainActor static func apply(_ mode: AppearanceMode = .saved) {
        NSApplication.shared.appearance = mode.nsAppearance
    }
}
