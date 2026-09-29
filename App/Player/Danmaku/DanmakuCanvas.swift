import AnimeGodCore
import AppKit
import CoreText
import QuartzCore

/// Snapshot of renderer internals for the diagnostics panel.
struct DanmakuRendererSnapshot: Sendable {
    var fps: Double = 0
    var activeCount = 0
    var droppedForCapacity = 0
    var droppedNoLane = 0
    var skippedOnSeek = 0
    var loadedCount = 0
    var totalCount = 0
    var mergedCount = 0
    var hiddenCount = 0
}

/// Native danmaku renderer: a mouse-transparent, layer-hosted NSView
/// driven by the display link. Comments are rasterized once into cached
/// bitmaps and moved by writing layer frames inside disabled CATransactions
/// — no SwiftUI involvement per frame, no per-frame layout or allocation,
/// and nothing here touches the video's Metal/HDR pipeline (the overlay is
/// a plain sRGB layer above it).
///
/// Synchronization: the player pushes position anchors; between anchors
/// media time is interpolated using the player-reported speed. Pause
/// freezes the clock (animations stop dead), seeks are detected by jump
/// magnitude and rebuild the engine state, and speed changes re-anchor.
@MainActor
final class DanmakuCanvas: NSView {
    var onDiagnostics: (@MainActor (DanmakuRendererSnapshot) -> Void)?

    private let hostLayer = CALayer()
    /// The display link's type is not Swift-nameable; keep only its
    /// invalidate closure. Deinit-only access from the nonisolated
    /// finalizer; safe because the object is already unreferenced there.
    nonisolated(unsafe) private var stopDisplayLink: (() -> Void)?
    private let rasterizer: DanmakuTextRasterizer

    private var clock = DanmakuPlaybackClock()
    private var engine: DanmakuEngine!
    private var settings: DanmakuDisplaySettings = .default
    private var hasComments = false
    private var isVisible = true
    /// The engine does not tick while there are no comments. Keep the latest
    /// player position separately so a late match starts at the current scene
    /// instead of scanning the entire movie from zero on its first frame.
    private var latestPlaybackPosition: Double = 0

    /// Layers aligned with the engine's active list, plus the comment ids
    /// and drawn widths they currently carry. Reconciling these three by a
    /// two-pointer walk (below) keeps structural frames free of hashing and
    /// allocation, which matters because a dense danmaku stream spawns or
    /// expires something on almost every frame.
    private var orderedLayers: [CALayer] = []
    private var orderedIDs: [String] = []
    private var orderedWidths: [Double] = []
    /// Scratch buffers for the reconcile, kept alive so the walk allocates
    /// nothing per frame.
    private var scratchLayers: [CALayer] = []
    private var scratchIDs: [String] = []
    private var scratchWidths: [Double] = []
    /// Retired layers, kept in the tree but hidden. Adding and removing
    /// sublayers is the expensive part of a structural change; reusing a
    /// hidden layer is not.
    private var freeLayers: [CALayer] = []

    private var frameCount = 0
    private var lastFPSWindow = CACurrentMediaTime()
    private var fps: Double = 0

    private var lineHeight: Double { rasterizer.lineHeight }

