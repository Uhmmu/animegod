import AnimeGodCore
import SwiftUI

struct AnimeDetailScreen: View {
    @EnvironmentObject private var model: MobileModel
    let entry: LibraryAnime

    @State private var episodes: [EpisodeMedia] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if let target = continueTarget { continueButton(target) }
                if let summary = model.metadataByAnimeID[entry.id]?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                episodeSections
            }
            .padding(16)
        }
        .navigationTitle(model.displayTitle(for: entry))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            episodes = await model.episodes(for: entry.id)
            loaded = true
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterView(url: model.posterURL(for: entry.id))
                .frame(width: 118)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.displayTitle(for: entry))
                    .font(.headline)
                if let original = model.metadataByAnimeID[entry.id]?.originalTitle,
                   !original.isEmpty, original != model.displayTitle(for: entry) {
                    Text(original)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let score = model.score(for: entry.id) {
                    Label(String(format: "%.1f", score), systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("\(entry.watchedCount) of \(entry.episodeCount) watched")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if entry.isFinished {
                    Label("Finished", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }

    /// The same rule the Mac's `AnimeDetailView.continueTarget` uses: the
    /// first main episode not yet seen, at its own breakpoint, falling back to
    /// the top once everything is watched. Phase 4 moves this into the core so
    /// the two screens cannot drift.
    private var mainEpisodes: [EpisodeMedia] {
        let main = episodes.filter { $0.episode.kind.category == .main }
        return main.isEmpty ? episodes : main
    }

    private var continueTarget: (episode: EpisodeMedia, isResume: Bool)? {
        let ordered = mainEpisodes
        guard let first = ordered.first else { return nil }
        guard let next = ordered.first(where: { $0.progress?.isWatched != true }) else {
            return (first, false)
        }
        return (next, (next.progress?.position ?? 0) > 0)
    }

    private func continueLabel(_ target: (episode: EpisodeMedia, isResume: Bool)) -> String {
        if mainEpisodes.allSatisfy({ $0.progress?.isWatched == true }) { return "Play Again" }
        if target.isResume { return "Resume Watching" }
        if target.episode.id == mainEpisodes.first?.id { return "Play First Episode" }
        return "Play \(Episode.localizedLabel(target.episode.episode.displayLabel))"
    }

    private func continueButton(_ target: (episode: EpisodeMedia, isResume: Bool)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
            } label: {
                Label(continueLabel(target), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if target.isResume, let p = target.episode.progress {
                Text("Picks up at \(formatTime(p.position)) — handed off from your Mac")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var episodeSections: some View {
        ForEach(EpisodeCategory.allCases, id: \.self) { category in
            let items = episodes.filter { $0.episode.kind.category == category }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.displayName)
                        .font(.subheadline.weight(.semibold))
                    ForEach(items) { item in
                        EpisodeRow(item: item)
                        if item.id != items.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

struct EpisodeRow: View {
    let item: EpisodeMedia

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(.quaternary).frame(width: 30, height: 30)
                if item.progress?.isWatched == true {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                } else {
                    Image(systemName: "play.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(Episode.localizedLabel(item.episode.displayLabel))
                    .font(.subheadline)
                if let title = item.episode.title, !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let p = item.progress, p.position > 0, p.isWatched == false, p.duration > 0 {
                    ProgressBar(fraction: p.completion).frame(width: 110)
                    Text("\(formatTime(p.position)) / \(formatTime(p.duration))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}
