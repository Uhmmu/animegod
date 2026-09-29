import AnimeGodCore
import Combine
import Foundation

/// The phone's own danmaku presentation settings.
///
/// Deliberately not synced from the Mac. `DanmakuDisplaySettings` is shared
/// code, but the values that read well are not: the Mac's font scale is
/// judged on a 27-inch panel at arm's length and the phone's on a 6-inch one
/// held a foot away, and the fraction of the picture it is acceptable to
/// cover is far smaller when the picture is the size of a postcard.
@MainActor
final class MobileDanmakuSettingsStore: ObservableObject {
    @Published var settings: DanmakuDisplaySettings {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private static let key = "danmaku.display"

    /// Opaque text, and half the picture. Both differ from the core defaults
    /// on purpose: 0.8 opacity over a bright scene on a small screen reads as
    /// washed out rather than as subtle, and three quarters of a phone-sized
    /// picture under comments leaves nothing to watch.
    static let phoneDefaults = DanmakuDisplaySettings(
        opacity: 1.0,
        fontScale: 1.0,
        displayArea: 0.5,
        lineSpacing: 1.3
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(DanmakuDisplaySettings.self, from: data) {
            settings = stored
        } else {
            settings = Self.phoneDefaults
        }
    }

    func reset() { settings = Self.phoneDefaults }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The share of the picture comments may cover, as the presets worth having
/// on a phone. The engine fills lanes from the top, so this is literally
/// "keep the bottom N free".
enum DanmakuAreaPreset: Double, CaseIterable, Identifiable {
    case quarter = 0.25
    case third = 0.34
    case half = 0.5
    case threeQuarters = 0.75
    case full = 1.0

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .quarter: String(localized: "Top ¼")
        case .third: String(localized: "Top ⅓")
        case .half: String(localized: "Top ½")
        case .threeQuarters: String(localized: "Top ¾")
        case .full: String(localized: "Full")
        }
    }

    /// The preset a stored fraction is closest to, so a value written by an
    /// older build still selects something.
    static func nearest(to value: Double) -> DanmakuAreaPreset {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .half
    }
}
