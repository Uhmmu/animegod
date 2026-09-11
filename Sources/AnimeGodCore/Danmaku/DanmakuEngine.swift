import Foundation

/// User-tunable danmaku presentation settings. Persisted by the app;
/// consumed by the engine and renderer.
public struct DanmakuDisplaySettings: Codable, Sendable, Equatable {
    /// 0.1...1.0
    public var opacity: Double
    /// 0.5...1.5 multiplier on the base font size
    public var fontScale: Double
    /// 0.25...1.0 fraction of the viewport height danmaku may cover
    public var displayArea: Double
    /// 0.5...2.0 multiplier on scroll speed
    public var speedMultiplier: Double
    /// 0 = unlimited
    public var maxSimultaneous: Int
    public var hideScroll: Bool
    public var hideTop: Bool
    public var hideBottom: Bool
    public var hideColored: Bool
    /// Manual timing offset in seconds; positive delays danmaku.
    public var timeOffset: Double

    public init(
        opacity: Double = 0.8,
        fontScale: Double = 1.0,
        displayArea: Double = 0.75,
        speedMultiplier: Double = 1.0,
        maxSimultaneous: Int = 0,
        hideScroll: Bool = false,
        hideTop: Bool = false,
        hideBottom: Bool = false,
        hideColored: Bool = false,
        timeOffset: Double = 0
    ) {
        self.opacity = opacity
        self.fontScale = fontScale
        self.displayArea = displayArea
        self.speedMultiplier = speedMultiplier
        self.maxSimultaneous = maxSimultaneous
        self.hideScroll = hideScroll
        self.hideTop = hideTop
        self.hideBottom = hideBottom
        self.hideColored = hideColored
        self.timeOffset = timeOffset
    }

    public static let `default` = DanmakuDisplaySettings()
}

/// A comment currently on screen, with geometry in points. The renderer
/// maps these onto layers; everything here is derived from the media clock
/// so pause, speed, and seek stay exact.
public struct DanmakuActiveComment: Identifiable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let color: Int
    public let mode: DanmakuMode
    /// Left edge x, in points (origin top-left).
    public var x: Double
    /// Top edge y, in points.
    public var y: Double
    public var width: Double

    public init(id: String, text: String, color: Int, mode: DanmakuMode, x: Double, y: Double, width: Double) {
        self.id = id
        self.text = text
        self.color = color
        self.mode = mode
        self.x = x
        self.y = y
        self.width = width
    }
}

/// Pure danmaku presentation engine: spawn tracking, lane scheduling with
/// collision avoidance, deterministic overflow, and seek rebuilds. Time is
/// always media time; the renderer feeds the engine the media clock, so
/// pause freezes (the clock stops), speed scales movement, and drift is
/// impossible by construction.
///
/// Not thread-safe by design — the renderer (or a test) drives it from one
/// thread.
public final class DanmakuEngine {
    /// Media seconds a scrolling comment takes to cross the viewport,
    /// before the user speed multiplier.
    public static let baseScrollDuration: Double = 11
    /// Media seconds a fixed (top/bottom) comment stays visible.
    public static let fixedDuration: Double = 5
    /// Comments whose timestamp is more than this far in the past at spawn
    /// time are skipped instead of flashed (post-seek debris).
    public static let spawnGrace: Double = 0.75

    public struct Diagnostics: Sendable, Equatable {
        public var loadedCount = 0
        public var skippedOnSeek = 0
        public var droppedForCapacity = 0
        public var droppedNoLane = 0
    }

    public private(set) var diagnostics = Diagnostics()
    public private(set) var activeComments: [DanmakuActiveComment] = []

    /// The unfiltered comment list as delivered by load(comments:).
    private var allComments: [DanmakuComment] = []
    /// Filtered + sorted comments, parallel to `effectiveTimes`.
    private var comments: [DanmakuComment] = []
    /// Comment time plus the user offset; the engine's timeline.
    private var effectiveTimes: [Double] = []
    private var cursor = 0
    private var lastMediaTime: Double = 0

