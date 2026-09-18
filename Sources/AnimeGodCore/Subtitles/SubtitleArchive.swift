import Compression
import Foundation

/// Expands the ZIP archives subtitle sites serve. Only what subtitle packs
/// use is supported — stored and deflated entries — with hard size limits
/// so a hostile archive cannot exhaust memory. RAR and 7z are recognized
/// and rejected with a clear error instead of being mistaken for text.
public enum SubtitleArchive {
    public static let maximumEntryBytes = 32 * 1024 * 1024
    public static let maximumEntries = 500

    public enum Kind: String, Sendable {
        case zip, rar, sevenZip = "7z", none
    }

    public static func kind(of data: Data) -> Kind {
        let head = [UInt8](data.prefix(6))
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) || head.starts(with: [0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if head.starts(with: [0x52, 0x61, 0x72, 0x21]) { return .rar }
        if head.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        return .none
    }

    /// Replaces every archive in `files` by its contents (one level deep),
    /// leaving plain files as they are. Archive folders are flattened into
    /// the entry name ("Fonts/xxx.ttf") so callers can still see them.
    public static func expand(_ files: [SubtitleDownloadedFile]) throws -> [SubtitleDownloadedFile] {
        var expanded: [SubtitleDownloadedFile] = []
        var rejected: Kind?
        for file in files {
            switch kind(of: file.data) {
            case .zip: expanded += try zipEntries(file.data)
            case .rar, .sevenZip: rejected = kind(of: file.data)
            case .none: expanded.append(file)
            }
        }
        if expanded.isEmpty, let rejected { throw SubtitleProviderError.unsupportedArchive(rejected.rawValue.uppercased()) }
        return expanded
    }

    public static func zipEntries(_ data: Data) throws -> [SubtitleDownloadedFile] {
        let bytes = [UInt8](data)
        guard let end = endOfCentralDirectory(in: bytes) else { throw SubtitleProviderError.invalidSubtitle }
        let entryCount = Int(readUInt16(bytes, end + 10))
        var offset = Int(readUInt32(bytes, end + 16))
        guard entryCount <= maximumEntries else { throw SubtitleProviderError.invalidSubtitle }

        var files: [SubtitleDownloadedFile] = []
        for _ in 0..<entryCount {
            guard offset + 46 <= bytes.count, readUInt32(bytes, offset) == 0x02014B50 else { break }
            let flags = readUInt16(bytes, offset + 8)
            let method = readUInt16(bytes, offset + 10)
            let compressedSize = Int(readUInt32(bytes, offset + 20))
            let uncompressedSize = Int(readUInt32(bytes, offset + 24))
            let nameLength = Int(readUInt16(bytes, offset + 28))
            let extraLength = Int(readUInt16(bytes, offset + 30))
            let commentLength = Int(readUInt16(bytes, offset + 32))
            let localOffset = Int(readUInt32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else { break }
            let nameBytes = Array(bytes[(offset + 46)..<(offset + 46 + nameLength)])
            offset += 46 + nameLength + extraLength + commentLength

            let name = decodeName(nameBytes, isUTF8: flags & 0x0800 != 0)
            guard !name.hasSuffix("/"), !name.hasPrefix("__MACOSX"), !name.contains("/._"),
                  flags & 0x0001 == 0, // encrypted
                  uncompressedSize <= maximumEntryBytes else { continue }

            guard localOffset + 30 <= bytes.count, readUInt32(bytes, localOffset) == 0x04034B50 else { continue }
            let localNameLength = Int(readUInt16(bytes, localOffset + 26))
            let localExtraLength = Int(readUInt16(bytes, localOffset + 28))
            let start = localOffset + 30 + localNameLength + localExtraLength
            guard start + compressedSize <= bytes.count else { continue }
            let payload = Array(bytes[start..<(start + compressedSize)])

            switch method {
            case 0:
                files.append(SubtitleDownloadedFile(name: name, data: Data(payload)))
            case 8:
                if let inflated = inflate(payload, expectedSize: uncompressedSize) {
                    files.append(SubtitleDownloadedFile(name: name, data: inflated))
                }
            default:
                continue
            }
        }
        return files
    }

    private static func endOfCentralDirectory(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 65_535)
        var index = bytes.count - 22
        while index >= lowest {
            if readUInt32(bytes, index) == 0x06054B50 { return index }
            index -= 1
        }
        return nil
    }

    /// ZIP names are UTF-8 only when flagged; Chinese archives made on
    /// Windows store GBK (occasionally Big5) instead.
    private static func decodeName(_ bytes: [UInt8], isUTF8: Bool) -> String {
        let data = Data(bytes)
        if isUTF8, let name = String(data: data, encoding: .utf8) { return name }
        if let name = String(data: data, encoding: .utf8) { return name }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let name = String(data: data, encoding: gb18030) { return name }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Raw DEFLATE (RFC 1951) — what `COMPRESSION_ZLIB` implements.
    private static func inflate(_ payload: [UInt8], expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        guard !payload.isEmpty else { return nil }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = payload.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(
                    destination.baseAddress!, expectedSize,
                    source.baseAddress!, payload.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { return nil }
        return Data(output)
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
