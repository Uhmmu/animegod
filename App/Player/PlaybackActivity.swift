import Foundation

/// Keeps the display awake while a video is actually playing.
///
/// The screen saver and display sleep are driven by how long the user has
/// been idle at the keyboard, and watching a film is exactly the case where
/// nobody touches anything for two hours. mpv renders into our own
/// CAMetalLayer, so nothing in the system knows a movie is on screen unless
/// the app says so.
///
/// The assertion is held only while playback is running: a paused or closed
/// player must let the Mac sleep normally. `beginActivity` is the sandbox-
/// safe API for this — it takes the same power assertions IOKit would,
/// without IOKit access.
@MainActor
final class PlaybackActivity {
    /// Deinit-only access from the nonisolated finalizer; safe because the
    /// object is already unreferenced there.
    nonisolated(unsafe) private var token: NSObjectProtocol?

    func setPlaying(_ playing: Bool) {
        if playing {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "Playing video"
            )
        } else if let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }

    deinit {
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }
}
