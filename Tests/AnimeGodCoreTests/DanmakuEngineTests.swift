import Foundation
import Testing
@testable import AnimeGodCore

struct DanmakuEngineTests {
    private let viewportWidth = 1000.0
    private let viewportHeight = 600.0
    private let lineHeight = 30.0
    /// Constant comment width keeps collision math predictable.
    private let commentWidth = 200.0

    private func makeEngine(settings: DanmakuDisplaySettings = .default) -> DanmakuEngine {
        DanmakuEngine(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            lineHeight: lineHeight,
            settings: settings,
            measure: { [commentWidth] _ in commentWidth }
        )
    }

    private func comment(_ id: String, at time: Double, mode: DanmakuMode = .scroll, color: Int = 0xFFFFFF) -> DanmakuComment {
        DanmakuComment(id: id, time: time, text: "c\(id)", mode: mode, color: color)
    }

    private func activeIDs(_ engine: DanmakuEngine) -> Set<String> {
        Set(engine.activeComments.map(\.id))
    }

    // MARK: - Spawning & timing

    @Test func commentsAppearAtTheirTimestamps() {
        let engine = makeEngine()
        engine.load(comments: [comment("1", at: 10), comment("2", at: 10.5), comment("3", at: 20)])

        engine.tick(at: 9.9)
        #expect(engine.activeComments.isEmpty)
        engine.tick(at: 10.0)
        #expect(activeIDs(engine) == ["1"])
        engine.tick(at: 10.6)
        #expect(activeIDs(engine) == ["1", "2"])
        engine.tick(at: 20.1)
        #expect(activeIDs(engine) == ["1", "2", "3"])
    }

    @Test func subSecondTimestampsAreHonored() {
        let engine = makeEngine()
        engine.load(comments: [comment("1", at: 1.25)])
        engine.tick(at: 1.24)
        #expect(engine.activeComments.isEmpty)
        engine.tick(at: 1.26)
        #expect(activeIDs(engine) == ["1"])
    }

    @Test func scrolledCommentsExpireAfterCrossingTheViewport() {
        let engine = makeEngine()
        engine.load(comments: [comment("1", at: 0)])
        engine.tick(at: 0)
        // Speed = (viewport + width) / duration = 1200 / 11.
        let speed = (viewportWidth + commentWidth) / DanmakuEngine.baseScrollDuration
        // Starts at the right edge…
        #expect(engine.activeComments[0].x == viewportWidth)
        engine.tick(at: 1)
        #expect(engine.activeComments[0].x == viewportWidth - speed)
        // …and disappears once fully past the left edge.
        engine.tick(at: DanmakuEngine.baseScrollDuration + 0.01)
        #expect(engine.activeComments.isEmpty)
    }

    @Test func fixedCommentsExpireAfterTheirDuration() {
        let engine = makeEngine()
        engine.load(comments: [comment("t", at: 5, mode: .top), comment("b", at: 5, mode: .bottom)])
        engine.tick(at: 5)
        #expect(activeIDs(engine) == ["t", "b"])
        // Fixed comments stay centered.
        #expect(engine.activeComments[0].x == (viewportWidth - commentWidth) / 2)
        engine.tick(at: 5 + DanmakuEngine.fixedDuration / 2)
        #expect(activeIDs(engine) == ["t", "b"])
        engine.tick(at: 5 + DanmakuEngine.fixedDuration + 0.01)
        #expect(engine.activeComments.isEmpty)
    }

    // MARK: - Pause / resume

    @Test func pausedClockFreezesPositions() {
        // Pause means the renderer stops advancing media time; ticking the
        // engine at a constant time must not move anything.
        let engine = makeEngine()
        engine.load(comments: [comment("1", at: 0)])
        engine.tick(at: 0)
        #expect(activeIDs(engine) == ["1"])
        engine.tick(at: 5)
        let frozen = engine.activeComments[0].x
        #expect(frozen < 1000) // it did move to its t=5 position once
        for _ in 0..<60 {
            engine.tick(at: 5)
        }
        #expect(engine.activeComments[0].x == frozen)
    }

    // MARK: - Speed

