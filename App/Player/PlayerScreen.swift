import AnimeGodCore
import AppKit
import SwiftUI

struct MPVPlayerView: NSViewControllerRepresentable {
    @ObservedObject var state: PlayerState

    func makeNSViewController(context: Context) -> MPVPlayerController {
        let controller = MPVPlayerController()
        controller.delegate = state
        controller.initialURL = state.mediaURL
        controller.initialPosition = state.position
        state.controller = controller
        return controller
    }

    func updateNSViewController(_ controller: MPVPlayerController, context: Context) {}
}

@MainActor
final class PlayerState: ObservableObject, MPVPlayerControllerDelegate {
    @Published var position: Double
    @Published var duration: Double
    @Published var paused = false
    @Published var audioTracks: [MediaTrack] = []
    @Published var subtitleTracks: [MediaTrack] = []
    @Published var audioID: Int64?
    @Published var subtitleID: Int64?
    @Published var chapters: [MediaChapter] = []
    @Published var currentChapter: Int?
    @Published var speed: Double = 1
    @Published var volume: Double = 100
    @Published var subtitleDelay: Double = 0
    @Published var audioDelay: Double = 0
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published private(set) var currentEpisode: EpisodeMedia
    @Published private(set) var colorProfile: VideoColorProfile?
    @Published private(set) var hdrOutputActive = false

    let episodes: [EpisodeMedia]
    var currentIndex: Int
    /// Invoked when the current file reaches its end so the screen can advance.
    var onFileFinished: (() -> Void)?

    private(set) var mediaURL: URL
    weak var controller: MPVPlayerController?
    private var access: ScopedLibraryAccess?
    private let roots: [LibraryRoot]
    let startedAt = Date.now
    private var lastPosition: Double?
    private var watchedDuration: Double = 0
    private var didEndSession = false
    // Deinit-only access from the nonisolated finalizer; safe because the
    // object is already unreferenced there.
    nonisolated(unsafe) private var displayObserver: NSObjectProtocol?

    init(request: PlayerRequest) {
        episodes = request.episodes
        currentIndex = request.startIndex
        roots = request.roots
        let episode = request.episode
        let root = request.root(for: episode)
        currentEpisode = episode
        access = root.flatMap { try? ScopedLibraryAccess(root: $0) }
        let rootURL = access?.url ?? URL(fileURLWithPath: root?.lastKnownPath ?? "/", isDirectory: true)
        mediaURL = rootURL.appending(path: episode.mediaFile.relativePath)
        position = episode.progress?.position ?? 0
        duration = episode.progress?.duration ?? 0
        if !FileManager.default.isReadableFile(atPath: mediaURL.path) {
            errorMessage = "AnimeGod can no longer read this file. Remove and re-add its library folder to renew access."
            isLoading = false
        }
    }

    var hasNext: Bool { episodes.indices.contains(currentIndex + 1) }
    var hasPrevious: Bool { episodes.indices.contains(currentIndex - 1) }

    /// Swaps to another encode of the same episode (DoVi ↔ SDR), keeping the
    /// current playback position and session bookkeeping.
    func switchVersion(to file: MediaFile) {
        guard file.id != currentEpisode.mediaFile.id,
              let root = roots.first(where: { $0.id == file.libraryRootID }) else { return }
        let newAccess = try? ScopedLibraryAccess(root: root)
        let rootURL = newAccess?.url ?? URL(fileURLWithPath: root.lastKnownPath, isDirectory: true)
        let url = rootURL.appending(path: file.relativePath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            newAccess?.stop()
            errorMessage = "AnimeGod can no longer read this file. Remove and re-add its library folder to renew access."
            return
        }
        access?.stop()
        access = newAccess
        mediaURL = url
        isLoading = true
        errorMessage = nil
        currentEpisode = EpisodeMedia(
            episode: currentEpisode.episode,
            mediaFile: file,
            progress: currentEpisode.progress,
            versions: currentEpisode.versions
        )
        controller?.play(url: url, position: position)
    }

