import CryptoKit
import Foundation

/// Minimal, bounded bencode reader for `.torrent` files.
///
/// Only what AnimeGod needs: validate structure, compute the v1 info hash
/// from the *raw* `info` bytes (re-encoding could reorder keys and change the
/// hash), and read the name, total size and file list. Limits mirror
/// magnet-crawler's downloader so a hostile file can't exhaust memory.
public struct TorrentFile: Sendable {
    public struct Entry: Hashable, Sendable {
        public var path: [String]
        public var length: Int64
    }

    public let infoHash: TorrentInfoHash
    public let name: String
    public let files: [Entry]
    public let announce: [String]

    public var totalSize: Int64 { files.reduce(0) { $0 + $1.length } }

    public enum ParseError: Error, Equatable {
        case malformed(String)
        case tooLarge
        case missingInfo
        case unsafePath
    }

    public static let maximumBytes = 10 * 1024 * 1024

    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw ParseError.tooLarge }
        var reader = BencodeReader(bytes: [UInt8](data))
        guard case .dictionary(let root, _) = try reader.readValue(depth: 0), reader.offset == reader.bytes.count else {
            throw ParseError.malformed("root is not a single dictionary")
        }
        guard let infoValue = root["info"], case .dictionary(let info, let range) = infoValue else {
            throw ParseError.missingInfo
        }
        infoHash = TorrentInfoHash(bytes: Array(Insecure.SHA1.hash(data: reader.bytes[range])))!

        name = info["name.utf-8"]?.string ?? info["name"]?.string ?? ""
        if case .list(let items)? = info["files"] {
            files = try items.map { item in
                guard case .dictionary(let file, _) = item,
                      let length = file["length"]?.integer, length >= 0,
                      case .list(let parts)? = file["path.utf-8"] ?? file["path"] else {
                    throw ParseError.malformed("bad file entry")
                }
                let path = parts.compactMap(\.string)
                guard path.count == parts.count, !path.isEmpty,
                      !path.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("/") }) else {
                    throw ParseError.unsafePath
                }
                return Entry(path: path, length: length)
            }
        } else if let length = info["length"]?.integer, length >= 0 {
            guard !name.isEmpty, !name.contains("/"), name != "..", name != "." else { throw ParseError.unsafePath }
            files = [Entry(path: [name], length: length)]
        } else {
            throw ParseError.malformed("info has neither length nor files")
        }

        var trackers: [String] = []
        if let single = root["announce"]?.string { trackers.append(single) }
        if case .list(let tiers)? = root["announce-list"] {
            for tier in tiers {
                guard case .list(let urls) = tier else { continue }
                for url in urls.compactMap(\.string) where !trackers.contains(url) { trackers.append(url) }
            }
        }
        announce = trackers
    }
}

private indirect enum BencodeValue {
    case integer(Int64)
    case bytes([UInt8])
    case list([BencodeValue])
    /// The byte range lets callers hash a dictionary exactly as encoded.
    case dictionary([String: BencodeValue], Range<Int>)

    var string: String? {
        guard case .bytes(let bytes) = self else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    var integer: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }
}

private struct BencodeReader {
    let bytes: [UInt8]
    var offset = 0
    var nodes = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func readValue(depth: Int) throws -> BencodeValue {
        guard depth < 64 else { throw TorrentFile.ParseError.malformed("nesting too deep") }
        nodes += 1
        guard nodes <= 200_000 else { throw TorrentFile.ParseError.malformed("too many nodes") }
        guard offset < bytes.count else { throw TorrentFile.ParseError.malformed("truncated") }
        switch bytes[offset] {
        case UInt8(ascii: "i"):
            offset += 1
            let value = try readInteger(until: UInt8(ascii: "e"))
            return .integer(value)
        case UInt8(ascii: "l"):
            offset += 1
            var items: [BencodeValue] = []
            while try peek() != UInt8(ascii: "e") {
                items.append(try readValue(depth: depth + 1))
            }
            offset += 1
            return .list(items)
        case UInt8(ascii: "d"):
            let start = offset
            offset += 1
            var dictionary: [String: BencodeValue] = [:]
            while try peek() != UInt8(ascii: "e") {
                guard case .bytes(let keyBytes) = try readValue(depth: depth + 1) else {
                    throw TorrentFile.ParseError.malformed("dictionary key is not a string")
                }
                let key = String(decoding: keyBytes, as: UTF8.self)
                guard dictionary[key] == nil else { throw TorrentFile.ParseError.malformed("duplicate key") }
                dictionary[key] = try readValue(depth: depth + 1)
            }
            offset += 1
            return .dictionary(dictionary, start..<offset)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            let length = try readInteger(until: UInt8(ascii: ":"))
            guard length >= 0, length <= bytes.count - offset else { throw TorrentFile.ParseError.malformed("string overruns data") }
            let value = Array(bytes[offset..<(offset + Int(length))])
            offset += Int(length)
            return .bytes(value)
        default:
            throw TorrentFile.ParseError.malformed("unexpected byte")
        }
    }

    private func peek() throws -> UInt8 {
        guard offset < bytes.count else { throw TorrentFile.ParseError.malformed("truncated") }
        return bytes[offset]
    }

    private mutating func readInteger(until terminator: UInt8) throws -> Int64 {
        guard let end = bytes[offset...].firstIndex(of: terminator), end - offset <= 20, end > offset else {
            throw TorrentFile.ParseError.malformed("bad integer")
        }
        guard let text = String(bytes: bytes[offset..<end], encoding: .ascii), let value = Int64(text) else {
            throw TorrentFile.ParseError.malformed("bad integer")
        }
        offset = end + 1
        return value
    }
}