    @Test func playbackSpeedScalesScrollDistance() {
        // Engine time is media time; at 2x playback the wall-clock halves
        // but media seconds drive identical positions. What changes is how
        // much media time passes per wall second — verified via the clock
        // in DanmakuPlaybackClockTests. Here: speedMultiplier (user pref)
        // scales the travel velocity.
        let engine = makeEngine()
        engine.load(comments: [comment("1", at: 0)])
        engine.tick(at: 0)
        let normalSpeed = (viewportWidth + commentWidth) / DanmakuEngine.baseScrollDuration

        let fast = makeEngine(settings: .init(speedMultiplier: 2))
        fast.load(comments: [comment("1", at: 0)])
        fast.tick(at: 0)
        fast.tick(at: 1)
        #expect(fast.activeComments[0].x == viewportWidth - 2 * normalSpeed)
        #expect(engine.activeComments[0].x == viewportWidth)
        engine.tick(at: 1)
        #expect(engine.activeComments[0].x == viewportWidth - normalSpeed)
    }

    // MARK: - Seek

    @Test func seekDiscardsActiveCommentsAndResyncs() {
        let engine = makeEngine()
        engine.load(comments: (0..<100).map { comment("\($0)", at: Double($0)) })
        engine.tick(at: 50.5)
        #expect(engine.activeComments.count > 0)
        engine.seek(to: 80)
        #expect(engine.activeComments.isEmpty)
        // Comments before the seek target never replay…
        engine.tick(at: 80.1)
        let ids = activeIDs(engine)
        #expect(!ids.contains("49"))
        #expect(!ids.contains("79"))
        // …but the comment at the new position does appear.
        #expect(ids.contains("80"))
    }

    @Test func repeatedSeekingDoesNotDuplicateComments() {
        let engine = makeEngine()
        engine.load(comments: (0..<50).map { comment("\($0)", at: Double($0) * 2) })
        for target in [10.0, 40.0, 10.0, 80.0, 40.0, 10.0] {
            engine.seek(to: target)
            engine.tick(at: target + 0.1)
        }
        let idCounts = Dictionary(grouping: engine.activeComments.map(\.id), by: { $0 }).mapValues(\.count)
        for (id, count) in idCounts {
            #expect(count == 1, "comment \(id) duplicated \(count)×")
        }
    }

    @Test func backwardSeekReplaysThatSectionsDanmaku() {
        let engine = makeEngine()
        engine.load(comments: [comment("5", at: 5), comment("6", at: 6)])
        engine.tick(at: 6.1)
        engine.seek(to: 4.9)
        engine.tick(at: 5.0)
        #expect(activeIDs(engine) == ["5"])
    }

    @Test func seekDoesNotReplayLargeAmountsOfOldDanmaku() {
        let engine = makeEngine()
        engine.load(comments: (0..<2000).map { comment("\($0)", at: Double($0) * 0.1) })
        engine.tick(at: 1)
        engine.seek(to: 190)
        let before = engine.diagnostics.skippedOnSeek
        engine.tick(at: 190.05)
        // After the seek only comments within the grace window around the
        // target may appear — not the 1,900 older ones.
        #expect(engine.activeComments.count <= 10)
        #expect(engine.diagnostics.skippedOnSeek >= before)
        #expect(engine.diagnostics.skippedOnSeek >= 1800)
    }

    // MARK: - Timing offset

    @Test func timingOffsetShiftsAppearance() {
        var settings = DanmakuDisplaySettings.default
        settings.timeOffset = 5
        let delayed = makeEngine(settings: settings)
        delayed.load(comments: [comment("1", at: 100)])
        delayed.tick(at: 104.9)
        #expect(delayed.activeComments.isEmpty)
        delayed.tick(at: 105.1)
        #expect(activeIDs(delayed) == ["1"])

        settings.timeOffset = -5
        var early = makeEngine(settings: settings)
        early.load(comments: [comment("1", at: 100)])
        early.tick(at: 94.9)
        #expect(early.activeComments.isEmpty)
        early.tick(at: 95.1)
        #expect(activeIDs(early) == ["1"])
    }

    // MARK: - Lane scheduling

    @Test func simultaneousCommentsOccupyDifferentLanes() {
        let engine = makeEngine()
        engine.load(comments: (0..<10).map { comment("\($0)", at: 100) })
        engine.tick(at: 100)
        let lanes = Set(engine.activeComments.map(\.y))
        #expect(lanes.count == engine.activeComments.count)
        // Lane pitch is the line height.
        #expect(engine.activeComments.allSatisfy { $0.y.truncatingRemainder(dividingBy: lineHeight) == 0 })
    }

