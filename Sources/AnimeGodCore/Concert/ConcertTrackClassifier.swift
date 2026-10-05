import Foundation

/// Decides what an entry on a concert disc's track list actually is, and
/// strips the markers the listing decorates it with.
///
/// This exists because a concert disc's track list is not a setlist. Measured
/// on `ANZX-10294`, Discogs lists twenty entries across three discs: sixteen
/// songs, an `オーディオコメンタリー`, a bonus event and two making-of features.
/// Laying all twenty over the programme's chapter marks would be wrong twice
/// over — the commentary is a whole alternative soundtrack rather than a
/// segment, and the bonus features are on other discs entirely.
public enum ConcertTrackClassifier {
    /// Audio commentary, in the spellings the discs use. An alternative
    /// soundtrack, so it occupies no place on the timeline.
    static let commentaryMarkers = [
        "オーディオコメンタリー", "オーディオ・コメンタリー", "コメンタリー",
        "audio commentary", "commentary", "音声特典", "副音声", "评论音轨", "評論音軌"
    ]

    /// Bonus features. `メイキング` and its kin are programmes of their own;
    /// so is a documentary, a digest and a trailer reel.
    static let bonusMarkers = [
        "making of", "making", "メイキング", "ドキュメント", "ドキュメンタリー",
        "documentary", "digest", "ダイジェスト", "ノンクレジット", "ノンテロップ",
        "special feature", "bonus", "特典映像", "映像特典", "予告", "pv集",
        "teaser", "trailer", "behind the scenes", "off shot", "オフショット",
        "番外編", "特報", "幕后", "幕後", "花絮"
    ]

    /// Stage talk, when a disc lists it as an entry of its own.
    static let talkMarkers = [
        "mc", "トーク", "talk", "インターミッション", "intermission", "interlude"
    ]

    /// The encore, which a listing marks rather than numbers. Worth keeping:
    /// it is the one structural hint a setlist carries and it reads well as a
    /// divider.
    static let encoreMarkers = [
        "アンコール", "encore", "en.", "w encore", "ダブルアンコール", "安可"
    ]

    /// What this entry is, and the title with the listing's own markers
    /// removed.
    public static func classify(title rawTitle: String) -> (title: String, kind: ConcertTrackKind, isEncore: Bool) {
        let (stripped, isEncore) = splitEncoreMarker(from: rawTitle)
        let haystack = fold(stripped)
        let kind: ConcertTrackKind
        if contains(haystack, anyOf: commentaryMarkers) {
            kind = .commentary
        } else if contains(haystack, anyOf: bonusMarkers) {
            kind = .bonus
        } else if isWholeMarker(haystack, anyOf: talkMarkers) {
            kind = .talk
        } else {
            kind = .song
        }
        return (stripped, kind, isEncore)
    }

    /// `[アンコール] 光の中へ`, `光の中へ (Encore)`, `EN1. 青春コンプレックス` — the
    /// marker comes off so the title matches the same song listed plainly
    /// somewhere else, and comes back as a flag.
    private static func splitEncoreMarker(from title: String) -> (String, Bool) {
        var working = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var found = false
        // A leading bracketed group, which is how every Japanese listing
        // writes it.
        for opening in ["[", "【", "（", "("] {
            let closing = ["[": "]", "【": "】", "（": "）", "(": ")"][opening]!
            guard working.hasPrefix(opening), let end = working.range(of: closing) else { continue }
            let inside = String(working[working.index(after: working.startIndex)..<end.lowerBound])
            guard contains(fold(inside), anyOf: encoreMarkers) else { continue }
            working = String(working[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            found = true
            break
        }
        if !found, contains(fold(working), anyOf: ["アンコール", "encore", "安可"]) {
            found = true
        }
        return (working, found)
    }

    private static func fold(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func contains(_ haystack: String, anyOf markers: [String]) -> Bool {
        markers.contains { haystack.contains(fold($0)) }
    }

    /// For markers short enough to appear inside a song's name. `MC` is two
    /// letters and `talk` is a word people put in titles, so those only count
    /// when the entry is *nothing but* the marker and perhaps a number.
    private static func isWholeMarker(_ haystack: String, anyOf markers: [String]) -> Bool {
        let bare = haystack.filter { $0.isLetter || $0.isNumber }
        return markers.contains { marker in
            let folded = fold(marker).filter { $0.isLetter || $0.isNumber }
            guard !folded.isEmpty, bare.hasPrefix(folded) else { return false }
            let rest = bare.dropFirst(folded.count)
            return rest.isEmpty || rest.allSatisfy(\.isNumber)
        }
    }
}

/// Where a listing says an entry sits: which disc, and which track of it.
public struct ConcertTrackPosition: Hashable, Sendable {
    /// What the listing calls the disc — `1`, `CD`, `BD`, or empty when the
    /// release has only one.
    public let discKey: String
    /// 1-based within the disc, when the listing numbers it.
    public let track: Int?

    public init(discKey: String, track: Int?) {
        self.discKey = discKey
        self.track = track
    }

    /// Reads Discogs' `position` field.
    ///
    /// It is not a number. `1-01` is disc one track one, `CD-1` names the
    /// medium instead of numbering it (measured on `BRMM-10716`), a plain `3`
    /// means the release has one disc, and an empty string marks a heading
    /// row rather than a track.
    public static func parse(_ position: String) -> ConcertTrackPosition? {
        let trimmed = position.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            let key = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
            return ConcertTrackPosition(discKey: key, track: Int(digits(in: parts[1])))
        }
        return ConcertTrackPosition(discKey: "", track: Int(digits(in: trimmed)))
    }

    /// A vinyl side is `A1`, so the digits are what the track number is.
    private static func digits(in text: some StringProtocol) -> String {
        String(text.filter(\.isNumber))
    }
}
