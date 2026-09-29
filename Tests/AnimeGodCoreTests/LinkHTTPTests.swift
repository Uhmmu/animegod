import Foundation
import Testing
@testable import AnimeGodCore

struct LinkHTTPParserTests {
    private func parse(_ text: String) -> LinkHTTPRequest? {
        var parser = LinkHTTPParser()
        parser.append(Data(text.utf8))
        return parser.next()
    }

    @Test func readsAPlainRequest() {
        let request = parse("GET /library HTTP/1.1\r\nHost: mac\r\n\r\n")
        #expect(request?.method == "GET")
        #expect(request?.path == "/library")
        #expect(request?.header("host") == "mac")
    }

    @Test func headerLookupIgnoresCase() {
        // Clients disagree about capitalisation, and the bearer check must not
        // depend on which one turns up.
        let request = parse("GET /library HTTP/1.1\r\nAuTHoriZation: Bearer abc\r\n\r\n")
        #expect(request?.header("Authorization") == "Bearer abc")
        #expect(request?.header("authorization") == "Bearer abc")
    }

    @Test func splitsTheQueryOffThePath() {
        let request = parse("GET /library?since=2026-09-29T00%3A00%3A00Z&full=1 HTTP/1.1\r\n\r\n")
        #expect(request?.path == "/library")
        #expect(request?.query["since"] == "2026-09-29T00:00:00Z")
        #expect(request?.query["full"] == "1")
    }

    @Test func waitsForTheWholeBody() {
        var parser = LinkHTTPParser()
        parser.append(Data("POST /pair HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"code\"".utf8))
        // The head is complete but the body is not; answering now would send a
        // half-read pairing request.
        #expect(parser.next() == nil)
        parser.append(Data(":1}".utf8))
        let request = parser.next()
        #expect(request?.method == "POST")
        #expect(String(data: request?.body ?? Data(), encoding: .utf8) == "{\"code\":1}")
    }

    @Test func readsTwoRequestsFromOneChunk() {
        // TCP gives no message boundaries: two requests can arrive together and
        // both have to come back out.
        var parser = LinkHTTPParser()
        parser.append(Data("GET /health HTTP/1.1\r\n\r\nGET /library HTTP/1.1\r\n\r\n".utf8))
        #expect(parser.next()?.path == "/health")
        #expect(parser.next()?.path == "/library")
        #expect(parser.next() == nil)
    }

    @Test func refusesAnOversizedRequest() {
        var parser = LinkHTTPParser()
        parser.append(Data(repeating: 0x41, count: LinkHTTPParser.maxRequestBytes + 1))
        #expect(parser.isOverflowed)
        #expect(parser.next() == nil)
    }

    @Test func pullsTheIdentifierOutOfAPath() {
        let id = UUID()
        let request = LinkHTTPRequest(method: "GET", path: "/media/\(id.uuidString)")
        #expect(request.identifier(after: LinkProtocol.Route.mediaPrefix) == id.uuidString)
        // A trailing segment must not be swallowed into the identifier.
        let watched = LinkHTTPRequest(method: "POST", path: "/episodes/\(id.uuidString)/watched")
        #expect(watched.identifier(after: LinkProtocol.Route.episodesPrefix) == id.uuidString)
    }
}

struct LinkByteRangeTests {
    /// Tuples have no Optional equality, so resolutions are checked by parts.
    private func expectResolves(_ header: String, totalSize: Int64, to expected: (Int64, Int64)) {
        guard let resolved = LinkByteRange(header: header)?.resolve(totalSize: totalSize) else {
            Issue.record("\(header) did not resolve against \(totalSize)")
            return
        }
        #expect(resolved.offset == expected.0)
        #expect(resolved.length == expected.1)
    }

    @Test func readsAClosedRange() {
        let range = LinkByteRange(header: "bytes=0-1023")
        #expect(range?.start == 0)
        #expect(range?.end == 1023)
        expectResolves("bytes=0-1023", totalSize: 4096, to: (0, 1024))
    }

    @Test func readsAnOpenEndedRange() {
        // What mpv actually sends when it starts a file.
        expectResolves("bytes=1024-", totalSize: 4096, to: (1024, 3072))
    }

    @Test func readsASuffixRange() {
        // Matroska's cues live at the end, so the seek path asks for a suffix.
        #expect(LinkByteRange(header: "bytes=-500")?.start == nil)
        expectResolves("bytes=-500", totalSize: 4096, to: (3596, 500))
        // A suffix longer than the file is the whole file, not an error.
        expectResolves("bytes=-500", totalSize: 300, to: (0, 300))
    }

    @Test func clampsPastTheEnd() {
        expectResolves("bytes=100-99999", totalSize: 1000, to: (100, 900))
    }

    @Test func rejectsRangesItCannotAnswer() {
        #expect(LinkByteRange(header: nil) == nil)
        #expect(LinkByteRange(header: "items=0-1") == nil)
        #expect(LinkByteRange(header: "bytes=500-100") == nil)
        // Multi-range is legal HTTP and never needed here; answering one span
        // of it would silently corrupt the stream.
        #expect(LinkByteRange(header: "bytes=0-99,200-299") == nil)
        // Starting beyond the end is a 416, not a clamp.
        #expect(LinkByteRange(header: "bytes=5000-")?.resolve(totalSize: 1000) == nil)
    }
}

struct LinkAuthTests {
    @Test func tokensAreLongAndDistinct() {
        let a = LinkAuth.makeToken(), b = LinkAuth.makeToken()
        #expect(a != b)
        #expect(a.count >= 40)
        // base64url: nothing that needs escaping in a header.
        #expect(!a.contains("+") && !a.contains("/") && !a.contains("="))
    }

    @Test func comparesTokensWithoutShortCircuiting() {
        #expect(LinkAuth.constantTimeEquals("abc", "abc"))
        #expect(!LinkAuth.constantTimeEquals("abc", "abd"))
        #expect(!LinkAuth.constantTimeEquals("abc", "abcd"))
        #expect(!LinkAuth.constantTimeEquals("", "a"))
        #expect(LinkAuth.constantTimeEquals("", ""))
    }

    @Test func readsTheBearerHeader() {
        #expect(LinkAuth.bearerToken(from: "Bearer abc123") == "abc123")
        #expect(LinkAuth.bearerToken(from: "bearer abc123") == "abc123")
        #expect(LinkAuth.bearerToken(from: "  Bearer   abc123  ") == "abc123")
        #expect(LinkAuth.bearerToken(from: "Basic abc123") == nil)
        #expect(LinkAuth.bearerToken(from: "Bearer ") == nil)
        #expect(LinkAuth.bearerToken(from: nil) == nil)
    }

    @Test func pairingCodesAreSixDigits() {
        for _ in 0..<50 {
            let code = LinkAuth.makePairingCode()
            #expect(code.count == 6)
            #expect(code.allSatisfy { $0.isNumber })
        }
    }
}
