import Foundation
import Testing
@testable import AnimeGodCore

struct LinkClaimRegistryTests {
    private let phone = UUID()
    private let tablet = UUID()
    private let episode = UUID()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func grantsAnUnheldEpisode() {
        var registry = LinkClaimRegistry()
        #expect(registry.claim(episodeID: episode, deviceID: phone, deviceName: "Phone", force: false, now: now) == .granted)
        let holder = registry.holder(of: episode, now: now)
        #expect(holder?.deviceID == phone)
    }

    @Test func refusesAnEpisodeSomeoneElseIsWatching() {
        var registry = LinkClaimRegistry()
        _ = registry.claim(episodeID: episode, deviceID: phone, deviceName: "Phone", force: false, now: now)
        // Named, because "someone else has it" is useless without knowing who.
        let outcome = registry.claim(episodeID: episode, deviceID: tablet, deviceName: "iPad", force: false, now: now)
        #expect(outcome == .heldBy("Phone"))
    }

    @Test func theSameDeviceMayReclaimItsOwn() {
        // Reopening the player on the phone that already holds the episode is
        // not a conflict with itself.
        var registry = LinkClaimRegistry()
        _ = registry.claim(episodeID: episode, deviceID: phone, deviceName: "Phone", force: false, now: now)
        let again = registry.claim(episodeID: episode, deviceID: phone, deviceName: "Phone", force: false, now: now)
        #expect(again == .granted)
    }

    @Test func forceTakesItOver() {
        var registry = LinkClaimRegistry()
        _ = registry.claim(episodeID: episode, deviceID: phone, deviceName: "Phone", force: false, now: now)
        let forced = registry.claim(episodeID: episode, deviceID: tablet, deviceName: "iPad", force: true, now: now)
        #expect(forced == .granted)
        let holder = registry.holder(of: episode, now: now)
        #expect(holder?.deviceID == tablet)
    }

    @Test func anExpiredClaimIsNotAHolder() {
        // The phone died on the bus. The episode has to become playable again
        // on its own, or it is stuck for ever.
        var registry = LinkClaimRegistry(lease: 60)
        _ = registry.claim(episodeID: episode, deviceID: phone, deviceName: "Phone", force: false, now: now)
        let later = now.addingTimeInterval(61)
        let lapsed = registry.holder(of: episode, now: later)
        #expect(lapsed == nil)
        let regranted = registry.claim(episodeID: episode, deviceID: tablet, deviceName: "iPad", force: false, now: later)
        #expect(regranted == .granted)
    }

    @Test func writingProgressKeepsTheClaimAlive() {
        var registry = LinkClaimRegistry(lease: 60)
        _ = registry.claim(episodeID: episode, deviceID: phone, deviceName: "Phone", force: false, now: now)
        registry.renew(episodeID: episode, deviceID: phone, now: now.addingTimeInterval(50))
        // Without the renewal this would have lapsed at +60.
        let holder = registry.holder(of: episode, now: now.addingTimeInterval(100))
        #expect(holder?.deviceID == phone)
    }

    @Test func anotherDeviceCannotRenewOrRelease() {
        var registry = LinkClaimRegistry(lease: 60)
        _ = registry.claim(episodeID: episode, deviceID: phone, deviceName: "Phone", force: false, now: now)
        registry.renew(episodeID: episode, deviceID: tablet, now: now.addingTimeInterval(50))
        let lapsed = registry.holder(of: episode, now: now.addingTimeInterval(61))
        #expect(lapsed == nil)

        _ = registry.claim(episodeID: episode, deviceID: phone, deviceName: "Phone", force: false, now: now)
        let released = registry.release(episodeID: episode, deviceID: tablet, now: now)
        #expect(released == false)
        let holder = registry.holder(of: episode, now: now)
        #expect(holder?.deviceID == phone)
    }

    @Test func theHolderReleasesIt() {
        var registry = LinkClaimRegistry()
        _ = registry.claim(episodeID: episode, deviceID: phone, deviceName: "Phone", force: false, now: now)
        let released = registry.release(episodeID: episode, deviceID: phone, now: now)
        #expect(released)
        let holder = registry.holder(of: episode, now: now)
        #expect(holder == nil)
    }
}
