import AnimeGodCore
import SwiftUI

struct AnimeDetailScreen: View {
    @EnvironmentObject private var model: MobileModel
    let work: LinkWork

    @State private var detail: LinkAnimeDetail?

    private var episodes: [LinkEpisode] { detail?.episodes ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if let target = continueTarget { continueButton(target) }
                if let summary = detail?.summary, !summary.isEmpty {
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                }
                if let sources = detail?.sources, !sources.isEmpty { ratings(sources) }
                episodeSections
            }
            .padding(16)
        }
        .navigationTitle(work.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            detail = model.cachedDetail(for: work.id)
            detail = await model.detail(for: work.id)
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterView(animeID: work.id).frame(width: 118)

            VStack(alignment: .leading, spacing: 6) {
                Text(work.displayTitle).font(.headline)
                if let original = work.originalTitle, !original.isEmpty, original != work.displayTitle {
                    Text(original).font(.caption).foregroundStyle(.secondary)
                }
                if let score = work.score {
                    Label(String(format: "%.1f", score), systemImage: "star.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("\(work.watchedCount) of \(work.episodeCount) watched")
                    .font(.caption).foregroundStyle(.secondary)
                if work.isFinished {
                    Label("Finished", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }

    private func ratings(_ sources: [LinkMetadataSource]) -> some View {
        HStack(spacing: 16) {
            ForEach(sources, id: \.provider) { source in
                if let score = source.score {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.displayName).font(.caption2).foregroundStyle(.secondary)
                        Text(String(format: "%.1f", score)).font(.subheadline.weight(.medium))
                    }
                }
            }
            Spacer()
        }
    }

    /// The same rule the Mac's `AnimeDetailView.continueTarget` uses: the first
    /// main episode not yet seen, at its own breakpoint, falling back to the
    /// top once everything is watched.
    private var mainEpisodes: [LinkEpisode] {
        let main = episodes.filter { $0.kind.category == .main }
        return main.isEmpty ? episodes : main
    }

    private var continueTarget: (episode: LinkEpisode, isResume: Bool)? {
        let ordered = mainEpisodes
        guard let first = ordered.first else { return nil }
        guard let next = ordered.first(where: { !$0.isWatched }) else { return (first, false) }
        return (next, next.position > 0)
    }

    private func continueLabel(_ target: (episode: LinkEpisode, isResume: Bool)) -> String {
        if mainEpisodes.allSatisfy(\.isWatched) { return String(localized: "Play Again") }
        if target.isResume { return String(localized: "Resume Watching") }
        if target.episode.id == mainEpisodes.first?.id { return String(localized: "Play First Episode") }
        return String(localized: "Play \(Episode.localizedLabel(target.episode.label))")
    }

    private func continueButton(_ target: (episode: LinkEpisode, isResume: Bool)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
            } label: {
                Label(continueLabel(target), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if target.isResume {
                Text("Picks up at \(formatTime(target.episode.position)) — where your Mac left it")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var episodeSections: some View {
        ForEach(EpisodeCategory.allCases, id: \.self) { category in
            let items = episodes.filter { $0.kind.category == category }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.displayName).font(.subheadline.weight(.semibold))
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
    @EnvironmentObject private var model: MobileModel
    let item: LinkEpisode

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(.quaternary).frame(width: 30, height: 30)
                Image(systemName: item.isWatched ? "checkmark" : "play.fill")
                    .font(.caption2.weight(item.isWatched ? .bold : .regular))
                    .foregroundStyle(item.isWatched ? Color.green : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(Episode.localizedLabel(item.label)).font(.subheadline)
                if let title = item.title, !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if item.position > 0, !item.isWatched, item.duration > 0 {
                    ProgressBar(fraction: item.completion).frame(width: 110)
                    Text(verbatim: "\(formatTime(item.position)) / \(formatTime(item.duration))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .contextMenu {
            Button(item.isWatched ? "Mark as Unwatched" : "Mark as Watched") {
                Task { await model.setWatched(!item.isWatched, episodeID: item.id) }
            }
        }
    }
}
