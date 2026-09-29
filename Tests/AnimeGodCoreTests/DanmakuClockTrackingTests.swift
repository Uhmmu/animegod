import Foundation
import Testing
@testable import AnimeGodCore

/// The tracking half of the clock. `DanmakuPlaybackClockTests` in
/// DanmakuEngineTests covers plain anchoring and interpolation.
@Suite("Danmaku clock tracking")
struct DanmakuClockTrackingTests {
    /// The judder fix. mpv reports a position quantised to the video frame
    /// period and delivers it after a variable hop, so a hard anchor on every
    /// sample moves the timeline backwards and forwards several times a
    /// second. Tracking must swallow that.
    @Test("A sample that agrees only corrects a fraction of the error")
    func trackingIsGradual() {
        var clock = DanmakuPlaybackClock()
        clock.anchor(position: 10, speed: 1, playing: true, hostTime: 100)
        // 40 ms of noise, the size of one frame period at 24 fps.
        let outcome = clock.sample(position: 10.54, speed: 1, playing: true, hostTime: 100.5)
        #expect(outcome == .tracked)
        let moved = clock.mediaTime(atHost: 100.5) - 10.5
        #expect(moved > 0)
        #expect(moved < 0.04 * 0.2, "a 40 ms sample error must not move the clock 40 ms")
    }

    @Test("Repeated noise averages out rather than accumulating")
    func noiseAveragesOut() {
        var clock = DanmakuPlaybackClock()
        clock.anchor(position: 0, speed: 1, playing: true, hostTime: 0)
        var host = 0.0
        // Alternating ±20 ms error around a perfectly regular timeline.
        for step in 1...200 {
            host = Double(step) * 0.04
            let noise = step.isMultiple(of: 2) ? 0.02 : -0.02
            clock.sample(position: host + noise, speed: 1, playing: true, hostTime: host)
        }
        #expect(abs(clock.mediaTime(atHost: host) - host) < 0.02)
    }

    @Test("A steady offset is still corrected in full")
    func steadyOffsetConverges() {
        var clock = DanmakuPlaybackClock()
        clock.anchor(position: 0, speed: 1, playing: true, hostTime: 0)
        var host = 0.0
        for step in 1...200 {
            host = Double(step) * 0.04
            clock.sample(position: host + 0.1, speed: 1, playing: true, hostTime: host)
        }
        #expect(abs(clock.mediaTime(atHost: host) - (host + 0.1)) < 0.005)
    }

    @Test("A seek is reported and taken whole")
    func seekIsDiscontinuous() {
        var clock = DanmakuPlaybackClock()
        clock.anchor(position: 10, speed: 1, playing: true, hostTime: 100)
        let outcome = clock.sample(position: 400, speed: 1, playing: true, hostTime: 100.1)
        #expect(outcome == .discontinuous)
        #expect(abs(clock.mediaTime(atHost: 100.1) - 400) < 1e-9)
    }

    @Test("Pausing and resuming anchor exactly")
    func pauseAnchorsExactly() {
        var clock = DanmakuPlaybackClock()
        clock.anchor(position: 10, speed: 1, playing: true, hostTime: 100)
        clock.sample(position: 10.5, speed: 1, playing: false, hostTime: 100.5)
        #expect(abs(clock.mediaTime(atHost: 200) - 10.5) < 1e-9)
        clock.sample(position: 10.5, speed: 1, playing: true, hostTime: 200)
        #expect(abs(clock.mediaTime(atHost: 201) - 11.5) < 1e-9)
    }

    @Test("A speed change re-bases immediately")
    func speedChangeAnchors() {
        var clock = DanmakuPlaybackClock()
        clock.anchor(position: 10, speed: 1, playing: true, hostTime: 100)
        clock.sample(position: 10.5, speed: 2, playing: true, hostTime: 100.5)
        #expect(abs(clock.mediaTime(atHost: 101.5) - 12.5) < 1e-9)
    }
}
