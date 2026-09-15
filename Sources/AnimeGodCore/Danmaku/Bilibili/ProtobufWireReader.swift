import Foundation

/// Minimal protobuf wire-format reader.
///
/// Bilibili's danmaku segment endpoint answers with
/// `bilibili.community.service.dm.v1.DmSegMobileReply`, a two-level message
/// whose fields are all scalars. Decoding it needs the wire format, not the
/// full protobuf runtime, so this reader keeps the project dependency-free:
/// it walks tag/value pairs and hands each field to a closure. Unknown
/// fields are skipped exactly the way a generated decoder skips them, so a
/// server-side schema addition cannot break parsing.
///
/// Wire types (protobuf spec): 0 varint, 1 fixed64, 2 length-delimited,
/// 5 fixed32. Groups (3/4) are deprecated and unsupported.
struct ProtobufWireReader {
    enum WireType: Int {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    /// One decoded field. The payload keeps the raw wire representation so
    /// the caller decides how to interpret it (signed, unsigned, bytes…).
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)

        /// Unsigned varint value, or 0 for non-numeric fields.
        var unsigned: UInt64 {
            switch self {
            case let .varint(value): value
            case let .fixed64(value): value
            case let .fixed32(value): UInt64(value)
            case .bytes: 0
            }
        }

        /// Two's-complement signed reading (protobuf `int32`/`int64`).
        var signed: Int64 { Int64(bitPattern: unsigned) }

        /// Signed 32-bit reading. Negative `int32` values are encoded as
        /// 10-byte varints sign-extended to 64 bits, so truncation is the
        /// correct narrowing here.
        var int32: Int32 { Int32(truncatingIfNeeded: signed) }

        var data: Data? {
            if case let .bytes(value) = self { return value }
            return nil
        }

        var string: String? {
            guard let data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    enum DecodingError: Error {
        case truncated
        case unsupportedWireType(Int)
        case varintOverflow
    }

    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    var isAtEnd: Bool { index >= data.endIndex }

    /// Iterates every field in the message, calling `body` with the field
    /// number and its value. Fields the caller ignores are simply dropped.
    static func forEachField(in data: Data, _ body: (Int, Value) throws -> Void) throws {
        var reader = ProtobufWireReader(data)
        while !reader.isAtEnd {
            let (field, value) = try reader.readField()
            try body(field, value)
        }
    }

    mutating func readField() throws -> (field: Int, value: Value) {
        let tag = try readVarint()
        let fieldNumber = Int(tag >> 3)
        let rawWireType = Int(tag & 0x07)
        guard let wireType = WireType(rawValue: rawWireType) else {
            throw DecodingError.unsupportedWireType(rawWireType)
        }
        switch wireType {
        case .varint:
            return (fieldNumber, .varint(try readVarint()))
        case .fixed64:
            return (fieldNumber, .fixed64(try readFixed(byteCount: 8)))
        case .fixed32:
            return (fieldNumber, .fixed32(UInt32(truncatingIfNeeded: try readFixed(byteCount: 4))))
        case .lengthDelimited:
            let length = Int(try readVarint())
            return (fieldNumber, .bytes(try readBytes(length)))
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < data.endIndex else { throw DecodingError.truncated }
            let byte = data[index]
            index = data.index(after: index)
            // The 10th byte of a 64-bit varint contributes its lowest bit
            // only; anything beyond that is a malformed message.
            guard shift < 64 else { throw DecodingError.varintOverflow }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func readFixed(byteCount: Int) throws -> UInt64 {
        let bytes = try readBytes(byteCount)
        var result: UInt64 = 0
        for (offset, byte) in bytes.enumerated() {
            result |= UInt64(byte) << UInt64(8 * offset)
        }
        return result
    }

    private mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, data.distance(from: index, to: data.endIndex) >= count else {
            throw DecodingError.truncated
        }
        let end = data.index(index, offsetBy: count)
        defer { index = end }
        return data[index..<end]
    }
}
