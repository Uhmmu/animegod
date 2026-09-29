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
        let line = textLine(comment)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) + 6
        trimIfNeeded()
        widths[key] = width
        return width
    }

    public func bitmap(for comment: DanmakuComment) -> CGImage? {
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
        // CGColor rather than NSColor/UIColor: CoreText takes the Core
        // Graphics colour directly, and that is the same call on both
        // platforms.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let fill = CGColor(colorSpace: space, components: [rgb.r, rgb.g, rgb.b, 1])
        let stroke = CGColor(colorSpace: space, components: [0, 0, 0, 1])
        // CoreText's own attribute names, not AppKit's or UIKit's: the
        // `.font` / `.foregroundColor` spellings are declared by those
        // frameworks, and this file has neither.
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            // Negative stroke width: stroke *and* fill, which is what gives
            // the text its outline against bright video.
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -2.5
        ]
        if let fill {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = fill
        }
        if let stroke {
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = stroke
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
