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
        let predicted = clock.mediaTime(atHost: hostTime)
        if abs(position - predicted) > max(0.5, 0.25 * speed) {
            engine.seek(to: max(0, position))
            syncLayers(structural: true)
        }
        clock.anchor(position: position, speed: speed, playing: !paused, hostTime: hostTime)
    }

    // MARK: - Display link

    private func updateDisplayLinkState() {
        let shouldRun = window != nil && isVisible && hasComments
        if shouldRun, !displayLinkIsRunning {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            stopDisplayLink = { [weak link] in link?.invalidate() }
            displayLinkIsRunning = true
        } else if !shouldRun, displayLinkIsRunning {
            stopDisplayLink?()
            stopDisplayLink = nil
            displayLinkIsRunning = false
        }
    }

    @objc private func tick() {
        let media = clock.mediaTime(atHost: CACurrentMediaTime())
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
        let baseFontSize = min(max(bounds.height * 0.05, 16), 44)
        let fontSize = min(max(baseFontSize * settings.fontScale, 12), 60)
        let spacing = min(max(settings.lineSpacing, 1.05), 2)
        let metricsChanged = fontSize != rasterizer.fontSize
            || (fontSize * spacing).rounded() != rasterizer.lineHeight
        rasterizer.update(fontSize: fontSize, lineHeight: (fontSize * spacing).rounded(), scale: scale)
        // Every cached bitmap was just thrown away; a reused layer would keep
        // drawing the old one at the new size.
        if metricsChanged { discardLayers() }
        engine.updateSettings(settings)
        engine.updateViewport(width: max(bounds.width, 1), height: max(bounds.height, 1), lineHeight: lineHeight)
        if ProcessInfo.processInfo.environment["AG_DANMAKU_LOG"] == "1" {
            let probe = DanmakuComment(id: "probe", time: 0, text: "測試", mode: .scroll)
            let bitmap = rasterizer.bitmap(for: probe)
            FileHandle.standardError.write(Data(String(
                format: "DANMAKU bounds=%.0fx%.0f font=%.2f line=%.2f rasterScale=%d contentsScale=%.1f probe=%dx%dpx probeWidthPt=%.1f\n",
                bounds.width, bounds.height, fontSize, lineHeight, scale, contentsScale,
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
            let layer = orderedLayers[index]
            layer.position = CGPoint(x: active[index].x, y: active[index].y)
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

    private func commentForRaster(_ item: DanmakuActiveComment) -> DanmakuComment {
        DanmakuComment(id: item.id, time: 0, text: item.text, mode: item.mode, color: item.color)
    }
}
