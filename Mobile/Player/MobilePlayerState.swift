import AnimeGodCore
import Foundation
import QuartzCore
import UIKit

/// What the player screen shows and does.
@MainActor
final class MobilePlayerState: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var paused = false
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var audioTracks: [MobileTrack] = []
    @Published var subtitleTracks: [MobileTrack] = []
    @Published var audioID: Int64?
    @Published var subtitleID: Int64?
    @Published var speed: Double = 1
    @Published var isScrubbing = false
    @Published private(set) var isWatched = false

    /// The unthrottled position. `position` is republished at 5 Hz so the
    /// whole SwiftUI player is not re-evaluated on every rendered frame — the
    /// Mac's own lesson — and this is what a save or a handoff must read.
    private(set) var livePosition: Double = 0
    private var lastPublish: CFTimeInterval = 0

    /// Holds the tail rule off for the rest of the session once the viewer has
    /// said an episode is not watched; otherwise the autosave re-marks it ten
    /// seconds later.
    private(set) var keepsUnwatched = false

    let episode: LinkEpisode
    let work: LinkWork
    private weak var model: MobileModel?
    private var watchedTail: Double

    init(episode: LinkEpisode, work: LinkWork, model: MobileModel) {
        self.episode = episode
        self.work = work
        self.model = model
        self.duration = episode.duration
        self.position = episode.position
        self.livePosition = episode.position
        self.isWatched = episode.isWatched
        // Films get a longer tail than series; the count comes off the card
        // the same way the Mac reads it.
        let kind = WatchedWorkKind.classify(reportedKind: work.kind, mainEpisodeCount: work.episodeCount)
        self.watchedTail = kind.completionTail
    }

    /// Where playback starts. An episode played to the end starts over rather
    /// than resuming a fraction of a second before EOF, which looks exactly
    /// like a file that will not play.
    var startPosition: Double {
        let from = handedOverPosition ?? episode.position
        let total = duration > 0 ? duration : episode.duration
        guard from > 0, total > 0 else { return from }
        return from >= total - 15 ? 0 : from
    }

    /// Takes the session the Mac handed over.
    ///
    /// The position here beats the cached row by up to ten seconds — the Mac's
    /// autosave interval — which is the whole reason the handoff is a request
    /// rather than a database read.
    func adopt(_ handoff: LinkHandoffState) {
        position = handoff.position
        livePosition = handoff.position
        if handoff.duration > 0 { duration = handoff.duration }
        isWatched = handoff.isWatched
        keepsUnwatched = handoff.keepsUnwatched
        speed = handoff.speed
        handedOverPosition = handoff.position
    }

    /// Where the Mac said to start, once it has said so.
    private var handedOverPosition: Double?

    func setWatched(_ value: Bool) {
        isWatched = value
        keepsUnwatched = !value
        Task { await model?.setWatched(value, episodeID: episode.id) }
    }

    func save() async {
        guard duration > 0 else { return }
        await model?.saveProgress(episodeID: episode.id, position: livePosition, duration: duration)
    }

    // MARK: - Delegate plumbing

    func didUpdate(position: Double?, duration: Double?, paused: Bool?) {
        if let position {
            livePosition = position
            if !isWatched, !keepsUnwatched,
               WatchedWorkKind.isWatched(position: position, duration: duration ?? self.duration, tail: watchedTail) {
                isWatched = true
            }
            let now = CACurrentMediaTime()
            // A jump, a pause or the first sample lands immediately; the rest
            // is throttled, because the timeline moves under a pixel in 200 ms.
            if !isScrubbing, (paused ?? self.paused) || abs(position - self.position) > 1 || now - lastPublish >= 0.2 {
                lastPublish = now
                self.position = position
            }
        }
        if let duration, duration > 0 { self.duration = duration }
        if let paused { self.paused = paused }
    }
}
