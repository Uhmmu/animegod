import AnimeGodCore
import SwiftUI

/// The phone's player: the video, and chrome that gets out of the way.
struct MobilePlayerScreen: View {
    @EnvironmentObject private var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: MobilePlayerState

    @State private var controller: MobilePlayerController?
    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubValue: Double = 0
    /// Nothing plays until the Mac has handed the episode over. Starting from
    /// the cached row and correcting afterwards would mean playing the wrong
    /// ten seconds first, and leaving the Mac playing it too.
    @State private var handoff: LinkHandoffState?
    @State private var conflict: LinkHandoffConflict?
    @State private var sendsBackToMac = false
    @State private var danmakuCanvas: MobileDanmakuCanvas?
    /// When the screen was last tapped, so a hold that follows one can ask
    /// for a higher rate than a hold on its own.
    @State private var lastTapAt: Date = .distantPast
    @State private var speedBeforeBoost: Double?
    @StateObject private var danmakuSettings = MobileDanmakuSettingsStore()
    @StateObject private var orientation = MobileOrientation()
    @State private var showsDanmakuPanel = false

    init(episode: LinkEpisode, work: LinkWork, model: MobileModel) {
        _state = StateObject(wrappedValue: MobilePlayerState(episode: episode, work: work, model: model))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if handoff != nil {
                MobilePlayerHost(state: state) { ready in
                    controller = ready
                    start(on: ready)
                }
                .ignoresSafeArea()

                // Sized to the picture, not the screen. In landscape the two
                // coincide; in portrait the video is a letterboxed strip, and
                // a full-screen canvas both scales the font off the wrong
                // dimension — 44pt instead of ~14 — and scrolls comments
                // across the black bars.
                MobileDanmakuOverlay(
                    comments: state.danmakuComments,
                    isVisible: state.danmakuEnabled,
                    settings: danmakuSettings.settings,
                    videoAspect: state.videoAspect
                ) { canvas in
                    danmakuCanvas = canvas
                    // The clock is anchored on player samples, never on a
                    // timer of its own.
                    state.onPlaybackSample = { [weak canvas] position, speed, paused in
                        canvas?.playbackSample(position: position, speed: speed, paused: paused)
                    }
                }
                // The whole screen, like the video layer — the canvas works
                // out where the picture is inside it and keeps its lanes and
                // its type size there, while comments travel the full width.
                // Fitting the *view* to the picture instead put the seam they
                // enter and leave on 80 points inside the bezel, and, because
                // this view respected the safe area while the video layer did
                // not, left it 18 points inside the picture as well (measured:
                // a 679×382 canvas over a 715×402 picture).
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            if state.isLoading || handoff == nil {
                VStack(spacing: 10) {
                    ProgressView().tint(.white).controlSize(.large)
                    if handoff == nil, conflict == nil {
                        Text("Taking over from your Mac…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }

            if let conflict {
                ContentUnavailableView {
                    Label("Already Playing", systemImage: "play.slash")
                } description: {
                    Text("\(conflict.holder) is watching this episode.")
                } actions: {
                    Button("Take Over") {
                        self.conflict = nil
                        Task { await beginHandoff(force: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") { dismiss() }
                }
                .foregroundStyle(.white)
            } else if let error = state.errorMessage {
                ContentUnavailableView {
                    Label("Playback Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Close") { close() }.buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            } else if showsControls {
                chrome.transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) { rotationHint }
        .animation(.spring(duration: 0.3), value: orientation.suggestion?.rawValue)
        .sheet(isPresented: $showsDanmakuPanel) {
            MobilePlayerStylePanel(store: danmakuSettings, state: state, controller: controller)
        }
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .contentShape(.rect)
        .onTapGesture {
            lastTapAt = .now
            toggleControls()
        }
        // Press and hold to run fast, the way every video app on a phone now
        // works. A tap immediately before the hold asks for more: the second
        // gesture is deliberately harder to reach by accident than the first.
        .onLongPressGesture(minimumDuration: 0.35) { } onPressingChanged: { isPressing in
            isPressing ? beginBoost() : endBoost()
        }
        .overlay(alignment: .top) { boostBadge }
        .task {
            // Nothing else tells iOS a film is on: mpv renders into our own
            // layer, so the idle timer has to be held off by hand.
            UIApplication.shared.isIdleTimerDisabled = true
            orientation.start()
            revealControls()
            await beginHandoff(force: false)
            // After the handoff, so a slow match never delays the picture.
            // Both are additive: if neither arrives, playback is unaffected.
            Task { await state.loadDanmaku() }
            Task { await state.loadExternalSubtitles(into: controller) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                // Also renews this device's claim on the Mac, so no separate
                // heartbeat is needed.
                await state.save()
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // Landscape belongs to the player. The rest of the app is a
            // portrait interface, so leaving with the screen sideways means
            // browsing the library on its side.
            orientation.restoreIfForced()
            orientation.stop()
            hideTask?.cancel()
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            controls
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.65), .clear, .black.opacity(0.8)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
    }

    private var header: some View {
        HStack(alignment: .top) {
            Button { close() } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .padding(10)
                    .background(.ultraThinMaterial, in: .circle)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(work.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(Episode.localizedLabel(state.episode.label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)

            Spacer(minLength: 0)

            Button {
                sendsBackToMac = true
                close()
            } label: {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.headline)
                    .padding(10)
                    .background(.ultraThinMaterial, in: .circle)
            }
            .foregroundStyle(.white)

            Button { state.setWatched(!state.isWatched) } label: {
                Image(systemName: state.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.headline)
                    .padding(10)
                    .background(.ultraThinMaterial, in: .circle)
            }
            .foregroundStyle(state.isWatched ? .green : .white)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .foregroundStyle(.white)
    }

    /// Appears only when the phone is being held one way and the interface
    /// is pinned another — which can only happen with the system's rotation
    /// lock on. With the lock off iOS has already turned the screen, there is
    /// nothing to disagree about, and this is never drawn.
    @ViewBuilder
    private var rotationHint: some View {
        if let suggestion = orientation.suggestion {
            Button { orientation.takeSuggestion() } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: .circle)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                    .shadow(radius: 8)
            }
            .padding(.trailing, 14)
            .padding(.top, showsControls ? 62 : 14)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel(Text("Rotate to match how you are holding the phone"))
        }
    }

    private var work: LinkWork { state.work }

    /// The rate badge, so the hold is visibly doing something.
    @ViewBuilder
    private var boostBadge: some View {
        if let rate = state.boostedSpeed {
            Label(String(format: "%g×", rate), systemImage: "forward.fill")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: .capsule)
                .padding(.top, 20)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Hold for double speed; tap first, then hold, for triple.
    ///
    /// The tap window is short on purpose. It is long enough to be a
    /// deliberate tap-then-hold and short enough that pausing with a tap and
    /// then settling a thumb on the screen does not silently triple the rate.
    private func beginBoost() {
        guard state.boostedSpeed == nil, !state.paused else { return }
        let rate = Date.now.timeIntervalSince(lastTapAt) < 0.6 ? 3.0 : 2.0
        speedBeforeBoost = state.speed
        state.boostedSpeed = rate
        controller?.setSpeed(rate)
        // One knock, so the hold is felt rather than only seen — the picture
        // is what the eyes are on.
        UIImpactFeedbackGenerator(style: rate > 2 ? .heavy : .medium).impactOccurred()
    }

    private func endBoost() {
        guard let previous = speedBeforeBoost, state.boostedSpeed != nil else { return }
        state.boostedSpeed = nil
        speedBeforeBoost = nil
        controller?.setSpeed(previous)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 34) {
                Button { controller?.seek(by: -10) } label: {
                    Image(systemName: "gobackward.10").font(.title2)
                }
                Button { togglePause() } label: {
                    Image(systemName: state.paused ? "play.fill" : "pause.fill")
                        .font(.largeTitle)
                        .frame(width: 54, height: 54)
                }
                Button { controller?.seek(by: 10) } label: {
                    Image(systemName: "goforward.10").font(.title2)
                }
            }
            .foregroundStyle(.white)

            timeline

            HStack(spacing: 18) {
                trackMenu(
                    title: String(localized: "Audio"),
                    icon: "speaker.wave.2",
                    tracks: state.audioTracks,
                    selection: state.audioID
                ) { controller?.select(audioID: $0) }

                subtitleMenu

                Button {
                    state.danmakuEnabled.toggle()
                } label: {
                    Label(
                        state.danmakuComments.isEmpty
                            ? String(localized: "Danmaku")
                            : String(localized: "\(state.danmakuComments.count)"),
                        systemImage: state.danmakuEnabled ? "text.bubble.fill" : "text.bubble"
                    )
                    .font(.caption)
                }
                .opacity(state.danmakuComments.isEmpty ? 0.5 : 1)
                .disabled(state.danmakuComments.isEmpty)

                Button { showsDanmakuPanel = true } label: {
                    Label(String(localized: "Style"), systemImage: "slider.horizontal.3")
                        .font(.caption)
                }
                .opacity(state.danmakuComments.isEmpty ? 0.5 : 1)
                .disabled(state.danmakuComments.isEmpty)

                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            state.speed = rate
                            controller?.setSpeed(rate)
                        } label: {
                            if state.speed == rate { Label(String(format: "%.2g×", rate), systemImage: "checkmark") }
                            else { Text(verbatim: String(format: "%.2g×", rate)) }
                        }
                    }
                } label: {
                    Label(String(format: "%.2g×", state.speed), systemImage: "speedometer")
                        .font(.caption)
                }

                Spacer()

                // The deliberate one. The floating hint covers "I turned the
                // phone and nothing happened"; this covers a phone lying flat
                // on a table, where the accelerometer has no opinion.
                Button { orientation.toggle() } label: {
                    Image(systemName: orientation.current.isPortrait
                          ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
                        .font(.callout)
                }
                .accessibilityLabel(Text("Rotate"))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var timeline: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { state.isScrubbing ? scrubValue : state.position },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(state.duration, 1),
                onEditingChanged: { editing in
                    state.isScrubbing = editing
                    if editing {
                        scrubValue = state.position
                        hideTask?.cancel()
                    } else {
                        controller?.seek(to: scrubValue)
                        state.position = scrubValue
                        revealControls()
                    }
                }
            )
            .tint(.white)

            HStack {
                Text(verbatim: formatTime(state.isScrubbing ? scrubValue : state.position))
                Spacer()
                Text(verbatim: "-\(formatTime(max(0, state.duration - (state.isScrubbing ? scrubValue : state.position))))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    /// Embedded tracks and the Mac's sidecars in one menu.
    ///
    /// They are the same thing to the viewer; that one came out of the
    /// Matroska and the other off assrt is not their problem.
    @ViewBuilder
    private var subtitleMenu: some View {
        if !state.subtitleTracks.isEmpty || !state.externalSubtitles.isEmpty {
            Menu {
                Button {
                    controller?.select(subtitleID: 0)
                } label: {
                    if state.subtitleID == nil || state.subtitleID == 0 {
                        Label("Off", systemImage: "checkmark")
                    } else {
                        Text("Off")
                    }
                }

                if !state.subtitleTracks.isEmpty {
                    Section(String(localized: "In this file")) {
                        ForEach(state.subtitleTracks) { track in
                            Button {
                                controller?.select(subtitleID: track.id)
                            } label: {
                                if state.subtitleID == track.id {
                                    Label(track.displayName, systemImage: "checkmark")
                                } else {
                                    Text(track.displayName)
                                }
                            }
                        }
                    }
                }

                if !state.externalSubtitles.isEmpty {
                    Section(String(localized: "From your Mac")) {
                        ForEach(state.externalSubtitles) { record in
                            Button {
                                Task { await state.select(record, into: controller, model: model) }
                            } label: {
                                let name = [record.language?.displayName, record.releaseGroup]
                                    .compactMap { $0 }
                                    .joined(separator: " · ")
                                let label = name.isEmpty ? record.fileName : name
                                if state.loadedExternalSubtitleID == record.id {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    }
                }
            } label: {
                Label(String(localized: "Subtitles"), systemImage: "captions.bubble").font(.caption)
            }
        }
    }

    @ViewBuilder
    private func trackMenu(
        title: String,
        icon: String,
        tracks: [MobileTrack],
        selection: Int64?,
        allowsOff: Bool = false,
        select: @escaping (Int64) -> Void
    ) -> some View {
        if !tracks.isEmpty {
            Menu {
                if allowsOff {
                    Button {
                        select(0)
                    } label: {
                        if selection == nil || selection == 0 { Label("Off", systemImage: "checkmark") }
                        else { Text("Off") }
                    }
                }
                ForEach(tracks) { track in
                    Button {
                        select(track.id)
                    } label: {
                        if selection == track.id { Label(track.displayName, systemImage: "checkmark") }
                        else { Text(track.displayName) }
                    }
                }
            } label: {
                Label(title, systemImage: icon).font(.caption)
            }
        }
    }

    // MARK: - Actions

    private func togglePause() {
        controller?.setPaused(!state.paused)
        revealControls()
    }

    private func toggleControls() {
        if showsControls {
            withAnimation(.easeOut(duration: 0.2)) { showsControls = false }
            hideTask?.cancel()
        } else {
            revealControls()
        }
    }

    private func revealControls() {
        withAnimation(.easeOut(duration: 0.2)) { showsControls = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !state.paused, !state.isScrubbing else { return }
            withAnimation(.easeOut(duration: 0.25)) { showsControls = false }
        }
    }

    /// Asks the Mac for the episode, then starts.
    ///
    /// A downloaded episode plays whatever the Mac says, including nothing at
    /// all. That is the point of downloading it: the claim is still attempted,
    /// so a reachable Mac still stops playing and still hands over its live
    /// position, but an unreachable one falls back to the cached row rather
    /// than blocking playback on a train.
    private func beginHandoff(force: Bool) async {
        let isOffline = model.offlineURL(for: state.episode) != nil
        guard let result = await model.claim(state.episode, force: force) else {
            if isOffline {
                handoff = LinkHandoffState(
                    position: state.episode.position,
                    duration: state.episode.duration,
                    isWatched: state.episode.isWatched,
                    keepsUnwatched: false,
                    wasPlayingHere: false
                )
                return
            }
            state.errorMessage = String(localized: "Could not reach your Mac.")
            return
        }
        switch result {
        case .success(let handed):
            state.adopt(handed)
            handoff = handed
        case .failure(let held):
            conflict = held
        }
    }

    private func start(on controller: MobilePlayerController) {
        // A local copy wins: no network, no bearer header, no Mac.
        if let local = model.offlineURL(for: state.episode) {
            controller.play(url: local, authorization: nil, position: state.startPosition)
            return
        }
        guard let target = model.playbackTarget(for: state.episode) else {
            state.errorMessage = String(localized: "This phone is not paired with a Mac.")
            return
        }
        controller.play(
            url: target.url,
            authorization: target.authorization,
            position: state.startPosition
        )
    }

    private func close() {
        Task {
            controller?.stop()
            // Offline playback may have had no claim to release; the call is
            // harmless either way and still carries the position, which the
            // outbox keeps if the Mac cannot be reached.

            // Released rather than merely saved: this is what lets the Mac
            // pick the episode back up, and what frees the claim for another
            // device. The position goes with it, so no separate save is needed.
            await model.release(
                episodeID: state.episode.id,
                position: state.livePosition,
                duration: state.duration,
                resumeOnMac: sendsBackToMac
            )
            await model.refresh()
            dismiss()
        }
    }
}

/// Bridges the mpv view controller into SwiftUI.
struct MobilePlayerHost: UIViewControllerRepresentable {
    @ObservedObject var state: MobilePlayerState
    var onReady: (MobilePlayerController) -> Void

    func makeUIViewController(context: Context) -> MobilePlayerController {
        let controller = MobilePlayerController()
        controller.delegate = context.coordinator
        DispatchQueue.main.async { onReady(controller) }
        return controller
    }

    func updateUIViewController(_ controller: MobilePlayerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    @MainActor
    final class Coordinator: MobilePlayerDelegate {
        private let state: MobilePlayerState

        init(state: MobilePlayerState) { self.state = state }

        func playerDidUpdate(position: Double?, duration: Double?, paused: Bool?) {
            state.didUpdate(position: position, duration: duration, paused: paused)
        }

        func playerLoadingStateDidChange(isLoading: Bool) {
            state.isLoading = isLoading
        }

        func playerDidUpdateTracks(audio: [MobileTrack], subtitles: [MobileTrack], audioID: Int64?, subtitleID: Int64?) {
            state.audioTracks = audio
            state.subtitleTracks = subtitles
            state.audioID = audioID
            state.subtitleID = subtitleID
        }

        func playerDidUpdateAspect(_ aspect: Double) {
            state.videoAspect = aspect
        }

        func playerDidFail(message: String) {
            state.errorMessage = message
            state.isLoading = false
        }

        func playerDidFinishFile() {
            state.paused = true
        }
    }
}
