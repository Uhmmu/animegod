import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var model: MobileModel

    var body: some View {
        TabView {
            LibraryGridView()
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
            ContinueWatchingScreen()
                .tabItem { Label("Continue", systemImage: "play.circle") }
            MoreScreen()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
