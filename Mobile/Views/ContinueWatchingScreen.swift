import AnimeGodCore
import SwiftUI

struct ContinueWatchingScreen: View {
    @EnvironmentObject private var model: MobileModel

    var body: some View {
        NavigationStack {
            Group {
                if !model.isPaired {
                    NotPairedView()
                } else if model.continueWatching.isEmpty {
                    ContentUnavailableView("Nothing in Progress", systemImage: "play.circle", description: Text("Episodes you have started show up here, with the position your Mac left them at."))
                } else {
                    List(model.continueWatching) { item in
                        ContinueRow(item: item)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Continue")
        }
    }
}

struct ContinueRow: View {
    @EnvironmentObject private var model: MobileModel
    let item: EpisodeMedia

    var body: some View {
        HStack(spacing: 12) {
            PosterView(url: model.posterURL(for: item.episode.animeID), cornerRadius: 7)
                .frame(width: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.title(forAnimeID: item.episode.animeID))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(Episode.localizedLabel(item.episode.displayLabel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let p = item.progress, p.duration > 0 {
                    ProgressBar(fraction: p.completion)
                    Text("\(formatTime(p.position)) / \(formatTime(p.duration))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            Button {
            } label: {
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
