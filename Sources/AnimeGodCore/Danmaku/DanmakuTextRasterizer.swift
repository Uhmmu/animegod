import CoreGraphics
import CoreText
import Foundation

/// Measures and rasterizes comment text.
///
/// Danmaku text repeats heavily, so every unique (text, font size, colour,
/// scale) combination is rasterized once into a bitmap and blitted thereafter.
/// Main-thread only.
///
/// Lives in the core rather than beside either renderer because it is pure
/// CoreText and CoreGraphics — no AppKit, no UIKit — and both the Mac's canvas
/// and the phone's need exactly the same glyphs. What genuinely differs
/// between the two platforms is the view lifecycle, the display link and the
/// layer coordinate origin, and that stays in each canvas.
public final class DanmakuTextRasterizer {
    private struct Key: Hashable {
        let text: String
        let fontSize: Int
        let lineHeight: Int
        let color: Int
        let scale: Int
    }

    private var bitmaps: [Key: CGImage] = [:]
    private var widths: [Key: Double] = [:]
    public private(set) var fontSize: Double
    public private(set) var lineHeight: Double
    private var currentScale = 2

    public init(fontSize: Double, lineHeight: Double) {
        self.fontSize = fontSize
        self.lineHeight = lineHeight
    }

    /// Metrics changed (viewport resize / font scale / line spacing): fonts
    /// re-create, caches invalidate.
    public func update(fontSize newFontSize: Double, lineHeight newLineHeight: Double, scale: Int) {
        if newFontSize != fontSize || newLineHeight != lineHeight {
            fontSize = newFontSize
            lineHeight = newLineHeight
            bitmaps.removeAll(keepingCapacity: true)
            widths.removeAll(keepingCapacity: true)
        }
        if scale != currentScale {
            bitmaps.removeAll(keepingCapacity: true)
        }
        currentScale = scale
    }

    public func width(of comment: DanmakuComment) -> Double {
        let key = key(comment)
        if let cached = widths[key] { return cached }
        let line = textLine(comment, pass: .fill)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) + Self.padding * 2
        trimIfNeeded()
        widths[key] = width
        return width
    }

    public func bitmap(for comment: DanmakuComment) -> CGImage? {
        let key = key(comment)
        if let cached = bitmaps[key] { return cached }
        let outline = textLine(comment, pass: .outline)
        let fill = textLine(comment, pass: .fill)
        let textWidth = CTLineGetTypographicBounds(fill, nil, nil, nil)
        let scale = CGFloat(currentScale)
        let pixelWidth = max(1, Int(((textWidth + Self.padding * 2) * scale).rounded()))
        let pixelHeight = max(1, Int((lineHeight * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Baseline: vertically centered within the line box.
        let baseline = CGPoint(x: Self.padding, y: (lineHeight - fontSize) / 2 + fontSize * 0.18)
        // Two passes, and the order is the whole point. A single
        // fill-and-stroke pass (a negative stroke width) fills the glyph and
        // then strokes it **on top**, and the stroke is centred on the
        // outline — half of that black sits *inside* the letterform. Latin
        // text survives it; a CJK glyph at 16pt has strokes about a pixel
        // wide and a 1px gap between them, so the inward half swallows the
        // stroke and closes the gap, and the character turns into a dark
        // smudge exactly where strokes crowd together. Drawing the outline
        // first and the fill over it leaves only the outward half visible.
        context.textPosition = baseline
        CTLineDraw(outline, context)
        context.textPosition = baseline
        CTLineDraw(fill, context)
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

    /// Which of the two drawing passes a line is built for.
    private enum Pass {
        /// Black, stroke only, wide enough that half of it shows outside the
        /// glyph. Drawn first.
        case outline
        /// The comment's own colour, fill only. Drawn over the outline.
        case fill
    }

    /// Horizontal padding, in points, so the outline is not clipped by the
    /// bitmap edge. `strokePercent` is a percentage of the font size, half of
    /// it outside the glyph, so this is comfortable at every size used.
    private static let padding: Double = 3
    /// Stroke width as a percentage of the font size, the unit CoreText uses
    /// for `kCTStrokeWidthAttributeName`.
    private static let strokePercent: Double = 6

    private func textLine(_ comment: DanmakuComment, pass: Pass) -> CTLine {
        let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, fontSize, nil)
        let rgb = Self.rgbComponents(comment.color)
        // CGColor rather than NSColor/UIColor: CoreText takes the Core
        // Graphics colour directly, and that is the same call on both
        // platforms.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // CoreText's own attribute names, not AppKit's or UIKit's: the
        // `.font` / `.foregroundColor` spellings are declared by those
        // frameworks, and this file has neither.
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        switch pass {
        case .outline:
            // A positive stroke width is stroke *without* fill.
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = Self.strokePercent
            if let stroke = CGColor(colorSpace: space, components: [0, 0, 0, 1]) {
                attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = stroke
            }
        case .fill:
            if let fill = CGColor(colorSpace: space, components: [rgb.r, rgb.g, rgb.b, 1]) {
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = fill
            }
        }
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

    public static func rgbComponents(_ value: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        (
            CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255
        )
    }
}