    /// Finalizes the current episode's watch session and prepares playback of
    /// another episode inside the same player window. When the finished episode
    /// produced a meaningful session, its data is returned so the screen can
    /// persist it; the new file is already loading by then.
    func switchEpisode(to index: Int) -> (oldEpisode: EpisodeMedia, startedAt: Date, watchedDuration: Double, position: Double, duration: Double)? {
        guard episodes.indices.contains(index), index != currentIndex else { return nil }
        guard let root = roots.first(where: { $0.id == episodes[index].mediaFile.libraryRootID }) else {
            errorMessage = "The library folder for this episode is unavailable."
            return nil
        }
        let newAccess = try? ScopedLibraryAccess(root: root)
        let rootURL = newAccess?.url ?? URL(fileURLWithPath: root.lastKnownPath, isDirectory: true)
        let url = rootURL.appending(path: episodes[index].mediaFile.relativePath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            newAccess?.stop()
            errorMessage = "AnimeGod can no longer read this file. Remove and re-add its library folder to renew access."
            return nil
        }
        let oldEpisode = currentEpisode
        let finished = takeSession()
        access?.stop()
        access = newAccess
        load(url: url, episode: episodes[index], index: index)
        guard let finished else { return nil }
        return (oldEpisode, finished.startedAt, finished.watchedDuration, finished.position, finished.duration)
    }

    private func load(url: URL, episode: EpisodeMedia, index: Int) {
        errorMessage = nil
        isLoading = true
        mediaURL = url
        currentEpisode = episode
        currentIndex = index
        position = episode.progress?.position ?? 0
        duration = episode.progress?.duration ?? 0
        watchedDuration = 0
        lastPosition = nil
        didEndSession = false
        chapters = []
        currentChapter = nil
        speed = 1
        subtitleDelay = 0
        audioDelay = 0
        controller?.play(url: url, position: position)
    }

    func togglePause() {
        paused.toggle()
        controller?.setPaused(paused)
    }

    func seek(to value: Double) {
        position = value
        controller?.seek(to: value)
    }

    func seek(by offset: Double) {
        controller?.seek(by: offset)
    }

    func setSpeed(_ value: Double) {
        speed = value
        controller?.setSpeed(value)
    }

    func setVolume(_ value: Double) {
        volume = value
        controller?.setVolume(value)
    }

    func nudgeSubtitleDelay(_ delta: Double) {
        subtitleDelay += delta
        controller?.setSubtitleDelay(subtitleDelay)
    }

    func resetSubtitleDelay() {
        subtitleDelay = 0
        controller?.setSubtitleDelay(0)
    }

    func nudgeAudioDelay(_ delta: Double) {
        audioDelay += delta
        controller?.setAudioDelay(audioDelay)
    }

    func resetAudioDelay() {
        audioDelay = 0
        controller?.setAudioDelay(0)
    }

    func selectChapter(_ index: Int) {
        controller?.selectChapter(index)
    }

    func stepChapter(_ offset: Int) {
        controller?.stepChapter(offset)
    }

    func addExternalSubtitle(url: URL) {
        controller?.addSubtitle(url: url)
    }

    func playerDidUpdate(position: Double?, duration: Double?, paused: Bool?) {
        if let position {
            if let lastPosition, !self.paused {
                let delta = position - lastPosition
                if delta > 0, delta <= 5 { watchedDuration += delta }
            }
            lastPosition = position
            self.position = position
        }
        if let duration { self.duration = duration }
        if let paused { self.paused = paused }
    }

    /// Returns the finished session for the episode that just stopped, clearing
    /// per-episode bookkeeping so the next episode starts from a clean slate.
    func takeSession() -> (startedAt: Date, watchedDuration: Double, position: Double, duration: Double)? {
        let result = (startedAt, watchedDuration, position, duration)
        watchedDuration = 0
        lastPosition = nil
        didEndSession = true
        return result
    }