    private var settings: DanmakuDisplaySettings
    private var viewportWidth: Double
    private var viewportHeight: Double
    private var lineHeight: Double
    private var measure: (DanmakuComment) -> Double

    /// Active bookkeeping, parallel to `activeComments`.
    private struct Live {
        var comment: DanmakuComment
        var width: Double
        var lane: Int
        var spawnTime: Double
        var speed: Double
        var expireTime: Double
    }

    private var live: [Live] = []
    /// Most recently placed comment per scrolling lane.
    private struct LaneTail {
        var spawnTime: Double
        var width: Double
        var speed: Double
        var exitTime: Double
    }

    private var scrollLanes: [LaneTail?] = []
    private var topLanes: [Double] = []
    private var bottomLanes: [Double] = []

    public init(
        viewportWidth: Double,
        viewportHeight: Double,
        lineHeight: Double,
        settings: DanmakuDisplaySettings = .default,
        measure: @escaping (DanmakuComment) -> Double
    ) {
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.lineHeight = lineHeight
        self.settings = settings
        self.measure = measure
        rebuildLanes()
    }

    // MARK: - Inputs

    /// Replaces the comment set (provider shift already baked into comment
    /// times by the session). Active state resets around the current media
    /// time — a reload must not replay earlier comments.
    public func load(comments: [DanmakuComment]) {
        allComments = comments
        rebuildCommentTimeline()
        clearActive()
        cursor = insertionIndex(for: lastMediaTime - Self.spawnGrace)
    }

    public func updateSettings(_ newSettings: DanmakuDisplaySettings) {
        let needsReload = newSettings.timeOffset != settings.timeOffset
            || newSettings.hideScroll != settings.hideScroll
            || newSettings.hideTop != settings.hideTop
            || newSettings.hideBottom != settings.hideBottom
            || newSettings.hideColored != settings.hideColored
        let needsLaneRebuild = newSettings.displayArea != settings.displayArea
        settings = newSettings
        if needsReload {
            rebuildCommentTimeline()
        }
        if needsReload || needsLaneRebuild {
            clearActive()
            rebuildLanes()
            cursor = insertionIndex(for: lastMediaTime - Self.spawnGrace)
        }
    }

    /// Viewport or font metrics changed; re-derive lanes and drop active
    /// comments (a resize mid-flight is rare and cheap to rebuild).
    public func updateViewport(width: Double, height: Double, lineHeight: Double) {
        guard width != viewportWidth || height != viewportHeight || lineHeight != self.lineHeight else { return }
        viewportWidth = width
        viewportHeight = height
        self.lineHeight = lineHeight
        clearActive()
        rebuildLanes()
    }

    // MARK: - Time advancement

    /// Advances to `mediaTime`, spawning due comments and expiring finished
    /// ones. `activeComments` geometry is refreshed in place. Returns true
    /// when the active set changed structurally (spawn/expire).
    @discardableResult
    public func tick(at mediaTime: Double) -> Bool {
        lastMediaTime = mediaTime
        var structuralChange = false

        // Spawn every due comment. During normal playback ticks arrive one
        // frame apart, so comments spawn within a frame of their timestamp;
        // after a seek the cursor sits just below the seek target, so only
        // comments at/after the new position appear.
        while cursor < effectiveTimes.count && effectiveTimes[cursor] <= mediaTime {
            let comment = comments[cursor]
            let due = effectiveTimes[cursor]
            cursor += 1
            guard due >= mediaTime - Self.spawnGrace else {
                diagnostics.skippedOnSeek += 1
                continue
            }
            if spawnComment(comment, at: mediaTime) {
                structuralChange = true
            }
        }

        // Expire finished comments and refresh geometry, compacting both
        // parallel arrays in one pass.
        if !live.isEmpty {
            var writeIndex = 0
            for index in live.indices {
                let item = live[index]
                guard mediaTime < item.expireTime else { continue }
                live[writeIndex] = item
                var active = activeComments[index]
                active.x = xPosition(of: item, at: mediaTime)
                activeComments[writeIndex] = active
                writeIndex += 1
            }
            if writeIndex < live.count {
                live.removeSubrange(writeIndex...)
                activeComments.removeSubrange(writeIndex...)
                structuralChange = true
            }
        }
        return structuralChange
    }

