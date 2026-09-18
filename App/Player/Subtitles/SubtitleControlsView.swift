import AnimeGodCore
import SwiftUI

/// A small, non-blocking status line for online subtitles: what was loaded
/// automatically, or that a choice is waiting. Never covers the video for
/// long and never interrupts playback.
struct SubtitleStatusBadge: View {
    @ObservedObject var session: SubtitleSession
    let controlsVisible: Bool
    let openSearch: () -> Void

    @State private var announcementTask: Task<Void, Never>?

    var body: some View {
        VStack {
            HStack {
                if let text = visibleText {
                    Label(text, systemImage: icon)
                        .lineLimit(1)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onTapGesture { openSearch() }
                        .transition(.opacity)
                }
                Spacer()
            }
            .padding(.leading, 20)
            .padding(.top, 64)
            Spacer()
        }
        .opacity(controlsVisible || session.announcement != nil ? 1 : 0.35)
        .allowsHitTesting(visibleText != nil)
        .animation(.easeOut(duration: 0.2), value: visibleText)
        .onChange(of: session.announcement) { _, announcement in
            announcementTask?.cancel()
            guard announcement != nil else { return }
            announcementTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                session.clearAnnouncement()
            }
        }
    }

    private var visibleText: String? {
        if let announcement = session.announcement { return "Loaded online subtitles: \(announcement)" }
        switch session.phase {
        case .searching: return controlsVisible ? "Searching online subtitles…" : nil
        case .downloading: return controlsVisible ? Self.statusText(session.phase) : nil
        case .needsChoice, .noResults, .failed, .notConfigured: return Self.statusText(session.phase)
        default: return nil
        }
    }

    private var icon: String {
        if session.announcement != nil { return "captions.bubble.fill" }
        switch session.phase {
        case .searching, .downloading: return "magnifyingglass"
        case .needsChoice: return "questionmark.bubble"
        case .notConfigured: return "key"
        case .failed: return "wifi.exclamationmark"
        default: return "captions.bubble"
        }
    }

    /// One-line status used by the badge and the subtitle menu.
    static func statusText(_ phase: SubtitleSession.Phase) -> String {
        switch phase {
        case .idle, .waitingForTracks: "Online subtitles: waiting for the video"
        case let .existingSubtitle(name): "Using the video's own subtitles (\(name))"
        case .burnedIn: "Chinese subtitles are burned into this release"
        case .subtitlesOff: "Subtitles are off — no automatic search"
        case .ready: "Automatic search is off — use Search Subtitles…"
        case .notConfigured: "Online subtitles need a provider key — Settings"
        case .unavailableInPipeline: "Subtitles are not shown in native Dolby Vision mode (⌘⇧H switches)"
        case .searching: "Searching online subtitles…"
        case let .downloading(provider): "Downloading from \(provider)…"
        case let .loaded(record, fromCache): "\(record.displayTitle)\(fromCache ? " (cached)" : "")"
        case let .needsChoice(count): "\(count) subtitle\(count == 1 ? "" : "s") found — click to choose"
        case .noResults: "No matching Chinese subtitles found — click to search"
        case let .failed(message): "Online subtitles: \(message)"
        }
    }
}

/// The player's subtitle menu: tracks grouped by where they come from —
/// inside the file, files beside it (or chosen by hand), downloaded online
/// subtitles — plus online search, delays and loading a file.
///
/// Equatable on purpose: compared by what it shows, it is not rebuilt by
/// the player's frequent position updates, which would close its submenus
/// and swallow clicks while it is open.
struct SubtitleMenuButton: View, @MainActor Equatable {
    struct Actions {
        let select: (MediaTrack?) -> Void
        let nudgeSubtitleDelay: (Double) -> Void
        let resetSubtitleDelay: () -> Void
        let nudgeAudioDelay: (Double) -> Void
        let resetAudioDelay: () -> Void
        let openSearch: () -> Void
        let loadExternalFile: () -> Void
    }

    @ObservedObject var session: SubtitleSession
    let tracks: [MediaTrack]
    let selectedID: Int64?
    let subtitleDelay: Double
    let audioDelay: Double
    let actions: Actions