    override init(frame frameRect: NSRect) {
        // Placeholder metrics; recomputeMetrics() below derives the real ones.
        rasterizer = DanmakuTextRasterizer(fontSize: 16, lineHeight: 21)
        super.init(frame: frameRect)
        let rast = rasterizer
        engine = DanmakuEngine(
            viewportWidth: max(frameRect.width, 1),
            viewportHeight: max(frameRect.height, 1),
            lineHeight: rasterizer.lineHeight,
            measure: { rast.width(of: $0) }
        )
        wantsLayer = true
        layer = hostLayer
        // Keep Core Animation's native bottom-left coordinates and convert
        // the engine's top-origin lane positions explicitly in syncLayers.
        // A geometry-flipped root hosting layer is not reliably inherited by
        // its sublayers and previously made scrolling lanes grow upward from
        // the bottom of the player.
        hostLayer.isGeometryFlipped = false
        hostLayer.backgroundColor = NSColor.clear.cgColor
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFrameChange),
            name: NSView.frameDidChangeNotification, object: self
        )
        recomputeMetrics()
    }

    /// Clicks, moves, and gestures pass straight through to the player
    /// surface below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopDisplayLink?()
    }

    // MARK: - Public inputs

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

    /// Delivers a comment list for the current episode. `shift` is the
    /// provider-reported delay, baked in once.
    func setComments(_ comments: [DanmakuComment], shift: Double) {
        let baked: [DanmakuComment]
        if shift != 0 {
            baked = comments.map { comment in
                DanmakuComment(
                    id: comment.id, time: comment.time + shift, text: comment.text,
                    mode: comment.mode, color: comment.color,
                    senderID: comment.senderID, timestamp: comment.timestamp
                )
            }
        } else {
            baked = comments
        }
        hasComments = !baked.isEmpty
        engine.load(comments: baked)
        engine.seek(to: max(0, latestPlaybackPosition))
        syncLayers(structural: true)
        publishDiagnostics()
        updateDisplayLinkState()
    }

    /// Player position sample. Anchors the clock; detects seeks by jump
    /// magnitude and rebuilds engine state instead of replaying.
    func playbackSample(position: Double, speed: Double, paused: Bool, hostTime: Double = CACurrentMediaTime()) {
        latestPlaybackPosition = max(0, position)
        // Tracked, not anchored: mpv reports a position quantised to the
        // video frame period, so taking each one whole shakes the timeline
        // several times a second. See `DanmakuPlaybackClock.sample`.
        if clock.sample(position: position, speed: speed, playing: !paused, hostTime: hostTime) == .discontinuous {
            engine.seek(to: max(0, position))
            syncLayers(structural: true)
        }
    }

    // MARK: - Display link

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDisplayLinkState()
    }

    private func updateDisplayLinkState() {
        let shouldRun = window != nil && isVisible && hasComments
        if shouldRun, stopDisplayLink == nil {
            let link = displayLink(target: self, selector: #selector(displayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            stopDisplayLink = { [weak link] in link?.invalidate() }
        } else if !shouldRun, let stop = stopDisplayLink {
            stop()
            stopDisplayLink = nil
        }
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        let host = CACurrentMediaTime()
        // The frame's own display time, not the callback's arrival time: the
        // latter carries the run loop's scheduling jitter straight into every
        // comment's position.
        let media = clock.mediaTime(atHost: link.targetTimestamp)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let structural = engine.tick(at: media)
        syncLayers(structural: structural)
        CATransaction.commit()

        frameCount += 1
        if host - lastFPSWindow >= 1 {
            fps = Double(frameCount) / (host - lastFPSWindow)
            frameCount = 0
            lastFPSWindow = host
            publishDiagnostics()
        }
    }

    private func publishDiagnostics() {
        guard let onDiagnostics else { return }
        let engineDiag = engine.diagnostics
        onDiagnostics(DanmakuRendererSnapshot(
            fps: fps,
            activeCount: engine.activeComments.count,
            droppedForCapacity: engineDiag.droppedForCapacity,
            droppedNoLane: engineDiag.droppedNoLane,
            skippedOnSeek: engineDiag.skippedOnSeek,
            loadedCount: engineDiag.loadedCount,
            totalCount: engineDiag.totalCount,
            mergedCount: engineDiag.mergedCount,
            hiddenCount: engineDiag.hiddenCount
        ))
    }

    // MARK: - Layout

    @objc private func handleFrameChange() {
        recomputeMetrics()
    }

    /// Drops every layer back into the pool. Used when the rasterized
    /// bitmaps themselves become stale (font size or line height changed),
    /// since a recycled layer otherwise keeps the old image.
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
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        hostLayer.addSublayer(layer)
        return layer
    }

    private func recomputeMetrics() {
        let scale = Int((window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2).rounded())
        // Base size tracks the player height (≈29pt in a 1117pt-tall
        // fullscreen window); the user scale and line spacing apply on top.
        let baseFontSize = min(max(bounds.height * 0.026, 14), 40)
        let fontSize = min(max(baseFontSize * settings.fontScale, 10), 60)
        let spacing = min(max(settings.lineSpacing, 1.05), 2)
        let metricsChanged = fontSize != rasterizer.fontSize
            || (fontSize * spacing).rounded() != rasterizer.lineHeight
        rasterizer.update(fontSize: fontSize, lineHeight: (fontSize * spacing).rounded(), scale: scale)
        // Every cached bitmap was just thrown away; a reused layer would
        // otherwise keep drawing the old one at the new size.
        if metricsChanged { discardLayers() }
        engine.updateSettings(settings)
        engine.updateViewport(width: max(bounds.width, 1), height: max(bounds.height, 1), lineHeight: lineHeight)
        syncLayers(structural: true)
    }

    // MARK: - Layer sync

    /// Applies engine output onto layers. Structural changes reconcile the
    /// layer dictionary incrementally (dead layers removed, new ones
    /// added); position-only frames then walk the aligned `orderedLayers`
    /// array — no per-frame hashing, allocation, or implicit animation.
    private func syncLayers(structural: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let active = engine.activeComments
        let lineRectHeight = lineHeight
        if structural {
            // Both lists are in spawn order and expiry compacts in place, so
            // the new list is the old one minus some entries plus appends:
            // one forward walk matches them up. Ids that fall out hand their
            // layer to the pool, new ids take one from it.
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
            // Engine lanes are expressed from the top edge (lane zero is the
            // first row). CALayer positions use a bottom-left origin here,
            // and with anchorPoint .zero the position *is* the frame origin.
            let layerY = max(0, bounds.height - active[index].y - lineRectHeight)
            let layer = orderedLayers[index]
            layer.position = CGPoint(x: active[index].x, y: layerY)
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
