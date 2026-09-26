import AnimeGodCore
import SwiftUI

/// Searches the anime torrent indexes and presents merged releases with
/// anime-aware filters. Used from the sidebar and, pre-filled with a title's
/// aliases, from an anime's detail page.
struct ReleaseSearchView: View {
    @ObservedObject var search: TorrentSearchModel
    @ObservedObject private var preferences: TorrentSourcePreferences
    /// The embedded engine. Absent only in previews, where downloading is
    /// simply unavailable.
    @ObservedObject var downloads: TorrentDownloadManager
    /// Set when the search was opened from an anime, so downloads are bound
    /// to that title.
    let anime: Anime?
    @ObservedObject var subscriptions: TorrentSubscriptionManager
    @State private var selection: Set<TorrentInfoHash> = []
    @State private var showingSourceDetails = false
    @State private var newSubscription: TorrentSubscription?

    init(
        search: TorrentSearchModel,
        downloads: TorrentDownloadManager,
        subscriptions: TorrentSubscriptionManager,
        anime: Anime? = nil
    ) {
        self.search = search
        self.downloads = downloads
        self.subscriptions = subscriptions
        self.anime = anime
        preferences = search.preferences
    }

    var body: some View {
        let results = search.displayedResults
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            if search.snapshot != nil {
                progressBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                filterBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            content(results)
            if let message = search.statusMessage {
                Divider()
                HStack {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { search.statusMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .sheet(item: $newSubscription) { draft in
            SubscriptionEditor(subscription: draft) { saved in
                Task { await subscriptions.save(saved) }
            }
        }
        .sheet(isPresented: $showingSourceDetails) {
            if let snapshot = search.snapshot {
                SourceDetailsView(snapshot: snapshot, canRetry: snapshot.canRetry && !search.isSearching) {
                    search.retryFailed()
                }
                .frame(minWidth: 520, minHeight: 420)
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Anime title — separate aliases with commas", text: $search.queryText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { search.search() }
            Menu {
                if preferences.history.isEmpty {
                    Text("No Recent Searches")
                } else {
                    ForEach(preferences.history.prefix(20), id: \.self) { entry in
                        Button(entry) {
                            search.queryText = entry
                            search.search()
                        }
                    }
                    Divider()
                    Button("Clear Recent Searches") { preferences.clearHistory() }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Recent searches")

            Menu {
                ForEach(TorrentSourceID.allCases) { source in
                    Toggle(source.displayName, isOn: Binding(
                        get: { preferences.enabledSources.contains(source) },
                        set: { preferences.set(source, enabled: $0) }
                    ))
                }
            } label: {
                Text("Sources \(preferences.enabledSources.count)/\(TorrentSourceID.allCases.count)")
            }
            .fixedSize()
            .help("Which anime indexes to search")

            if search.snapshot != nil {
                Button {
                    newSubscription = TorrentSubscriptionManager.subscription(
                        from: search,
                        anime: anime,
                        title: anime?.title ?? TorrentSearchCoordinator.splitQueries(search.queryText).first ?? ""
                    )
                } label: {
                    Image(systemName: "bell.badge")
                }
                .help("Follow this search: download new episodes matching the current filters automatically")
            }
            if search.isSearching {
                Button("Stop") { search.cancel() }
            } else {
                Button("Search") { search.search() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(TorrentSearchCoordinator.splitQueries(search.queryText).isEmpty)
            }
        }
    }

    // MARK: - Progress

    private var progressBar: some View {
        let snapshot = search.snapshot!
        let failed = snapshot.pairs.filter { $0.status.isRetryable && !$0.status.isActive }.count
        return HStack(spacing: 10) {
            if search.isSearching {
                ProgressView(value: Double(snapshot.completedPairs), total: Double(max(snapshot.pairs.count, 1)))
                    .frame(width: 140)
            }
            Text(progressText(snapshot))
                .font(.caption)
                .foregroundStyle(.secondary)
            if failed > 0 {
                Label("\(failed) failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if snapshot.canRetry, !search.isSearching {
                Button("Retry Failed") { search.retryFailed() }
                    .controlSize(.small)
            }
            Button("Source Details") { showingSourceDetails = true }
                .controlSize(.small)
        }
    }

    private func progressText(_ snapshot: TorrentSearchSnapshot) -> String {
        let releases = String(localized: "\(snapshot.results.count) releases")
        if search.isSearching {
            return String(localized: "Searched \(snapshot.completedPairs) of \(snapshot.pairs.count) · \(releases)")
        }
        if snapshot.hitDeadline { return String(localized: "Stopped at the time limit · \(releases)") }
        return String(localized: "Searched \(Set(snapshot.pairs.map(\.source)).count) sources · \(releases)")
    }

    // MARK: - Filters

    private var filterBar: some View {
        let facets = search.facets
        return HStack(spacing: 8) {
            Picker("Layout", selection: $search.layout) {
                ForEach(TorrentSearchModel.Layout.allCases) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Episode Sets collects each fansub's episodes into one season you can start in a single click")

            if search.layout == .releases {
                Picker("Sort", selection: $search.sortOrder) {
                    ForEach(TorrentResultMerger.SortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            Menu(menuTitle("Type", count: search.filter.categories == TorrentCategory.defaultVisible ? 0 : search.filter.categories.count)) {
                ForEach(TorrentCategory.allCases) { category in
                    Toggle(category.displayName, isOn: setBinding(\.categories, category))
                }
                if search.layout == .releases {
                    Divider()
                    Picker("Episodes", selection: $search.filter.batchMode) {
                        ForEach(TorrentResultFilter.BatchMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .fixedSize()

            Menu(menuTitle("Resolution", count: search.filter.resolutions.count)) {
                ForEach(facets.resolutions, id: \.self) { resolution in
                    Toggle(resolution, isOn: setBinding(\.resolutions, resolution))
                }
            }
            .fixedSize()
            .disabled(facets.resolutions.isEmpty)

            Menu(menuTitle("Subtitles", count: search.filter.subtitleLanguages.count)) {
                ForEach(TorrentSubtitleLanguage.allCases) { language in
                    Toggle(language.menuName, isOn: setBinding(\.subtitleLanguages, language))
                }
            }
            .fixedSize()

            Menu(menuTitle("Group", count: search.filter.groups.count)) {
                if !search.filter.groups.isEmpty {
                    Button("Any Group") { search.filter.groups = [] }
                    Divider()
                }
                ForEach(facets.groups.prefix(40), id: \.name) { group in
                    Toggle("\(group.name) (\(group.count))", isOn: setBinding(\.groups, group.name))
                }
            }
            .fixedSize()
            .disabled(facets.groups.isEmpty)

            Toggle("Hide Unrelated", isOn: $search.filter.hidesUnrelated)
                .toggleStyle(.checkbox)
                .help("Hide listings whose titles share less than half of the searched words")
            if search.layout == .episodeSets {
                Toggle("Fill Gaps", isOn: $search.fillsGapsFromOtherGroups)
                    .toggleStyle(.checkbox)
                    .help("Take an episode a fansub never published from the closest other team, instead of leaving a hole in the season")
            }
            if search.hasOwnedEpisodes, search.layout == .releases {
                Toggle("Missing Episodes", isOn: $search.filter.missingEpisodesOnly)
                    .toggleStyle(.checkbox)
                    .help("Only releases that bring an episode your library doesn't have")
            }

            Spacer(minLength: 8)
            TextField("Refine", text: $search.filter.text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
        }
        .controlSize(.small)
    }

    private func menuTitle(_ title: LocalizedStringResource, count: Int) -> String {
        let title = String(localized: title)
        return count == 0 ? title : "\(title) (\(count))"
    }

    private func setBinding<Element: Hashable>(_ keyPath: WritableKeyPath<TorrentResultFilter, Set<Element>>, _ element: Element) -> Binding<Bool> {
        Binding(
            get: { search.filter[keyPath: keyPath].contains(element) },
            set: { isOn in
                if isOn { search.filter[keyPath: keyPath].insert(element) } else { search.filter[keyPath: keyPath].remove(element) }
            }
        )
    }

    // MARK: - Results

    @ViewBuilder
    private func content(_ results: [TorrentSearchResult]) -> some View {
        if search.snapshot == nil {
            ContentUnavailableView {
                Label("Find Anime Releases", systemImage: "magnifyingglass")
            } description: {
                Text("Search 动漫花园, 蜜柑计划, Nyaa and other anime indexes at once. Separate a title's aliases with commas to search them together.")
            }
            .frame(maxHeight: .infinity)
        } else if search.layout == .episodeSets {
            ReleaseEpisodeSetsView(search: search, downloads: downloads, anime: anime)
        } else if results.isEmpty {
            if search.isSearching {
                ProgressView("Searching…").frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Releases", systemImage: "tray")
                } description: {
                    Text(search.hiddenCount > 0
                         ? "\(search.hiddenCount) releases are hidden by the current filters."
                         : "None of the sources had a match. Try another alias or check Source Details.")
                } actions: {
                    if search.hiddenCount > 0 {
                        Button("Show All") {
                            search.filter = TorrentResultFilter(
                                categories: Set(TorrentCategory.allCases),
                                hidesUnrelated: false,
                                ownedEpisodes: search.filter.ownedEpisodes
                            )
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        } else {
            resultsTable(results)
        }
    }

    private func resultsTable(_ results: [TorrentSearchResult]) -> some View {
        Table(results, selection: $selection) {
            TableColumn("Release") { result in
                ReleaseTitleCell(result: result, ownedEpisodes: search.filter.ownedEpisodes)
            }
            .width(min: 320, ideal: 560)
            TableColumn("Size") { result in
                Text(result.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(result.size == nil ? .tertiary : .primary)
            }
            .width(min: 64, ideal: 80)
            TableColumn("Peers") { result in
                if let seeders = result.seeders {
                    Text("\(seeders) ↑  \(result.leechers ?? 0) ↓")
                        .monospacedDigit()
                        .foregroundStyle(seeders == 0 ? .secondary : .primary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 60, ideal: 80)
            TableColumn("Published") { result in
                if let date = result.publishedAt {
                    Text(date, format: .dateTime.year().month().day())
                        .monospacedDigit()
                        .help(date.formatted(date: .complete, time: .shortened))
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 80, ideal: 96)
            TableColumn("Sources") { result in
                Text(result.sources.map(\.displayName).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .width(min: 90, ideal: 150)
        }
        .contextMenu(forSelectionType: TorrentInfoHash.self) { hashes in
            contextMenu(for: results.filter { hashes.contains($0.infoHash) })
        } primaryAction: { hashes in
            if let result = results.first(where: { hashes.contains($0.infoHash) }) {
                downloads.download(result, anime: anime)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for selected: [TorrentSearchResult]) -> some View {
        if selected.count == 1, let result = selected.first {
            Button("Download") { downloads.download(result, anime: anime) }
            Button("Download and Play While Downloading") {
                downloads.download(result, anime: anime, sequential: true)
            }
            .help("Downloads the pieces in order so the episode can be played before it finishes")
            Divider()
            Button("Open in Another Torrent App") { search.openMagnet(result) }
            Button("Copy Magnet Link") { search.copyMagnet(result) }
            Button("Save Torrent File…") { search.saveTorrent(result) }
            Divider()
            if !result.pageURLs.isEmpty {
                Menu("Open Listing Page") {
                    ForEach(result.sources.filter { result.pageURLs[$0] != nil }) { source in
                        Button(source.displayName) { search.openPage(result.pageURLs[source]!) }
                    }
                }
            }
            Button("Copy Title") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.title, forType: .string)
            }
            if let group = result.group {
                Button("Only Show \(group)") { search.filter.groups = [group] }
            }
        } else if selected.count > 1 {
            Button("Download \(selected.count) Releases") {
                downloads.download(selected, anime: anime)
            }
            Button("Copy \(selected.count) Magnet Links") { search.copyMagnets(selected) }
        }
    }
}

private extension TorrentSubtitleLanguage {
    var menuName: String {
        switch self {
        case .simplifiedChinese: String(localized: "Simplified Chinese (简)")
        case .traditionalChinese: String(localized: "Traditional Chinese (繁)")
        case .japanese: String(localized: "Japanese (日)")
        case .english: String(localized: "English")
        }
    }
}

/// Title plus the tags a viewer picks a release by.
private struct ReleaseTitleCell: View {
    let result: TorrentSearchResult
    let ownedEpisodes: Set<Double>

    private var bringsMissingEpisode: Bool {
        !ownedEpisodes.isEmpty && result.release.firstEpisode != nil
            && TorrentResultFilter.hasMissingEpisode(result.release, owned: ownedEpisodes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result.title)
                .lineLimit(2)
                .help(result.title)
            HStack(spacing: 4) {
                if bringsMissingEpisode { Tag(text: String(localized: "New"), tint: .green) }
                if let group = result.group { Tag(text: group, tint: .accentColor) }
                if let episodes = result.release.episodeLabel {
                    Tag(text: "EP \(episodes)", tint: .purple)
                }
                if result.release.isBatch { Tag(text: String(localized: "Batch"), tint: .purple) }
                if result.category == .raw { Tag(text: String(localized: "Raw"), tint: .gray) }
                if result.category == .music { Tag(text: String(localized: "Music"), tint: .gray) }
                if let resolution = result.release.resolution { Tag(text: resolution, tint: .blue) }
                if !result.release.subtitleLanguages.isEmpty {
                    let languages = TorrentSubtitleLanguage.allCases
                        .filter(result.release.subtitleLanguages.contains)
                        .map(\.displayName)
                        .joined()
                    Tag(text: languages + (result.release.subtitleStyle.map { " \($0.displayName)" } ?? ""), tint: .orange)
                }
                if let codec = result.release.videoCodec { Tag(text: codec, tint: .gray) }
                if let source = result.release.videoSource { Tag(text: source, tint: .gray) }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct Tag: View {
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

/// Per (query × source) diagnostics, like magnet-crawler's execution details.
private struct SourceDetailsView: View {
    let snapshot: TorrentSearchSnapshot
    let canRetry: Bool
    let retry: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(snapshot.queries, id: \.self) { query in
                    Section(snapshot.queries.count > 1 ? query : String(localized: "Sources")) {
                        ForEach(snapshot.pairs.filter { $0.query == query }) { pair in
                            HStack {
                                Image(systemName: icon(pair.status)).foregroundStyle(tint(pair.status))
                                Text(pair.source.displayName)
                                Spacer()
                                Text(describe(pair.status)).foregroundStyle(.secondary)
                                if pair.elapsed > 0 {
                                    Text(String(format: "%.1fs", pair.elapsed))
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 48, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Source Details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Retry Failed") {
                        retry()
                        dismiss()
                    }
                    .disabled(!canRetry)
                }
            }
        }
    }

    private func icon(_ status: TorrentSearchPair.Status) -> String {
        switch status {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .empty: "circle"
        case .timedOut, .skipped: "hourglass"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ status: TorrentSearchPair.Status) -> Color {
        switch status {
        case .succeeded: .green
        case .failed, .timedOut: .orange
        default: .secondary
        }
    }

    private func describe(_ status: TorrentSearchPair.Status) -> String {
        switch status {
        case .queued: String(localized: "Waiting")
        case .running: String(localized: "Searching…")
        case .succeeded(let count): String(localized: "\(count) found")
        case .empty: String(localized: "No results")
        case .timedOut: String(localized: "Timed out")
        case .skipped: String(localized: "Not started (time limit)")
        case .cancelled: String(localized: "Cancelled")
        case .failed(.blocked): String(localized: "Blocked by an anti-bot check")
        case .failed(.http(let code)): String(localized: "HTTP \(code)")
        case .failed(.network(let message)): String(localized: "Network error: \(message)")
        case .failed(.parse): String(localized: "Unexpected response")
        }
    }
}

/// The sheet opened from an anime's detail page.
struct AnimeReleaseSearchSheet: View {
    @StateObject private var search: TorrentSearchModel
    @Environment(\.dismiss) private var dismiss
    let title: String
    let anime: Anime
    @ObservedObject var downloads: TorrentDownloadManager
    @ObservedObject var subscriptions: TorrentSubscriptionManager

    init(
        anime: Anime,
        title: String,
        queries: [String],
        ownedEpisodes: Set<Double>,
        preferences: TorrentSourcePreferences,
        downloads: TorrentDownloadManager,
        subscriptions: TorrentSubscriptionManager
    ) {
        self.anime = anime
        self.title = title
        self.downloads = downloads
        self.subscriptions = subscriptions
        _search = StateObject(wrappedValue: TorrentSearchModel(
            preferences: preferences,
            queries: queries,
            ownedEpisodes: ownedEpisodes
        ))
    }

    var body: some View {
        NavigationStack {
            ReleaseSearchView(search: search, downloads: downloads, subscriptions: subscriptions, anime: anime)
                .navigationTitle("Releases for \(title)")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task {
            if search.snapshot == nil { search.search() }
        }
        .onDisappear { search.cancel() }
    }
}
