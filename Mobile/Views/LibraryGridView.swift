import AnimeGodCore
import SwiftUI

struct LibraryGridView: View {
    @EnvironmentObject private var model: MobileModel

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView()
                } else if !model.isPaired {
                    NotPairedView()
                } else if let error = model.loadError {
                    ContentUnavailableView("Could not read the library", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    grid
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $model.sortOrder) {
                            ForEach(MobileSortOrder.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(model.sortedLibrary) { entry in
                    NavigationLink {
                        AnimeDetailScreen(entry: entry)
                    } label: {
                        LibraryCard(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

struct LibraryCard: View {
    @EnvironmentObject private var model: MobileModel
    let entry: LibraryAnime

    private var fraction: Double {
        guard entry.episodeCount > 0 else { return 0 }
        return Double(entry.watchedCount) / Double(entry.episodeCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterView(url: model.posterURL(for: entry.id))
                .overlay(alignment: .topTrailing) {
                    if entry.isFinished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white, .green)
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottom) {
                    if fraction > 0 && !entry.isFinished {
                        ProgressBar(fraction: fraction)
                            .padding(.horizontal, 5)
                            .padding(.bottom, 5)
                    }
                }

            Text(model.displayTitle(for: entry))
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(entry.watchedCount)/\(entry.episodeCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct NotPairedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Not Paired", systemImage: "laptopcomputer.and.iphone")
        } description: {
            Text("AnimeGod on your Mac holds the library. Pair with it to mirror the library here and hand playback back and forth.")
        } actions: {
            Button("Pair with a Mac…") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        }
    }
}
