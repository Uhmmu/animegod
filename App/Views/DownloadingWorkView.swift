import AnimeGodCore
import SwiftUI

/// A work being downloaded that has not been matched to an anime yet.
///
/// Its card on the home screen used to be the one thing there that did not
/// open: there was no anime row behind it, so there was nothing to push. But
/// "what is actually downloading, and how far along is it" is exactly what
/// somebody clicks a downloading card to find out — so this page answers that
/// much, and offers the match that turns it into an ordinary library entry.
struct IncomingWorkRoute: Hashable {
    /// The work key its downloads share — the folder they are saved into.
    let key: String
    let title: String
}

struct DownloadingWorkView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var downloads: TorrentDownloadManager
    let route: IncomingWorkRoute

    private var items: [TorrentDownloadItem] {
        downloads.items.filter { downloads.seriesKey(of: $0) == "folder:\(route.key)" || downloads.seriesKey(of: $0) == "series:\(route.key)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing Downloading", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Every episode of this work has finished. Once its folder is scanned it becomes an ordinary library entry.")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    DownloadingEpisodeSection(items: items, downloads: downloads)
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle(route.title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(route.title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .textSelection(.enabled)
            Text("This work is still downloading and has not been matched yet, so there is no artwork, synopsis or rating for it. Matching it now links every episode of it — and the scan that follows finds it already matched.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 700, alignment: .leading)
            Button {
                Task { await model.offerIncomingMatchAgain(workKey: route.key) }
            } label: {
                Label("Which Anime Is This?…", systemImage: "link.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

/// The episodes of one work that are still arriving, as a list that reads like
/// the episode list on an anime's page — because that is what it becomes.
struct DownloadingEpisodeSection: View {
    let items: [TorrentDownloadItem]
    @ObservedObject var downloads: TorrentDownloadManager

    /// Episode order, with the ones nobody could number last.
    private var ordered: [TorrentDownloadItem] {
        items.sorted { lhs, rhs in
            switch (lhs.episodeNumber, rhs.episodeNumber) {
            case let (left?, right?): return left < right
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.record.addedAt < rhs.record.addedAt
            }
        }
    }

    private var finished: Int { items.filter(\.isComplete).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Downloading").font(.title2.bold())
                Text("\(finished) of \(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if items.contains(where: { $0.record.isAutomatic }) {
                    Text("· started by your subscription")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            LazyVStack(spacing: 1) {
                ForEach(ordered) { item in
                    DownloadingEpisodeRow(item: item, downloads: downloads)
                    if item.id != ordered.last?.id { Divider().padding(.leading, 50) }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// One arriving episode. Where a finished episode has a play button, this has
/// the ring that says how much of it exists — and once enough of the start is
/// on disk, it becomes a play button without waiting for the rest.
private struct DownloadingEpisodeRow: View {
    @EnvironmentObject private var model: AppModel
    let item: TorrentDownloadItem
    @ObservedObject var downloads: TorrentDownloadManager

    private var playable: AGTorrentFileEntry? { downloads.playableVideoFile(for: item) }

    var body: some View {
        HStack(spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                Text(item.episodeText.map { String(localized: "Episode \($0)") } ?? item.title)
                    .font(.headline)
                Text(item.statusText)
                    .font(.caption)
                    .foregroundStyle(item.snapshot?.state == .errored ? .red : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let remaining = item.remainingText {
                Text("\(remaining) left")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            if let file = playable {
                Button {
                    downloads.play(file, of: item, using: model)
                } label: {
                    Text(item.isComplete ? "Play" : "Play Now")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.link)
                .help(item.isComplete ? "Play" : "Play now — the rest keeps downloading")
            }
            if !item.isComplete {
                Button {
                    item.isPaused ? downloads.resume(item) : downloads.pause(item)
                } label: {
                    Image(systemName: item.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .help(item.isPaused ? "Resume" : "Pause")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .help(item.title)
    }

    @ViewBuilder
    private var leading: some View {
        if item.isComplete {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.green)
        } else {
            EpisodeProgressRing(progress: item.progress, isPaused: item.isPaused)
                .frame(width: 26, height: 26)
        }
    }
}

/// The blue ring that stands where an episode's play button will be.
struct EpisodeProgressRing: View {
    let progress: Double
    var isPaused = false

    private var tint: Color { isPaused ? .secondary : .accentColor }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.22), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: progress)
            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint)
            } else {
                Text(verbatim: "\(Int(progress * 100))")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("Downloading, \(Int(progress * 100)) percent")
    }
}
