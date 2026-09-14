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
}

/// Measures and rasterizes comment text. Danmaku text repeats heavily, so
/// every unique (text, font size, color, scale) combination is rasterized
/// once into a bitmap and blitted thereafter. Main-thread only.
final class DanmakuTextRasterizer {
    private struct Key: Hashable {
        let text: String
        let fontSize: Int
        let lineHeight: Int
        let color: Int
        let scale: Int
    }

    private var bitmaps: [Key: CGImage] = [:]
    private var widths: [Key: Double] = [:]
    private(set) var fontSize: Double
    private(set) var lineHeight: Double

    init(lineHeight: Double) {
        self.lineHeight = lineHeight
        self.fontSize = lineHeight * 0.62
    }

    /// Metrics changed (viewport resize / font scale): fonts re-create,
    /// caches invalidate.
    func update(lineHeight newLineHeight: Double, scale: Int) {
        let clamped = min(max(newLineHeight, 16), 64)
        let lineHeightChanged = clamped != lineHeight
        if lineHeightChanged {
            lineHeight = clamped
            fontSize = clamped * 0.62
            bitmaps.removeAll(keepingCapacity: true)
            widths.removeAll(keepingCapacity: true)
        }
        if scale != currentScale {
            bitmaps.removeAll(keepingCapacity: true)
        }
        currentScale = scale
    }

    private var currentScale = 2

    func width(of comment: DanmakuComment) -> Double {
        let key = key(comment)
        if let cached = widths[key] { return cached }
        let line = textLine(comment)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) + 6
        trimIfNeeded()
        widths[key] = width
        return width
    }

    func bitmap(for comment: DanmakuComment) -> CGImage? {
        let key = key(comment)
        if let cached = bitmaps[key] { return cached }
        let line = textLine(comment)
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let scale = CGFloat(currentScale)
        let pixelWidth = max(1, Int(((textWidth + 6) * scale).rounded()))
        let pixelHeight = max(1, Int((lineHeight * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Baseline: vertically centered within the line box.
        context.textPosition = CGPoint(x: 3, y: (lineHeight - fontSize) / 2 + fontSize * 0.18)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        trimIfNeeded()
        bitmaps[key] = image
        return image
    }

    private func key(_ comment: DanmakuComment) -> Key {
        Key(
            text: comment.text,
            fontSize: Int(fontSize.rounded()),
            lineHeight: Int(lineHeight.rounded()),
            color: comment.color,
            scale: currentScale
        )
    }

    private func textLine(_ comment: DanmakuComment) -> CTLine {
        let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, fontSize, nil)
        let rgb = Self.rgbComponents(comment.color)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1),
            .strokeColor: NSColor.black,
            // Negative stroke width: stroke + fill together.
            .strokeWidth: -2.5,
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: comment.text, attributes: attributes)
        )
    }

    private func trimIfNeeded() {
        guard bitmaps.count > 800 else { return }
        let drop = bitmaps.count / 4
        for key in bitmaps.keys.prefix(drop) { bitmaps[key] = nil }
        for key in widths.keys.prefix(drop) { widths[key] = nil }
    }

    fileprivate static func rgbComponents(_ value: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        (
            CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255
        )
    }
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

    /// Layers by comment id; reused across frames, created/removed only on
    /// structural changes.
    private var layers: [String: CALayer] = [:]
    /// Aligned with the engine's active list each structural change so
    /// per-frame updates never touch the dictionary.
    private var orderedLayers: [CALayer] = []

    private var frameCount = 0
    private var lastFPSWindow = CACurrentMediaTime()
    private var fps: Double = 0

    private var lineHeight: Double { rasterizer.lineHeight }

    override init(frame frameRect: NSRect) {
        rasterizer = DanmakuTextRasterizer(lineHeight: max(frameRect.height, 1) * 0.042)
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
        hostLayer.isGeometryFlipped = true
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
        let fontChanged = newSettings.fontScale != settings.fontScale
        settings = newSettings
        hostLayer.opacity = Float(min(max(newSettings.opacity, 0.05), 1))
        if fontChanged {
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
        updateDisplayLinkState()
    }

    /// Player position sample. Anchors the clock; detects seeks by jump
    /// magnitude and rebuilds engine state instead of replaying.
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDisplayLinkState()
    }

    private func updateDisplayLinkState() {
        let shouldRun = window != nil && isVisible && hasComments
        if shouldRun, stopDisplayLink == nil {
            let link = displayLink(target: self, selector: #selector(displayLinkTick))
            stopDisplayLink = { [weak link] in link?.invalidate() }
        } else if !shouldRun, let stop = stopDisplayLink {
            stop()
            stopDisplayLink = nil
        }
    }

    @objc private func displayLinkTick() {
        let host = CACurrentMediaTime()
        let media = clock.mediaTime(atHost: host)

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
            loadedCount: engineDiag.loadedCount
        ))
    }

    // MARK: - Layout

    @objc private func handleFrameChange() {
        recomputeMetrics()
    }

    private func recomputeMetrics() {
        let scale = Int((window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2).rounded())
        rasterizer.update(lineHeight: max(bounds.height, 1) * 0.042, scale: scale)
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
        if structural {
            let liveIDs = Set(active.map(\.id))
            for (id, layer) in layers where !liveIDs.contains(id) {
                layer.removeFromSuperlayer()
                layers[id] = nil
            }
            orderedLayers = active.map { item in
                if let existing = layers[item.id] { return existing }
                let layer = CALayer()
                layer.anchorPoint = .zero
                if let bitmap = rasterizer.bitmap(for: commentForRaster(item)) {
                    layer.contents = bitmap
                }
                layers[item.id] = layer
                hostLayer.addSublayer(layer)
                return layer
            }
        }
        let lineRectHeight = lineHeight
        for index in active.indices {
            orderedLayers[index].frame = CGRect(
                x: active[index].x, y: active[index].y,
                width: max(active[index].width, 1), height: lineRectHeight
            )
        }
        CATransaction.commit()
    }

    private func commentForRaster(_ item: DanmakuActiveComment) -> DanmakuComment {
        DanmakuComment(id: item.id, time: 0, text: item.text, mode: item.mode, color: item.color)
    }
}
