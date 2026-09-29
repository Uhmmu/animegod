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
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .contentShape(.rect)
        .onTapGesture { toggleControls() }
        .task {
            // Nothing else tells iOS a film is on: mpv renders into our own
            // layer, so the idle timer has to be held off by hand.
            UIApplication.shared.isIdleTimerDisabled = true
            revealControls()
            await beginHandoff(force: false)
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

    private var work: LinkWork { state.work }

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

                trackMenu(
                    title: String(localized: "Subtitles"),
                    icon: "captions.bubble",
                    tracks: state.subtitleTracks,
                    selection: state.subtitleID,
                    allowsOff: true
                ) { controller?.select(subtitleID: $0) }

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
    private func beginHandoff(force: Bool) async {
        guard let result = await model.claim(state.episode, force: force) else {
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

        func playerDidFail(message: String) {
            state.errorMessage = message
            state.isLoading = false
        }

        func playerDidFinishFile() {
            state.paused = true
        }
    }
}
