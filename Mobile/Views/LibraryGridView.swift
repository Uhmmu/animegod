import AnimeGodCore
import SwiftUI

struct LibraryGridView: View {
    @EnvironmentObject private var model: MobileModel
    @State private var showingPairing = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if !model.isPaired {
                    NotPairedView { showingPairing = true }
                } else if model.works.isEmpty && model.isRefreshing {
                    ProgressView()
                } else if model.works.isEmpty {
                    ContentUnavailableView(
                        "Nothing Here Yet",
                        systemImage: "square.grid.2x2",
                        description: Text(model.lastError ?? String(localized: "Your Mac's library came back empty."))
                    )
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
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showingPairing) { PairingScreen() }
        }
    }

    private var grid: some View {
        ScrollView {
            if !model.isReachable {
                OfflineBanner(lastSyncedAt: model.lastSyncedAt)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(model.sortedWorks) { work in
                    NavigationLink {
                        AnimeDetailScreen(work: work)
                    } label: {
                        LibraryCard(work: work)
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
    let work: LinkWork

    private var fraction: Double {
        guard work.episodeCount > 0 else { return 0 }
        return Double(work.watchedCount) / Double(work.episodeCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterView(animeID: work.id)
                .overlay(alignment: .topTrailing) {
                    if work.isFinished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white, .green)
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottom) {
                    if fraction > 0 && !work.isFinished {
                        ProgressBar(fraction: fraction)
                            .padding(.horizontal, 5)
                            .padding(.bottom, 5)
                    }
                }

            Text(work.displayTitle)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: "\(work.watchedCount)/\(work.episodeCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct OfflineBanner: View {
    let lastSyncedAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            VStack(alignment: .leading, spacing: 1) {
                Text("Your Mac is not reachable")
                    .font(.caption.weight(.medium))
                if let lastSyncedAt {
                    Text("Showing what it said \(lastSyncedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary, in: .rect(cornerRadius: 10))
    }
}

struct NotPairedView: View {
    var pair: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Not Paired", systemImage: "laptopcomputer.and.iphone")
        } description: {
            Text("AnimeGod on your Mac holds the library. Pair with it to browse here and pick up where you left off.")
        } actions: {
            Button("Pair with a Mac…", action: pair)
                .buttonStyle(.borderedProminent)
        }
    }
}