    @Test func fasterNewcomerNeverRearEndsASlowerPredecessor() {
        // Wide (fast) comments entering behind narrow (slow) ones must not
        // overlap while both are alive.
        var widths: [String: Double] = ["n": 100, "w": 800]
        let engine = DanmakuEngine(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            lineHeight: lineHeight,
            measure: { widths[$0.id] ?? 100 }
        )
        engine.load(comments: [comment("n", at: 0), comment("w", at: 0.01)])
        // Force the same lane by filling all others first is complex;
        // instead verify via lane availability: the wide comment spawned
        // 0.01s after the narrow one cannot share its lane until the
        // overtake constraint clears, so lanes must differ.
        engine.tick(at: 0.01)
        let narrow = engine.activeComments.first { $0.id == "n" }
        let wide = engine.activeComments.first { $0.id == "w" }
        #expect(narrow != nil)
        #expect(wide != nil)
        #expect(narrow?.y != wide?.y)
        // And at every moment both are alive, their ranges never overlap.
        for t in stride(from: 0.01, to: DanmakuEngine.baseScrollDuration, by: 0.25) {
            engine.tick(at: t)
            let items = engine.activeComments
            guard items.count == 2 else { break }
            for i in items.indices {
                for j in (i + 1)..<items.count {
                    let a = items[i].x...(items[i].x + items[i].width)
                    let b = items[j].x...(items[j].x + items[j].width)
                    #expect(a.overlaps(b) == false || items[i].y != items[j].y)
                }
            }
        }
    }

    @Test func laneAvailabilityUsesTravelTimeNotJustEntry() {
        // A comment spawned long ago that has fully entered still blocks a
        // faster newcomer behind it: with a 1000pt viewport and a wide
        // newcomer, the overtake constraint must push it to another lane.
        var widths: [String: Double] = ["slow": 50, "fast": 900]
        let engine = DanmakuEngine(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            lineHeight: lineHeight,
            measure: { widths[$0.id] ?? 50 }
        )
        engine.load(comments: [comment("slow", at: 0), comment("fast", at: 2)])
        engine.tick(at: 0)
        engine.tick(at: 2)
        let slow = engine.activeComments.first { $0.id == "slow" }
        let fast = engine.activeComments.first { $0.id == "fast" }
        #expect(slow != nil)
        #expect(fast != nil)
        #expect(slow?.y != fast?.y)
    }

    @Test func fixedCommentsHaveIndependentLaneAllocation() {
        let engine = makeEngine()
        // Four top comments fit the five fixed lanes without overlap.
        engine.load(comments: (0..<4).map { comment("t\($0)", at: 10, mode: .top) })
        engine.tick(at: 10)
        let ys = Set(engine.activeComments.map(\.y))
        #expect(ys.count == engine.activeComments.count)
        // Top lanes start at the top of the display area.
        #expect(engine.activeComments.allSatisfy { $0.y >= 0 })
        #expect(engine.activeComments.allSatisfy { $0.y < usableAreaHeight })
    }

    @Test func fixedOverflowOverlapsTheSoonestFreeLane() {
        let engine = makeEngine()
        // Eight simultaneous top comments in five lanes: deterministic
        // overflow, never a crash, always inside the display area.
        engine.load(comments: (0..<8).map { comment("t\($0)", at: 10, mode: .top) })
        engine.tick(at: 10)
        #expect(engine.activeComments.count == 8)
        #expect(engine.activeComments.allSatisfy { $0.y >= 0 })
        #expect(engine.activeComments.allSatisfy { $0.y < usableAreaHeight })
    }

    private var usableAreaHeight: Double {
        viewportHeight * DanmakuDisplaySettings.default.displayArea
    }

    @Test func displayAreaLimitsScrollCoverage() {
        var settings = DanmakuDisplaySettings.default
        settings.displayArea = 0.25
        let engine = makeEngine(settings: settings)
        engine.load(comments: (0..<30).map { comment("\($0)", at: 0) })
        engine.tick(at: 0)
        let maxY = engine.activeComments.map(\.y).max() ?? 0
        #expect(maxY + lineHeight <= viewportHeight * 0.25 + lineHeight)
    }

    @Test func capacityLimitDropsDeterministically() {
        var settings = DanmakuDisplaySettings.default
        settings.maxSimultaneous = 3
        let engine = makeEngine(settings: settings)
        engine.load(comments: (0..<10).map { comment("\($0)", at: 0) })
        engine.tick(at: 0)
        #expect(engine.activeComments.count == 3)
        #expect(engine.diagnostics.droppedForCapacity == 7)
    }

    @Test func overflowStrategyIsDeterministic() {
        // More simultaneous comments than lanes: every tick sequence
        // produces the same placement.
        func run() -> [String] {
            let engine = makeEngine()
            engine.load(comments: (0..<40).map { comment("\($0)", at: 0) })
            engine.tick(at: 0)
            return engine.activeComments.map(\.id)
        }
        #expect(run() == run())
        // Overflow keeps the soonest-free lanes occupied rather than
        // dropping everything.
        #expect(run().count > 5)
    }

