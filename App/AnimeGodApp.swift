import SwiftUI

@main
struct AnimeGodApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        Window("Player", id: "player") {
            PlayerWindowRoot()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 400)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 660)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Library Folder…") { model.chooseLibraryRoot() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Scan All Libraries") { Task { await model.scanAll() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.isScanning || model.roots.isEmpty)
                Button("Find Library Metadata") { Task { await model.enrichLibraryMetadata() } }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(model.isEnrichingMetadata || model.library.isEmpty)
            }
        }
    }
}

/// The standalone player window's content: plays whatever the app last
/// requested, or waits for a request when opened without one.
struct PlayerWindowRoot: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let request = model.playerRequest {
                PlayerScreen(request: request)
                    .id(request.id)
            } else {
                ContentUnavailableView(
                    "Nothing Playing",
                    systemImage: "play.rectangle.on.rectangle",
                    description: Text("Pick an episode from the library window.")
                )
                .foregroundStyle(.white)
            }
        }
        .onDisappear {
            // Allow the next play action to reopen the window.
            model.playerRequest = nil
        }
        .task {
            // Headless smoke mode: auto-play the first episode so resize and
            // fullscreen behavior can be verified from the console.
            guard ProcessInfo.processInfo.arguments.contains("-smokePlayerTest"),
                  model.playerRequest == nil else { return }
            var waited = 0
            while model.library.isEmpty && waited < 20 {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
            guard let anime = model.library.first?.anime else { return }
            let episodes = await model.episodes(for: anime)
            if let episode = episodes.first { await model.play(episode) }
        }
    }
}
