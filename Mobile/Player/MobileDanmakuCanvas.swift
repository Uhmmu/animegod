import AnimeGodCore
import CoreText
import QuartzCore
import UIKit

/// The phone's danmaku renderer.
///
/// A port of the Mac's `DanmakuCanvas`, sharing the parts that are genuinely
/// shared: `DanmakuEngine` (lanes, timing, capacity) and
/// `DanmakuTextRasterizer` (glyphs) both live in the core. What is written
/// twice is what genuinely differs — the view lifecycle, the display link,
/// and the coordinate origin.
///
/// **The coordinate origin is the difference that matters.** On macOS a
/// layer-hosting `NSView`'s layer has a bottom-left origin, so the engine's
/// top-origin lane positions are converted with
/// `bounds.height - y - lineHeight`. A `UIView`'s layer is already top-left,
/// so the lane position *is* the layer position and that conversion must be
/// **deleted**, not carried over. Keeping it makes lanes grow upward from the
/// bottom — which is exactly the bug the macOS version hit when its host layer
/// was geometry-flipped.
final class MobileDanmakuCanvas: UIView {
    private let hostLayer = CALayer()
    /// Kept as its invalidate closure rather than the link itself: the
    /// deinit is nonisolated and `CADisplayLink` is not Sendable, so touching
    /// the object there does not compile. Safe because the view is already
    /// unreferenced by the time it runs.
    nonisolated(unsafe) private var stopDisplayLink: (() -> Void)?
    private var displayLinkIsRunning = false
    private let rasterizer: DanmakuTextRasterizer

    private var clock = DanmakuPlaybackClock()
    private var engine: DanmakuEngine!
    private var settings: DanmakuDisplaySettings = .default
    private var hasComments = false
    private var isVisible = true
    /// The engine does not tick while there are no comments. Keeping the last
    /// player position means a late match starts at the current scene rather
    /// than scanning the whole episode from zero on its first frame.
    private var latestPlaybackPosition: Double = 0
    /// The picture's aspect, so the canvas can work out where the video
    /// actually is inside a full-screen view.
    private var videoAspect: Double?

    /// Layers aligned with the engine's active list, plus the ids and drawn
    /// widths they carry. Reconciling the three by a two-pointer walk keeps
    /// structural frames free of hashing and allocation, which matters when a
    /// dense stream spawns or expires something on nearly every frame.
    private var orderedLayers: [CALayer] = []
    private var orderedIDs: [String] = []
    private var orderedWidths: [Double] = []
    private var scratchLayers: [CALayer] = []
    private var scratchIDs: [String] = []
    private var scratchWidths: [Double] = []
    /// Retired layers, kept in the tree but hidden: adding and removing
    /// sublayers is the expensive part, reusing a hidden one is not.
    private var freeLayers: [CALayer] = []

    /// Where the picture sits inside this view.
    ///
    /// **The canvas is the whole screen; the picture usually is not.** Those
    /// are two different rectangles and they govern different things. Type
    /// size and how far down comments may stack belong to the *picture* — a
    /// font scaled off a 19.5:9 screen over a letterboxed strip is the bug
    /// that produced 44pt text in portrait. But how far a comment *travels*
    /// belongs to the *screen*: a phone in landscape has black pillars either
    /// side of a 16:9 film, and confining the scroll to the picture means
    /// comments appear and vanish along a seam 80 points inside the bezel
    /// instead of sliding off the edge of the device.
    private var videoRect: CGRect {
        guard let videoAspect, videoAspect > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let width: Double
        let height: Double
        if bounds.width / bounds.height > videoAspect {
            height = bounds.height
            width = height * videoAspect
        } else {
            width = bounds.width
            height = width / videoAspect
        }
        return CGRect(
            x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
            width: width, height: height
        )
    }

