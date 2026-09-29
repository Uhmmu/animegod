import Foundation

/// Maps host (wall) time to media time using the player's own position
/// samples — never an independently running timer.
///
/// The player pushes anchors (`position`, `speed`, `playing`) every time it
/// reports a position (mpv wakes the app several times a second; AVPlayer
/// four times a second). Between anchors, media time is interpolated as
/// `position + speed * elapsed`, so interpolation error is bounded by the
/// anchor interval and eliminated at the next anchor: long sessions cannot
/// accumulate drift. While paused the clock simply holds the last media
/// time, which freezes every danmaku animation.
public struct DanmakuPlaybackClock: Sendable, Equatable {
    public private(set) var mediaTime: Double = 0
    public private(set) var speed: Double = 1
    public private(set) var playing = false
    private var hostTime: Double = 0

    public init() {}

    /// What a player sample did to the clock.
    public enum SampleOutcome: Sendable, Equatable {
        /// The sample agreed with the running estimate; the error was folded
        /// in gradually and motion is continuous.
        case tracked
        /// The sample disagreed by more than `seekThreshold`: a seek, a
        /// restart or a stall. The renderer must rebuild rather than animate
        /// across the gap.
        case discontinuous
    }

    /// How much of the remaining error each sample corrects. Over the ~24
    /// samples a second mpv produces this settles in about half a second,
    /// which is far below the threshold of noticing.
    public static let trackingGain: Double = 0.08

    /// Folds a player position sample in without snapping.
    ///
    /// **Anchoring hard on every sample is what makes danmaku judder.** mpv
    /// reports `time-pos` once per decoded frame, so the values are quantised
    /// to the video's frame period (41 ms at 23.976 fps), and the report
    /// reaches the main actor after a scheduling hop of its own. Setting
    /// `mediaTime = position` each time therefore yanks the timeline back and
    /// forth by tens of milliseconds several times a second; at a typical
    /// scroll speed that is a few points of position error per frame, and it
    /// reads as stutter even though playback itself is perfectly smooth.
    ///
    /// So a sample that agrees with the running estimate only corrects a
    /// fraction of the error. The error is zero-mean noise, so the average
    /// still tracks the player exactly and long-run drift is still impossible
    /// — what disappears is the per-sample snap. A sample that disagrees
    /// wildly is a real discontinuity and is taken whole.
    @discardableResult
    public mutating func sample(
        position: Double,
        speed: Double,
        playing: Bool,
        hostTime: Double,
        seekThreshold: Double = 0.5
    ) -> SampleOutcome {
        let threshold = max(seekThreshold, 0.25 * speed)
        let error = position - mediaTime(atHost: hostTime)
        // A change of speed or of playing state re-bases the interpolation,
        // so it has to be taken exactly whatever the error says.
        let stateChanged = playing != self.playing || speed != self.speed
        if abs(error) > threshold || !playing || !self.playing {
            anchor(position: position, speed: speed, playing: playing, hostTime: hostTime)
            return abs(error) > threshold ? .discontinuous : .tracked
        }
        if stateChanged {
            anchor(position: position, speed: speed, playing: playing, hostTime: hostTime)
            return .tracked
        }
        anchor(
            position: position - error * (1 - Self.trackingGain),
            speed: speed,
            playing: playing,
            hostTime: hostTime
        )
        return .tracked
    }

    /// Re-anchors to a fresh player position sample.
    public mutating func anchor(position: Double, speed: Double, playing: Bool, hostTime: Double) {
        self.mediaTime = max(0, position)
        self.speed = max(0, speed)
        self.playing = playing
        self.hostTime = hostTime
    }

    public mutating func setPlaying(_ playing: Bool, hostTime: Double) {
        guard playing != self.playing else { return }
        if !playing {
            // Fold the running estimate in, then hold it.
            mediaTime = mediaTime(atHost: hostTime)
        } else {
            self.hostTime = hostTime
        }
        self.playing = playing
    }

    public mutating func setSpeed(_ speed: Double, hostTime: Double) {
        guard speed != self.speed else { return }
        if playing {
            mediaTime = mediaTime(atHost: hostTime)
            self.hostTime = hostTime
        }
        self.speed = max(0, speed)
    }

    /// The interpolated media time at a host timestamp. Paused clocks
    /// return the frozen position.
    public func mediaTime(atHost host: Double) -> Double {
        guard playing, host >= hostTime else { return mediaTime }
        return mediaTime + (host - hostTime) * speed
    }
}
