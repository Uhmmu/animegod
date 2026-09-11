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
