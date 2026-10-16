import AnimeGodCore
import SwiftUI

/// Watching from a site rather than from the library.
///
/// Its own section, not a filter on the grid and not a tab on an anime
/// page: nothing here is scanned, matched or stored, a work found this way
/// is a page on somebody's site, and the grid answers "what am I watching"
/// about files this Mac has. Searching every installed source at once is
/// the point — the sources carry different shows, and which one has this
/// week's episode is not knowable in advance.
struct OnlineView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var online: OnlineCoordinator

    var body: some View {
        Group {
            if online.rules.isEmpty {
                noSources
            } else if let work = online.openWork {
                episodes(of: work)
            } else {
                searching
            }
        }
        .navigationTitle(online.openWork?.name ?? String(localized: "Online"))
        .toolbar {
            if online.openWork != nil {
                ToolbarItem(placement: .navigation) {
                    Button { online.closeWork() } label: {
                        Label("Back to Results", systemImage: "chevron.left")
                    }
                }
            }
        }
        .alert(
            "Online sources",
            isPresented: Binding(
                get: { online.errorMessage != nil },
                set: { if !$0 { online.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { online.errorMessage = nil }
        } message: {
            Text(online.errorMessage ?? "")
        }
        .task { await online.load() }
    }

    // MARK: - No sources yet

    private var noSources: some View {
        ContentUnavailableView {
            Label("No sources installed", systemImage: "globe")
        } description: {
            Text("A source is a short rule describing how one site lists its shows. Install a few in Settings → Online Sources.")
        } actions: {
            if online.unreadableRules > 0 {
                Text("^[\(online.unreadableRules) rule](inflect: true) in the file could not be read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Searching

    private var searching: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search every source", text: $online.keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { online.search() }
                if online.isSearching {
                    Button("Stop") { online.cancelSearch() }
                } else {
                    Button("Search") { online.search() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(online.keyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)

            if !online.statuses.isEmpty {
                sourceStatusBar
            }

            if online.results.isEmpty {
                Spacer()
                if online.isSearching {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "Nothing yet", systemImage: "magnifyingglass",
                        description: Text("Search ^[\(online.rules.count) installed source](inflect: true).")
                    )
                }
                Spacer()
            } else {
                List {
                    // Grouped by source, because the same show from two
                    // sites is two different episode lists and two different
                    // streams — not a duplicate to be merged away.
                    ForEach(groupedResults, id: \.source) { group in
                        Section(group.source) {
                            ForEach(group.items) { item in
                                Button { online.open(item) } label: {
                                    HStack {
                                        Text(item.name)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var groupedResults: [(source: String, items: [OnlineSearchItem])] {
        var order: [String] = []
        var grouped: [String: [OnlineSearchItem]] = [:]
        for item in online.results {
            if grouped[item.ruleName] == nil { order.append(item.ruleName) }
            grouped[item.ruleName, default: []].append(item)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    /// One line per source, saying what it did.
    ///
    /// A source that has never carried this show and a source whose rule has
    /// gone stale look identical in a list that shows only results, and they
    /// need different things done about them — so each says which it is.
    private var sourceStatusBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(online.rules) { rule in
                    if let status = online.statuses[rule.name] {
                        HStack(spacing: 4) {
                            statusIcon(status)
                            Text(rule.name).font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                        .help(statusDescription(status))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: OnlineSourceStatus) -> some View {
        switch status {
        case .searching:
            ProgressView().controlSize(.mini)
        case let .found(count):
            Text("\(count)").font(.caption.bold()).foregroundStyle(.green)
        case .noResults:
            Image(systemName: "minus").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        case .needsNewerClient:
            Image(systemName: "arrow.up.circle").font(.caption).foregroundStyle(.blue)
        }
    }

    private func statusDescription(_ status: OnlineSourceStatus) -> String {
        switch status {
        case .searching: String(localized: "Searching…")
        case let .found(count): String(localized: "\(count) result(s)")
        case .noResults: String(localized: "This source has nothing for that search.")
        case let .failed(message): message
        case .needsNewerClient: String(localized: "This rule needs a newer version of AnimeGod.")
        }
    }

    // MARK: - Episodes

    @ViewBuilder
    private func episodes(of work: OnlineSearchItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if online.isLoadingEpisodes {
                Spacer()
                HStack { Spacer(); ProgressView(); Spacer() }
                Spacer()
            } else if online.roads.isEmpty {
                ContentUnavailableView(
                    "No episodes found", systemImage: "list.bullet.rectangle",
                    description: Text("\(work.ruleName) lists this work but no playable episodes. Its rule may be out of date.")
                )
            } else {
                if online.roads.count > 1 {
                    // A site offers several lines because any one of them can
                    // be down, re-encoded or short the newest episode, and
                    // choosing between them is the viewer's.
                    Picker("Line", selection: $online.selectedRoad) {
                        ForEach(Array(online.roads.enumerated()), id: \.offset) { index, road in
                            Text("\(road.name) · \(road.episodes.count)").tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(12)
                }
                episodeGrid
            }
        }
    }

    private var episodeGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                ForEach(currentRoad?.episodes ?? []) { episode in
                    Button { online.play(episode, in: model) } label: {
                        HStack(spacing: 4) {
                            if online.resolvingEpisode == episode.id {
                                ProgressView().controlSize(.mini)
                            }
                            Text(episode.label)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    // One resolution at a time: there is one browser, and
                    // loading a second page cancels the first.
                    .disabled(online.resolvingEpisode != nil)
                }
            }
            .padding(12)

            if online.resolvingEpisode != nil {
                HStack(spacing: 8) {
                    Text("Finding the video — the site's own player has to run first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { online.cancelResolution() }
                        .controlSize(.small)
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var currentRoad: OnlineRoad? {
        online.roads.indices.contains(online.selectedRoad)
            ? online.roads[online.selectedRoad]
            : online.roads.first
    }
}
