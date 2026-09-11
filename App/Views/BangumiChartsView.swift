import AnimeGodCore
import AppKit
import SwiftUI

/// Bangumi's site-wide ranking charts: every channel (anime, books, music,
/// games, live action) and every filter sidebar the site offers. Charts are
/// cached per channel+filter so switching between them is instant, and rows
/// link into the local library whenever the subject is already matched.
struct BangumiChartsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var channel: BangumiChartChannel = .anime
    @State private var filter: BangumiChartFilter?
    @State private var cache: [ChartKey: ChartState] = [:]
    @State private var filtersByChannel: [BangumiChartChannel: [BangumiChartFilter]] = [:]
    @State private var isLoadingFirstPage = false
    @State private var isLoadingMore = false
    @State private var loadError: String?

    private let provider = BangumiChartsProvider()

    private var key: ChartKey { ChartKey(channel: channel, filter: filter) }
    private var state: ChartState? { cache[key] }

    var body: some View {
        Group {
            if let state, !state.entries.isEmpty {
                chartList(state)
            } else if isLoadingFirstPage {
                ProgressView("Loading Bangumi charts…")
            } else if let loadError {
                ContentUnavailableView {
                    Label("Charts Unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Retry") { Task { await loadFirstPage(force: true) } }
                }
            } else {
                ContentUnavailableView("No Chart Entries", systemImage: "chart.bar.doc.horizontal")
            }
        }
        .navigationTitle("Bangumi Charts")
        .toolbar {
            ToolbarItemGroup {
                Picker("Channel", selection: $channel) {
                    ForEach(BangumiChartChannel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .help("Bangumi subject category")

                if !availableFilters.isEmpty {
                    Picker("Filter", selection: $filter) {
                        Text("All").tag(BangumiChartFilter?.none)
                        ForEach(filterGroups, id: \.name) { group in
                            Section(group.name) {
                                ForEach(group.filters) { filter in
                                    Text(filter.title).tag(BangumiChartFilter?.some(filter))
                                }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Narrow the chart to one category, tag, or platform")
                }

                Button {
                    Task { await loadFirstPage(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingFirstPage || isLoadingMore)
            }
        }
        .onChange(of: channel) { _, _ in
            // Filter paths belong to their channel; keep a stale one from
            // requesting a chart that does not exist.
            filter = nil
        }
        .task(id: key) {
            await loadFirstPage()
        }
        .navigationDestination(for: Anime.self) { AnimeDetailView(anime: $0) }
    }

    private func chartList(_ state: ChartState) -> some View {
        let library = libraryBySubjectID
        return List {
            ForEach(state.entries) { entry in
                ChartRow(entry: entry, libraryAnime: library[entry.subjectID])
            }
            if state.loadedPages < state.totalPages {
                Section {
                    HStack(spacing: 12) {
                        if isLoadingMore { ProgressView().controlSize(.small) }
                        Button("Load More") { Task { await loadNextPage() } }
                            .disabled(isLoadingMore)
                        Text("Page \(state.loadedPages) of \(state.totalPages)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Filters

    private var availableFilters: [BangumiChartFilter] {
        filtersByChannel[channel] ?? []
    }

    private var filterGroups: [(name: String, filters: [BangumiChartFilter])] {
        var order: [String] = []
        var buckets: [String: [BangumiChartFilter]] = [:]
        for filter in availableFilters {
            if buckets[filter.group] == nil { order.append(filter.group) }
            buckets[filter.group, default: []].append(filter)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// Library anime keyed by their matched Bangumi subject id, so chart rows
    /// can link straight into the local collection.
    private var libraryBySubjectID: [String: LibraryAnime] {
        var matched: [String: LibraryAnime] = [:]
        for anime in model.library {
            for source in model.metadataSourcesByAnimeID[anime.id] ?? [] where source.provider == .bangumi {
                if matched[source.externalID] == nil { matched[source.externalID] = anime }
            }
        }
        return matched
    }

    // MARK: - Loading

    private func loadFirstPage(force: Bool = false) async {
        if !force, cache[key] != nil { return }
        isLoadingFirstPage = true
        defer { isLoadingFirstPage = false }
        do {
            let page = try await provider.chart(channel: channel, filter: filter, page: 1)
            // Filter discovery is best-effort and independent of the chart:
            // never cache a failed lookup, so the next visit retries it.
            if filtersByChannel[channel] == nil,
               let discovered = try? await provider.filters(channel: channel) {
                filtersByChannel[channel] = discovered
            }
            cache[key] = ChartState(
                entries: page.entries,
                loadedPages: 1,
                totalPages: max(page.totalPages, 1)
            )
            loadError = nil
        } catch {
            if cache[key] == nil { loadError = error.localizedDescription }
            else { model.errorMessage = "Could not load Bangumi charts: \(error.localizedDescription)" }
        }
    }

    private func loadNextPage() async {
        guard let current = cache[key], !isLoadingMore, current.loadedPages < current.totalPages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = current.loadedPages + 1
            let page = try await provider.chart(channel: channel, filter: filter, page: next)
            var state = cache[key] ?? ChartState()
            var seen = Set(state.entries.map(\.subjectID))
            for entry in page.entries where seen.insert(entry.subjectID).inserted {
                state.entries.append(entry)
            }
            state.loadedPages = next
            state.totalPages = max(page.totalPages, 1)
            cache[key] = state
        } catch {
            model.errorMessage = "Could not load more chart entries: \(error.localizedDescription)"
        }
    }

    private struct ChartKey: Hashable {
        let channel: BangumiChartChannel
        let filter: BangumiChartFilter?
    }

    private struct ChartState {
        var entries: [BangumiChartEntry] = []
        var loadedPages = 0
        var totalPages = 1
    }
}

private struct ChartRow: View {
    let entry: BangumiChartEntry
    let libraryAnime: LibraryAnime?

    var body: some View {
        Group {
            if let libraryAnime {
                NavigationLink(value: libraryAnime.anime) { label }
            } else {
                Button {
                    NSWorkspace.shared.open(entry.sourceURL)
                } label: {
                    label
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            Button("Open on Bangumi") { NSWorkspace.shared.open(entry.sourceURL) }
            Button("Copy Subject Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.sourceURL.absoluteString, forType: .string)
            }
        }
        .padding(.vertical, 4)
    }

    private var label: some View {
        HStack(spacing: 14) {
            Text(verbatim: "\(entry.rank)")
                .font(.title2.bold().monospacedDigit())
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(rankColor)
            PosterView(url: entry.coverURL)
                .frame(width: 44, height: 66)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: entry.title).font(.headline)
                if let originalTitle = entry.originalTitle {
                    Text(verbatim: originalTitle).font(.caption).foregroundStyle(.secondary)
                }
                if let info = entry.info {
                    Text(verbatim: info).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let score = entry.score {
                        Label(String(format: "%.1f", score), systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                    if let ratingCount = entry.ratingCount {
                        Text("\(ratingCount) ratings")
                    }
                    if libraryAnime != nil {
                        Label("In Library", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if libraryAnime == nil {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Gold / silver / bronze for the podium, secondary for the rest.
    private var rankColor: Color {
        switch entry.rank {
        case 1: .yellow
        case 2: .gray
        case 3: .orange.opacity(0.8)
        default: Color.secondary
        }
    }
}
