import AnimeGodCore
import SwiftUI

/// Non-intrusive danmaku status shown only when danmaku needs user
/// attention; never blocks playback.
struct DanmakuStatusBadge: View {
    @ObservedObject var session: DanmakuSession
    @ObservedObject var preferences: DanmakuPreferences
    let controlsVisible: Bool
    let openMatch: () -> Void

    var body: some View {
        if preferences.enabled, session.phase.isActionable {
            VStack {
                Spacer()
                HStack {
                    content
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onTapGesture { openMatch() }
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.bottom, 96)
            }
            .opacity(controlsVisible ? 1 : 0.35)
            .allowsHitTesting(controlsVisible)
        }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .needsConfiguration:
            Label("Danmaku needs your dandanplay AppId — Settings", systemImage: "key")
        case .noMatch:
            Label("No episode matched — click to match", systemImage: "text.bubble")
        case let .failed(message):
            Label("Danmaku unavailable: \(message)", systemImage: "wifi.exclamationmark")
        default:
            EmptyView()
        }
    }
}

/// Developer danmaku diagnostics for the ⌘⇧D panel.
struct DanmakuDiagnosticsSection: View {
    @ObservedObject var session: DanmakuSession
    @ObservedObject var preferences: DanmakuPreferences

    var body: some View {
        let snapshot = session.renderer
        return VStack(alignment: .leading, spacing: 3) {
            Text("Danmaku").foregroundStyle(.secondary)
            Text("Provider: dandanplay")
            Text("Matched Anime: \(match?.anime ?? "—")")
            Text("Episode: \(match?.episode ?? "—")")
            Text("Episode ID: \(episodeIDText)")
            Text("Comments Loaded: \(snapshot.loadedCount)")
            Text("Comments Active: \(snapshot.activeCount)")
            Text("Cache: \(cacheText)")
            Text("Timing Offset: \(String(format: "%+.1fs", preferences.settings.timeOffset))")
            Text("Renderer FPS: \(snapshot.fps > 0 ? String(format: "%.0f", snapshot.fps) : "—")")
            Text("Dropped: capacity \(snapshot.droppedForCapacity) · lane \(snapshot.droppedNoLane)")
            Text("Skipped (seek): \(snapshot.skippedOnSeek)")
        }
    }

    private var match: (anime: String, episode: String)? {
        if case let .ready(anime, episode, _, _) = session.phase { return (anime, episode) }
        return nil
    }

    private var episodeIDText: String {
        if case let .ready(_, _, episodeID, _) = session.phase { return String(episodeID) }
        return "—"
    }

    private var cacheText: String {
        if case let .ready(_, _, _, cache) = session.phase {
            return cache == .hit ? "HIT" : "MISS"
        }
        return "—"
    }
}

/// The player-bar danmaku control: one-click on/off (plus the `D`
/// shortcut), quick filters, and doors into settings and manual matching.
struct DanmakuMenuButton: View {
    @ObservedObject var preferences: DanmakuPreferences
    @ObservedObject var session: DanmakuSession
    let openSettings: () -> Void
    let openMatch: () -> Void

