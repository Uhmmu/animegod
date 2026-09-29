import SwiftUI

@main
struct AnimeGodMobileApp: App {
    @StateObject private var model = MobileModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(model)
                .task { await model.load() }
        }
    }
}
