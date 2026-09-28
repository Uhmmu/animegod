import Foundation

/// Whether a work is watched the way a series is, or the way a film is.
///
/// The two differ only in how much of the tail counts as "seen it": a
/// 24-minute episode whose last five minutes are the ED is finished long
/// before the file is, and nobody sits through ten minutes of a film's
/// credits either.
///
/// This decides marking-watched and nothing else. Subscriptions must never
/// consult it: what to download comes from the release schedule, and a season
/// one episode into its run is a series that happens to have one episode —
/// calling it a film here is harmless, calling it a film there would stop the
/// season being followed.
public enum WatchedWorkKind: String, Sendable, Hashable, CaseIterable {
    case series
    case film

    /// How close to the end counts as watched.
    public var completionTail: Double {
        switch self {
        case .series: 5 * 60
        case .film: 10 * 60
        }
    }

    /// What a work is watched as.
    ///
    /// A provider that says what it is settles the question. Otherwise the
    /// files do: one main episode is a film. Specials, creditless openings and
    /// the rest are not main episodes, so a film that shipped with three
    /// extras is still a film — which is why the caller passes the count the
    /// library already shows on the card rather than every file it holds.
    public static func classify(reportedKind: AnimeKind?, mainEpisodeCount: Int?) -> WatchedWorkKind {
        switch reportedKind {
        case .movie: return .film
        case .tv, .ova, .ona, .special: return .series
        case .unknown, nil: break
        }
        // Nothing has matched this work yet, so its own files answer.
        guard let mainEpisodeCount else { return .series }
        return mainEpisodeCount == 1 ? .film : .series
    }

    /// Whether playback has reached the point where the episode counts as seen.
    public static func isWatched(position: Double, duration: Double, kind: WatchedWorkKind) -> Bool {
        isWatched(position: position, duration: duration, tail: kind.completionTail)
    }

    /// The tail is capped at a quarter of the runtime, or the rule stops
    /// meaning anything for short content: five minutes from the end of a
    /// four-minute creditless opening is before it started, and the file would
    /// be marked watched the moment it opened.
    public static func isWatched(position: Double, duration: Double, tail: Double) -> Bool {
        guard duration > 0, position > 0 else { return false }
        return position >= duration - min(tail, duration * 0.25)
    }
}