    static func == (lhs: SubtitleMenuButton, rhs: SubtitleMenuButton) -> Bool {
        lhs.session === rhs.session && lhs.tracks == rhs.tracks && lhs.selectedID == rhs.selectedID
            && lhs.subtitleDelay == rhs.subtitleDelay && lhs.audioDelay == rhs.audioDelay
    }

    var body: some View {
        let online = tracks.filter { session.isOwnDownload($0) }
        let embedded = tracks.filter { !$0.isExternal }
        let external = tracks.filter { $0.isExternal && !session.isOwnDownload($0) }
        return Menu {
            Button { actions.select(nil) } label: {
                if selectedID == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            if !embedded.isEmpty {
                Section("Embedded") { trackButtons(embedded) }
            }
            if !external.isEmpty {
                Section("External Files") { trackButtons(external) }
            }
            if !online.isEmpty {
                Section("Online") { trackButtons(online) }
            }
            Divider()
            Menu("Online Subtitles") {
                // Never disabled: while a search runs, both open the sheet,
                // which shows its progress.
                Button("Auto-Match Chinese Subtitles") {
                    if session.isSearching { actions.openSearch() } else { session.autoMatchNow() }
                }
                Button("Search Subtitles…") { actions.openSearch() }
                if !session.downloads.isEmpty {
                    Menu("Downloaded") {
                        ForEach(session.downloads) { record in
                            Button { session.selectDownloaded(record) } label: {
                                let title = "\(record.displayTitle) · \(Int((record.matchScore * 100).rounded()))%"
                                if isSelected(record) { Label(title, systemImage: "checkmark") } else { Text(title) }
                            }
                        }
                        Divider()
                        Button("Remove Downloads and Search Again") { session.researchFromScratch() }
                        Button("Remove Downloads for This Episode", role: .destructive) {
                            Task { await session.removeDownloads() }
                        }
                    }
                }
                Divider()
                Text(SubtitleStatusBadge.statusText(session.phase))
            }
            Divider()
            Menu("Subtitle Delay") {
                Button("Earlier 0.5s") { actions.nudgeSubtitleDelay(-0.5) }
                Button("Later 0.5s") { actions.nudgeSubtitleDelay(0.5) }
                Button("Reset") { actions.resetSubtitleDelay() }
                if subtitleDelay != 0 {
                    Text("Current: \(String(format: "%+.1f", subtitleDelay))s")
                }
            }
            Menu("Audio Delay") {
                Button("Earlier 0.1s") { actions.nudgeAudioDelay(-0.1) }
                Button("Later 0.1s") { actions.nudgeAudioDelay(0.1) }
                Button("Reset") { actions.resetAudioDelay() }
                if audioDelay != 0 {
                    Text("Current: \(String(format: "%+.1f", audioDelay))s")
                }
            }
            Divider()
            Button("Load External Subtitle…") { actions.loadExternalFile() }
        } label: { Image(systemName: "captions.bubble") }
        .help("Subtitle Tracks, Online Subtitles, Delays, and External Files")
    }

    @ViewBuilder
    private func trackButtons(_ tracks: [MediaTrack]) -> some View {
        ForEach(tracks) { track in
            Button { actions.select(track) } label: {
                if selectedID == track.id { Label(track.displayName, systemImage: "checkmark") }
                else { Text(track.displayName) }
            }
        }
    }

    private func isSelected(_ record: SubtitleDownloadRecord) -> Bool {
        guard let current = tracks.first(where: { $0.id == selectedID }) else { return false }
        return session.download(for: current)?.id == record.id
    }
}

/// The "Search Subtitles…" sheet: every candidate with the facts that
/// decide whether its timing fits — language, format, provider, release
/// group, source — and the match score.
struct SubtitleSearchSheet: View {
    @ObservedObject var session: SubtitleSession
    let currentTrackFile: String?
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var allLanguages = false
    @State private var selection: ScoredSubtitle.ID?
    @State private var pendingID: ScoredSubtitle.ID?
    @State private var searchTask: Task<Void, Never>?

