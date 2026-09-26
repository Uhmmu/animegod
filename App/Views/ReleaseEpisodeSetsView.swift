import AnimeGodCore
import SwiftUI

/// The "Episode Sets" side of Find Releases: instead of one row per
/// listing, one row per fansub's season, with every episode of it ready to
/// start in one go.
///
/// This is the answer to not wanting a batch. The indexes interleave every
/// team, resolution and subtitle language into one long list, so collecting
/// episodes 1–12 of a single line by hand means twelve searches through it.
struct ReleaseEpisodeSetsView: View {
    @ObservedObject var search: TorrentSearchModel
    @ObservedObject var downloads: TorrentDownloadManager
    let anime: Anime?
    @State private var expanded: Set<String> = []

    var body: some View {
        let sets = search.episodeSets
        if sets.isEmpty {
            ContentUnavailableView {
                Label("No Episode Sets", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text("No fansub in these results published more than one numbered episode of the same shape. Batches are left out on purpose — switch to Releases to see them.")
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(sets) { season in
                        EpisodeSetCard(
                            episodeSet: season,
                            search: search,
                            downloads: downloads,
                            anime: anime,
                            isExpanded: Binding(
                                get: { expanded.contains(season.id) },
                                set: { isOn in
                                    if isOn { expanded.insert(season.id) } else { expanded.remove(season.id) }
                                }
                            )
                        )
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct EpisodeSetCard: View {
    let episodeSet: TorrentEpisodeSet
    @ObservedObject var search: TorrentSearchModel
    @ObservedObject var downloads: TorrentDownloadManager
    let anime: Anime?
    @Binding var isExpanded: Bool

    private var pending: Int { episodeSet.downloadableEntries.count }

    /// A set assembled across teams has no fansub of its own to name.
    private var title: String {
        if episodeSet.isMixed { return String(localized: "Best of every fansub") }
        return episodeSet.group ?? String(localized: "Unnamed fansub")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(episodeSet.entries) { entry in
                        EpisodeRow(entry: entry, search: search, downloads: downloads, anime: anime)
                        if entry.id != episodeSet.entries.last?.id { Divider().opacity(0.4) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.headline)
                    if episodeSet.isMixed {
                        SetTag(text: String(localized: "Mixed"), tint: .orange)
                    }
                    ForEach(episodeSet.variant.attributeTags, id: \.self) { tag in
                        SetTag(text: tag, tint: .secondary)
                    }
                }
                coverage
                notes
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }
    }

    private var coverage: some View {
        let needed = episodeSet.neededEpisodes.count
        let ready = episodeSet.downloadableEntries.count
        return HStack(spacing: 8) {
            CoverageBar(episodeSet: episodeSet)
                .frame(width: 120, height: 6)
            Text(episodeSet.ownedEpisodes.isEmpty
                 ? "\(ready)/\(needed) episodes"
                 : "\(ready)/\(needed) missing episodes · \(episodeSet.ownedEpisodes.count) in library")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let size = episodeSet.downloadSize {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .binary))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let seeders = episodeSet.minimumSeeders {
                Label("\(seeders)", systemImage: "arrow.up.circle")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(seeders == 0 ? .orange : .secondary)
                    .help("The weakest swarm in the set — one dead episode holds up the season")
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        HStack(spacing: 6) {
            if episodeSet.substituteCount > 0 {
                SetTag(text: String(localized: "\(episodeSet.substituteCount) from other fansubs"), tint: .orange)
            }
            if !episodeSet.missingEpisodes.isEmpty {
                SetTag(text: String(localized: "Nobody published \(episodeList(episodeSet.missingEpisodes))"), tint: .red)
            }
            if !episodeSet.extras.isEmpty {
                SetTag(text: String(localized: "\(episodeSet.extras.count) extras"), tint: .gray)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button(pending == episodeSet.expectedEpisodes.count
                   ? "Download Set"
                   : "Download \(pending) Episodes") {
                downloads.download(set: episodeSet, anime: anime)
            }
            .disabled(pending == 0)
            .help(episodeSet.isMixed
                  ? String(localized: "The whole season, taking each episode from whichever fansub published it; \(downloads.maximumActiveDownloads) download at a time")
                  : String(localized: "Starts every episode at once; \(downloads.maximumActiveDownloads) download at a time and the rest wait their turn"))

            Menu {
                Button("Download and Play While Downloading") {
                    downloads.download(set: episodeSet, anime: anime, sequential: true)
                }
                if episodeSet.ownedCount > 0 {
                    Button("Download Every Episode, Including \(episodeSet.ownedCount) in the Library") {
                        downloads.download(set: episodeSet, anime: anime, includingOwned: true)
                    }
                }
                Divider()
                Button("Copy \(pending) Magnet Links") { search.copyMagnets(of: episodeSet) }
                if let group = episodeSet.group {
                    Button("Only Show \(group)") { search.filter.groups = [group] }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.small)
    }

    private func episodeList(_ episodes: [Double]) -> String {
        let shown = episodes.prefix(6).map { TorrentEpisodeLabel.text(for: $0) }.joined(separator: ", ")
        return episodes.count > 6 ? "\(shown)…" : shown
    }
}

/// Episodes on disk, ready to fetch, borrowed, and missing — in one bar.
private struct CoverageBar: View {
    let episodeSet: TorrentEpisodeSet

    var body: some View {
        GeometryReader { geometry in
            let total = max(episodeSet.expectedEpisodes.count, 1)
            HStack(spacing: 1) {
                ForEach(episodeSet.expectedEpisodes, id: \.self) { episode in
                    Rectangle().fill(tint(for: episode))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(Capsule())
            .opacity(total == 0 ? 0 : 1)
        }
    }

    private func tint(for episode: Double) -> Color {
        guard let entry = episodeSet.entries.first(where: { $0.episode == episode }) else { return .red.opacity(0.35) }
        if entry.isOwned { return .green.opacity(0.5) }
        return entry.isSubstitute ? .orange : .accentColor
    }
}

private struct EpisodeRow: View {
    let entry: TorrentEpisodeSet.Entry
    @ObservedObject var search: TorrentSearchModel
    @ObservedObject var downloads: TorrentDownloadManager
    let anime: Anime?

    var body: some View {
        HStack(spacing: 10) {
            Text(TorrentEpisodeLabel.text(for: entry.episode))
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(entry.isOwned ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.result.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout)
                    .foregroundStyle(entry.isOwned ? .secondary : .primary)
                    .help(entry.result.title)
                HStack(spacing: 5) {
                    if entry.isOwned { SetTag(text: String(localized: "In library"), tint: .green) }
                    if entry.isExtra { SetTag(text: String(localized: "Extra"), tint: .gray) }
                    if entry.isSubstitute, let group = entry.group {
                        SetTag(text: group, tint: .orange)
                    }
                    Text(entry.result.sources.map(\.displayName).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(entry.result.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) } ?? "—")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(entry.result.seeders.map { "\($0) ↑" } ?? "—")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle((entry.result.seeders ?? 0) == 0 ? .orange : .secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Download") { downloads.download(entry.result, anime: anime) }
            Button("Download and Play While Downloading") {
                downloads.download(entry.result, anime: anime, sequential: true)
            }
            Divider()
            Button("Open in Another Torrent App") { search.openMagnet(entry.result) }
            Button("Copy Magnet Link") { search.copyMagnet(entry.result) }
            Button("Save Torrent File…") { search.saveTorrent(entry.result) }
            if !entry.result.pageURLs.isEmpty {
                Menu("Open Listing Page") {
                    ForEach(entry.result.sources.filter { entry.result.pageURLs[$0] != nil }) { source in
                        Button(source.displayName) { search.openPage(entry.result.pageURLs[source]!) }
                    }
                }
            }
        }
    }
}

private struct SetTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(tint)
    }
}

enum TorrentEpisodeLabel {
    /// "05", "12.5" — the same shape the release titles use.
    static func text(for episode: Double) -> String {
        episode.rounded() == episode
            ? String(format: "%02d", Int(episode))
            : String(episode)
    }
}
