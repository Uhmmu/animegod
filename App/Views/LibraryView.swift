import AnimeGodCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""

    private var filtered: [LibraryAnime] {
        guard !searchText.isEmpty else { return model.library }
        return model.library.filter { $0.anime.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if model.library.isEmpty {
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
                    ForEach(filtered) { item in
                        NavigationLink(value: item.anime) {
                            AnimeCard(
                                item: item,
                                title: model.metadataByAnimeID[item.anime.id]?.title,
                                posterURLs: model.posterCandidates(for: item.anime.id)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PosterView(urls: posterURLs)
                .aspectRatio(2 / 3, contentMode: .fit)
            Text(title ?? item.anime.title)
                .font(.headline)
                .lineLimit(2)
            Text("\(item.episodeCount) episode\(item.episodeCount == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
