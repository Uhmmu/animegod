import Foundation

/// One comment as Bilibili's protobuf schema describes it
/// (`bilibili.community.service.dm.v1.DanmakuElem`). Field numbers are part
/// of the wire contract and never change; unknown fields are ignored.
public struct BilibiliDanmakuElem: Hashable, Sendable {
    public var id: Int64 = 0
    /// Appearance time in milliseconds from the start of the video.
    public var progress: Int32 = 0
    /// Raw Bilibili display mode; see `BilibiliDanmakuMode`.
    public var mode: Int32 = 1
    public var fontSize: Int32 = 25
    /// Decimal RGB888, e.g. 16777215 for white.
    public var color: UInt32 = 0xFF_FFFF
    /// CRC32 hash of the sender's user id — Bilibili never exposes the id.
    public var midHash: String = ""
    public var content: String = ""
    /// Unix seconds when the comment was posted.
    public var ctime: Int64 = 0
    /// Bilibili's own quality weight, 1...11. Higher is better; the site's
    /// own "smart filter" levels are thresholds on this value.
    public var weight: Int32 = 0
    public var action: String = ""
    /// 0 normal, 1 subtitle pool, 2 special (advanced) pool.
    public var pool: Int32 = 0
    /// String form of `id`; authoritative when `id` overflows.
    public var idStr: String = ""
    /// Bit flags: 1 protected, 2 from a live room, 4 highly liked.
    public var attr: Int32 = 0

    public init() {}
}

/// Bilibili's display-mode codes.
public enum BilibiliDanmakuMode {
    public static let scrollRightToLeft: Int32 = 1
    public static let scrollAlternate1: Int32 = 2
    public static let scrollAlternate2: Int32 = 3
    public static let bottom: Int32 = 4
    public static let top: Int32 = 5
    public static let reverseScroll: Int32 = 6
    public static let advanced: Int32 = 7
    public static let code: Int32 = 8
    public static let bas: Int32 = 9

    /// Maps a Bilibili mode onto the player's presentation intents.
    ///
    /// 1/2/3 are the three ordinary right-to-left scrolling variants and 6 is
    /// the reverse (left-to-right) variant; the renderer has one scrolling
    /// lane type, so 6 renders as an ordinary scroll rather than being
    /// dropped. 7 (advanced), 8 (code) and 9 (BAS) carry scripted
    /// positioning payloads instead of display text — rendering their raw
    /// content would print JSON on the video, so they are skipped.
    public static func presentationMode(for raw: Int32) -> DanmakuMode? {
        switch raw {
        case scrollRightToLeft, scrollAlternate1, scrollAlternate2, reverseScroll: .scroll
        case bottom: .bottom
        case top: .top
        default: nil
        }
    }
}

/// Decoder for `DmSegMobileReply { repeated DanmakuElem elems = 1; }`.
public enum BilibiliDanmakuSegmentDecoder {
    /// Decodes one protobuf segment into raw elements.
    ///
    /// Damage is contained twice over: an element whose body fails to decode
    /// is dropped on its own, and a corrupt length header — which makes the
    /// rest of the buffer unparseable, since field boundaries are no longer
    /// known — keeps everything decoded before it. A single bad comment must
    /// not cost the viewer the other three thousand. The error is only
    /// raised when nothing at all could be read.
    public static func decodeSegment(_ data: Data) throws -> [BilibiliDanmakuElem] {
        var elements: [BilibiliDanmakuElem] = []
        do {
            try ProtobufWireReader.forEachField(in: data) { field, value in
                guard field == 1, let payload = value.data else { return }
                if let element = try? decodeElement(payload) { elements.append(element) }
            }
        } catch {
            guard !elements.isEmpty else { throw error }
        }
        return elements
    }

    static func decodeElement(_ data: Data) throws -> BilibiliDanmakuElem {
        var element = BilibiliDanmakuElem()
        try ProtobufWireReader.forEachField(in: data) { field, value in
            switch field {
            case 1: element.id = value.signed
            case 2: element.progress = value.int32
            case 3: element.mode = value.int32
            case 4: element.fontSize = value.int32
            case 5: element.color = UInt32(truncatingIfNeeded: value.unsigned)
            case 6: element.midHash = value.string ?? ""
            case 7: element.content = value.string ?? ""
            case 8: element.ctime = value.signed
            case 9: element.weight = value.int32
            case 10: element.action = value.string ?? ""
            case 11: element.pool = value.int32
            case 12: element.idStr = value.string ?? ""
            case 13: element.attr = value.int32
            default: break
            }
        }
        return element
    }
}

public extension BilibiliDanmakuElem {
    /// Stable identifier: `idStr` is authoritative because Bilibili's newer
    /// ids exceed what some clients read as `int64`.
    var stableID: String { idStr.isEmpty ? String(id) : idStr }

    /// Converts to the player's provider-independent comment, or nil when
    /// the element carries no renderable text (special pools, empty content,
    /// unmapped modes).
    func makeComment(providerID: String) -> DanmakuComment? {
        // Pool 2 is the special/advanced pool: scripted payloads, not text.
        guard pool != 2, let mode = BilibiliDanmakuMode.presentationMode(for: mode) else { return nil }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return DanmakuComment(
            id: "\(providerID):\(stableID)",
            time: max(0, Double(progress) / 1000),
            text: text,
            mode: mode,
            color: Int(color) & 0xFF_FFFF,
            senderID: midHash.isEmpty ? nil : midHash,
            timestamp: ctime > 0 ? Date(timeIntervalSince1970: TimeInterval(ctime)) : nil,
            source: providerID
        )
    }
}