    /// Discards active comments and re-syncs to a new playback position
    /// without replaying the comments the seek jumped over.
    public func seek(to mediaTime: Double) {
        let target = insertionIndex(for: mediaTime - Self.spawnGrace)
        if target > cursor {
            diagnostics.skippedOnSeek += target - cursor
        }
        clearActive()
        cursor = target
        lastMediaTime = mediaTime
    }

    // MARK: - Spawning

    private func spawnComment(_ comment: DanmakuComment, at mediaTime: Double) -> Bool {
        guard allowsCapacity() else {
            diagnostics.droppedForCapacity += 1
            return false
        }
        let width = measure(comment)
        switch comment.mode {
        case .scroll:
            let speed = scrollSpeed(forWidth: width)
            // Fixed-duration traversal: wider comments travel faster.
            if let lane = allocateScrollLane(now: mediaTime, width: width, speed: speed) {
                appendActive(comment, width: width, lane: lane, spawnTime: mediaTime, speed: speed,
                             duration: (Self.baseScrollDuration / max(settings.speedMultiplier, 0.1)))
                return true
            }
        case .top, .bottom:
            if let lane = allocateFixedLane(mode: comment.mode, now: mediaTime) {
                appendActive(comment, width: width, lane: lane, spawnTime: mediaTime, speed: 0,
                             duration: Self.fixedDuration)
                return true
            }
        }
        diagnostics.droppedNoLane += 1
        return false
    }

    private func appendActive(
        _ comment: DanmakuComment,
        width: Double,
        lane: Int,
        spawnTime: Double,
        speed: Double,
        duration: Double
    ) {
        let x: Double
        let y: Double
        switch comment.mode {
        case .scroll:
            x = viewportWidth
            y = Double(lane) * lineHeight
            scrollLanes[lane] = LaneTail(spawnTime: spawnTime, width: width, speed: speed, exitTime: spawnTime + duration)
        case .top:
            x = (viewportWidth - width) / 2
            y = Double(lane) * lineHeight
            topLanes[lane] = spawnTime + duration
        case .bottom:
            x = (viewportWidth - width) / 2
            let areaHeight = usableAreaHeight
            y = areaHeight - lineHeight - Double(lane) * lineHeight
            bottomLanes[lane] = spawnTime + duration
        }
        live.append(Live(
            comment: comment,
            width: width,
            lane: lane,
            spawnTime: spawnTime,
            speed: speed,
            expireTime: spawnTime + duration
        ))
        activeComments.append(DanmakuActiveComment(
            id: comment.id,
            text: comment.text,
            color: comment.color,
            mode: comment.mode,
            x: x,
            y: y,
            width: width
        ))
    }

    private func xPosition(of item: Live, at mediaTime: Double) -> Double {
        switch item.comment.mode {
        case .scroll:
            viewportWidth - item.speed * (mediaTime - item.spawnTime)
        case .top, .bottom:
            (viewportWidth - item.width) / 2
        }
    }

    // MARK: - Lanes

    private var usableAreaHeight: Double {
        max(lineHeight, viewportHeight * min(max(settings.displayArea, 0.1), 1))
    }

    private func rebuildLanes() {
        let laneCount = max(1, Int(usableAreaHeight / lineHeight))
        scrollLanes = Array(repeating: nil, count: laneCount)
        let fixedCount = max(1, min(12, laneCount / 3))
        topLanes = Array(repeating: 0, count: fixedCount)
        bottomLanes = Array(repeating: 0, count: fixedCount)
    }

