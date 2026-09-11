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
        let window: UInt64 = 8 * 1_024 * 1_024
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
        guard data.count >= 13 else { return nil }
        for (tag, kind) in [
            ("dvvC", DolbyVisionConfigurationKind.dvvC),
            ("dvcC", DolbyVisionConfigurationKind.dvcC)
        ] {
            let marker = Data(tag.utf8)
            var search = data.startIndex..<data.endIndex
            while let range = data.range(of: marker, in: search) {
                let index = range.lowerBound
                guard index >= data.startIndex + 4, range.upperBound + 5 <= data.endIndex else {
                    search = range.upperBound..<data.endIndex
                    continue
                }
                let sizeIndex = index - 4
                let declaredSize = Int(data[sizeIndex]) << 24 | Int(data[sizeIndex + 1]) << 16
                    | Int(data[sizeIndex + 2]) << 8 | Int(data[sizeIndex + 3])
                if declaredSize >= 13,
                   let metadata = DolbyVisionConfigurationParser.parse(
                       data.subdata(in: range.upperBound..<(range.upperBound + 5)), kind: kind
                   ) {
                    let nearbyStart = max(data.startIndex, index - 64)
                    let nearby = String(data: data.subdata(in: nearbyStart..<index), encoding: .isoLatin1) ?? ""
                    let codecTag = nearby.contains("hvc1") ? "hvc1" : nearby.contains("hev1") ? "hev1" : nil
                    return Result(metadata: metadata, codecTag: codecTag)
                }
                search = range.upperBound..<data.endIndex
            }
        }
        return nil
    }
}