    var body: some View {
        Menu {
            Button {
                preferences.enabled.toggle()
            } label: {
                if preferences.enabled {
                    Label("Danmaku On", systemImage: "checkmark")
                } else {
                    Text("Danmaku Off")
                }
            }

            Divider()

            if let status = statusLine {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Match Episode…") { openMatch() }
                .disabled(session.phase.isActionable == false && isReady == false)
            Button("Reload Danmaku") { session.reload() }
                .disabled(session.phase == .idle || session.phase == .disabled || session.phase == .needsConfiguration)

            Divider()

            Toggle("Hide Scrolling Comments", isOn: binding(\.hideScroll))
            Toggle("Hide Top Comments", isOn: binding(\.hideTop))
            Toggle("Hide Bottom Comments", isOn: binding(\.hideBottom))
            Toggle("Hide Colored Comments", isOn: binding(\.hideColored))

            Divider()

            Button("Danmaku Settings…") { openSettings() }
        } label: {
            Image(systemName: preferences.enabled ? "text.bubble.fill" : "text.bubble")
        }
        .help("Danmaku — toggle with D, configure, or match an episode")
    }

    private var isReady: Bool {
        if case .ready = session.phase { return true }
        return false
    }

    private var statusLine: String? {
        switch session.phase {
        case .idle: nil
        case .disabled: "Danmaku is off"
        case .needsConfiguration: "Add your dandanplay AppId/Secret in Settings"
        case .matching: "Identifying episode…"
        case .loading: session.isReloading ? "Fetching danmaku…" : "Loading danmaku…"
        case let .ready(anime, episode, episodeID, cache):
            "\(anime) · \(episode) · #\(episodeID) · cache \(cache == .hit ? "HIT" : "MISS")"
        case .noMatch: "No episode matched — match it manually"
        case let .failed(message): message
        }
    }

    private func binding(_ keyPath: WritableKeyPath<DanmakuDisplaySettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { preferences.settings[keyPath: keyPath] },
            set: { preferences.settings[keyPath: keyPath] = $0 }
        )
    }
}

/// Full danmaku settings: appearance, behavior, timing, and the current
/// match with its replacement path.
struct DanmakuSettingsPanel: View {
    @ObservedObject var preferences: DanmakuPreferences
    @ObservedObject var session: DanmakuSession
    let openMatch: () -> Void

