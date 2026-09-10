import SwiftUI

struct ContinueWatchingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.continueWatching.isEmpty {
                ContentUnavailableView(
                    "Nothing in Progress",
                    systemImage: "play.circle",
                    description: Text("Episodes you stop partway through will appear here.")
                )
            } else {
                List(model.continueWatching) { item in
                    Button { Task { await model.play(item) } } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(item.mediaFile.relativePath).lineLimit(1)
                            ProgressView(value: item.progress?.completion ?? 0)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Continue Watching")
    }
}

