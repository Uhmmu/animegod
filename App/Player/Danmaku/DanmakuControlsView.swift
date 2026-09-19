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
                        .foregroundStyle(PlayerChrome.foreground)
                        .playerSurface(cornerRadius: 8)
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
            Text("Comments Loaded: \(snapshot.loadedCount) of \(snapshot.totalCount)")
            Text("Filtered: merged \(snapshot.mergedCount) · hidden \(snapshot.hiddenCount)")
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

/// The danmaku bubble in the player bar: the on/off switch, the current
/// match and its replacement, display filters, and the manager and settings.
struct DanmakuPanelContent: View {
    @ObservedObject var preferences: DanmakuPreferences
    @ObservedObject var session: DanmakuSession
    let openSettings: () -> Void
    let openMatch: () -> Void
    let openManager: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlayerPanelToggleRow(title: "Show Danmaku (D)", isOn: $preferences.enabled)
            if let status = statusLine {
                PlayerPanelNote(text: status)
            }
            PlayerPanelDivider()
            PlayerPanelRow(title: "Match Episode…", systemImage: "text.magnifyingglass", action: openMatch)
                .disabled(session.phase.isActionable == false && isReady == false)
            PlayerPanelRow(title: "Refresh Danmaku", systemImage: "arrow.clockwise") { session.reload() }
                .disabled(session.phase == .idle || session.phase == .disabled || session.phase == .needsConfiguration)
            PlayerPanelDivider()
            PlayerPanelToggleRow(title: "Hide Scrolling Comments", isOn: binding(\.hideScroll))
            PlayerPanelToggleRow(title: "Hide Top Comments", isOn: binding(\.hideTop))
            PlayerPanelToggleRow(title: "Hide Bottom Comments", isOn: binding(\.hideBottom))
            PlayerPanelToggleRow(title: "Hide Colored Comments", isOn: binding(\.hideColored))
            PlayerPanelToggleRow(title: "Merge Duplicate Comments", isOn: binding(\.mergeDuplicates))
            PlayerPanelDivider()
            PlayerPanelRow(title: "Manage Danmaku… (M)", systemImage: "list.bullet.rectangle", action: openManager)
            PlayerPanelRow(title: "Danmaku Settings…", systemImage: "gearshape", action: openSettings)
        }
    }

    private var isReady: Bool {
        if case .ready = session.phase { return true }
        return false
    }

    private var statusLine: String? {
        switch session.phase {
        case .idle: nil
        case .disabled: "Danmaku is off"
        case .needsConfiguration: "Add danmaku credentials in Settings, or switch the source to Bilibili"
        case .matching: "Identifying episode…"
        case .loading: session.isReloading ? "Fetching danmaku…" : "Loading danmaku…"
        case let .ready(anime, episode, episodeID, cache):
            "\(anime) · \(episode) · #\(episodeID) · cache \(cache == .hit ? "HIT" : "MISS")\(sourceSuffix)"
        case .noMatch: "No file match — choose an automatic suggestion"
        case let .failed(message): message
        }
    }

    /// With merged sources, says what each pool contributed — the counts
    /// are pre-deduplication, so they explain the total rather than sum to
    /// it.
    private var sourceSuffix: String {
        var suffix = ""
        let sources = session.loadedSources
        if sources.count > 1 {
            suffix += " · " + sources.map { "\($0.displayName) \($0.commentCount.formatted())" }.joined(separator: " + ")
        }
        // One source failing to identify the file is a hint, not a failure:
        // the others already loaded.
        if !session.unmatchedSources.isEmpty {
            suffix += " · no \(session.unmatchedSources.joined(separator: "/")) match"
        }
        return suffix
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
                Picker("Line Spacing", selection: $preferences.settings.lineSpacing) {
                    Text("Compact").tag(1.15)
                    Text("Standard").tag(1.3)
                    Text("Relaxed").tag(1.5)
                }
                LabeledContent("Max Lines") {
                    Picker("Max Lines", selection: $preferences.settings.maxLines) {
                        Text("Fill Display Area").tag(0)
                        ForEach([4, 6, 8, 10, 12, 16], id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .labelsHidden()
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

            Section {
                Toggle("Merge Duplicate Comments", isOn: $preferences.settings.mergeDuplicates)
                Slider(value: $preferences.settings.density, in: 0.2...1, step: 0.1) {
                    Text("Density \(Int((preferences.settings.density * 100).rounded()))%")
                }
                LabeledContent("Hide Long Comments") {
                    Picker("Hide Long Comments", selection: $preferences.settings.maxLength) {
                        Text("Off").tag(0)
                        ForEach([15, 20, 30, 50], id: \.self) { value in
                            Text("Over \(value) Characters").tag(value)
                        }
                    }
                    .labelsHidden()
                }
                Toggle("Hide Scrolling Comments", isOn: $preferences.settings.hideScroll)
                Toggle("Hide Top Comments", isOn: $preferences.settings.hideTop)
                Toggle("Hide Bottom Comments", isOn: $preferences.settings.hideBottom)
                Toggle("Hide Colored Comments", isOn: $preferences.settings.hideColored)
            } header: {
                Text("Filters")
            } footer: {
                Text("Merging shows a comment repeated within \(Int(DanmakuCommentFilter.mergeWindow)) seconds once, with a ×N count. Lower density thins comments evenly; comments repeated \(DanmakuCommentFilter.popularThreshold) or more times are always kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Blocked Keywords") {
                DanmakuKeywordRows(preferences: preferences)
            }

            Section("Blocked Users") {
                DanmakuBlockedUserRows(preferences: preferences, comments: session.comments)
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

/// Metadata-assisted episode selection. Opening the sheet immediately searches
/// clean local title aliases and ranks likely episodes; typed search remains a
/// fallback for genuinely ambiguous libraries.
struct DanmakuMatchSheet: View {
    @ObservedObject var session: DanmakuSession
    let currentAnime: String?
    let currentEpisode: String?
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var results: [DanmakuSearchedAnime] = []
    @State private var isSearching = false
    @State private var automaticSuggestions: [DanmakuEpisodeSuggestion] = []
    @State private var isSearchingAutomatically = false
    @State private var didSearchAutomatically = false
    @State private var searchTask: Task<Void, Never>?
    @State private var expandedAnimeID: String?
    @State private var pendingEpisodeID: Int64?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose Danmaku Episode").font(.headline)
                    Text("Suggestions use library metadata and the episode number, not a pasted filename.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    session.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(liveMatch == nil || session.isReloading)
                Button("Done") { onDismiss() }
            }
            .padding(12)

            if let match = liveMatch {
                HStack {
                    Label {
                        Text("Current: \(match.anime) · \(match.episode) · \(session.renderer.totalCount.formatted()) comments")
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            } else if let currentAnime {
                HStack {
                    Text("Previously matched: \(currentAnime)\(currentEpisode.map { " · \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            Divider()

            if isSearchingAutomatically {
                Spacer()
                ProgressView("Finding the closest episodes on \(sourceLabel)…")
                Spacer()
            } else if !results.isEmpty {
                manualResults
            } else if !automaticSuggestions.isEmpty {
                automaticResults
            } else if isSearching {
                Spacer()
                ProgressView("Searching \(sourceLabel)…")
                Spacer()
            } else if results.isEmpty {
                Spacer()
                ContentUnavailableView(
                    didSearchAutomatically ? "No Automatic Suggestions" : "Preparing Suggestions",
                    systemImage: "text.bubble",
                    description: Text(query.isEmpty
                        ? "Try another title below if the library metadata cannot identify this release."
                        : "No results for “\(query)”.")
                )
                Spacer()
            }

            Divider()
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search another anime title (optional)", text: $query)
                    .onSubmit(beginSearch)
                    .textFieldStyle(.roundedBorder)
                Button("Search", action: beginSearch)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                if !results.isEmpty {
                    Button("Back to Suggestions") {
                        results = []
                        query = ""
                    }
                }
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 520)
        .onAppear(perform: beginAutomaticSearch)
        .onChange(of: session.phase) { _, phase in
            switch phase {
            case .ready, .failed, .noMatch:
                pendingEpisodeID = nil
            default:
                break
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    /// Names the sources being searched, so the sheet does not claim to be
    /// querying dandanplay when Bilibili is the active source.
    private var sourceLabel: String {
        let names = session.activeProviderDisplayNames
        return names.isEmpty ? "danmaku sources" : names.joined(separator: " + ")
    }

    private var automaticResults: some View {
        List(Array(automaticSuggestions.enumerated()), id: \.element.id) { index, suggestion in
            Button {
                select(suggestion.episode, in: suggestion.anime)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: rowIcon(for: suggestion, index: index))
                        .foregroundStyle(rowColor(for: suggestion, index: index))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(suggestion.anime.animeTitle).font(.body.weight(.medium))
                            if suggestion.episode.episodeID == liveMatch?.episodeID {
                                Text("Current Match")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.14), in: Capsule())
                            } else if pendingEpisodeID == suggestion.episode.episodeID {
                                ProgressView().controlSize(.small)
                            } else if index == 0 {
                                Text("Best Match")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(suggestion.episode.episodeTitle.isEmpty
                             ? "Episode \(suggestion.episode.episodeID)" : suggestion.episode.episodeTitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
    }

    private var manualResults: some View {
        List(results) { anime in
            DisclosureGroup(isExpanded: binding(for: anime.id)) {
                ForEach(anime.episodes, id: \.episodeID) { episode in
                    Button { select(episode, in: anime) } label: {
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
                        if !anime.providerID.isEmpty { Text(anime.providerID) }
                        if !anime.typeDescription.isEmpty { Text(anime.typeDescription) }
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

    private func binding(for animeID: String) -> Binding<Bool> {
        Binding(
            get: { expandedAnimeID == animeID },
            set: { expanded in
                expandedAnimeID = expanded ? animeID : nil
            }
        )
    }

    private func toggle(_ anime: DanmakuSearchedAnime) {
        withAnimation { expandedAnimeID = expandedAnimeID == anime.id ? nil : anime.id }
    }

    private func beginSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        isSearchingAutomatically = false
        isSearching = true
        results = []
        expandedAnimeID = nil
        searchTask = Task { @MainActor in
            let found = await session.search(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
            expandedAnimeID = found.first?.id
            isSearching = false
        }
    }

    private func beginAutomaticSearch() {
        guard !didSearchAutomatically else { return }
        didSearchAutomatically = true
        isSearchingAutomatically = true
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            let found = await session.automaticSuggestions()
            guard !Task.isCancelled else { return }
            automaticSuggestions = found
            isSearchingAutomatically = false
        }
    }

    private var liveMatch: (anime: String, episode: String, episodeID: Int64)? {
        if case let .ready(anime, episode, episodeID, _) = session.phase {
            return (anime, episode, episodeID)
        }
        return nil
    }

    private func rowIcon(for suggestion: DanmakuEpisodeSuggestion, index: Int) -> String {
        if suggestion.episode.episodeID == liveMatch?.episodeID { return "checkmark.circle.fill" }
        if pendingEpisodeID == suggestion.episode.episodeID { return "arrow.triangle.2.circlepath" }
        return index == 0 ? "sparkles" : "text.bubble"
    }

    private func rowColor(for suggestion: DanmakuEpisodeSuggestion, index: Int) -> Color {
        if suggestion.episode.episodeID == liveMatch?.episodeID { return .green }
        if pendingEpisodeID == suggestion.episode.episodeID || index == 0 { return .accentColor }
        return .secondary
    }

    private func select(_ episode: DanmakuSearchedEpisode, in anime: DanmakuSearchedAnime) {
        pendingEpisodeID = episode.episodeID
        // The result carries the provider that returned it: with several
        // sources enabled, binding it to the wrong one would fetch a
        // different service's episode id.
        let providerID = anime.providerID.isEmpty
            ? (session.activeProviderIDs.first ?? "dandanplay")
            : anime.providerID
        session.matchManually(to: DanmakuEpisodeRef(
            providerID: providerID,
            episodeID: episode.episodeID,
            animeTitle: anime.animeTitle,
            episodeTitle: episode.episodeTitle,
            providerContext: episode.providerContext
        ))
    }
}
