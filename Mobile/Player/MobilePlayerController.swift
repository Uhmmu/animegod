import AnimeGodCore
import AVFoundation
import Foundation
import Libmpv
import UIKit

struct MobileTrack: Identifiable, Hashable {
    let id: Int64
    let type: String
    let title: String
    let language: String?

    var displayName: String {
        if let language, !language.isEmpty { return "\(title) · \(language)" }
        return title
    }
}

@MainActor
protocol MobilePlayerDelegate: AnyObject {
    func playerDidUpdate(position: Double?, duration: Double?, paused: Bool?)
    func playerLoadingStateDidChange(isLoading: Bool)
    func playerDidUpdateTracks(audio: [MobileTrack], subtitles: [MobileTrack], audioID: Int64?, subtitleID: Int64?)
    /// The video's display aspect, once mpv reports it. The danmaku overlay
    /// needs it: comments belong over the picture, not over the letterbox.
    func playerDidUpdateAspect(_ aspect: Double)
    func playerDidFail(message: String)
    func playerDidFinishFile()
}

/// libmpv on the phone.
///
/// The same engine as the Mac, which is the whole reason nothing is
/// transcoded: mpv opens the link's HTTP URL itself, issues its own byte
/// ranges, and handles Matroska, ASS subtitles and multi-track audio natively
/// — none of which AVFoundation will do.
///
/// Deliberately SDR for now. The Mac's EDR pipeline took a whole plan and a
/// genuinely nasty bug to get right; iOS display handling is different again,
/// and shipping a correct SDR picture beats shipping a dark HDR one.
@MainActor
final class MobilePlayerController: UIViewController {
    weak var delegate: (any MobilePlayerDelegate)?

    private var mpv: OpaquePointer?
    private let metalLayer = CAMetalLayer()
    private var renderSurfaceSize: CGSize = .zero
    private var videoDisplayAspect: Double?
    private var currentURL: URL?
    private var authorization: String?
    private var startPosition: Double = 0
    private(set) var isFileLoaded = false

