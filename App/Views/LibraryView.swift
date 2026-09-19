import AnimeGodCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""

    private var filtered: [LibraryAnime] {
        guard !searchText.isEmpty else { return model.library }
        return model.library.filter { $0.anime.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// Downloads that are not in the library yet, so a title being fetched
    /// is visible here rather than only under Downloads.
    private var incoming: [TorrentDownloadItem] {
        let libraryIDs = Set(model.library.map(\.anime.id))
        return model.downloads.items.filter { item in
            guard !item.isComplete else { return false }
            guard let animeID = item.record.animeID else { return true }
            return !libraryIDs.contains(animeID)
        }
        .filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// Progress to draw on a library card for a title still downloading.
    private func downloadProgress(for animeID: UUID) -> Double? {
        let active = model.downloads.items.filter { $0.record.animeID == animeID && !$0.isComplete }
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
                    ForEach(incoming) { item in
                        DownloadingCard(item: item)
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
            PosterView(urls: posterURLs)
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


/// A title being downloaded, shown beside the library so it is visible from
/// the moment it starts rather than only once it lands on disk.
private struct DownloadingCard: View {
    @EnvironmentObject private var model: AppModel
    let item: TorrentDownloadItem

    /// The release title parsed down to the work's name, since a raw release
    /// name is unreadable at card size.
    private var displayTitle: String {
        if let animeTitle = item.record.animeTitle, !animeTitle.isEmpty { return animeTitle }
        let parsed = AnimeFilenameParser().parse(url: URL(fileURLWithPath: item.title))
        return parsed.title.isEmpty ? item.title : parsed.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                DownloadRing(progress: item.progress)
                    .frame(width: 56, height: 56)
            }
            .aspectRatio(2 / 3, contentMode: .fit)

            Text(displayTitle)
                .font(.headline)
                .lineLimit(2)
            Text(item.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .help(item.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayTitle), downloading, \(Int(item.progress * 100)) percent")
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