    private func scrollSpeed(forWidth width: Double) -> Double {
        let duration = Self.baseScrollDuration / max(settings.speedMultiplier, 0.1)
        return (viewportWidth + width) / duration
    }

    /// Collision-free lane allocation for a scrolling comment.
    ///
    /// A lane is usable when the previous comment (a) has fully entered the
    /// viewport and (b) the newcomer cannot rear-end it before it exits.
    /// When no lane is collision-free, the lane that becomes available
    /// soonest wins — a deterministic overflow that keeps overlaps minimal.
    private func allocateScrollLane(now: Double, width: Double, speed: Double) -> Int? {
        var fallbackLane: Int?
        var fallbackAvailableAt = Double.infinity
        for (lane, tail) in scrollLanes.enumerated() {
            guard let tail else { return lane }
            if now >= tail.exitTime { return lane }
            let availableAt = laneAvailableAt(tail: tail, width: width, speed: speed)
            if availableAt < fallbackAvailableAt {
                fallbackAvailableAt = availableAt
                fallbackLane = lane
            }
        }
        // Overflow placement: only into the soonest-free lane whose
        // previous comment is already fully on screen; otherwise drop.
        guard let lane = fallbackLane, let tail = scrollLanes[lane] else { return nil }
        guard tail.speed * (now - tail.spawnTime) >= tail.width else { return nil }
        return lane
    }

    /// When the lane becomes collision-free for a comment with the given
    /// width and speed: the predecessor must clear the right edge, and a
    /// faster newcomer must not catch up before the predecessor exits
    /// (`v_new * (t_exit - t_spawn_new) <= viewportWidth`).
    private func laneAvailableAt(tail: LaneTail, width: Double, speed: Double) -> Double {
        var constraints = [tail.spawnTime + tail.width / tail.speed]
        if speed > tail.speed {
            constraints.append(tail.exitTime - viewportWidth / speed)
        }
        return constraints.max() ?? 0
    }

    private func allocateFixedLane(mode: DanmakuMode, now: Double) -> Int? {
        let lanes: [Double]
        switch mode {
        case .top: lanes = topLanes
        case .bottom: lanes = bottomLanes
        case .scroll: return nil
        }
        var fallback: Int?
        var fallbackFreeAt = Double.infinity
        for (lane, freeAt) in lanes.enumerated() {
            if now >= freeAt { return lane }
            if freeAt < fallbackFreeAt {
                fallbackFreeAt = freeAt
                fallback = lane
            }
        }
        return fallback
    }

    private func allowsCapacity() -> Bool {
        settings.maxSimultaneous <= 0 || live.count < settings.maxSimultaneous
    }

    // MARK: - Helpers

    private func rebuildCommentTimeline() {
        comments = allComments.filter { comment in
            let modeAllowed: Bool
            switch comment.mode {
            case .scroll: modeAllowed = !settings.hideScroll
            case .top: modeAllowed = !settings.hideTop
            case .bottom: modeAllowed = !settings.hideBottom
            }
            return modeAllowed && !(settings.hideColored && comment.isColored)
        }
        .sorted { lhs, rhs in
            lhs.time < rhs.time || (lhs.time == rhs.time && lhs.id < rhs.id)
        }
        effectiveTimes = comments.map { $0.time + settings.timeOffset }
        diagnostics.loadedCount = comments.count
    }

    private func clearActive() {
        live.removeAll()
        activeComments.removeAll()
        for lane in scrollLanes.indices { scrollLanes[lane] = nil }
        for lane in topLanes.indices { topLanes[lane] = 0 }
        for lane in bottomLanes.indices { bottomLanes[lane] = 0 }
    }

    private func insertionIndex(for mediaTime: Double) -> Int {
        var low = 0
        var high = effectiveTimes.count
        while low < high {
            let mid = (low + high) / 2
            if effectiveTimes[mid] < mediaTime { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