    private var lineHeight: Double { rasterizer.lineHeight }
    /// The scale every comment layer is drawn at.
    ///
    /// **A hand-made `CALayer` has `contentsScale` 1.0 and does not inherit
    /// it.** AppKit propagates the backing scale through a layer-backed
    /// view's whole sublayer tree, so the Mac's canvas never had to think
    /// about this; UIKit does not, and only sets it on the view's own layer.
    /// Left at 1.0, Core Animation treats the 3×-rasterized bitmap as if one
    /// pixel were one point, downsamples it to the layer's bounds and then
    /// composites that back up to the display's scale — which is exactly what
    /// pixellated danmaku over a sharp picture looks like.
    private var contentsScale: CGFloat = 1
    /// `AG_DANMAKU_LOG=1` prints the metrics whenever they are recomputed;
    /// `=2` adds every spawn. Guessing at what danmaku are doing on a device
    /// has cost this project two rounds already, so the trace is cheap to
    /// reach for.
    private let traceLevel = Int(ProcessInfo.processInfo.environment["AG_DANMAKU_LOG"] ?? "") ?? 0

    override init(frame: CGRect) {
        rasterizer = DanmakuTextRasterizer(fontSize: 16, lineHeight: 21)
        super.init(frame: frame)
        let rast = rasterizer
        engine = DanmakuEngine(
            viewportWidth: max(frame.width, 1),
            viewportHeight: max(frame.height, 1),
            lineHeight: rasterizer.lineHeight,
            measure: { rast.width(of: $0) }
        )
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // The canvas is sized to the picture, and a comment spawns at the
        // right edge of it. Without clipping that is drawn over whatever is
        // beside the video — in portrait, the black bars and the chrome — so
        // comments appear to pop into existence off the picture instead of
        // sliding in from its edge.
        clipsToBounds = true
        layer.addSublayer(hostLayer)
        hostLayer.backgroundColor = UIColor.clear.cgColor
        recomputeMetrics()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        stopDisplayLink?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.frame = bounds
        CATransaction.commit()
        recomputeMetrics()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLinkState()
    }

    // MARK: - Inputs

    func apply(settings newSettings: DanmakuDisplaySettings) {
        let metricsChanged = newSettings.fontScale != settings.fontScale
            || newSettings.lineSpacing != settings.lineSpacing
        settings = newSettings
        hostLayer.opacity = Float(min(max(newSettings.opacity, 0.05), 1))
        if metricsChanged {
            recomputeMetrics()
        } else {
            engine.updateSettings(newSettings)
        }
    }

    func setVideoAspect(_ aspect: Double?) {
        guard aspect != videoAspect else { return }
        videoAspect = aspect
        recomputeMetrics()
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        hostLayer.isHidden = !visible
        updateDisplayLinkState()
    }

    /// The pool for the current episode. The provider shift is already baked
    /// in by the Mac, so nothing is applied here.
    func setComments(_ comments: [DanmakuComment]) {
        hasComments = !comments.isEmpty
        engine.load(comments: comments)
        engine.seek(to: max(0, latestPlaybackPosition))
        syncLayers(structural: true)
        updateDisplayLinkState()
    }

    /// Player position sample. Anchors the clock and detects seeks by jump
    /// magnitude, rebuilding engine state instead of replaying.
    func playbackSample(position: Double, speed: Double, paused: Bool, hostTime: Double = CACurrentMediaTime()) {
        latestPlaybackPosition = max(0, position)
        // Tracked, not anchored. A hard anchor on every sample is what made
        // the comments judder: see `DanmakuPlaybackClock.sample`.
        if clock.sample(position: position, speed: speed, playing: !paused, hostTime: hostTime) == .discontinuous {
            engine.seek(to: max(0, position))
            syncLayers(structural: true)
        }
    }

    // MARK: - Display link

