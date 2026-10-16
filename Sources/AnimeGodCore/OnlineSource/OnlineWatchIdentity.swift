import Foundation

/// Everything the library needs to file one online episode under a work.
///
/// Carried whole rather than looked up piecemeal because the episode row and
/// the work row are created together, on the first play, out of exactly this.
public struct OnlineEpisodeRef: Sendable, Hashable {
    /// The rule that found it. Two sites carrying one show are two works
    /// here: their episode lists come from different places, they number
    /// differently, and one of them can go down.
    public let ruleName: String
    /// The work's own page, already run through `OnlineEpisodeURL.absolute`.
    public let workPageURL: String
    /// What the site calls the work, for the diary and the history.
    public let workName: String
    /// The playback line this episode was picked from. Recorded, not part of
    /// the identity — see `OnlineWatchIdentity.episodeIdentity`.
    public let roadName: String
    /// The site's own label: `第5集`, `01`, `OVA`, `预告`.
    public let label: String
    /// Position within the line, because a label is not always a number.
    public let index: Int
    /// The episode's page, already run through `OnlineEpisodeURL.absolute`.
    public let pageURL: String

    public init(
        ruleName: String,
        workPageURL: String,
        workName: String,
        roadName: String,
        label: String,
        index: Int,
        pageURL: String
    ) {
        self.ruleName = ruleName
        self.workPageURL = workPageURL
        self.workName = workName
        self.roadName = roadName
        self.label = label
        self.index = index
        self.pageURL = pageURL
    }
}

/// Where an online episode got to, as the grid needs to draw it.
public struct OnlineWatchState: Sendable, Hashable {
    public let position: Double
    public let duration: Double
    public let isWatched: Bool

    public init(position: Double, duration: Double, isWatched: Bool) {
        self.position = position
        self.duration = duration
        self.isWatched = isWatched
    }

    public var completion: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    /// Whether it is worth drawing a progress bar: started, not finished.
    public var isPartial: Bool { !isWatched && position > 0 && duration > 0 }
}

/// How an online episode is filed in the library's own tables.
///
/// Watching from a site writes the same rows watching a file does — an
/// `anime`, its `episode`s, their `playbackProgress`, and a `watchEvent` when
/// a session ends — because that is what the diary and the statistics read.
/// Nothing else is shared: an online work has no `mediaFile`, and every query
/// behind the library grid, the continue shelf and the concert passes joins
/// one, so it stays out of all of them without being filtered out of any.
public enum OnlineWatchIdentity {
    /// U+001F, the unit separator. It cannot occur in a rule's name or in a
    /// URL, and `LibraryDatabase.normalize` strips it along with every other
    /// non-alphanumeric — so a key built here can never be a key the scanner
    /// derived from a folder.
    static let separator = "\u{1F}"

    /// The `anime.normalizedTitle` an online work is filed under.
    ///
    /// Namespaced rather than the work's own name. That column is unique, so
    /// a site carrying a show this Mac also has on disk would otherwise be
    /// folded into it — and they are not one work: their episode lists have
    /// different numbering, and marking the file watched because the stream
    /// was is a claim nobody made. The page URL rather than the name, because
    /// a site files a season and its recap under one title often enough.
    public static func workIdentity(ruleName: String, pageURL: String) -> String {
        "online\(separator)\(OnlineSourceRule.identityKey(ruleName))\(separator)\(pageURL)"
    }

    /// Whether a normalized title is one of ours. The orphan sweeps and the
    /// duplicate detector both have to leave online works alone.
    public static func isOnlineWorkIdentity(_ normalizedTitle: String) -> Bool {
        normalizedTitle.hasPrefix("online\(separator)")
    }

    /// How one episode of an online work is filed inside it.
    public struct EpisodeIdentity: Sendable, Hashable {
        /// Unique within the work — the `episode.identityKey` column.
        public let key: String
        public let number: Double?
        public let numberText: String?
        public let kind: EpisodeKind
        public let sortIndex: Double
    }

    /// Reads a site's episode label.
    ///
    /// The number it states, when it states exactly one, so the same episode
    /// on two of a site's playback lines is **one** episode row and one watch
    /// record: the lines are different uploads of the same thing, and
    /// finishing episode 5 on whichever line was up is finishing episode 5.
    /// Exactly one, because a label carrying two numbers is not stating an
    /// episode — `1080P第5集` would otherwise be episode 1080 and `第2季第1集`
    /// would be two different seasons' episode 2.
    ///
    /// A label that states no number can only be itself, and is a `special`:
    /// `预告` and `OVA` are not the season, and counting them as regular
    /// episodes would keep a finished work from ever reading as finished.
    public static func episodeIdentity(label: String, index: Int) -> EpisodeIdentity {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let runs = digitRuns(in: trimmed)
        if runs.count == 1, let number = Int(runs[0]) {
            return EpisodeIdentity(
                key: "E\(number)",
                number: Double(number),
                numberText: String(number),
                kind: .regular,
                sortIndex: Double(number)
            )
        }
        // Folded the way the library folds a title, so `OVA` and ` ova `
        // are the same slot on two lines that spell it differently.
        let folded = trimmed
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        return EpisodeIdentity(
            key: "L\(separator)\(folded)",
            number: nil,
            numberText: trimmed.isEmpty ? nil : trimmed,
            kind: .special,
            // Behind every numbered episode, in the order the site listed it.
            sortIndex: Double(200_000 + index)
        )
    }

    /// The runs of ASCII digits in a label, longest-first order preserved.
    /// Full-width digits are folded to ASCII before this runs.
    private static func digitRuns(in label: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in label.folding(options: .widthInsensitive, locale: .current) {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}
