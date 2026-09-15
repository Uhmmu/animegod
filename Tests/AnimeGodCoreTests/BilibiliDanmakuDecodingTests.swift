import Foundation
import Testing
@testable import AnimeGodCore

/// Builds protobuf messages so the decoder is tested against the real wire
/// format rather than a Swift-shaped fixture.
enum ProtobufWireWriter {
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
        return data
    }

    static func tag(_ field: Int, _ wireType: Int) -> Data {
        varint(UInt64(field << 3 | wireType))
    }

    static func int(_ field: Int, _ value: Int64) -> Data {
        tag(field, 0) + varint(UInt64(bitPattern: value))
    }

    static func string(_ field: Int, _ value: String) -> Data {
        let bytes = Data(value.utf8)
        return tag(field, 2) + varint(UInt64(bytes.count)) + bytes
    }

    static func message(_ field: Int, _ body: Data) -> Data {
        tag(field, 2) + varint(UInt64(body.count)) + body
    }

    static func fixed32(_ field: Int, _ value: UInt32) -> Data {
        var data = tag(field, 5)
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
        return data
    }

    /// One `DanmakuElem`.
    static func element(
        id: Int64 = 0,
        progress: Int64 = 0,
        mode: Int64 = 1,
        fontSize: Int64 = 25,
        color: Int64 = 0xFF_FFFF,
        midHash: String = "",
        content: String = "",
        ctime: Int64 = 0,
        weight: Int64 = 0,
        pool: Int64 = 0,
        idStr: String = ""
    ) -> Data {
        var body = Data()
        if id != 0 { body += int(1, id) }
        body += int(2, progress)
        body += int(3, mode)
        body += int(4, fontSize)
        body += int(5, color)
        if !midHash.isEmpty { body += string(6, midHash) }
        body += string(7, content)
        if ctime != 0 { body += int(8, ctime) }
        if weight != 0 { body += int(9, weight) }
        if pool != 0 { body += int(11, pool) }
        if !idStr.isEmpty { body += string(12, idStr) }
        return body
    }

    /// `DmSegMobileReply { repeated DanmakuElem elems = 1; }`
    static func segment(_ elements: [Data]) -> Data {
        elements.reduce(Data()) { $0 + message(1, $1) }
    }
}

@Suite struct BilibiliDanmakuDecodingTests {
    @Test func decodesEveryDanmakuElemField() throws {
        let data = ProtobufWireWriter.segment([
            ProtobufWireWriter.element(
                id: 1_754_000_000_000_000_000,
                progress: 12_340,
                mode: 1,
                fontSize: 25,
                color: 16_777_215,
                midHash: "a1b2c3d4",
                content: "前方高能",
                ctime: 1_700_000_000,
                weight: 9,
                idStr: "1754000000000000000"
            )
        ])

        let elements = try BilibiliDanmakuSegmentDecoder.decodeSegment(data)
        #expect(elements.count == 1)
        let element = try #require(elements.first)
        #expect(element.progress == 12_340)
        #expect(element.mode == 1)
        #expect(element.fontSize == 25)
        #expect(element.color == 16_777_215)
        #expect(element.midHash == "a1b2c3d4")
        #expect(element.content == "前方高能")
        #expect(element.ctime == 1_700_000_000)
        #expect(element.weight == 9)
        #expect(element.stableID == "1754000000000000000")
    }

    @Test func mapsModesOntoPresentationIntents() throws {
        let data = ProtobufWireWriter.segment([
            ProtobufWireWriter.element(progress: 1_000, mode: 1, content: "scroll"),
            ProtobufWireWriter.element(progress: 2_000, mode: 2, content: "scroll too"),
            ProtobufWireWriter.element(progress: 3_000, mode: 3, content: "also scroll"),
            ProtobufWireWriter.element(progress: 4_000, mode: 4, content: "bottom"),
            ProtobufWireWriter.element(progress: 5_000, mode: 5, content: "top"),
            ProtobufWireWriter.element(progress: 6_000, mode: 6, content: "reverse")
        ])
        let comments = try BilibiliDanmakuSegmentDecoder.decodeSegment(data)
            .compactMap { $0.makeComment(providerID: "bilibili") }

        #expect(comments.map(\.mode) == [.scroll, .scroll, .scroll, .bottom, .top, .scroll])
        #expect(comments.map(\.time) == [1, 2, 3, 4, 5, 6])
        #expect(comments.allSatisfy { $0.source == "bilibili" })
    }