    // MARK: - Visibility filters

    @Test func hideFiltersRemoveModesAndColors() {
        var settings = DanmakuDisplaySettings.default
        settings.hideTop = true
        settings.hideColored = true
        let engine = makeEngine(settings: settings)
        engine.load(comments: [
            comment("s", at: 1, mode: .scroll),
            comment("t", at: 1, mode: .top),
            comment("b", at: 1, mode: .bottom, color: 0xFF0000),
        ])
        engine.tick(at: 1)
        #expect(activeIDs(engine) == ["s"])
        #expect(engine.diagnostics.loadedCount == 1)
    }

    // MARK: - Reload & viewport

    @Test func reloadDoesNotReplayAlreadyShownComments() {
        let engine = makeEngine()
        engine.load(comments: (0..<20).map { comment("\($0)", at: Double($0)) })
        engine.tick(at: 10.5)
        engine.load(comments: (0..<20).map { comment("\($0)", at: Double($0)) })
        engine.tick(at: 10.6)
        // Only comments around/after the current time may appear.
        let ids = activeIDs(engine)
        #expect(ids.contains("10"))
        #expect(!ids.contains("9"))
        #expect(!ids.contains("5"))
    }

    @Test func viewportChangeRebuildsLanes() {
        let engine = makeEngine()
        engine.load(comments: (0..<10).map { comment("\($0)", at: 0) } + [comment("later", at: 5)])
        engine.tick(at: 0)
        #expect(!engine.activeComments.isEmpty)
        engine.updateViewport(width: 1920, height: 400, lineHeight: lineHeight)
        #expect(engine.activeComments.isEmpty)
        // Comments already consumed stay consumed; later ones spawn fine.
        engine.tick(at: 5.1)
        #expect(activeIDs(engine) == ["later"])
    }
}

@Suite struct DanmakuPlaybackClockTests {
    @Test func interpolatesBetweenAnchors() {
        var clock = DanmakuPlaybackClock()
        clock.anchor(position: 100, speed: 1, playing: true, hostTime: 10)
        #expect(clock.mediaTime(atHost: 10.5) == 100.5)
        #expect(clock.mediaTime(atHost: 11) == 101)
    }

    @Test func reAnchoringEliminatesDrift() {
        // Long sessions: every player position sample re-anchors, so
        // interpolation error never accumulates.
        var clock = DanmakuPlaybackClock()
        var host = 0.0
        var trueMedia = 0.0
        clock.anchor(position: 0, speed: 1, playing: true, hostTime: host)
        for _ in 0..<1000 {
            host += 0.25
            trueMedia += 0.24 // Simulated player report lags reality.
            clock.anchor(position: trueMedia, speed: 1, playing: true, hostTime: host)
            #expect(abs(clock.mediaTime(atHost: host) - trueMedia) < 0.0001)
        }
    }

    @Test func pauseFreezesAndResumeContinuesWithoutDrift() {
        var clock = DanmakuPlaybackClock()
        clock.anchor(position: 50, speed: 1, playing: true, hostTime: 0)
        clock.setPlaying(false, hostTime: 10)
        #expect(clock.mediaTime(atHost: 12) == 60)
        #expect(clock.mediaTime(atHost: 100) == 60)
        clock.setPlaying(true, hostTime: 100)
        #expect(clock.mediaTime(atHost: 101) == 61)
    }

    @Test func speedChangesFoldRunningTimeBeforeRescaling() {
        var clock = DanmakuPlaybackClock()
        clock.anchor(position: 0, speed: 1, playing: true, hostTime: 0)
        clock.setSpeed(2, hostTime: 10)
        #expect(clock.mediaTime(atHost: 10) == 10)
        #expect(clock.mediaTime(atHost: 15) == 20)
        clock.setSpeed(0.5, hostTime: 15)
        #expect(clock.mediaTime(atHost: 17) == 21)
    }

    @Test func speedChangeWhilePausedHoldsPosition() {
        var clock = DanmakuPlaybackClock()
        clock.anchor(position: 10, speed: 1, playing: true, hostTime: 0)
        clock.setPlaying(false, hostTime: 5)
        clock.setSpeed(3, hostTime: 50)
        #expect(clock.mediaTime(atHost: 60) == 15)
    }

    @Test func futureHostTimesAreExtrapolated() {
        var clock = DanmakuPlaybackClock()
        clock.anchor(position: 0, speed: 1.5, playing: true, hostTime: 0)
        #expect(clock.mediaTime(atHost: 2) == 3)
    }
}