    func endSession() -> (startedAt: Date, watchedDuration: Double, position: Double, duration: Double)? {
        guard !didEndSession else { return nil }
        didEndSession = true
        return (startedAt, watchedDuration, position, duration)
    }

    func playerDidUpdateTracks(audio: [MediaTrack], subtitles: [MediaTrack], audioID: Int64?, subtitleID: Int64?) {
        audioTracks = audio
        subtitleTracks = subtitles
        self.audioID = audioID
        self.subtitleID = subtitleID
    }

    func playerDidUpdateChapters(_ chapters: [MediaChapter], current: Int?) {
        self.chapters = chapters
        self.currentChapter = current
    }

    func playerDidUpdatePlaybackState(speed: Double?, volume: Double?, subtitleDelay: Double?, audioDelay: Double?) {
        if let speed { self.speed = speed }
        if let volume { self.volume = volume }
        if let subtitleDelay { self.subtitleDelay = subtitleDelay }
        if let audioDelay { self.audioDelay = audioDelay }
    }

    func playerDidUpdateColor(_ profile: VideoColorProfile) {
        colorProfile = profile
        reconfigureColorOutput()
    }

    /// End-to-end HDR output report: with the experimental EDR path enabled
    /// at mpv creation, mpv tone-maps to the display itself; otherwise HDR
    /// plays through SDR tone mapping. Never a half-configured pipeline.
    func reconfigureColorOutput() {
        let screen = controller?.view.window?.screen ?? NSScreen.main
        let potential = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        let current = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        displayInfo = DisplayHDRInfo(
            name: screen?.localizedName,
            headroom: current > 1 ? current : nil,
            potentialHeadroom: potential > 1 ? potential : nil
        )
        hdrOutputActive = MPVPlayerController.experimentalEDRPipelineEnabled
            && (colorProfile?.isHDR == true)
            && potential > 1.0
    }

    struct DisplayHDRInfo: Equatable {
        let name: String?
        let headroom: Double?
        let potentialHeadroom: Double?
    }

    @Published private(set) var displayInfo = DisplayHDRInfo(name: nil, headroom: nil, potentialHeadroom: nil)

    func startObservingDisplay() {
        guard displayObserver == nil else { return }
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconfigureColorOutput() }
        }
    }

    func playerLoadingStateDidChange(isLoading: Bool) {
        self.isLoading = isLoading
        if !isLoading { errorMessage = nil }
    }

    func playerDidFail(message: String) {
        isLoading = false
        errorMessage = message
    }

    func playerDidFinishFile() {
        onFileFinished?()
    }

    deinit {
        if let displayObserver {
            NotificationCenter.default.removeObserver(displayObserver)
        }
        access?.stop()
    }
}

/// Reports raw mouse movement and click gestures inside the video area so
/// the overlay controls can follow the "appear when needed, disappear when
/// idle" playback rule. A plain NSView consumes the events, so click handling
/// must live here — SwiftUI tap gestures never see them.
private struct MouseMovementView: NSViewRepresentable {
    let onMove: () -> Void
    let onClick: () -> Void
    let onDoubleClick: () -> Void

    final class MouseCatcher: NSView {
        var onMove: (() -> Void)?
        var onClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseMoved(with event: NSEvent) { onMove?() }
        override func mouseEntered(with event: NSEvent) { onMove?() }

        override func mouseUp(with event: NSEvent) {
            if event.clickCount >= 2 {
                onDoubleClick?()
            } else {
                onClick?()
            }
        }
    }

    func makeNSView(context: Context) -> MouseCatcher {
        let view = MouseCatcher()
        view.onMove = onMove
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: MouseCatcher, context: Context) {
        view.onMove = onMove
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
    }
}

