import Foundation

/// What one entry of a concert disc's track list actually is.
///
/// A live Blu-ray's track list is not all songs: the discs carry audio
/// commentary, making-of features and the bonus events that share the box.
/// Measured on `ANZX-10294` (結束バンドLIVE-恒星-), Discogs lists 20 entries
/// across three discs of which 16 are songs, one is `オーディオコメンタリー`
/// and the rest are bonus features. Only songs belong on a timeline, so the
/// kind has to travel with the track rather than be re-guessed per screen.
public enum ConcertTrackKind: String, Codable, Hashable, Sendable {
    case song
    /// Between-song talk, when a disc lists it as its own entry.
    case talk
    /// An audio commentary track — a whole alternative soundtrack, not a
    /// segment of the programme, so it never takes a place on the timeline.
    case commentary
    /// Making-of features, bonus events, anything that is not the concert.
    case bonus

    /// Whether this entry is part of the performance the timeline describes.
    public var belongsOnTimeline: Bool { self == .song || self == .talk }
}

public struct ConcertTrack: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// 1-based position within its own disc.
    public var position: Int
    public var title: String
    /// How long the performance runs, when a source says. MusicBrainz fills
    /// this for roughly two thirds of live Blu-ray media and Discogs — this
    /// was measured, not assumed — fills it for none of them, so a nil here
    /// is the ordinary case and every consumer has to work without it.
    public var duration: TimeInterval?
    public var kind: ConcertTrackKind
    /// The disc marked this as part of the encore (`[アンコール]`). Worth
    /// keeping: it is the one structural hint a setlist carries, and it reads
    /// well as a divider on the page.
    public var isEncore: Bool

    public init(
        id: UUID = UUID(),
        position: Int,
        title: String,
        duration: TimeInterval? = nil,
        kind: ConcertTrackKind = .song,
        isEncore: Bool = false
    ) {
        self.id = id
        self.position = position
        self.title = title
        self.duration = duration
        self.kind = kind
        self.isEncore = isEncore
    }
}

/// One chapter mark read off the disc being played.
///
/// The core's own value type rather than the player's `MediaChapter`: the
/// alignment is pure logic and has to be testable without a player, and
/// `AnimeGodCore` imports no AppKit.
public struct ConcertChapterMark: Codable, Hashable, Sendable, Identifiable {
    public let index: Int
    public let title: String
    public let startTime: TimeInterval

    public var id: Int { index }

    public init(index: Int, title: String = "", startTime: TimeInterval) {
        self.index = index
        self.title = title
        self.startTime = startTime
    }
}
