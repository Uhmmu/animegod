import SwiftUI

@main
struct AnimeGodMobileApp: App {
    @StateObject private var model = MobileModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before any player exists: libass asks CoreText for the font by
        // name, so it has to be registered by the time mpv starts.
        MobileSubtitleFont.register()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(model)
                .task {
                    // Browsing runs while the app is up so a Mac that appears
                    // later is still found; the resolver stops it on pairing.
                    model.resolver.startBrowsing()
                    await model.refresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back from the background is exactly when the
                    // library is most likely to be stale — something was
                    // probably just watched on the Mac.
                    if phase == .active { Task { await model.refresh() } }
                }
        }
    }
}