    @Test func dropsScriptedAndSpecialPoolComments() throws {
        let data = ProtobufWireWriter.segment([
            // Advanced/code/BAS modes carry positioning payloads, not text.
            ProtobufWireWriter.element(progress: 1_000, mode: 7, content: "[0,0,\"1-1\",4,\"x\"]"),
            ProtobufWireWriter.element(progress: 2_000, mode: 8, content: "function(){}"),
            ProtobufWireWriter.element(progress: 3_000, mode: 9, content: "def anim{}"),
            // Special pool, even with an ordinary mode.
            ProtobufWireWriter.element(progress: 4_000, mode: 1, content: "special", pool: 2),
            ProtobufWireWriter.element(progress: 5_000, mode: 1, content: "   "),
            ProtobufWireWriter.element(progress: 6_000, mode: 1, content: "kept")
        ])
        let comments = try BilibiliDanmakuSegmentDecoder.decodeSegment(data)
            .compactMap { $0.makeComment(providerID: "bilibili") }

        #expect(comments.map(\.text) == ["kept"])
    }

    @Test func keepsDecodingAfterUnknownFieldsAndVariedWireTypes() throws {
        // A future schema addition must not break the current decoder.
        var body = ProtobufWireWriter.element(progress: 7_500, mode: 5, color: 16_711_680, content: "unchanged")
        body += ProtobufWireWriter.string(99, "some future string field")
        body += ProtobufWireWriter.fixed32(98, 4_242)
        body += ProtobufWireWriter.int(97, -5)
        let data = ProtobufWireWriter.segment([body])

        let comment = try #require(
            try BilibiliDanmakuSegmentDecoder.decodeSegment(data).first?.makeComment(providerID: "bilibili")
        )
        #expect(comment.text == "unchanged")
        #expect(comment.mode == .top)
        #expect(comment.color == 0xFF0000)
        #expect(comment.time == 7.5)
    }

    @Test func keepsIntactCommentsWhenAnElementBodyIsGarbage() throws {
        // A body that is not valid protobuf costs that one comment only.
        var data = ProtobufWireWriter.message(1, ProtobufWireWriter.element(progress: 1_000, content: "first"))
        data += ProtobufWireWriter.message(1, Data([0xFF, 0xFF, 0xFF]))
        data += ProtobufWireWriter.message(1, ProtobufWireWriter.element(progress: 2_000, content: "third"))

        let elements = try BilibiliDanmakuSegmentDecoder.decodeSegment(data)
        #expect(elements.map(\.content) == ["first", "third"])
    }

    @Test func keepsWhatWasDecodedBeforeCorruptFraming() throws {
        // A bogus length header makes the remaining field boundaries
        // unknowable; everything decoded up to that point still stands.
        var data = ProtobufWireWriter.message(1, ProtobufWireWriter.element(progress: 1_000, content: "first"))
        data += ProtobufWireWriter.tag(1, 2) + ProtobufWireWriter.varint(4_000) + Data([0x0A, 0xFF])

        let elements = try BilibiliDanmakuSegmentDecoder.decodeSegment(data)
        #expect(elements.map(\.content) == ["first"])
    }

    @Test func throwsOnlyWhenNothingCouldBeDecoded() {
        let garbage = Data([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: (any Error).self) {
            try BilibiliDanmakuSegmentDecoder.decodeSegment(garbage)
        }
    }

    @Test func negativeInt32FieldsDecodeAsNegative() throws {
        // protobuf sign-extends negative int32 into a 10-byte varint.
        let body = ProtobufWireWriter.int(2, 1_000) + ProtobufWireWriter.int(3, 1)
            + ProtobufWireWriter.string(7, "x") + ProtobufWireWriter.int(9, -3)
        let element = try BilibiliDanmakuSegmentDecoder.decodeElement(body)
        #expect(element.weight == -3)
    }

    @Test func parsesLegacyXMLPoolForDebugging() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><i><chatserver>chat.bilibili.com</chatserver>
        <d p="12.34,1,25,16777215,1700000000,0,a1b2c3d4,9876543210">老番外传 &amp; 回忆</d>
        <d p="56.78,5,25,16711680,1700000001,0,deadbeef,9876543211">顶部弹幕</d>
        <d p="90.0,1,25,16777215,1700000002,2,cafebabe,9876543212">特殊池</d>
        </i>
        """
        let elements = BilibiliLegacyXMLParser.parse(xml)
        #expect(elements.count == 3)
        #expect(elements[0].progress == 12_340)
        #expect(elements[0].content == "老番外传 & 回忆")
        #expect(elements[0].stableID == "9876543210")
        #expect(elements[1].mode == 5)
        #expect(elements[1].color == 16_711_680)

        // Pool 2 is still filtered at conversion time, same as protobuf.
        let comments = elements.compactMap { $0.makeComment(providerID: "bilibili") }
        #expect(comments.count == 2)
    }
}