    var body: some View {
        Form {
            Section("Danmaku") {
                Toggle("Show Danmaku", isOn: $preferences.enabled)
                Slider(value: $preferences.settings.opacity, in: 0.1...1) {
                    Text("Opacity \(Int(preferences.settings.opacity * 100))%")
                }
                Slider(value: $preferences.settings.fontScale, in: 0.5...1.5) {
                    Text("Font Size \(String(format: "%.1f×", preferences.settings.fontScale))")
                }
                Picker("Display Area", selection: $preferences.settings.displayArea) {
                    Text("¼ Screen").tag(0.25)
                    Text("½ Screen").tag(0.5)
                    Text("¾ Screen").tag(0.75)
                    Text("Full Screen").tag(1.0)
                }
                Slider(value: $preferences.settings.speedMultiplier, in: 0.5...2) {
                    Text("Scrolling Speed \(String(format: "%.1f×", preferences.settings.speedMultiplier))")
                }
                LabeledContent("Max Simultaneous") {
                    Picker(
                        "Max Simultaneous",
                        selection: $preferences.settings.maxSimultaneous
                    ) {
                        Text("Unlimited").tag(0)
                        ForEach([20, 50, 100, 200], id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .labelsHidden()
                }
            }

            Section("Filters") {
                Toggle("Hide Scrolling Comments", isOn: $preferences.settings.hideScroll)
                Toggle("Hide Top Comments", isOn: $preferences.settings.hideTop)
                Toggle("Hide Bottom Comments", isOn: $preferences.settings.hideBottom)
                Toggle("Hide Colored Comments", isOn: $preferences.settings.hideColored)
            }

            Section("Timing") {
                Slider(
                    value: $preferences.settings.timeOffset,
                    in: -10...10,
                    step: 0.1
                ) {
                    Text("Timing Offset \(String(format: "%+.1fs", preferences.settings.timeOffset))")
                }
                Button("Reset Offset") { preferences.settings.timeOffset = 0 }
                    .disabled(preferences.settings.timeOffset == 0)
            }

            Section("Matched Episode") {
                switch session.phase {
                case let .ready(anime, episode, episodeID, _):
                    LabeledContent("Anime", value: anime)
                    LabeledContent("Episode", value: episode)
                    LabeledContent("Episode ID", value: String(episodeID))
                case .matching:
                    Text("Identifying episode…").foregroundStyle(.secondary)
                case .loading:
                    Text("Loading danmaku…").foregroundStyle(.secondary)
                case .noMatch:
                    Text("No episode matched for this file.").foregroundStyle(.secondary)
                case let .failed(message):
                    Text(message).foregroundStyle(.secondary)
                case .needsConfiguration:
                    Text("Enter your dandanplay AppId and AppSecret in AnimeGod Settings first.")
                        .foregroundStyle(.secondary)
                case .disabled:
                    Text("Danmaku is off.").foregroundStyle(.secondary)
                case .idle:
                    Text("Waiting for playback…").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Match Episode…") { openMatch() }
                    Button("Reload") { session.reload() }
                        .disabled(session.phase == .idle || session.phase == .disabled)
                }
            }

            Section {
                Text("Danmaku by the dandanplay Open Danmaku Network (弹弹play开放弹幕网络). Comments are cached locally after the first fetch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Danmaku")
        .frame(minWidth: 460, minHeight: 620)
    }
}

/// Manual anime/episode matching when identification fails or guesses
/// wrong: search a title, pick the work, pick the episode, done.
struct DanmakuMatchSheet: View {
    @ObservedObject var session: DanmakuSession
    let currentAnime: String?
    let currentEpisode: String?
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var results: [DanmakuSearchedAnime] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var expandedAnimeID: Int64?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Anime title", text: $query)
                    .onSubmit(beginSearch)
                    .textFieldStyle(.roundedBorder)
                Button("Search", action: beginSearch)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                Button("Done") { onDismiss() }
            }
            .padding(12)

            if let currentAnime {
                HStack {
                    Text("Currently matched: \(currentAnime)\(currentEpisode.map { " · \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            Divider()

            if isSearching {
                Spacer()
                ProgressView("Searching dandanplay…")
                Spacer()
            } else if results.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "Search an Anime",
                    systemImage: "text.bubble",
                    description: Text(query.isEmpty
                        ? "Type a title to find its danmaku library."
                        : "No results for “\(query)”.")
                )
                Spacer()
            } else {
                List(results) { anime in
                    DisclosureGroup(
                        isExpanded: binding(for: anime.animeID)
                    ) {
                        ForEach(anime.episodes, id: \.episodeID) { episode in
                            Button {
                                select(episode, in: anime)
                            } label: {
                                HStack {
                                    Text(episode.episodeTitle.isEmpty
                                         ? "Episode \(episode.episodeID)" : episode.episodeTitle)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "arrow.triangle.2.circle.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(anime.animeTitle).font(.body.weight(.medium))
                            HStack(spacing: 6) {
                                if !anime.typeDescription.isEmpty {
                                    Text(anime.typeDescription)
                                }
                                Text("\(anime.episodes.count) episodes")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(anime) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .onAppear {
            if results.isEmpty, query.isEmpty, let currentAnime {
                query = currentAnime
                beginSearch()
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func binding(for animeID: Int64) -> Binding<Bool> {
        Binding(
            get: { expandedAnimeID == animeID },
            set: { expanded in
                expandedAnimeID = expanded ? animeID : nil
            }
        )
    }

    private func toggle(_ anime: DanmakuSearchedAnime) {
        withAnimation { expandedAnimeID = expandedAnimeID == anime.animeID ? nil : anime.animeID }
    }

    private func beginSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        isSearching = true
        results = []
        expandedAnimeID = nil
        searchTask = Task { @MainActor in
            let found = await session.search(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
            expandedAnimeID = found.first?.animeID
            isSearching = false
        }
    }

    private func select(_ episode: DanmakuSearchedEpisode, in anime: DanmakuSearchedAnime) {
        session.matchManually(to: DanmakuEpisodeRef(
            providerID: "dandanplay",
            episodeID: episode.episodeID,
            animeTitle: anime.animeTitle,
            episodeTitle: episode.episodeTitle
        ))
        onDismiss()
    }
}
