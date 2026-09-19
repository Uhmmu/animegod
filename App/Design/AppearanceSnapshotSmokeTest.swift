import AppKit
import Foundation

/// Visual check of every library screen in both appearances:
///
///     AnimeGod -smokeAppearanceSnapshots
///
/// Walks each sidebar section (plus one anime detail page) in light and
/// dark, writing a PNG of the library window per screen into the app's
/// temporary folder; then opens the empty player window while the app is
/// light, to show it stays dark. Prints the folder and quits. It captures
/// only its own windows, which needs no Screen Recording permission.
enum AppearanceSnapshotSmokeTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-smokeAppearanceSnapshots")
    }

    @MainActor
    static func run(model: AppModel, sections: [String], openPlayer: () -> Void, show: (String) -> Void) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-snapshots", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var waited = 0
        while model.library.isEmpty && waited < 20 {
            try? await Task.sleep(for: .milliseconds(500))
            waited += 1
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title != "Player" }) else {
            print("SMOKE appearance: no library window")
            exit(1)
        }
        window.setContentSize(NSSize(width: 1280, height: 800))

        for mode in [AppearanceMode.light, .dark] {
            AppearanceMode.apply(mode)
            for section in sections {
                show(section)
                // Artwork and provider-backed pages load asynchronously.
                try? await Task.sleep(for: .seconds(section == "detail" || section == "bangumiCharts" ? 4 : 2))
                let url = folder.appendingPathComponent("\(mode.rawValue)-\(section).png")
                if let data = WindowSnapshot.png(of: window) {
                    try? data.write(to: url)
                    print("SMOKE appearance wrote \(url.path)")
                } else {
                    print("SMOKE appearance capture failed for \(section)")
                }
            }
        }
        // The player window must stay dark while the app is light.
        AppearanceMode.apply(.light)
        openPlayer()
        try? await Task.sleep(for: .seconds(2))
        if let player = NSApp.windows.first(where: { $0.isVisible && $0 !== window }), let data = WindowSnapshot.png(of: player) {
            let url = folder.appendingPathComponent("light-player.png")
            try? data.write(to: url)
            print("SMOKE appearance wrote \(url.path) playerAppearance=\(player.effectiveAppearance.name.rawValue)")
            // ...and must not drag the library window along with it.
            if let data = WindowSnapshot.png(of: window) {
                try? data.write(to: folder.appendingPathComponent("light-library-beside-player.png"))
            }
            print("SMOKE appearance libraryAppearance=\(window.effectiveAppearance.name.rawValue)")
            // Closed so window restoration doesn't reopen it on the next launch.
            player.close()
        }
        print("SMOKE appearance folder \(folder.path)")
        exit(0)
    }
}

/// PNG of one of the app's own windows, for smoke tests.
enum WindowSnapshot {
    /// `CGWindowListCreateImage` is unavailable in the macOS 15 SDK but
    /// still present at runtime, and it can read the caller's own windows
    /// without Screen Recording permission; `cacheDisplay` is the fallback,
    /// though it leaves visual-effect backgrounds blank.
    @MainActor
    static func png(of window: NSWindow) -> Data? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let handle = dlopen(nil, RTLD_NOW),
           let symbol = dlsym(handle, "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            // .optionIncludingWindow, .boundsIgnoreFraming | .bestResolution
            if let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() {
                return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
