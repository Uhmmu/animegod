import AnimeGodCore
import AppKit
import Foundation
import Libmpv

struct MediaTrack: Identifiable, Hashable {
    let id: Int64
    let type: String
    let title: String
    let language: String?

    var displayName: String {
        if let language, !language.isEmpty { return "\(title) · \(language)" }
        return title
    }
}

struct MediaChapter: Identifiable, Hashable {
    let index: Int
    let title: String
    let startTime: Double

    var id: Int { index }
}

@MainActor
protocol MPVPlayerControllerDelegate: AnyObject {
    func playerDidUpdate(position: Double?, duration: Double?, paused: Bool?)
    func playerDidUpdateTracks(audio: [MediaTrack], subtitles: [MediaTrack], audioID: Int64?, subtitleID: Int64?)
    func playerDidUpdateChapters(_ chapters: [MediaChapter], current: Int?)
    func playerDidUpdatePlaybackState(speed: Double?, volume: Double?, subtitleDelay: Double?, audioDelay: Double?)
    func playerDidUpdateColor(_ profile: VideoColorProfile)
    func playerLoadingStateDidChange(isLoading: Bool)
    func playerDidFail(message: String)
    func playerDidFinishFile()
}

/// A small libmpv adapter. Rendering follows MPVKit's LGPL macOS Metal demo;
/// application state and controls remain independent of the C API.
@MainActor
final class MPVPlayerController: NSViewController {
    weak var delegate: MPVPlayerControllerDelegate?
    var initialURL: URL?
    var initialPosition: Double = 0

