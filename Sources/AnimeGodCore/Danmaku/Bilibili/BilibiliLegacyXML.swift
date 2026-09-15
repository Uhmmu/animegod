import Compression
import Foundation

/// Raw DEFLATE support for the legacy XML danmaku endpoint.
///
/// `/x/v1/dm/list.so` historically answers with a raw deflate stream that
/// carries no `Content-Encoding` header, so URLSession hands it over
/// untouched. Only the debug path needs this.
public enum BilibiliDeflate {
    public static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = max(data.count * 8, 64 * 1024)
        var output = Data()
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        output.append(destination, count: written)
        return output
    }
}

/// Parser for the legacy `<d p="...">text</d>` danmaku XML.
///
/// Kept as a debugging aid and a last-resort fallback only. The pool it
/// returns is capped and server-sampled, so it is materially less complete
/// than the protobuf segments; the provider never prefers it.
public enum BilibiliLegacyXMLParser {
    /// `p` is `time,mode,fontsize,color,ctime,pool,midHash,dmid`.
    public static func parse(_ xml: String) -> [BilibiliDanmakuElem] {
        guard let regex = try? NSRegularExpression(
            pattern: "<d\\s+p=\"([^\"]*)\"[^>]*>(.*?)</d>",
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(xml.startIndex..., in: xml)
        return regex.matches(in: xml, range: range).compactMap { match in
            guard match.numberOfRanges == 3,
                  let attributeRange = Range(match.range(at: 1), in: xml),
                  let textRange = Range(match.range(at: 2), in: xml) else { return nil }
            return element(attributes: String(xml[attributeRange]), text: String(xml[textRange]))
        }
    }

    static func element(attributes: String, text: String) -> BilibiliDanmakuElem? {
        let fields = attributes.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4, let seconds = Double(fields[0]) else { return nil }
        var element = BilibiliDanmakuElem()
        element.progress = Int32(clamping: Int((max(0, seconds) * 1000).rounded()))
        element.mode = Int32(fields[1]) ?? 1
        element.fontSize = Int32(fields[2]) ?? 25
        element.color = UInt32(fields[3]) ?? 0xFF_FFFF
        if fields.count > 4, let ctime = Int64(fields[4]) { element.ctime = ctime }
        if fields.count > 5, let pool = Int32(fields[5]) { element.pool = pool }
        if fields.count > 6 { element.midHash = fields[6] }
        if fields.count > 7 { element.idStr = fields[7] }
        element.content = decodeEntities(text)
        return element.content.isEmpty ? nil : element
    }

    private static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
