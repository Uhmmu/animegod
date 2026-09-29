import Foundation
import Testing
@testable import AnimeGodCore

struct LinkAddressKindTests {
    @Test func recognisesTailscale() {
        // 100.64/10 is the range Tailscale hands out.
        #expect(LinkAddressKind.classify("100.64.0.1:47380") == .tailscale)
        #expect(LinkAddressKind.classify("100.101.102.103") == .tailscale)
        #expect(LinkAddressKind.classify("mac-mini.tailnet-abcd.ts.net:47380") == .tailscale)
        // 100.x outside 64–127 is ordinary public space, not a tailnet.
        #expect(LinkAddressKind.classify("100.200.0.1") == .other)
    }

    @Test func recognisesLocalAddresses() {
        #expect(LinkAddressKind.classify("192.168.1.10:47380") == .lan)
        #expect(LinkAddressKind.classify("10.131.8.20:47380") == .lan)
        #expect(LinkAddressKind.classify("172.16.0.5") == .lan)
        #expect(LinkAddressKind.classify("172.32.0.5") == .other)
        #expect(LinkAddressKind.classify("169.254.4.4") == .lan)
        #expect(LinkAddressKind.classify("127.0.0.1:47380") == .lan)
        #expect(LinkAddressKind.classify("jiales-macbook-pro.local:47380") == .lan)
    }

    @Test func anythingElseIsOther() {
        #expect(LinkAddressKind.classify("mac.example.com:47380") == .other)
        #expect(LinkAddressKind.classify("8.8.8.8") == .other)
    }
}

struct LinkAddressBookTests {
    @Test func aLanWinDoesNotEraseTheTailscaleAddress() {
        // The whole reason this type exists. Pair at home, leave the
        // building: without separate slots there is nothing left to try.
        var book = LinkAddressBook()
        book.setTailscale("mac.tailnet-abcd.ts.net:47380")
        book.remember("192.168.1.10:47380")
        #expect(book.tailscale == "mac.tailnet-abcd.ts.net:47380")
        #expect(book.lan == "192.168.1.10:47380")
        #expect(book.candidates().contains("mac.tailnet-abcd.ts.net:47380"))
    }

    @Test func aNewLeaseReplacesTheOldLocalAddress() {
        var book = LinkAddressBook()
        book.remember("192.168.1.10:47380")
        book.remember("192.168.1.42:47380")
        #expect(book.lan == "192.168.1.42:47380")
        #expect(!book.candidates().contains("192.168.1.10:47380"))
    }

    @Test func aResolvedTailnetAddressDoesNotReplaceATypedName() {
        // A MagicDNS name survives a reboot; a raw 100.x address may not.
        var book = LinkAddressBook()
        book.setTailscale("mac.tailnet-abcd.ts.net:47380")
        book.remember("100.64.1.2:47380")
        #expect(book.tailscale == "mac.tailnet-abcd.ts.net:47380")
    }

    @Test func remembersWhatWorkedOnEachNetwork() {
        var book = LinkAddressBook()
        book.remember("192.168.1.10:47380", network: "Home")
        book.remember("10.131.8.20:47380", network: "Glide")
        // Back on the home Wi-Fi, its own address is tried first.
        #expect(book.candidates(network: "Home").first == "192.168.1.10:47380")
        #expect(book.candidates(network: "Glide").first == "10.131.8.20:47380")
    }

    @Test func candidatesAreDeduplicatedAndOrdered() {
        var book = LinkAddressBook()
        book.setTailscale("mac.ts.net:47380")
        book.remember("192.168.1.10:47380", network: "Home")
        let candidates = book.candidates(network: "Home", discovered: ["192.168.1.10:47380", "192.168.1.11:47380"])
        #expect(candidates == ["192.168.1.10:47380", "192.168.1.11:47380", "mac.ts.net:47380"])
    }

    @Test func clearingTheTailscaleAddressTakesItOutOfTheRace() {
        var book = LinkAddressBook()
        book.setTailscale("mac.ts.net:47380")
        book.setTailscale("   ")
        #expect(book.tailscale == nil)
        #expect(book.candidates().isEmpty)
    }
}
