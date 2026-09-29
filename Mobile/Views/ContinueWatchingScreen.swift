import AnimeGodCore
import SwiftUI

struct ContinueWatchingScreen: View {
    @EnvironmentObject private var model: MobileModel
    @State private var showingPairing = false
    @State private var playing: LinkEpisode?

    var body: some View {
        NavigationStack {
            Group {
                if !model.isPaired {
                    NotPairedView { showingPairing = true }
                } else if model.continueWatching.isEmpty {
                    ContentUnavailableView(
                        "Nothing in Progress",
                        systemImage: "play.circle",
                        description: Text("Episodes you have started show up here, at the position your Mac left them.")
                    )
                } else {
                    List(model.continueWatching) { item in
                        ContinueRow(item: item) { playing = item }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Continue")
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showingPairing) { PairingScreen() }
            .fullScreenCover(item: $playing) { episode in
                if let work = model.work(id: episode.animeID) {
                    MobilePlayerScreen(episode: episode, work: work, model: model)
                        .environmentObject(model)
                }
            }
        }
    }
}

struct ContinueRow: View {
    @EnvironmentObject private var model: MobileModel
    let item: LinkEpisode
    var play: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PosterView(animeID: item.animeID, cornerRadius: 7).frame(width: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.title(forAnimeID: item.animeID))
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                Text(Episode.localizedLabel(item.label))
                    .font(.caption).foregroundStyle(.secondary)
                if item.duration > 0 {
                    ProgressBar(fraction: item.completion)
                    Text(verbatim: "\(formatTime(item.position)) / \(formatTime(item.duration))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            Button(action: play) {
                Image(systemName: "play.fill")
                    .font(.footnote.weight(.bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(.circle)
        }
        .padding(.vertical, 4)
    }
}
