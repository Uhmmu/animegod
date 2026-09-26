import AnimeGodCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    /// Observed here rather than through AppModel: download progress ticks
    /// once a second, and only this screen and the sidebar badge show it.
    @ObservedObject var downloads: TorrentDownloadManager
    @State private var searchText = ""

    private var filtered: [LibraryAnime] {
        guard !searchText.isEmpty else { return model.library }
        return model.library.filter { $0.anime.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// Downloads that are not in the library yet, so a title being fetched is
    /// visible here rather than only under Downloads.
    private var pendingDownloads: [TorrentDownloadItem] {
        let libraryIDs = Set(model.library.map(\.anime.id))
        return downloads.items.filter { item in
            guard !item.isComplete else { return false }
            guard let animeID = item.record.animeID else { return true }
            return !libraryIDs.contains(animeID)
        }
    }

    /// The same downloads grouped by the work they belong to: a season
    /// started as a set is one card here, not twelve, because twelve cards
    /// for one show is not what "downloading" looks like to a viewer.
    private var incoming: [IncomingWork] {
        var order: [String] = []
        var grouped: [String: [TorrentDownloadItem]] = [:]
        for item in pendingDownloads {
            let key = item.record.animeID?.uuidString
                ?? TorrentDownloadFolder.sharedSeriesTitle(of: [item.title])
                ?? item.record.infoHash
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        return order.compactMap { key -> IncomingWork? in
            guard let items = grouped[key], let first = items.first else { return nil }
            let series = TorrentDownloadFolder.sharedSeriesTitle(of: items.map(\.title))
            // A work matched while it downloads has a real anime row, so its
            // cover and page come from the library like any other card's.
            let animeID = first.record.animeID
            let anime = animeID.flatMap { model.incomingAnime[$0] }
            let posters = animeID.map { model.posterCandidates(for: $0) } ?? []
            let matched = series.flatMap { model.incomingMatches[$0] }
            return IncomingWork(
                id: key,
                title: animeID.flatMap { model.metadataByAnimeID[$0]?.title }
                    ?? first.record.animeTitle
                    ?? matched?.title
                    ?? series
                    ?? first.title,
                posterURLs: posters.isEmpty ? [matched?.posterURL].compactMap { $0 } : posters,
                anime: anime,
                items: items
            )
        }
        .filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// Anime rows that downloads point at but the library has no files for
    /// yet, so their cards can open after a relaunch too.
    private var incomingAnimeIDs: [UUID] {
        Array(Set(pendingDownloads.compactMap(\.record.animeID))).sorted { $0.uuidString < $1.uuidString }
    }

    /// The works being downloaded, for the metadata lookup that gives their
    /// cards a cover before a single file has landed.
    private var incomingSeriesTitles: [String] {
        Array(Set(pendingDownloads.compactMap { TorrentDownloadFolder.sharedSeriesTitle(of: [$0.title]) })).sorted()
    }

    /// Progress to draw on a library card for a title still downloading.
    private func downloadProgress(for animeID: UUID) -> Double? {
        let active = downloads.items.filter { $0.record.animeID == animeID && !$0.isComplete }
        guard !active.isEmpty else { return nil }
        return active.map(\.progress).reduce(0, +) / Double(active.count)
    }

    var body: some View {
        Group {
            if model.library.isEmpty && incoming.isEmpty {
                ContentUnavailableView {
                    Label("No Anime Yet", systemImage: "film.stack")
                } description: {
                    Text("Add a folder to turn local video files into an anime library.")
                } actions: {
                    Button("Add Anime Folder…") { model.chooseLibraryRoot() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 24) {
                    ForEach(incoming) { work in
                        if let anime = work.anime {
                            NavigationLink(value: anime) {
                                DownloadingCard(work: work)
                            }
                            .buttonStyle(.plain)
                        } else {
                            DownloadingCard(work: work)
                        }
                    }
                    ForEach(filtered) { item in
                        NavigationLink(value: item.anime) {
                            AnimeCard(
                                item: item,
                                title: model.metadataByAnimeID[item.anime.id]?.title,
                                posterURLs: model.posterCandidates(for: item.anime.id),
                                downloadProgress: downloadProgress(for: item.anime.id)
                            )
                        }
                            .buttonStyle(.plain)
                    }
                    }
                    .padding(24)
                }
                .navigationDestination(for: Anime.self) { AnimeDetailView(anime: $0) }
            }
        }
        .navigationTitle("All Anime")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search library")
        .task(id: incomingSeriesTitles) {
            await model.resolveIncomingMatches(seriesTitles: incomingSeriesTitles)
        }
        .task(id: incomingAnimeIDs) {
            await model.loadIncomingAnime(ids: incomingAnimeIDs)
        }
    }
}

private struct AnimeCard: View {
    let item: LibraryAnime
    let title: String?
    let posterURLs: [URL]
    /// Non-nil while an episode of this title is downloading.
    var downloadProgress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PosterView(urls: posterURLs, height: 380)
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if let downloadProgress {
                        DownloadRing(progress: downloadProgress)
                            .frame(width: 30, height: 30)
                            .padding(8)
                    }
                }
            Text(title ?? item.anime.title)
                .font(.headline)
                .lineLimit(2)
            Text("\(item.episodeCount) episodes")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}


/// One work being downloaded: every episode of it that is still running,
/// under the name and cover the metadata lookup found for it.
struct IncomingWork: Identifiable {
    let id: String
    let title: String
    let posterURLs: [URL]
    /// Set once the work has been matched, which is what makes the card
    /// open the anime's own page.
    let anime: Anime?
    let items: [TorrentDownloadItem]

    var progress: Double {
        guard !items.isEmpty else { return 0 }
        return items.map(\.progress).reduce(0, +) / Double(items.count)
    }

    /// Episodes of this work that have landed, out of the ones running.
    var finishedCount: Int { items.filter { $0.progress >= 1 }.count }
}

/// A title being downloaded, shown beside the library so it is visible from
/// the moment it starts rather than only once it lands on disk.
private struct DownloadingCard: View {
    let work: IncomingWork

    private var statusText: String {
        guard work.items.count > 1 else { return work.items.first?.statusText ?? "" }
        return String(localized: "\(work.finishedCount) of \(work.items.count) episodes")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if !work.posterURLs.isEmpty {
                    PosterView(urls: work.posterURLs, height: 380)
                        .overlay(alignment: .topTrailing) {
                            DownloadRing(progress: work.progress)
                                .frame(width: 30, height: 30)
                                .padding(8)
                        }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                        DownloadRing(progress: work.progress)
                            .frame(width: 56, height: 56)
                    }
                }
            }
            .aspectRatio(2 / 3, contentMode: .fit)

            Text(work.title)
                .font(.headline)
                .lineLimit(2)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .help(work.items.map(\.title).joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(work.title), downloading, \(Int(work.progress * 100)) percent")
    }
}

/// The App Store-style ring: fills clockwise as the download completes.
private struct DownloadRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.35))
            Circle()
                .stroke(.white.opacity(0.3), lineWidth: 3)
                .padding(3)
            Circle()
                .trim(from: 0, to: max(0.01, min(progress, 1)))
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
                .animation(.easeInOut(duration: 0.4), value: progress)
            Text("\(Int(progress * 100))")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
