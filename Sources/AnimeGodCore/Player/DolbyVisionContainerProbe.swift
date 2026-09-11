import Foundation

/// Lightweight, bounded container probe used before playback. It recognizes
/// real dvcC/dvvC boxes and never classifies Dolby Vision from a filename.
public enum DolbyVisionContainerProbe {
    public struct Result: Sendable, Equatable {
        public let metadata: DolbyVisionMetadata
        public let codecTag: String?

        public init(metadata: DolbyVisionMetadata, codecTag: String?) {
            self.metadata = metadata
            self.codecTag = codecTag
        }
    }

    public static func inspect(url: URL) -> Result? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 32 * 1_024 * 1_024
        var chunks: [Data] = []
        try? handle.seek(toOffset: 0)
        if let head = try? handle.read(upToCount: Int(min(size, window))) { chunks.append(head) }
        if size > window {
            try? handle.seek(toOffset: size - window)
            if let tail = try? handle.read(upToCount: Int(window)) { chunks.append(tail) }
        }
        for data in chunks {
            if let result = inspect(data: data) { return result }
        }
        return nil
    }

    public static func inspect(data: Data) -> Result? {
        let bytes = [UInt8](data)
        guard bytes.count >= 13 else { return nil }
        for index in 4...(bytes.count - 9) {
            let tag = String(bytes: bytes[index..<(index + 4)], encoding: .ascii)
            guard tag == "dvvC" || tag == "dvcC" else { continue }
            let declaredSize = Int(bytes[index - 4]) << 24 | Int(bytes[index - 3]) << 16
                | Int(bytes[index - 2]) << 8 | Int(bytes[index - 1])
            guard declaredSize >= 13, index + 9 <= bytes.count else { continue }
            let kind: DolbyVisionConfigurationKind = tag == "dvvC" ? .dvvC : .dvcC
            guard let metadata = DolbyVisionConfigurationParser.parse(
                Data(bytes[(index + 4)..<(index + 9)]), kind: kind
            ) else { continue }
            let searchStart = max(0, index - 64)
            let nearby = String(bytes: bytes[searchStart..<index], encoding: .isoLatin1) ?? ""
            let codecTag = nearby.contains("hvc1") ? "hvc1" : nearby.contains("hev1") ? "hev1" : nil
            return Result(metadata: metadata, codecTag: codecTag)
        }
        return nil
    }
}