    private func updateDisplayLinkState() {
        let shouldRun = window != nil && isVisible && hasComments
        if shouldRun, !displayLinkIsRunning {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            // 60, deliberately, not the panel's 120. `tick()` runs on the
            // main actor and so does mpv's event drain, so every extra danmaku
            // frame is taken directly out of the player's budget — at 120 Hz
            // over a full-screen canvas the video itself started stuttering.
            // The source is 24 fps and the comments move a few points a
            // frame; there is nothing up there to see.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            stopDisplayLink = { [weak link] in link?.invalidate() }
            displayLinkIsRunning = true
        } else if !shouldRun, displayLinkIsRunning {
            stopDisplayLink?()
            stopDisplayLink = nil
            displayLinkIsRunning = false
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        // `targetTimestamp` — when this frame will actually be on screen —
        // not `CACurrentMediaTime()`, which is merely when the callback got
        // to run. The callback's latency varies by a few milliseconds and
        // would otherwise be added straight onto every comment's position.
        let media = clock.mediaTime(atHost: link.targetTimestamp)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let structural = engine.tick(at: media)
        syncLayers(structural: structural)
        CATransaction.commit()
    }

    // MARK: - Layout

    private func recomputeMetrics() {
        // `scale` (for the rasterizer) and `contentsScale` (for the layers)
        // have to agree, or the bitmap is drawn at a resolution the layer does
        // not expect.
        let displayScale = window?.screen.scale ?? UIScreen.main.scale
        if displayScale != contentsScale {
            contentsScale = displayScale
            hostLayer.contentsScale = displayScale
            for layer in orderedLayers { layer.contentsScale = displayScale }
            for layer in freeLayers { layer.contentsScale = displayScale }
        }
        let scale = Int(displayScale.rounded())
        // Base size tracks the player height — but **not** with the Mac's
        // factor. The Mac derives ~29pt from a 1100pt-tall window; a phone in
        // landscape is only ~402pt tall, and the same 0.026–0.032 gives 13pt.
        // Dense CJK glyphs at 13pt read as mush however cleanly they are
        // rasterized, which is what "the danmaku look low resolution" turned
        // out to mean: measured at 12.86pt, the bitmap was a correct 3× (95×51
        // pixels for 31.7×17 points) and simply too small. A phone is also
        // held far closer to the eye than a laptop, so angular size does not
        // rescue it either.
        // Rounded to whole points, and the viewport with it. Every metric
        // change throws away the bitmap cache and clears the engine, so a
        // layout pass that moves the view by a fraction of a point — the
        // controls appearing, a safe-area update, an aspect ratio that does
        // not divide evenly — used to wipe the screen and respawn the lot
        // from the right edge at once. Quantising means only a real size
        // change costs that.
        let picture = videoRect
        let viewWidth = bounds.width.rounded()
        let viewHeight = picture.height.rounded()
        let baseFontSize = min(max(viewHeight * 0.05, 16), 44)
        let fontSize = min(max(baseFontSize * settings.fontScale, 12), 60).rounded()
        let spacing = min(max(settings.lineSpacing, 1.05), 2)
        let metricsChanged = fontSize != rasterizer.fontSize
            || (fontSize * spacing).rounded() != rasterizer.lineHeight
        rasterizer.update(fontSize: fontSize, lineHeight: (fontSize * spacing).rounded(), scale: scale)
        // Every cached bitmap was just thrown away; a reused layer would keep
        // drawing the old one at the new size.
        if metricsChanged { discardLayers() }
        engine.updateSettings(settings)
        engine.updateViewport(width: max(viewWidth, 1), height: max(viewHeight, 1), lineHeight: lineHeight)
        if traceLevel >= 1, metricsChanged || traceLevel >= 2 {
            let probe = DanmakuComment(id: "probe", time: 0, text: "測試", mode: .scroll)
            let bitmap = rasterizer.bitmap(for: probe)
            FileHandle.standardError.write(Data(String(
                format: "DANMAKU bounds=%.0fx%.0f font=%.2f line=%.2f rasterScale=%d contentsScale=%.1f probe=%dx%dpx probeWidthPt=%.1f\n",
                viewWidth, viewHeight, fontSize, lineHeight, scale, contentsScale,
                bitmap?.width ?? -1, bitmap?.height ?? -1, rasterizer.width(of: probe)
            ).utf8))
        }
        syncLayers(structural: true)
    }

    private func discardLayers() {
        for layer in orderedLayers { recycle(layer) }
        orderedLayers.removeAll(keepingCapacity: true)
        orderedIDs.removeAll(keepingCapacity: true)
        orderedWidths.removeAll(keepingCapacity: true)
    }

    private func recycle(_ layer: CALayer) {
        layer.isHidden = true
        if freeLayers.count < 256 {
            freeLayers.append(layer)
        } else {
            layer.removeFromSuperlayer()
        }
    }

    private func dequeueLayer() -> CALayer {
        if let layer = freeLayers.popLast() {
            layer.isHidden = false
            return layer
        }
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.contentsScale = contentsScale
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        hostLayer.addSublayer(layer)
        return layer
    }

    // MARK: - Layer sync

    private func syncLayers(structural: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let active = engine.activeComments
        let lineRectHeight = lineHeight
        let pictureTop = videoRect.minY
        if structural {
            // Both lists are in spawn order and expiry compacts in place, so
            // the new list is the old one minus some entries plus appends: one
            // forward walk matches them up.
            scratchLayers.removeAll(keepingCapacity: true)
            scratchIDs.removeAll(keepingCapacity: true)
            scratchWidths.removeAll(keepingCapacity: true)
            var old = 0
            for index in active.indices {
                let id = active[index].id
                while old < orderedIDs.count, orderedIDs[old] != id {
                    recycle(orderedLayers[old])
                    old += 1
                }
                if old < orderedIDs.count {
                    scratchLayers.append(orderedLayers[old])
                    scratchWidths.append(orderedWidths[old])
                    old += 1
                } else {
                    let layer = dequeueLayer()
                    layer.contents = rasterizer.bitmap(for: commentForRaster(active[index]))
                    scratchLayers.append(layer)
                    scratchWidths.append(.nan)
                    if traceLevel >= 2 { trace(spawned: active[index]) }
                }
                scratchIDs.append(id)
            }
            while old < orderedIDs.count {
                recycle(orderedLayers[old])
                old += 1
            }
            swap(&orderedLayers, &scratchLayers)
            swap(&orderedIDs, &scratchIDs)
            swap(&orderedWidths, &scratchWidths)
        }
        for index in active.indices {
            // No flip. UIKit's layer is top-left origin and the engine's lanes
            // are top-origin, so lane zero is simply y = 0. The macOS canvas
            // subtracts from `bounds.height` here because its layer is
            // bottom-left; copying that line over is what makes lanes crawl up
            // from the bottom of the screen.
            // The engine's lanes are measured from the top of the picture,
            // not of the view: it is handed the picture's height, so lane
            // zero is the picture's first line and everything shifts down by
            // wherever the picture starts.
            let layer = orderedLayers[index]
            layer.position = CGPoint(x: active[index].x, y: active[index].y + pictureTop)
            // Bounds are per-comment and never change while it is on screen;
            // setting them every frame would re-lay-out the layer for nothing.
            let width = max(active[index].width, 1)
            if orderedWidths[index] != width {
                layer.bounds = CGRect(x: 0, y: 0, width: width, height: lineRectHeight)
                orderedWidths[index] = width
            }
        }
        CATransaction.commit()
    }

    /// Where a comment came on screen. A scrolling comment must always
    /// start at `x == bounds.width`; anything else is a bug, and a `top` or
    /// `bottom` comment appearing centred is not one.
    private func trace(spawned item: DanmakuActiveComment) {
        FileHandle.standardError.write(Data(String(
            format: "DANMAKU spawn mode=%@ x=%.1f y=%.1f w=%.1f viewW=%.0f text=%@\n",
            String(describing: item.mode), item.x, item.y, item.width, bounds.width,
            item.text.prefix(12).description
        ).utf8))
    }

    private func commentForRaster(_ item: DanmakuActiveComment) -> DanmakuComment {
        DanmakuComment(id: item.id, time: 0, text: item.text, mode: item.mode, color: item.color)
    }
}