    private var ranked: [ScoredSubtitle] { session.lastReport?.ranked ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            outcomes
            if session.isSearching {
                Spacer()
                ProgressView("Searching subtitle sites…")
                Spacer()
            } else if ranked.isEmpty {
                Spacer()
                ContentUnavailableView(
                    session.lastReport == nil ? "Ready to Search" : "No Subtitles Found",
                    systemImage: "captions.bubble",
                    description: Text(session.lastReport == nil
                        ? "Search uses the library's titles, the episode number and the release."
                        : "Try another title below, or include every language.")
                )
                Spacer()
            } else {
                results
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 520)
        .onAppear {
            // An automatic search already running fills the sheet itself.
            if session.lastReport == nil, !session.isSearching { runSearch() }
        }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: session.phase) { _, phase in
            switch phase {
            case .loaded, .failed: pendingID = nil
            default: break
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Online Subtitles").font(.headline)
                Text(identitySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Done") { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var identitySummary: String {
        guard let identity = session.identity else { return session.request?.fileName ?? "" }
        var parts: [String] = [identity.titles.first ?? identity.fileName, identity.episodeLabel]
        parts += [identity.releaseGroup, identity.source, identity.resolution].compactMap { $0 }
        var ids: [String] = []
        if let id = identity.ids.aniListID { ids.append("AniList \(id)") }
        if let id = identity.ids.tmdbID { ids.append("TMDB \(id)\(identity.ids.tmdbSeason.map { " S\($0)" } ?? "")") }
        if let id = identity.ids.aniDBID { ids.append("AniDB \(id)") }
        if let id = identity.ids.malID { ids.append("MAL \(id)") }
        return (parts + ids).joined(separator: " · ")
    }

    @ViewBuilder
    private var outcomes: some View {
        if let report = session.lastReport, !report.outcomes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SubtitleProviderID.allCases.filter { report.outcomes[$0] != nil }) { provider in
                        outcomeChip(provider, report.outcomes[provider]!)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Divider()
        }
    }

    private func outcomeChip(_ provider: SubtitleProviderID, _ outcome: SubtitleProviderOutcome) -> some View {
        let (text, color): (String, Color) = switch outcome {
        case let .succeeded(count): ("\(provider.displayName): \(count)", .green)
        case let .skipped(reason): ("\(provider.displayName): \(reason)", .secondary)
        case let .failed(message): ("\(provider.displayName): \(message)", .orange)
        }
        return Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .help(text)
    }

    private var results: some View {
        Table(ranked, selection: $selection) {
            TableColumn("Language") { scored in
                Text(scored.result.languages.map(\.displayName).joined(separator: " / ").nilIfEmptyText ?? "—")
            }
            .width(min: 70, ideal: 90)
            TableColumn("Format") { scored in
                Text(scored.result.format?.displayName ?? "Archive")
            }
            .width(min: 50, ideal: 60)
            TableColumn("Provider") { scored in
                Text(scored.result.provider.displayName)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Group") { scored in
                Text(scored.result.displayGroup ?? "Unknown").lineLimit(1)
            }
            .width(min: 70, ideal: 100)
            TableColumn("Match") { scored in
                Text("\(scored.score.percent)%")
                    .monospacedDigit()
                    .foregroundStyle(matchColor(scored))
                    .help(scoreHelp(scored))
            }
            .width(min: 44, ideal: 52)
            TableColumn("Version") { scored in
                Text(versionText(scored)).lineLimit(1).help(versionText(scored))
            }
            .width(min: 90, ideal: 150)
            TableColumn("File") { scored in
                Text(scored.result.fileName ?? scored.result.releaseName ?? scored.result.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(scored.result.releaseName ?? scored.result.fileName ?? "")
            }
            TableColumn("") { scored in
                if pendingID == scored.id {
                    ProgressView().controlSize(.small)
                } else if isCurrent(scored) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Load") { load(scored) }
                        .disabled(pendingID != nil)
                }
            }
            .width(56)
        }
        .contextMenu(forSelectionType: ScoredSubtitle.ID.self) { _ in } primaryAction: { ids in
            if let id = ids.first, let scored = ranked.first(where: { $0.id == id }) { load(scored) }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(session.identity?.titles.first.map { "Search another title (default: \($0))" } ?? "Search another title",
                          text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runSearch)
                Toggle("All languages", isOn: $allLanguages)
                    .toggleStyle(.checkbox)
                Button("Search", action: runSearch)
            }
            HStack {
                statusLine
                Spacer()
                if session.preferences?.enabledProviders.contains(.assrt) == true {
                    Text(AssrtSubtitleProvider.attribution)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch session.phase {
        case .downloading, .failed, .loaded:
            Text(SubtitleStatusBadge.statusText(session.phase))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        default:
            Text("Match weighs episode, release group and source (BD/WEB timing) first, then your language and format order.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: - Actions

    private func runSearch() {
        searchTask?.cancel()
        let text = query
        let everyLanguage = allLanguages
        searchTask = Task { @MainActor in
            await session.search(customText: text, allLanguages: everyLanguage)
            selection = session.lastReport?.ranked.first?.id
        }
    }

    private func load(_ scored: ScoredSubtitle) {
        pendingID = scored.id
        Task { @MainActor in
            await session.choose(scored)
            pendingID = nil
        }
    }

    // MARK: - Formatting

    private func isCurrent(_ scored: ScoredSubtitle) -> Bool {
        guard let currentTrackFile, let preferences = session.preferences else { return false }
        return session.downloads.contains { record in
            record.provider == scored.result.provider
                && record.providerSubtitleID == scored.result.providerSubtitleID
                && preferences.cache.url(for: record).path == currentTrackFile
        }
    }

    private func matchColor(_ scored: ScoredSubtitle) -> Color {
        if scored.score.warnings.contains(where: \.blocksAutoLoad) && scored.score.total < 0.5 { return .secondary }
        if scored.score.total >= (session.preferences?.ranking.autoLoadThreshold ?? 0.7) { return .green }
        if scored.score.total >= 0.45 { return .orange }
        return .secondary
    }

    private func scoreHelp(_ scored: ScoredSubtitle) -> String {
        let score = scored.score
        var lines = [
            String(format: "Identity %.0f/25 · Episode %.0f/25 · Release %.0f/25", score.identity, score.episode, score.release),
            String(format: "Language %.0f/15 · Format %.1f/7 · Quality %.1f/3", score.language, score.format, score.quality)
        ]
        if !score.warnings.isEmpty { lines.append(score.warnings.map(\.displayName).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    private func versionText(_ scored: ScoredSubtitle) -> String {
        let result = scored.result
        let timed = result.timedRelease
        var parts: [String] = []
        if result.isPack {
            parts.append(timed.episodeLabel.map { "Pack \($0)" } ?? "Pack")
        } else if let episode = result.episode {
            parts.append(episode.rounded() == episode ? String(format: "E%02d", Int(episode)) : "E\(episode)")
        }
        parts += [timed.videoSource, timed.resolution].compactMap { $0 }
        if result.isHashMatch { parts.insert("Exact file", at: 0) }
        let warnings = scored.score.warnings.filter { $0 != .seasonPack }.map(\.displayName)
        return (parts + warnings).joined(separator: " · ")
    }
}

/// Online-subtitle lines for the ⌘⇧D diagnostics panel.
struct SubtitleDiagnosticsSection: View {
    @ObservedObject var session: SubtitleSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Online Subtitles").foregroundStyle(.secondary)
            Text("Status: \(SubtitleStatusBadge.statusText(session.phase))")
            if let identity = session.identity {
                Text("Identity: \(identity.titles.first ?? "—") \(identity.episodeLabel)")
                Text("Release: \(identity.releaseGroup ?? "—") · \(identity.source ?? "—") · \(identity.resolution ?? "—")")
                Text("IDs: AniList \(identity.ids.aniListID.map(String.init) ?? "—") · TMDB \(identity.ids.tmdbID.map(String.init) ?? "—") · AniDB \(identity.ids.aniDBID.map(String.init) ?? "—")")
            }
            if let report = session.lastReport {
                Text("Last search: \(report.ranked.count) results, best \(report.ranked.first.map { "\($0.score.percent)%" } ?? "—")")
            }
            Text("Cached for this file: \(session.downloads.count)")
        }
    }
}

private extension String {
    var nilIfEmptyText: String? { isEmpty ? nil : self }
}
