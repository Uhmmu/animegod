import AnimeGodCore
import AppKit
import AVFoundation
import Foundation
import Libmpv
import Metal

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
    enum PlaybackPipeline: String {
        case mpvEDR = "mpv gpu-next / MoltenVK EDR"
        case mpvSDR = "mpv gpu-next / MoltenVK SDR fallback"
        case avFoundationDolbyVision = "AVFoundation Dolby Vision native"
    }

    private enum MetalOutputConfiguration {
        case hdr10, hlg, sdrFallback
    }

    weak var delegate: MPVPlayerControllerDelegate?
    var initialURL: URL?
    var initialPosition: Double = 0

    nonisolated(unsafe) private var mpv: OpaquePointer?
    private let metalLayer = StableMetalLayer()
    private var currentURL: URL?
    private var pendingRestoration: PlaybackRestoration?
    private var metalOutputConfiguration: MetalOutputConfiguration = .hdr10
    private var playbackPipeline: PlaybackPipeline = .mpvEDR
    private var forcedSDR = false
    private var targetHDRActive = false
    private var playerGeneration = UUID()
    private var currentContainerProbe: DolbyVisionContainerProbe.Result?
    nonisolated(unsafe) private var avPlayer: AVPlayer?
    nonisolated(unsafe) private var avPlayerLayer: AVPlayerLayer?
    nonisolated(unsafe) private var avTimeObserver: Any?
    nonisolated(unsafe) private var avEndObserver: NSObjectProtocol?

    var pipelineName: String { playbackPipeline.rawValue }
    var swapchainFormatName: String {
        playbackPipeline == .avFoundationDolbyVision ? "AVFoundation managed" : metalLayer.pixelFormat.diagnosticName
    }
    var toneMappingModeName: String {
        if playbackPipeline == .avFoundationDolbyVision { return "Apple Dolby Vision display mapping" }
        if forcedSDR || !targetHDRActive { return getString("tone-mapping") ?? "auto (HDR → SDR)" }
        return "EDR passthrough / libplacebo"
    }
    var isForcedSDR: Bool { forcedSDR }
    var isHDROutputActive: Bool { targetHDRActive }

    private struct PlaybackRestoration {
        let paused: Bool
        let speed: Double
        let volume: Double
        let subtitleDelay: Double
        let audioDelay: Double
        let audioID: Int64?
        let subtitleID: Int64?
    }

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
        configureMetalLayer(.hdr10)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFullscreenTransition),
            name: NSWindow.didEnterFullScreenNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFullscreenTransition),
            name: NSWindow.didExitFullScreenNotification,
            object: nil
        )
        if let initialURL { play(url: initialURL, position: initialPosition) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateSurface()
    }

    @objc private func handleFrameChange() {
        updateSurface()
    }

    /// MPVKit's MoltenVK swapchain does not pick up a new drawable size after
    /// the host window enters or leaves fullscreen. Recreate the renderer only
    /// after the transition has completed, preserving the user's playback
    /// state. This avoids the runtime `wid = 0` cycle that can freeze playback
    /// immediately after the first frame.
    @objc private func handleFullscreenTransition(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === view.window else { return }
        updateSurface()
        rebuildRendererForCurrentSurface()
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
        avPlayerLayer?.frame = bounds
    }

    func setPaused(_ paused: Bool) {
        if let avPlayer {
            paused ? avPlayer.pause() : avPlayer.play()
            return
        }
        var flag: Int32 = paused ? 1 : 0
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func seek(to position: Double) {
        if let avPlayer {
            avPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600))
            return
        }
        command("seek", arguments: [String(position), "absolute", "exact"])
    }

    func seek(by offset: Double) {
        if let avPlayer {
            let seconds = max(0, avPlayer.currentTime().seconds + offset)
            avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
            return
        }
        command("seek", arguments: [String(offset), "relative", "exact"])
    }

    func selectAudio(id: Int64) { setInt64("aid", id) }
    func selectSubtitle(id: Int64?) { id.map { setInt64("sid", $0) } ?? setString("sid", "no") }

    func setSpeed(_ speed: Double) {
        if let avPlayer { avPlayer.rate = Float(speed); return }
        setDouble("speed", speed)
    }
    func setVolume(_ volume: Double) {
        if let avPlayer { avPlayer.volume = Float(min(max(volume / 100, 0), 1)); return }
        setDouble("volume", volume)
    }
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
        currentURL = url
        playerGeneration = UUID()
        let generation = playerGeneration
        delegate?.playerLoadingStateDidChange(isLoading: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let probe = await Task.detached(priority: .userInitiated) {
                DolbyVisionContainerProbe.inspect(url: url)
            }.value
            let nativeInfo = await Self.inspectNativeDolbyVision(url: url, probe: probe)
            guard generation == self.playerGeneration else { return }
            self.currentContainerProbe = probe
            if let nativeInfo, nativeInfo.eligible, !self.forcedSDR {
                self.startNativePlayback(url: url, position: position, info: nativeInfo)
            } else {
                self.stopNativePlayback()
                if self.mpv == nil { self.setupMPV() }
                guard self.mpv != nil else { return }
                var options: [String] = []
                if position > 0 { options.append("start=\(position)") }
                self.command("loadfile", arguments: [url.absoluteString, "replace", "-1", options.joined(separator: ",")])
            }
        }
    }

    private func rebuildRendererForCurrentSurface() {
        guard avPlayer == nil, let handle = mpv, let currentURL else { return }
        let restoration = PlaybackRestoration(
            paused: getFlag("pause") ?? false,
            speed: getDouble("speed") ?? 1,
            volume: getDouble("volume") ?? 100,
            subtitleDelay: getDouble("sub-delay") ?? 0,
            audioDelay: getDouble("audio-delay") ?? 0,
            audioID: getInt64("aid"),
            subtitleID: getInt64("sid")
        )
        let position = getDouble("time-pos") ?? 0

        mpv_set_wakeup_callback(handle, nil, nil)
        mpv = nil
        mpv_terminate_destroy(handle)

        pendingRestoration = restoration
        setupMPV()
        guard mpv != nil else { return }
        play(url: currentURL, position: position)
    }

    private func setupMPV(allowEDRFallback: Bool = true) {
        configureMetalLayer(metalOutputConfiguration)
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
        if metalOutputConfiguration != .sdrFallback {
            // Must be set before mpv_initialize. The CAMetalLayer format and
            // colorspace are fixed for this renderer session.
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
            mpv = nil
            mpv_terminate_destroy(handle)
            if allowEDRFallback, metalOutputConfiguration != .sdrFallback {
                metalOutputConfiguration = .sdrFallback
                playbackPipeline = .mpvSDR
                setupMPV(allowEDRFallback: false)
                return
            }
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
        observe("video-params/matrix", format: MPV_FORMAT_STRING)
        observe("video-params/sig-peak", format: MPV_FORMAT_DOUBLE)
        observe("video-params/dolby-vision-profile", format: MPV_FORMAT_INT64)
        observe("video-params/dolby-vision-level", format: MPV_FORMAT_INT64)
        observe("hwdec-current", format: MPV_FORMAT_STRING)
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
                case "video-params/pixelformat", "video-params/primaries", "video-params/gamma",
                     "video-params/matrix", "video-params/sig-peak",
                     "video-params/dolby-vision-profile", "video-params/dolby-vision-level",
                     "hwdec-current": needsColor = true
                default: break
                }
            case MPV_EVENT_START_FILE:
                delegate?.playerLoadingStateDidChange(isLoading: true)
            case MPV_EVENT_FILE_LOADED:
                restorePlaybackStateIfNeeded()
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

    private func restorePlaybackStateIfNeeded() {
        guard let restoration = pendingRestoration else { return }
        pendingRestoration = nil
        setSpeed(restoration.speed)
        setVolume(restoration.volume)
        setSubtitleDelay(restoration.subtitleDelay)
        setAudioDelay(restoration.audioDelay)
        if let audioID = restoration.audioID { selectAudio(id: audioID) }
        selectSubtitle(id: restoration.subtitleID)
        setPaused(restoration.paused)
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
        let probe = currentContainerProbe
        let sideDataProfile = getInt64("video-params/dolby-vision-profile").map(Int.init)
        let sideDataLevel = getInt64("video-params/dolby-vision-level").map(Int.init)
        let dolbyVision = sideDataProfile.map {
            DolbyVisionMetadata(
                profile: $0,
                level: sideDataLevel,
                rpuPresent: true,
                enhancementLayerPresent: probe?.metadata.enhancementLayerPresent ?? false,
                baseLayerPresent: probe?.metadata.baseLayerPresent ?? true,
                compatibilityID: probe?.metadata.compatibilityID,
                configurationKind: .mpvSideData
            )
        } ?? probe?.metadata
        let profile = VideoColorProfile(
            codec: getString("video-format"),
            pixelFormat: getString("video-params/pixelformat"),
            bitDepth: VideoColorProfile.bitDepth(fromPixelFormat: getString("video-params/pixelformat")),
            primaries: getString("video-params/primaries"),
            transfer: getString("video-params/gamma"),
            matrix: getString("video-params/matrix"),
            signalPeak: getDouble("video-params/sig-peak"),
            hardwareDecoder: getString("hwdec-current"),
            releaseHint: dolbyVision?.profileLabel,
            dolbyVision: dolbyVision,
            codecTag: probe?.codecTag,
            videoTrackCount: videoTrackCount
        )
        delegate?.playerDidUpdateColor(profile)
    }

    private var videoTrackCount: Int {
        let count = Int(getInt64("track-list/count") ?? 0)
        return (0..<count).reduce(into: 0) { result, index in
            if getString("track-list/\(index)/type") == "video",
               getString("track-list/\(index)/albumart") != "yes" { result += 1 }
        }
    }

    /// The host drawable size. mpv's dwidth/dheight describe source display
    /// dimensions and are deliberately not presented as swapchain evidence.
    var renderedOutputSize: (width: Double, height: Double)? {
        let size = metalLayer.drawableSize
        guard size.width > 0, size.height > 0 else { return nil }
        return (Double(size.width), Double(size.height))
    }

    /// Applies only runtime-safe mpv target properties. A required HLG/HDR10
    /// CAEDRMetadata change recreates the renderer before touching the layer.
    func applyColorOutput(profile: VideoColorProfile?, forcedSDR: Bool, displayPeak: Double) {
        self.forcedSDR = forcedSDR
        let hasEDRDisplay = displayPeak > 1
        targetHDRActive = profile?.isHDR == true && hasEDRDisplay && !forcedSDR
            && playbackPipeline != .mpvSDR

        if playbackPipeline == .avFoundationDolbyVision {
            if forcedSDR, let url = currentURL {
                let position = avPlayer?.currentTime().seconds ?? 0
                stopNativePlayback()
                setupMPV()
                var options = [String]()
                if position > 0 { options.append("start=\(position)") }
                command("loadfile", arguments: [url.absoluteString, "replace", "-1", options.joined(separator: ",")])
            }
            return
        }
        if !forcedSDR, let metadata = profile?.dolbyVision,
           metadata.isAppleNativeEligible(
               codecTag: profile?.codecTag, bitDepth: profile?.bitDepth,
               videoTrackCount: profile?.videoTrackCount ?? 0,
               primaries: profile?.primaries, transfer: profile?.transfer
           ), let url = currentURL {
            play(url: url, position: getDouble("time-pos") ?? 0)
            return
        }
        guard mpv != nil else { return }

        if targetHDRActive {
            let desired: MetalOutputConfiguration = profile?.hdrFormat == .hlg ? .hlg : .hdr10
            if metalOutputConfiguration != desired, mpv != nil {
                metalOutputConfiguration = desired
                rebuildRendererForCurrentSurface()
                return
            }
            setString("target-prim", "bt.2020")
            setString("target-trc", "linear")
            setString("target-peak", String(max(100, displayPeak * 100)))
        } else {
            setString("target-prim", "bt.709")
            setString("target-trc", "bt.1886")
            setString("target-peak", "100")
        }
    }

    private func configureMetalLayer(_ configuration: MetalOutputConfiguration) {
        metalLayer.device = MTLCreateSystemDefaultDevice()
        switch configuration {
        case .hdr10:
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.edrMetadata = .hdr10(minLuminance: 0.5, maxLuminance: 1_000, opticalOutputScale: 100)
            playbackPipeline = .mpvEDR
        case .hlg:
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.edrMetadata = .hlg
            playbackPipeline = .mpvEDR
        case .sdrFallback:
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metalLayer.wantsExtendedDynamicRangeContent = false
            metalLayer.edrMetadata = nil
            playbackPipeline = .mpvSDR
        }
    }

    private struct NativeDolbyVisionInfo: Sendable {
        let metadata: DolbyVisionMetadata
        let codecTag: String
        let videoTrackCount: Int
        let primaries: String
        let transfer: String
        let eligible: Bool
    }

    nonisolated private static func inspectNativeDolbyVision(
        url: URL, probe: DolbyVisionContainerProbe.Result?
    ) async -> NativeDolbyVisionInfo? {
        guard ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased()) else { return nil }
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }
            let descriptions = try await track.load(.formatDescriptions)
            guard let description = descriptions.first else { return nil }
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            let bytes = [
                UInt8((subtype >> 24) & 0xff), UInt8((subtype >> 16) & 0xff),
                UInt8((subtype >> 8) & 0xff), UInt8(subtype & 0xff)
            ]
            let codecTag = String(bytes: bytes, encoding: .ascii) ?? probe?.codecTag ?? ""
            let atoms = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
            ) as? [String: Any]
            let dvvC = (atoms?["dvvC"] as? Data).flatMap {
                DolbyVisionConfigurationParser.parse($0, kind: .dvvC)
            }
            let metadata = dvvC ?? probe?.metadata
            guard let metadata else { return nil }
            let hvcC = atoms?["hvcC"] as? Data
            let isMain10 = hvcC.map { $0.count > 1 && ($0[$0.startIndex + 1] & 0x1f) == 2 } ?? false
            let primaries = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
            ) as? String ?? ""
            let transfer = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_TransferFunction
            ) as? String ?? ""
            let eligible = isMain10 && metadata.isAppleNativeEligible(
                codecTag: codecTag, bitDepth: 10, videoTrackCount: tracks.count,
                primaries: primaries, transfer: transfer
            )
            return NativeDolbyVisionInfo(
                metadata: metadata, codecTag: codecTag,
                videoTrackCount: tracks.count, primaries: primaries,
                transfer: transfer, eligible: eligible
            )
        } catch {
            return nil
        }
    }

    private func startNativePlayback(url: URL, position: Double, info: NativeDolbyVisionInfo) {
        if let handle = mpv {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv = nil
            mpv_terminate_destroy(handle)
        }
        stopNativePlayback()
        playbackPipeline = .avFoundationDolbyVision
        targetHDRActive = !forcedSDR && (view.window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        view.layer?.addSublayer(layer)
        avPlayer = player
        avPlayerLayer = layer
        delegate?.playerDidUpdateTracks(audio: [], subtitles: [], audioID: nil, subtitleID: nil)
        delegate?.playerDidUpdateChapters([], current: nil)
        if position > 0 { player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
        avTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self, weak player] time in
            Task { @MainActor in
                guard let self, let player else { return }
                let duration = player.currentItem?.duration.seconds
                self.delegate?.playerDidUpdate(
                    position: time.seconds.isFinite ? time.seconds : nil,
                    duration: duration?.isFinite == true ? duration : nil,
                    paused: player.rate == 0
                )
            }
        }
        avEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.delegate?.playerDidFinishFile() }
        }
        player.play()
        delegate?.playerLoadingStateDidChange(isLoading: false)
        delegate?.playerDidUpdateColor(VideoColorProfile(
            codec: "hevc", pixelFormat: "p010", bitDepth: 10,
            primaries: info.primaries, transfer: info.transfer, matrix: "bt.2020nc",
            signalPeak: nil, hardwareDecoder: "VideoToolbox / AVFoundation",
            releaseHint: info.metadata.profileLabel, dolbyVision: info.metadata,
            codecTag: info.codecTag, videoTrackCount: info.videoTrackCount
        ))
    }

    private func stopNativePlayback() {
        if let avTimeObserver, let avPlayer { avPlayer.removeTimeObserver(avTimeObserver) }
        if let avEndObserver { NotificationCenter.default.removeObserver(avEndObserver) }
        avPlayer?.pause()
        avPlayerLayer?.removeFromSuperlayer()
        avTimeObserver = nil
        avEndObserver = nil
        avPlayer = nil
        avPlayerLayer = nil
    }

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

    private func getFlag(_ name: String) -> Bool? {
        var value: Int32 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
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
        if let avTimeObserver, let avPlayer { avPlayer.removeTimeObserver(avTimeObserver) }
        if let avEndObserver { NotificationCenter.default.removeObserver(avEndObserver) }
        NotificationCenter.default.removeObserver(self)
        if let mpv {
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
        }
    }
}

private extension MTLPixelFormat {
    var diagnosticName: String {
        switch self {
        case .rgba16Float: "rgba16Float"
        case .bgra8Unorm: "bgra8Unorm"
        default: "MTLPixelFormat(\(rawValue))"
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