    nonisolated(unsafe) private var mpv: OpaquePointer?
    private let metalLayer = StableMetalLayer()
    private var lastSurfaceSize: CGSize = .zero
    private var widResetTask: Task<Void, Never>?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        view.wantsLayer = true
        view.layer = metalLayer
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrameChange),
            name: NSView.frameDidChangeNotification,
            object: view
        )
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupMPV()
        if let initialURL { play(url: initialURL, position: initialPosition) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateSurface()
    }

    @objc private func handleFrameChange() {
        updateSurface()
    }

    private func updateSurface() {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        metalLayer.frame = bounds
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
        // MoltenVK swapchains created through mpv's wid path never follow a
        // live resize (mpvOut stays frozen at the source size). Re-setting
        // wid makes mpv rebuild the whole VO against the new layer size.
        if size != lastSurfaceSize, mpv != nil {
            lastSurfaceSize = size
            scheduleWidReset()
        }
    }

    private func scheduleWidReset() {
        widResetTask?.cancel()
        guard let mpvPointer = mpv else { return }
        let layerPointer = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque())))
        widResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.mpv == mpvPointer else { return }
            // mpv ignores property writes that set the same value, so cycle
            // wid through "detached" and back to force a full VO rebuild —
            // the new swapchain then picks up the current layer size.
            var zero: Int64 = 0
            mpv_set_property(mpvPointer, "wid", MPV_FORMAT_INT64, &zero)
            try? await Task.sleep(for: .milliseconds(120))
            guard self.mpv == mpvPointer else { return }
            var pointer = layerPointer
            mpv_set_property(mpvPointer, "wid", MPV_FORMAT_INT64, &pointer)
        }
    }

    func setPaused(_ paused: Bool) {
        var flag: Int32 = paused ? 1 : 0
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func seek(to position: Double) {
        command("seek", arguments: [String(position), "absolute", "exact"])
    }

    func seek(by offset: Double) {
        command("seek", arguments: [String(offset), "relative", "exact"])
    }

    func selectAudio(id: Int64) { setInt64("aid", id) }
    func selectSubtitle(id: Int64?) { id.map { setInt64("sid", $0) } ?? setString("sid", "no") }

    func setSpeed(_ speed: Double) { setDouble("speed", speed) }
    func setVolume(_ volume: Double) { setDouble("volume", volume) }
    func setSubtitleDelay(_ delay: Double) { setDouble("sub-delay", delay) }
    func setAudioDelay(_ delay: Double) { setDouble("audio-delay", delay) }

    func selectChapter(_ index: Int) { setInt64("chapter", Int64(index)) }
    func stepChapter(_ offset: Int) { command("add", arguments: ["chapter", String(offset)]) }

    /// Registers an external subtitle file with the running player.
    func addSubtitle(url: URL, title: String? = nil) {
        var arguments = [url.absoluteString, "auto"]
        if let title { arguments.append(title) }
        command("sub-add", arguments: arguments)
    }

    /// Replaces the playing file, keeping the mpv instance (and its window) alive.
    func play(url: URL, position: Double) {
        var options: [String] = []
        if position > 0 { options.append("start=\(position)") }
        command("loadfile", arguments: [url.absoluteString, "replace", "-1", options.joined(separator: ",")])
    }

    private func setupMPV() {
        guard let handle = mpv_create() else {
            delegate?.playerDidFail(message: "Could not create the playback engine.")
            return
        }
        mpv = handle
        setOption("vo", "gpu-next")
        setOption("gpu-api", "vulkan")
        setOption("gpu-context", "moltenvk")
        setOption("hwdec", "videotoolbox")
        setOption("ytdl", "no")
        setOption("subs-match-os-language", "yes")
        setOption("subs-fallback", "yes")
        setOption("input-media-keys", "yes")
        if Self.experimentalEDRPipelineEnabled {
            // mpv-native EDR: let it configure its layer and tone-mapping
            // from the display; must never be toggled at runtime.
            setOption("target-colorspace-hint", "yes")
        }
        // Pick up sidecar subtitle files that sit next to the video or in a
        // "subs" folder without requiring the user to load them manually.
        setOption("sub-auto", "fuzzy")
        setOption("sub-file-paths", "subs:subtitles:字幕")
        var layerPointer = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque())))
        let windowStatus = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &layerPointer)
        guard windowStatus >= 0 else {
            delegate?.playerDidFail(message: errorMessage(for: windowStatus))
            return
        }
        let initializeStatus = mpv_initialize(handle)
        guard initializeStatus >= 0 else {
            delegate?.playerDidFail(message: errorMessage(for: initializeStatus))
            return
        }

        observe("time-pos", format: MPV_FORMAT_DOUBLE)
        observe("duration", format: MPV_FORMAT_DOUBLE)
        observe("pause", format: MPV_FORMAT_FLAG)
        observe("track-list/count", format: MPV_FORMAT_INT64)
        observe("aid", format: MPV_FORMAT_INT64)
        observe("sid", format: MPV_FORMAT_INT64)
        observe("chapter", format: MPV_FORMAT_INT64)
        observe("chapter-list/count", format: MPV_FORMAT_INT64)
        observe("speed", format: MPV_FORMAT_DOUBLE)
        observe("volume", format: MPV_FORMAT_DOUBLE)
        observe("sub-delay", format: MPV_FORMAT_DOUBLE)
        observe("audio-delay", format: MPV_FORMAT_DOUBLE)
        observe("video-params/pixelformat", format: MPV_FORMAT_STRING)
        observe("video-params/primaries", format: MPV_FORMAT_STRING)
        observe("video-params/gamma", format: MPV_FORMAT_STRING)
        // The wakeup callback runs on mpv's core thread. Typing it explicitly
        // as a C function pointer keeps it non-isolated; otherwise Swift 6
        // infers MainActor isolation for the literal and the runtime trap
        // fires the moment mpv calls it off the main thread.
        let wakeupHandler: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
            guard let context else { return }
            let controller = Unmanaged<MPVPlayerController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.drainEvents() }
        }
        mpv_set_wakeup_callback(handle, wakeupHandler, Unmanaged.passUnretained(self).toOpaque())
    }

    private func observe(_ name: String, format: mpv_format) {
        mpv_observe_property(mpv, 0, name, format)
    }

    private func drainEvents() {
        guard let mpv else { return }
        var position: Double?
        var duration: Double?
        var paused: Bool?
        var needsTracks = false
        var needsChapters = false
        var playbackState = false
        var needsColor = false
        var finishedFile = false
        while let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let raw = event.pointee.data else { continue }
                let property = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
                let name = String(cString: property.name)
                guard let data = property.data else { continue }
                switch name {
                case "time-pos": position = data.assumingMemoryBound(to: Double.self).pointee
                case "duration": duration = data.assumingMemoryBound(to: Double.self).pointee
                case "pause": paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                case "track-list/count", "aid", "sid": needsTracks = true
                case "chapter", "chapter-list/count": needsChapters = true
                case "speed", "volume", "sub-delay", "audio-delay": playbackState = true
                case "video-params/pixelformat", "video-params/primaries", "video-params/gamma": needsColor = true
                default: break
                }
            case MPV_EVENT_START_FILE:
                delegate?.playerLoadingStateDidChange(isLoading: true)
            case MPV_EVENT_FILE_LOADED:
                delegate?.playerLoadingStateDidChange(isLoading: false)
                needsTracks = true
                needsChapters = true
                playbackState = true
                needsColor = true
            case MPV_EVENT_END_FILE:
                delegate?.playerLoadingStateDidChange(isLoading: false)
                if let raw = event.pointee.data {
                    let end = raw.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if end.error < 0 {
                        delegate?.playerDidFail(message: errorMessage(for: end.error))
                    } else if end.reason == MPV_END_FILE_REASON_EOF {
                        finishedFile = true
                    }
                }
            default: break
            }
        }
        if position != nil || duration != nil || paused != nil {
            delegate?.playerDidUpdate(position: position, duration: duration, paused: paused)
        }
        if needsTracks { publishTracks() }
        if needsChapters { publishChapters() }
        if playbackState { publishPlaybackState() }
        if needsColor { publishColorProfile() }
        if finishedFile { delegate?.playerDidFinishFile() }
    }

    private func publishTracks() {
        let count = getInt64("track-list/count") ?? 0
        var audio: [MediaTrack] = []
        var subtitles: [MediaTrack] = []
        for index in 0..<count {
            guard let type = getString("track-list/\(index)/type"),
                  let id = getInt64("track-list/\(index)/id") else { continue }
            let fallback = type == "audio" ? "Audio \(audio.count + 1)" : "Subtitle \(subtitles.count + 1)"
            let track = MediaTrack(
                id: id,
                type: type,
                title: getString("track-list/\(index)/title") ?? fallback,
                language: getString("track-list/\(index)/lang")
            )
            if type == "audio" { audio.append(track) }
            if type == "sub" { subtitles.append(track) }
        }
        delegate?.playerDidUpdateTracks(
            audio: audio,
            subtitles: subtitles,
            audioID: getInt64("aid"),
            subtitleID: getInt64("sid")
        )
    }

    private func publishChapters() {
        let count = Int(getInt64("chapter-list/count") ?? 0)
        var chapters: [MediaChapter] = []
        for index in 0..<count {
            let title = getString("chapter-list/\(index)/title") ?? "Chapter \(index + 1)"
            let start = getDouble("chapter-list/\(index)/time") ?? 0
            chapters.append(MediaChapter(index: index, title: title, startTime: start))
        }
        let current = getInt64("chapter")
        delegate?.playerDidUpdateChapters(chapters, current: current.map(Int.init))
    }

    private func publishPlaybackState() {
        delegate?.playerDidUpdatePlaybackState(
            speed: getDouble("speed"),
            volume: getDouble("volume"),
            subtitleDelay: getDouble("sub-delay"),
            audioDelay: getDouble("audio-delay")
        )
    }

    /// Gathers real color metadata from mpv so HDR decisions (and the
    /// diagnostics panel) are based on the decoded signal, not filenames.
    private func publishColorProfile() {
        let profile = VideoColorProfile(
            codec: getString("video-format"),
            pixelFormat: getString("video-params/pixelformat"),
            bitDepth: VideoColorProfile.bitDepth(fromPixelFormat: getString("video-params/pixelformat")),
            primaries: getString("video-params/primaries"),
            transfer: getString("video-params/gamma"),
            matrix: getString("video-params/matrix"),
            signalPeak: getDouble("video-params/sig-peak"),
            hardwareDecoder: getString("hwdec-current"),
            releaseHint: releaseHint
        )
        delegate?.playerDidUpdateColor(profile)
    }

    private var releaseHint: String? {
        guard let path = currentFilePath else { return nil }
        let lower = path.lowercased()
        if lower.contains("dovi") || lower.contains("dolby") || lower.contains("_dv_") { return "DoVi" }
        return nil
    }

    private var currentFilePath: String? {
        guard let value = getString("path") else { return nil }
        return value
    }

    /// The size mpv actually renders at (post-scale output), proving the
    /// swapchain follows the layer through runtime resizes.
    var renderedOutputSize: (width: Double, height: Double)? {
        guard let width = getDouble("dwidth"),
              let height = getDouble("dheight"),
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Experimental end-to-end EDR path. mpv's native macOS mechanism
    /// (`target-colorspace-hint`) lets it configure its own layer for EDR and
    /// tone-map to the display — it must be set BEFORE mpv_initialize, so the
    /// toggle only takes effect for players created after it changes.
    static var experimentalEDRPipelineEnabled = false

    private func setOption(_ name: String, _ value: String) {
        mpv_set_option_string(mpv, name, value)
    }

    private func setString(_ name: String, _ value: String) {
        mpv_set_property_string(mpv, name, value)
    }

    private func setInt64(_ name: String, _ value: Int64) {
        var value = value
        mpv_set_property(mpv, name, MPV_FORMAT_INT64, &value)
    }

    private func setDouble(_ name: String, _ value: Double) {
        var value = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &value)
    }

    private func getInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    private func getDouble(_ name: String) -> Double? {
        var value: Double = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    private func getString(_ name: String) -> String? {
        guard let value = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    private func command(_ name: String, arguments: [String]) {
        var strings: [UnsafePointer<CChar>?] = ([name] + arguments).map { value in
            value.withCString { pointer in UnsafePointer(strdup(pointer)) }
        }
        strings.append(nil)
        defer {
            for pointer in strings.compactMap({ $0 }) {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }
        strings.withUnsafeMutableBufferPointer { buffer in
            let status = mpv_command(mpv, buffer.baseAddress)
            if status < 0 { delegate?.playerDidFail(message: errorMessage(for: status)) }
        }
    }

    private func errorMessage(for status: Int32) -> String {
        let detail = mpv_error_string(status).map { String(cString: $0) } ?? "unknown error"
        return "Playback failed: \(detail)"
    }

    deinit {
        if let mpv {
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
        }
    }
}

private final class StableMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if newValue.width > 1, newValue.height > 1 { super.drawableSize = newValue }
        }
    }
}