struct PlayerScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: PlayerRequest
    @StateObject private var state: PlayerState
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isHoveringControls = false
    @State private var isSwitching = false
    @State private var showDiagnostics = false

    init(request: PlayerRequest) {
        self.request = request
        _state = StateObject(wrappedValue: PlayerState(request: request))
    }

    private var episodeLabel: String {
        let episode = state.currentEpisode.episode
        return switch episode.kind {
        case .regular: episode.numberText.map { "Episode \($0)" } ?? "Movie"
        case .special: "Special \(episode.numberText ?? "")"
        case .opening: "Creditless Opening"
        case .ending: "Creditless Ending"
        case .music: "Music Video"
        case .trailer: "Trailer"
        case .extra: "Extra"
        }
    }

    var body: some View {
        ZStack {
            MPVPlayerView(state: state)
                .background(.black)
            MouseMovementView(
                onMove: { revealControls() },
                onClick: { toggleControls() },
                onDoubleClick: { toggleFullscreen() }
            )
            if state.isLoading {
                ProgressView("Opening video…")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let error = state.errorMessage {
                ContentUnavailableView {
                    Label("Unable to Play", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    if state.hasNext {
                        Button("Play Next Episode") { Task { await switchTo(state.currentIndex + 1) } }
                            .disabled(isSwitching)
                    }
                    Button("Close") { dismiss() }
                }
                .foregroundStyle(.white)
            }
            VStack(spacing: 0) {
                Spacer()
                controls
                    .opacity(controlsVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: controlsVisible)
                    .onHover { hovering in isHoveringControls = hovering }
            }
            VStack {
                header
                    .opacity(controlsVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: controlsVisible)
                Spacer()
            }
            if showDiagnostics {
                diagnosticsPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 64)
                // Keyboard toggles stay alive only while present in the view
                // hierarchy; keep them outside the conditional.
            }
            diagnosticsShortcuts
                .frame(width: 0, height: 0)
                .opacity(0.001)
        }
        .background(.black)
        .onAppear {
            state.onFileFinished = { Task { await advanceAfterFinish() } }
            state.startObservingDisplay()
            revealControls()
            if ProcessInfo.processInfo.arguments.contains("-smokePlayerTest") {
                scheduleSmokeTest()
            }
        }
        .onDisappear {
            hideTask?.cancel()
            guard let session = state.endSession() else { return }
            Task {
                await model.finishPlaybackSession(
                    episode: state.currentEpisode,
                    startedAt: session.startedAt,
                    watchedDuration: session.watchedDuration,
                    position: session.position,
                    duration: session.duration
                )
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                await model.saveProgress(episodeID: state.currentEpisode.id, position: state.position, duration: state.duration)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.metadataByAnimeID[state.currentEpisode.episode.animeID]?.title
                     ?? model.library.first(where: { $0.id == state.currentEpisode.episode.animeID })?.anime.title
                     ?? "AnimeGod")
                    .font(.headline)
                Text(episodeLabel).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Episode \(state.currentIndex + 1) of \(state.episodes.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 84)
        .padding(.vertical, 12)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private var controls: some View {
        VStack(spacing: 10) {
            // Timeline row keeps the scrubber wide instead of fighting the
            // buttons for space.
            HStack(spacing: 10) {
                Text(time(state.position)).monospacedDigit().foregroundStyle(.secondary)
                Slider(value: Binding(get: { state.position }, set: { state.seek(to: $0) }), in: 0...max(state.duration, 1))
                Text("−\(time(max(state.duration - state.position, 0)))").monospacedDigit().foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Button { state.togglePause() } label: {
                    Image(systemName: state.paused ? "play.fill" : "pause.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(state.paused ? "Play" : "Pause")

                Button { state.seek(by: -10) } label: { Image(systemName: "gobackward.10") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Back 10 Seconds")

                Button { state.seek(by: 10) } label: { Image(systemName: "goforward.10") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Forward 10 Seconds")

                Button { Task { await switchTo(state.currentIndex - 1) } } label: { Image(systemName: "chevron.left.2") }
                    .disabled(!state.hasPrevious || isSwitching)
                    .keyboardShortcut("p", modifiers: [])
                    .help("Previous Episode (P)")

                Button { Task { await switchTo(state.currentIndex + 1) } } label: { Image(systemName: "chevron.right.2") }
                    .disabled(!state.hasNext || isSwitching)
                    .keyboardShortcut("n", modifiers: [])
                    .help("Next Episode (N)")

                if state.episodes.count > 1 {
                    episodeMenu
                }

                Spacer(minLength: 12)

                if !state.chapters.isEmpty {
                    chapterMenu
                }
                if state.currentEpisode.versions.count > 1 {
                    versionMenu
                }
                speedMenu
                audioMenu
                subtitleMenu
                volumeControl
                Button { toggleFullscreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .keyboardShortcut("f", modifiers: [])
                    .help("Enter Full Screen (F)")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    /// Quick jump between episodes with their category labels so specials
    /// and music are distinguishable without leaving the player.
    private var episodeMenu: some View {
        Menu {
            ForEach(Array(state.episodes.enumerated()), id: \.element.id) { index, item in
                Button {
                    Task { await switchTo(index) }
                } label: {
                    if index == state.currentIndex {
                        Label(episodeMenuItemLabel(item), systemImage: "checkmark")
                    } else {
                        Text(episodeMenuItemLabel(item))
                    }
                }
                .disabled(index == state.currentIndex)
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .fixedSize()
        .help("Jump to Episode")
    }

    private func episodeMenuItemLabel(_ item: EpisodeMedia) -> String {
        let episode = item.episode
        let label = switch episode.kind {
        case .regular: episode.numberText.map { "Episode \($0)" } ?? "Movie"
        case .special: "SP \(episode.numberText ?? "")"
        case .opening: "NCOP"
        case .ending: "NCED"
        case .music: "Music \(episode.numberText ?? "")"
        case .trailer: "Trailer"
        case .extra: "Extra"
        }
        return label.trimmingCharacters(in: .whitespaces)
    }

    /// Alternative encodes of the same episode (DoVi / SDR / …).
    private var versionMenu: some View {
        Menu {
            ForEach(state.currentEpisode.versions) { file in
                Button {
                    state.switchVersion(to: file)
                } label: {
                    if file.id == state.currentEpisode.mediaFile.id {
                        Label(versionLabel(file), systemImage: "checkmark")
                    } else {
                        Text(versionLabel(file))
                    }
                }
            }
        } label: {
            Image(systemName: "square.stack.3d.up")
        }
        .fixedSize()
        .help("Video Version — default picks SDR when available because macOS players cannot render Dolby Vision metadata")
    }

    private func versionLabel(_ file: MediaFile) -> String {
        let name = (file.relativePath as NSString).lastPathComponent
        let tokens = ["dovi", "dolby vision", "hdr10", "hdr", "sdr", "2160p", "1080p", "720p", "60fps"]
        let found = tokens.filter { name.lowercased().contains($0) }.prefix(2)
        if found.isEmpty {
            return ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file)
        }
        return found.map { $0.uppercased() }.joined(separator: " · ")
    }

    private var audioMenu: some View {
        Menu {
            ForEach(state.audioTracks) { track in
                Button { state.controller?.selectAudio(id: track.id) } label: {
                    if state.audioID == track.id { Label(track.displayName, systemImage: "checkmark") }
                    else { Text(track.displayName) }
                }
            }
        } label: { Image(systemName: "waveform") }
        .help("Audio Track")
    }

    private var chapterMenu: some View {
        Menu {
            ForEach(state.chapters) { chapter in
                Button {
                    state.selectChapter(chapter.index)
                } label: {
                    if state.currentChapter == chapter.index {
                        Label("\(time(chapter.startTime))  \(chapter.title)", systemImage: "checkmark")
                    } else {
                        Text("\(time(chapter.startTime))  \(chapter.title)")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                if let current = state.currentChapter, state.chapters.indices.contains(current) {
                    Text(state.chapters[current].title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: 120)
        .fixedSize()
        .help("Chapters")
    }

    private var subtitleMenu: some View {
        Menu {
            Button("Off") { state.controller?.selectSubtitle(id: nil) }
            Divider()
            ForEach(state.subtitleTracks) { track in
                Button { state.controller?.selectSubtitle(id: track.id) } label: {
                    if state.subtitleID == track.id { Label(track.displayName, systemImage: "checkmark") }
                    else { Text(track.displayName) }
                }
            }
            Divider()
            Menu("Subtitle Delay") {
                Button("Earlier 0.5s") { state.nudgeSubtitleDelay(-0.5) }
                Button("Later 0.5s") { state.nudgeSubtitleDelay(0.5) }
                Button("Reset") { state.resetSubtitleDelay() }
                if state.subtitleDelay != 0 {
                    Text("Current: \(String(format: "%+.1f", state.subtitleDelay))s").foregroundStyle(.secondary)
                }
            }
            Menu("Audio Delay") {
                Button("Earlier 0.1s") { state.nudgeAudioDelay(-0.1) }
                Button("Later 0.1s") { state.nudgeAudioDelay(0.1) }
                Button("Reset") { state.resetAudioDelay() }
                if state.audioDelay != 0 {
                    Text("Current: \(String(format: "%+.1f", state.audioDelay))s").foregroundStyle(.secondary)
                }
            }
            Divider()
            Button("Load External Subtitle…") { chooseExternalSubtitle() }
        } label: { Image(systemName: "captions.bubble") }
        .help("Subtitle Track, Delays, and External Files")
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { value in
                Button {
                    state.setSpeed(value)
                } label: {
                    if abs(state.speed - value) < 0.01 {
                        Label(speedLabel(value), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(value))
                    }
                }
            }
        } label: {
            Text(speedLabel(state.speed)).monospacedDigit()
        }
        .fixedSize()
        .help("Playback Speed")
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill")
            Slider(value: Binding(
                get: { state.volume },
                set: { state.setVolume($0) }
            ), in: 0...130)
            .frame(width: 76)
        }
        .help("Volume")
    }

    private func speedLabel(_ value: Double) -> String {
        abs(value - 1.0) < 0.01 ? "1×" : String(format: "%g×", value)
    }

    private func scheduleSmokeTest() {
        Task { @MainActor in
            func capture(_ path: String) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", path]
                try? process.run()
                process.waitUntilExit()
            }
            try? await Task.sleep(for: .seconds(4))
            let window = state.controller?.view.window
            if window?.styleMask.contains(.fullScreen) == true {
                toggleFullscreen()
                try? await Task.sleep(for: .seconds(2))
            }
            capture("/tmp/ag_windowed.png")
            Self.printSmokeState("windowed", state: state)
            toggleFullscreen()
            try? await Task.sleep(for: .seconds(3))
            capture("/tmp/ag_fullscreen.png")
            Self.printSmokeState("fullscreen", state: state)
            try? await Task.sleep(for: .seconds(1))
            NSApp.terminate(nil)
        }
    }

    private static func printSmokeState(_ label: String, state: PlayerState) {
        let controller = state.controller
        let windowFrame = controller?.view.window?.frame ?? .zero
        let viewBounds = controller?.view.bounds ?? .zero
        let drawable = (controller?.view.layer as? CAMetalLayer)?.drawableSize ?? .zero
        let rendered = controller?.renderedOutputSize
        let renderedText = rendered.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
        let fullscreen = controller?.view.window?.styleMask.contains(.fullScreen) ?? false
        print("SMOKE \(label): window=\(Int(windowFrame.width))x\(Int(windowFrame.height)) fs=\(fullscreen) view=\(Int(viewBounds.width))x\(Int(viewBounds.height)) drawable=\(Int(drawable.width))x\(Int(drawable.height)) mpvOut=\(renderedText) pos=\(Int(state.position))/\(Int(state.duration))")
    }

    private func revealControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            // Keep controls available while paused, loading, broken, or hovered.
            if !state.paused, !state.isLoading, state.errorMessage == nil, !isHoveringControls {
                withAnimation { controlsVisible = false }
            }
        }
    }

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            withAnimation { controlsVisible = false }
        } else {
            revealControls()
        }
    }

    /// Fullscreen must target THIS window — with the library window also
    /// open, NSApp.keyWindow is not reliably the player. SwiftUI windows are
    /// not created with .fullScreenPrimary, without which toggleFullScreen
    /// silently does nothing.
    private func toggleFullscreen() {
        guard let window = state.controller?.view.window ?? NSApp.keyWindow else { return }
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
    }

    /// ⌘⇧D toggles the HDR diagnostics panel; ⌘⇧H toggles the experimental
    /// EDR pipeline (may corrupt output until the renderer supports a
    /// constant HDR format — diagnostics tool, not a feature yet).
    private var diagnosticsShortcuts: some View {
        Group {
            Button("Toggle Diagnostics") { showDiagnostics.toggle() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Toggle HDR Output") {
                MPVPlayerController.experimentalEDRPipelineEnabled.toggle()
                state.reconfigureColorOutput()
            }
                .keyboardShortcut("h", modifiers: [.command, .shift])
        }
        .accessibilityHidden(true)
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            section("Video",
                "\(state.colorProfile?.codec?.uppercased() ?? "—")",
                "Pixel: \(state.colorProfile?.pixelFormat ?? "—")",
                "Bit depth: \(state.colorProfile.map { "\($0.bitDepth ?? 8)-bit" } ?? "—")",
                "HW decode: \((state.colorProfile?.hardwareDecoder).flatMap { $0.isEmpty ? nil : $0 } ?? "no")")

            section("Color",
                "Primaries: \(state.colorProfile?.primariesDisplayName ?? "—")",
                "Transfer: \(state.colorProfile?.transferDisplayName ?? "—")",
                "Matrix: \(state.colorProfile?.matrix ?? "—")")

            section("HDR",
                state.colorProfile?.hdrFormat.displayName ?? "Unknown",
                state.colorProfile?.signalPeak.map { "Signal peak: \($0)" } ?? "Signal peak: —",
                "Release hint: \(state.colorProfile?.releaseHint ?? "none")")

            section("Output",
                "Display: \(state.displayInfo.name ?? "—")",
                "EDR headroom: \(state.displayInfo.headroom.map { String(format: "%.1f×", $0) } ?? "1.0× (SDR)")",
                "Potential: \(state.displayInfo.potentialHeadroom.map { String(format: "%.1f×", $0) } ?? "—")",
                "Pipeline: mpv gpu (mac OpenGL) → EDR / Tone Mapping → \(outputMode)",
                "Mode: \(outputMode)")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.trailing, 20)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var outputMode: String {
        guard MPVPlayerController.experimentalEDRPipelineEnabled else {
            if let profile = state.colorProfile, profile.isHDR {
                return "HDR → SDR tone mapping"
            }
            return "SDR"
        }
        if let profile = state.colorProfile, profile.isHDR {
            return state.hdrOutputActive ? "EDR HDR (experimental)" : "HDR → SDR tone mapping"
        }
        return "SDR"
    }

    private func section(_ title: String, _ lines: String...) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            ForEach(lines, id: \.self) { Text($0) }
        }
    }

    private func chooseExternalSubtitle() {
        let panel = NSOpenPanel()
        panel.title = "Choose a subtitle file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.init(filenameExtension: "srt"), .init(filenameExtension: "ass"), .init(filenameExtension: "ssa"), .init(filenameExtension: "sub")].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { state.addExternalSubtitle(url: url) }
        revealControls()
    }

    private func switchTo(_ index: Int) async {
        guard !isSwitching else { return }
        guard state.episodes.indices.contains(index) else { return }
        isSwitching = true
        defer { isSwitching = false }
        if let finished = state.switchEpisode(to: index) {
            await model.finishPlaybackSession(
                episode: finished.oldEpisode,
                startedAt: finished.startedAt,
                watchedDuration: finished.watchedDuration,
                position: finished.position,
                duration: finished.duration
            )
        }
        revealControls()
    }

    private func advanceAfterFinish() async {
        guard state.hasNext else { return }
        await switchTo(state.currentIndex + 1)
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