    override func loadView() {
        let host = UIView()
        host.backgroundColor = .black
        host.clipsToBounds = true
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        // SDR, fixed for the whole renderer session. Changing a live layer's
        // format under mpv is what the Mac learned not to do.
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        view.layer.addSublayer(metalLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutVideoLayer()
    }

    // MARK: - Playback

    func play(url: URL, authorization: String?, position: Double) {
        currentURL = url
        self.authorization = authorization
        startPosition = position
        if mpv == nil { setupMPV() }
        guard mpv != nil else { return }
        loadCurrentFile()
    }

    private func loadCurrentFile() {
        guard let url = currentURL else { return }
        isFileLoaded = false
        delegate?.playerLoadingStateDidChange(isLoading: true)
        // `loadfile <url> [<flags> [<index> [<options>]]]` — the options are
        // the *fourth* argument, and the third is an integer index. Putting
        // the options where the index goes is rejected outright, which
        // presents as a spinner that never stops.
        let options = startPosition > 1 ? "start=\(startPosition)" : ""
        command("loadfile", url.absoluteString, "replace", "-1", options)
    }

    func stop() {
        guard let handle = mpv else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        mpv = nil
        mpv_terminate_destroy(handle)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setPaused(_ paused: Bool) {
        var flag: Int32 = paused ? 1 : 0
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func seek(to seconds: Double) {
        command("seek", String(seconds), "absolute+exact")
    }

    func seek(by offset: Double) {
        command("seek", String(offset), "relative")
    }

    func setSpeed(_ speed: Double) {
        var value = speed
        mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &value)
    }

    /// Shifts the subtitles against the picture, in seconds. Positive shows
    /// them later.
    ///
    /// Needed far more often on the phone than on the Mac: an episode played
    /// over the link with a sidecar the Mac matched separately has two
    /// timelines that were never checked against each other, and a fansub's
    /// own timing can be a second out on a different release anyway.
    func setSubtitleDelay(_ seconds: Double) {
        guard let mpv else { return }
        var value = seconds
        mpv_set_property(mpv, "sub-delay", MPV_FORMAT_DOUBLE, &value)
    }

    /// Scales the subtitles. 1.0 is the file's own size.
    ///
    /// `sub-scale` governs plain-text subtitles (mpv converts SRT into its
    /// own ASS style, so it applies there). A real ASS file carries its own
    /// sizes and mpv honours them unless told otherwise, which is why
    /// `sub-ass-override` goes along with it — set to `scale`, which applies
    /// the size and leaves the fansub's colours, positions and signs alone.
    /// It is set **without** the usual rejection assert: the value is
    /// documented but this is not the place to discover that a particular
    /// libass build disagrees, and the cost of it not applying is a slider
    /// that does nothing to one subtitle format, not a broken player.
    func setSubtitleScale(_ scale: Double) {
        guard let mpv else { return }
        var value = scale
        mpv_set_property(mpv, "sub-scale", MPV_FORMAT_DOUBLE, &value)
        _ = mpv_set_property_string(mpv, "sub-ass-override", scale == 1 ? "no" : "scale")
    }

    func select(audioID: Int64) {
        var value = audioID
        mpv_set_property(mpv, "aid", MPV_FORMAT_INT64, &value)
    }

    func select(subtitleID: Int64) {
        var value = subtitleID
        mpv_set_property(mpv, "sid", MPV_FORMAT_INT64, &value)
    }

    var position: Double { getDouble("time-pos") ?? 0 }

    /// Loads a sidecar subtitle file and selects it.
    ///
    /// Additive only: a subtitle that will not load must never surface as a
    /// playback failure, which is the rule the Mac's player already follows.
    /// mpv reports the problem in its own log and carries on with the video.
    func addSubtitle(url: URL) {
        command("sub-add", url.path, "select")
    }

    // MARK: - Setup

    private func setupMPV() {
        configureAudioSession()
        prepareRenderSurface()
        guard let handle = mpv_create() else {
            delegate?.playerDidFail(message: String(localized: "Could not start the playback engine."))
            return
        }
        mpv = handle
        if let level = ProcessInfo.processInfo.environment["AG_MPV_LOG"] {
            mpv_request_log_messages(handle, level)
        }
        setOption("vo", "gpu-next")
        setOption("gpu-api", "vulkan")
        setOption("gpu-context", "moltenvk")
        setOption("hwdec", "videotoolbox")
        // No `ytdl` here, unlike the Mac. MPVKit builds LuaJIT for macOS only,
        // so iOS has no ytdl_hook and the option does not exist — setting it
        // is rejected outright. There is nothing to disable.
        // The link's bearer token rides in a header rather than the URL, so it
        // stays out of logs and history. `-smokeLink` proves mpv honours this
        // and is refused without it.
        if let authorization {
            setOption("http-header-fields", "Authorization: \(authorization)")
        }
        // A local file needs none of the network tuning below, and a large
        // demuxer cache on a file already on disk is wasted memory.
        let isLocal = currentURL?.isFileURL == true
        if !isLocal {
            // A phone on Wi-Fi is not a local disk; a larger demuxer cache is
            // what keeps a seek from stalling the picture.
            setOption("cache", "yes")
            setOption("demuxer-max-bytes", "150MiB")
            setOption("demuxer-readahead-secs", "20")
            setOption("network-timeout", "20")
        }
        setOption("keepaspect", "yes")
        setOption("panscan", "0")
        setOption("video-unscaled", "no")
        setOption("sub-auto", "no")

        var layerPointer = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque())))
        let windowStatus = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &layerPointer)
        guard windowStatus >= 0 else {
            delegate?.playerDidFail(message: errorMessage(for: windowStatus))
            return
        }
        guard mpv_initialize(handle) >= 0 else {
            let status = mpv_initialize(handle)
            mpv = nil
            mpv_terminate_destroy(handle)
            delegate?.playerDidFail(message: errorMessage(for: status))
            return
        }

        for (name, format) in [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG), ("track-list/count", MPV_FORMAT_INT64),
            ("aid", MPV_FORMAT_INT64), ("sid", MPV_FORMAT_INT64),
            ("video-params/dw", MPV_FORMAT_INT64), ("video-params/dh", MPV_FORMAT_INT64)
        ] {
            mpv_observe_property(handle, 0, name, format)
        }

        // The wakeup callback runs on mpv's own thread. Typed explicitly as a
        // C function pointer so Swift 6 does not infer MainActor isolation for
        // the literal and trap the moment mpv calls it off the main thread.
        let wakeupHandler: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
            guard let context else { return }
            let controller = Unmanaged<MobilePlayerController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.drainEvents() }
        }
        mpv_set_wakeup_callback(handle, wakeupHandler, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Playback has to keep going with the screen locked and mix correctly
    /// with the rest of the system, which is what the audio session decides.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    /// mpv's moltenvk backend reads `drawableSize` exactly once, at reconfig,
    /// and has no resize path at all. So the surface is fixed for the session
    /// at the screen's full native size and the layer is *fitted* to the view
    /// with a transform — the video is always scaled down, never blurred.
    private func prepareRenderSurface() {
        let screen = view.window?.windowScene?.screen ?? UIScreen.main
        let scale = screen.nativeScale
        metalLayer.contentsScale = scale
        let native = screen.nativeBounds.size
        // Landscape and portrait share one surface: the larger dimension is
        // the width, so a rotation is a layout pass rather than a rebuild.
        renderSurfaceSize = CGSize(
            width: max(native.width, native.height),
            height: min(native.width, native.height)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        metalLayer.bounds = CGRect(
            x: 0, y: 0,
            width: renderSurfaceSize.width / scale,
            height: renderSurfaceSize.height / scale
        )
        // CAMetalLayer re-derives drawableSize from its bounds on every bounds
        // change, so it is set after them and the bounds never move again.
        metalLayer.drawableSize = renderSurfaceSize
        CATransaction.commit()
        layoutVideoLayer()
    }

    /// Places the fixed render surface over the view so the video inside it
    /// lands exactly on the view's aspect-fit rectangle. mpv letterboxes the
    /// video inside its surface; the view wants it letterboxed inside itself.
    private func layoutVideoLayer() {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              renderSurfaceSize.width > 1, renderSurfaceSize.height > 1 else { return }
        let scale = metalLayer.contentsScale
        let surface = CGSize(width: renderSurfaceSize.width / scale, height: renderSurfaceSize.height / scale)
        let aspect = videoDisplayAspect ?? Double(surface.width / surface.height)
        let videoInSurface = Self.fit(aspect: aspect, in: surface)
        let videoInView = Self.fit(aspect: aspect, in: bounds.size)
        let factor = videoInSurface.width > 0 ? videoInView.width / videoInSurface.width : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        metalLayer.transform = CATransform3DMakeScale(factor, factor, 1)
        CATransaction.commit()
    }

    private static func fit(aspect: Double, in box: CGSize) -> CGSize {
        guard aspect > 0, box.width > 0, box.height > 0 else { return box }
        let boxAspect = Double(box.width / box.height)
        if aspect > boxAspect {
            return CGSize(width: box.width, height: box.width / aspect)
        }
        return CGSize(width: box.height * aspect, height: box.height)
    }

    // MARK: - Events

    private func drainEvents() {
        guard let mpv else { return }
        var position: Double?
        var duration: Double?
        var paused: Bool?
        var needsTracks = false
        var needsGeometry = false
        var finished = false

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
                case "video-params/dw", "video-params/dh": needsGeometry = true
                default: break
                }
            case MPV_EVENT_LOG_MESSAGE:
                // Only with AG_MPV_LOG set. mpv reports its own failures here
                // and nowhere else — a Vulkan context that will not come up
                // is otherwise just a spinner that never stops.
                if let raw = event.pointee.data {
                    let message = raw.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    let text = "[mpv/\(String(cString: message.prefix))] \(String(cString: message.text))"
                    FileHandle.standardError.write(Data(text.utf8))
                }
            case MPV_EVENT_FILE_LOADED:
                isFileLoaded = true
                needsTracks = true
                needsGeometry = true
                delegate?.playerLoadingStateDidChange(isLoading: false)
            case MPV_EVENT_END_FILE:
                let reason = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason
                if reason == MPV_END_FILE_REASON_ERROR {
                    delegate?.playerDidFail(message: String(localized: "This episode could not be played."))
                } else if reason == MPV_END_FILE_REASON_EOF {
                    finished = true
                }
                delegate?.playerLoadingStateDidChange(isLoading: false)
            default:
                break
            }
        }

        if needsGeometry { updateGeometry() }
        if position != nil || duration != nil || paused != nil {
            delegate?.playerDidUpdate(position: position, duration: duration, paused: paused)
        }
        if needsTracks { publishTracks() }
        if finished { delegate?.playerDidFinishFile() }
    }

    private func updateGeometry() {
        let width = getInt64("video-params/dw") ?? 0
        let height = getInt64("video-params/dh") ?? 0
        guard width > 0, height > 0 else { return }
        let aspect = Double(width) / Double(height)
        guard videoDisplayAspect != aspect else { return }
        videoDisplayAspect = aspect
        layoutVideoLayer()
        delegate?.playerDidUpdateAspect(aspect)
    }

    private func publishTracks() {
        guard let mpv else { return }
        let count = Int(getInt64("track-list/count") ?? 0)
        var audio: [MobileTrack] = []
        var subtitles: [MobileTrack] = []
        for index in 0..<count {
            guard let type = getString("track-list/\(index)/type"),
                  let id = getInt64("track-list/\(index)/id") else { continue }
            let language = getString("track-list/\(index)/lang")
            let title = getString("track-list/\(index)/title")
                ?? language
                ?? String(localized: "Track \(String(id))")
            let track = MobileTrack(id: id, type: type, title: title, language: language)
            if type == "audio" { audio.append(track) }
            if type == "sub" { subtitles.append(track) }
        }
        _ = mpv
        delegate?.playerDidUpdateTracks(
            audio: audio,
            subtitles: subtitles,
            audioID: getInt64("aid"),
            subtitleID: getInt64("sid")
        )
    }

    // MARK: - mpv plumbing

    private func setOption(_ name: String, _ value: String) {
        let status = mpv_set_option_string(mpv, name, value)
        if status < 0 {
            // Nothing else surfaces a rejected option; the Mac learned this
            // when `target-peak` was silently ignored for being a float.
            assertionFailure("MPV REJECTED \(name)=\(value): \(errorMessage(for: status))")
        }
    }

    private func command(_ arguments: String...) {
        guard let mpv else { return }
        let copies = arguments.map { strdup($0) }
        defer { for pointer in copies { free(pointer) } }
        // mpv_command takes an array of *const* char pointers; strdup hands
        // back mutable ones, so the array has to be built at the const type.
        var pointers: [UnsafePointer<CChar>?] = copies.map { UnsafePointer($0) }
        pointers.append(nil)
        pointers.withUnsafeMutableBufferPointer { buffer in
            _ = mpv_command(mpv, buffer.baseAddress)
        }
    }

    private func getDouble(_ name: String) -> Double? {
        guard let mpv else { return nil }
        var value: Double = 0
        guard mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return nil }
        return value
    }

    private func getInt64(_ name: String) -> Int64? {
        guard let mpv else { return nil }
        var value: Int64 = 0
        guard mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return value
    }

    private func getString(_ name: String) -> String? {
        guard let mpv, let raw = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(raw) }
        let text = String(cString: raw)
        return text.isEmpty ? nil : text
    }

    private func errorMessage(for status: Int32) -> String {
        guard let raw = mpv_error_string(status) else { return String(localized: "Playback failed.") }
        return String(cString: raw)
    }
}
