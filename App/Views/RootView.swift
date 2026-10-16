import AnimeGodCore
import SwiftUI

private enum SidebarItem: String, Hashable, CaseIterable {
    case library
    case continueWatching
    case concerts
    case songs
    case bangumiCharts
    case releases
    case online
    case rankings
    case diary
    case statistics
    case folders
    case episodeCache
    case downloads
    case seeding
    case subscriptions
    case settings
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SidebarItem? = .library
    @State private var showingMatchReview = false
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label("All Anime", systemImage: "square.grid.2x2").tag(SidebarItem.library)
                    Label("Continue Watching", systemImage: "play.circle").tag(SidebarItem.continueWatching)
                    // Its own row rather than a filter on the grid: a concert is
                    // not something anyone is partway through a season of, and
                    // the viewer asked for it off the home screen.
                    Label("Concerts", systemImage: "music.mic").tag(SidebarItem.concerts)
                    Label("Songs", systemImage: "music.note.list").tag(SidebarItem.songs)
                }
                Section("Discover") {
                    Label("Bangumi Charts", systemImage: "chart.bar.doc.horizontal").tag(SidebarItem.bangumiCharts)
                    Label("Find Releases", systemImage: "arrow.down.circle").tag(SidebarItem.releases)
                    // Watching from a site rather than from this Mac. Under
                    // Discover rather than Sources, because a source here is
                    // somebody's website and nothing it plays is kept.
                    Label("Online", systemImage: "globe").tag(SidebarItem.online)
                }
                Section("Personal") {
                    Label("My Rankings", systemImage: "list.number").tag(SidebarItem.rankings)
                    Label("Anime Diary", systemImage: "book.pages").tag(SidebarItem.diary)
                    Label("Statistics", systemImage: "chart.bar.xaxis").tag(SidebarItem.statistics)
                }
                Section("Sources") {
                    Label("Library Folders", systemImage: "externaldrive").tag(SidebarItem.folders)
                    Label("Episode Cache", systemImage: "arrow.down.circle.dotted").tag(SidebarItem.episodeCache)
                    // `.tag` has to be the outermost modifier: a `.badge`
                    // applied after it wraps the row and the list stops
                    // matching the selection, so the section does nothing.
                    DownloadsSidebarLabel(downloads: model.downloads)
                        .tag(SidebarItem.downloads)
                    SeedingSidebarLabel(downloads: model.downloads)
                        .tag(SidebarItem.seeding)
                    SubscriptionsSidebarLabel(subscriptions: model.subscriptions)
                        .tag(SidebarItem.subscriptions)
                }
                Section("App") {
                    Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            // NavigationLink(value:) inside the detail views needs a stack to
            // push onto; without this wrapper, library cards do nothing.
            NavigationStack(path: $navigationPath) {
                Group {
                    switch selection {
                    case .library: LibraryView(downloads: model.downloads, subscriptions: model.subscriptions)
                    case .continueWatching: ContinueWatchingView()
                    case .concerts:
                        ConcertsView(section: model.concertSection, downloads: model.downloads, navigationPath: $navigationPath)
                    case .songs:
                        SongsView(section: model.concertSection, navigationPath: $navigationPath)
                    case .bangumiCharts: BangumiChartsView()
                    case .releases: ReleaseSearchView(search: model.releaseSearch, downloads: model.downloads, subscriptions: model.subscriptions)
                            .navigationTitle("Find Releases")
                    case .online:
                        if let online = model.online {
                            OnlineView(online: online)
                        } else {
                            ProgressView()
                        }
                    case .rankings: RankingsView()
                    case .diary: DiaryView()
                    case .statistics: StatisticsView()
                    case .folders: LibraryRootsView()
                    case .episodeCache: EpisodeCacheView(cache: model.episodeCache)
                    case .downloads: DownloadsView(downloads: model.downloads)
                    case .seeding: SeedingView(downloads: model.downloads)
                    case .subscriptions: SubscriptionsView(subscriptions: model.subscriptions, downloads: model.downloads)
                    case .settings: SettingsView(translation: model.translation, danmaku: model.danmakuPreferences, torrentSources: model.torrentSources, subtitles: model.subtitlePreferences, downloads: model.downloads, subscriptions: model.subscriptions, link: model.link, online: model.online, database: model.libraryDatabase)
                    case nil: ContentUnavailableView("Choose a section", systemImage: "sidebar.left")
                    }
                }
                // Both sections can reach a BD; register on the stack content
                // so the song -> BD path retains its back navigation.
                .navigationDestination(for: ConcertRoute.self) { route in
                    ConcertDetailView(
                        section: model.concertSection, animeID: route.animeID,
                        initialDiscNumber: route.discNumber
                    )
                }
                .navigationDestination(for: SongRoute.self) { route in
                    SongDetailView(section: model.concertSection, songID: route.songID)
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
        // The automatic pass asks for the sheet itself when it ends with
        // questions: metadata that fills in on its own is the whole point, and
        // a badge in the toolbar is not something anyone looks at.
        .onChange(of: model.wantsMatchReview) { _, wants in
            guard wants else { return }
            model.wantsMatchReview = false
            showingMatchReview = true
        }
        .sheet(item: $model.incomingMatchPrompt) { _ in
            IncomingMatchSheet()
                .environmentObject(model)
        }
        .onChange(of: model.playerRequest?.id) { _, _ in
            guard model.playerRequest != nil else { return }
            openWindow(id: "player")
        }
        .task {
            guard AppearanceSnapshotSmokeTest.isRequested else { return }
            // A concert's page shares nothing with an anime's, so it has to be
            // walked too or the one screen built from scratch is the one screen
            // never drawn.
            let sections = AppearanceSnapshotSmokeTest.songsOnly
                ? ["songs", "songDetail", "songBD"]
                : SidebarItem.allCases.map(\.rawValue) + ["detail", "concertDetail", "songDetail"]
            await AppearanceSnapshotSmokeTest.run(model: model, sections: sections, openPlayer: { openWindow(id: "player") }) { name in
                switch name {
                case "songDetail", "songBD":
                    selection = .songs
                    navigationPath = NavigationPath()
                    if let song = model.concertSection.songs.max(by: { $0.discCount < $1.discCount }) {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            navigationPath.append(SongRoute(songID: song.id))
                            if name == "songBD", let appearance = song.appearances.first {
                                try? await Task.sleep(for: .milliseconds(300))
                                navigationPath.append(ConcertRoute(
                                    animeID: appearance.concert.id, discNumber: appearance.discNumber
                                ))
                            }
                            print("SMOKE songs route=\(name) song=\(song.title) BDs=\(song.discCount)")
                        }
                    }
                case "detail":
                    selection = .library
                    let item = model.library.first { model.metadataByAnimeID[$0.id] != nil } ?? model.library.first
                    if let anime = item?.anime { navigationPath.append(anime) }
                case "concertDetail":
                    selection = .concerts
                    navigationPath = NavigationPath()
                    // Let the sidebar selection settle before pushing, so its
                    // path reset does not discard the smoke test's route.
                    if let concert = model.concertSection.concerts.first {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            navigationPath.append(ConcertRoute(animeID: concert.id))
                        }
                    }
                default:
                    navigationPath = NavigationPath()
                    selection = SidebarItem(rawValue: name)
                }
            }
        }
        .task {
            // Exercises the phone link end to end, headless:
            //
            //     AnimeGod -smokeLink
            //
            // Waits for the library because the interesting checks stream a
            // real episode off a real library root.
            if LinkSmokeTest.servesOnly {
                var waited = 0
                while model.library.isEmpty && waited < 40 {
                    try? await Task.sleep(for: .milliseconds(500))
                    waited += 1
                }
                await LinkSmokeTest.serve(model: model)
                // Reports where the player is every few seconds, so a handoff
                // can be checked against what was actually on screen.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    LinkSmokeTest.reportPlayer(model: model)
                }
                return
            }
            guard LinkSmokeTest.isRequested else { return }
            var waited = 0
            while model.library.isEmpty && waited < 40 {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
            await LinkSmokeTest.run(model: model)
        }
        .task {
            // Exercises the rule-based online sources end to end, headless:
            //
            //     AnimeGod -smokeOnlineSource "药师少女"
            //
            // Needs no library, so it does not wait for one: every step is
            // against a live site, which is the half the core's own tests
            // over captured pages cannot reach.
            guard OnlineSourceSmokeTest.isRequested else { return }
            await OnlineSourceSmokeTest.run()
        }
        .task {
            // Fills in every metadata source the library is missing, headless:
            //
            //     AnimeGod -smokeEnrichMetadata
            //
            // The same pass the toolbar button runs. It exists because the
            // pass is slow by design — AniList allows 30 requests a minute and
            // a library needs hundreds — so watching a window for five minutes
            // is not how anyone should have to do it.
            guard ProcessInfo.processInfo.arguments.contains("-smokeEnrichMetadata") else { return }
            var waited = 0
            while model.library.isEmpty && waited < 40 {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
            // The launch pass runs on its own now; wait it out rather than
            // bouncing off its guard and reporting a run that never happened.
            while model.isEnrichingMetadata {
                try? await Task.sleep(for: .seconds(1))
            }
            let before = model.library.reduce(into: [MetadataProviderID: Int]()) { counts, item in
                for source in model.metadataSourcesByAnimeID[item.anime.id] ?? [] {
                    counts[source.provider, default: 0] += 1
                }
            }
            FileHandle.standardError.write(Data("SMOKE enrich library=\(model.library.count) before=\(before)\n".utf8))
            await model.enrichLibraryMetadata()
            let after = model.library.reduce(into: [MetadataProviderID: Int]()) { counts, item in
                for source in model.metadataSourcesByAnimeID[item.anime.id] ?? [] {
                    counts[source.provider, default: 0] += 1
                }
            }
            let unmatched = model.library.filter { item in
                (model.metadataSourcesByAnimeID[item.anime.id] ?? []).allSatisfy { $0.provider != .anilist }
            }.map(\.anime.title)
            FileHandle.standardError.write(Data("SMOKE enrich after=\(after) pending=\(model.pendingMatches.count)\n".utf8))
            for title in unmatched {
                FileHandle.standardError.write(Data("SMOKE enrich no-anilist \(title)\n".utf8))
            }
            if let message = model.errorMessage {
                FileHandle.standardError.write(Data("SMOKE enrich message: \(message)\n".utf8))
            }
            exit(0)
        }
        .task {
            // The library window owns openWindow, so smoke mode must initiate
            // playback here before the standalone player window can exist.
            guard ProcessInfo.processInfo.arguments.contains("-smokePlayerTest"),
                  model.playerRequest == nil else { return }
            // AG_SMOKE_FILE=<path> plays that file instead of the library's
            // first episode — how a disc image, or any other one-off file,
            // is checked without adding it to the library first.
            //
            // An `http(s)` value plays a stream instead, with the headers
            // `AG_SMOKE_HEADERS=Referer=https://…;Origin=…` supplies. That is
            // how a resolved online source is checked on the real player path
            // rather than with a range request: a URL that serves bytes to
            // `curl` and a URL mpv can play are not the same claim.
            if let value = ProcessInfo.processInfo.environment["AG_SMOKE_FILE"] {
                let remote = value.hasPrefix("http://") || value.hasPrefix("https://")
                guard let url = remote ? URL(string: value) : URL(fileURLWithPath: value) else { return }
                var headers: [String: String] = [:]
                for pair in (ProcessInfo.processInfo.environment["AG_SMOKE_HEADERS"] ?? "")
                    .split(separator: ";") where pair.contains("=") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    headers[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1])
                }
                FileHandle.standardError.write(
                    Data("SMOKE playing \(remote ? "stream" : "file") \(url.absoluteString) headers=\(headers.keys.sorted())\n".utf8)
                )
                model.playFile(at: url, title: url.lastPathComponent, headers: headers)
                return
            }
            var waited = 0
            while model.library.isEmpty && waited < 20 {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-smokeSong"),
               let appearance = model.concertSection.songs.flatMap(\.appearances).first(where: { $0.startTime != nil }) {
                print("SMOKE song playback title=\(appearance.track.title) BD=\(appearance.concert.displayTitle) disc=\(appearance.discNumber) start=\(appearance.startTime!)")
                await model.play(appearance.episode, startingAt: appearance.startTime)
                return
            }
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

/// The Subscriptions row counts the rules still waiting for an episode, plus
/// anything waiting to be confirmed — a number that only changes when a check
/// runs, so it observes the manager rather than the whole app.
private struct SubscriptionsSidebarLabel: View {
    @ObservedObject var subscriptions: TorrentSubscriptionManager

    var body: some View {
        Label("Subscriptions", systemImage: "bell")
            .badge(subscriptions.followingCount + subscriptions.candidates.count)
    }
}

/// The Downloads row observes the download manager itself. Its badge counts
/// running tasks and therefore changes every second; routing that through
/// AppModel would re-render the whole window at the same rate.
private struct DownloadsSidebarLabel: View {
    @ObservedObject var downloads: TorrentDownloadManager

    var body: some View {
        Label("Downloads", systemImage: "arrow.down.to.line")
            .badge(downloads.activeCount)
    }
}

/// The Seeding row counts what is actually uploading, which is zero whenever
/// sharing is switched off — so the badge is also how the sidebar says the
/// switch is off, without a second control for it.
private struct SeedingSidebarLabel: View {
    @ObservedObject var downloads: TorrentDownloadManager

    var body: some View {
        Label("Seeding", systemImage: "arrow.up.to.line")
            .badge(downloads.seedingCount)
    }
}
