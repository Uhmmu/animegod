import AnimeGodCore
import SwiftUI

private enum SidebarItem: Hashable {
    case library
    case continueWatching
    case bangumiCharts
    case releases
    case rankings
    case diary
    case statistics
    case folders
    case episodeCache
    case downloads
    case settings
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SidebarItem? = .library
    @State private var showingMatchReview = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label("All Anime", systemImage: "square.grid.2x2").tag(SidebarItem.library)
                    Label("Continue Watching", systemImage: "play.circle").tag(SidebarItem.continueWatching)
                }
                Section("Discover") {
                    Label("Bangumi Charts", systemImage: "chart.bar.doc.horizontal").tag(SidebarItem.bangumiCharts)
                    Label("Find Releases", systemImage: "arrow.down.circle").tag(SidebarItem.releases)
                }
                Section("Personal") {
                    Label("My Rankings", systemImage: "list.number").tag(SidebarItem.rankings)
                    Label("Anime Diary", systemImage: "book.pages").tag(SidebarItem.diary)
                    Label("Statistics", systemImage: "chart.bar.xaxis").tag(SidebarItem.statistics)
                }
                Section("Sources") {
                    Label("Library Folders", systemImage: "externaldrive").tag(SidebarItem.folders)
                    Label("Episode Cache", systemImage: "arrow.down.circle.dotted").tag(SidebarItem.episodeCache)
                    Label("Downloads", systemImage: "arrow.down.to.line").tag(SidebarItem.downloads)
                        .badge(model.downloads.activeCount)
                }
                Section("App") {
                    Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            // NavigationLink(value:) inside the detail views needs a stack to
            // push onto; without this wrapper, library cards do nothing.
            NavigationStack {
                switch selection {
                case .library: LibraryView()
                case .continueWatching: ContinueWatchingView()
                case .bangumiCharts: BangumiChartsView()
                case .releases: ReleaseSearchView(search: model.releaseSearch, downloads: model.downloads)
                        .navigationTitle("Find Releases")
                case .rankings: RankingsView()
                case .diary: DiaryView()
                case .statistics: StatisticsView()
                case .folders: LibraryRootsView()
                case .episodeCache: EpisodeCacheView(cache: model.episodeCache)
                case .downloads: DownloadsView(downloads: model.downloads)
                case .settings: SettingsView(translation: model.translation, danmaku: model.danmakuPreferences, torrentSources: model.torrentSources)
                case nil: ContentUnavailableView("Choose a section", systemImage: "sidebar.left")
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isScanning || model.isEnrichingMetadata {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        if let progress = model.metadataProgress { Text(progress).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Button { model.chooseLibraryRoot() } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                Button { Task { await model.scanAll() } } label: { Label("Scan", systemImage: "arrow.clockwise") }
                    .disabled(model.isScanning || model.roots.isEmpty)
                Button { Task { await model.enrichLibraryMetadata() } } label: {
                    Label("Find Metadata", systemImage: "sparkle.magnifyingglass")
                }
                .disabled(model.isEnrichingMetadata || model.library.isEmpty)
                .help("Link every title with its most likely Bangumi / AniList entry; dubious ones wait in Review Matches")
                if !model.pendingMatches.isEmpty {
                    Button { showingMatchReview = true } label: {
                        Label("Review Matches (\(model.pendingMatches.count))", systemImage: "questionmark.circle")
                    }
                    .help("Decide ambiguous metadata matches")
                }
            }
        }
        .sheet(isPresented: $showingMatchReview) {
            MatchReviewView()
                .environmentObject(model)
        }
        .onChange(of: model.playerRequest?.id) { _, _ in
            guard model.playerRequest != nil else { return }
            openWindow(id: "player")
        }
        .task {
            // The library window owns openWindow, so smoke mode must initiate
            // playback here before the standalone player window can exist.
            guard ProcessInfo.processInfo.arguments.contains("-smokePlayerTest"),
                  model.playerRequest == nil else { return }
            var waited = 0
            while model.library.isEmpty && waited < 20 {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
            let arguments = ProcessInfo.processInfo.arguments
            if let flag = arguments.firstIndex(of: "-smokeMatch"), flag + 1 < arguments.count {
                let needle = arguments[flag + 1]
                FileHandle.standardError.write(Data("SMOKE match needle=\(needle) library=\(model.library.count)\n".utf8))
                for item in model.library {
                    let episodes = await model.episodes(for: item.anime)
                    if let hit = episodes.first(where: { $0.versions.contains { $0.relativePath.contains(needle) } }) {
                        FileHandle.standardError.write(Data("SMOKE match hit anime=\(item.anime.title) primary=\(hit.mediaFile.relativePath)\n".utf8))
                    }
                    if let episode = episodes.first(where: { episode in
                        episode.mediaFile.relativePath.contains(needle)
                            || episode.versions.contains { $0.relativePath.contains(needle) }
                    }) {
                        await model.play(episode)
                        return
                    }
                }
            }
            guard let anime = model.library.first?.anime else { return }
            let episodes = await model.episodes(for: anime)
            if let episode = episodes.first { await model.play(episode) }
        }
        .alert("AnimeGod", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
