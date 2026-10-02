import Foundation

/// Whether two downloads are of the same work, judged by name alone.
///
/// A season that has only just started airing cannot be downloaded as a set:
/// one episode is out, so it is fetched on its own. A week later the second
/// episode appears — as a set now that there are two, through a subscription,
/// or on its own again — and taken on its own terms it is a second folder, a
/// second card in Downloads and a second entry in the library. Matching the
/// names is what keeps the season together however its episodes were started.
public enum TorrentWorkIdentity {
    /// A name reduced to what its identity depends on: case, width, accents,
    /// punctuation and spacing all removed.
    ///
    /// Precomposed first. macOS hands folder names back decomposed, so
    /// 「まだ」 arrives as `ま` + `た` + U+3099, and diacritic-insensitive
    /// folding then *removes* the combining mark while leaving a precomposed
    /// `だ` alone — two spellings of one title, folded to two different keys.
    /// This is deliberately `LibraryDatabase`'s own rule for a work's
    /// identity: the folders and the library rows must not be able to
    /// disagree about what counts as the same show.
    public static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }

    /// Two names for one work.
    ///
    /// A later season is a different work here: "Yani Neko" and "Yani Neko
    /// S2" are two names, and treating them as one would gather two seasons
    /// into one folder and file them as one show.
    public static func namesSameWork(_ one: String, _ other: String) -> Bool {
        let folded = key(one)
        return !folded.isEmpty && folded == key(other)
    }

    /// A download already under way, as deciding what a new one is of needs
    /// to see it. Only a download that was given a folder counts: one that
    /// predates folders has its file loose under the download folder, so
    /// adopting its name would not put the episodes together.
    public struct Downloading: Sendable {
        public var folderName: String
        public var animeID: UUID?
        public var animeTitle: String?
        public var addedAt: Date

        public init(folderName: String, animeID: UUID? = nil, animeTitle: String? = nil, addedAt: Date) {
            self.folderName = folderName
            self.animeID = animeID
            self.animeTitle = animeTitle
            self.addedAt = addedAt
        }
    }

    /// What a new download turns out to be of.
    public struct Join: Sendable, Equatable {
        public var folderName: String?
        public var animeID: UUID?
        public var animeTitle: String?
    }

    /// What a download belongs to: the folder it goes in and the anime it is
    /// bound to, taken from the work already being downloaded under a name
    /// that matches.
    ///
    /// The folder that is already there wins over the name just derived, down
    /// to its spelling — the episodes on disk are in it, so adopting the new
    /// spelling would split the season rather than join it. An anime the
    /// caller already knows is never overruled; one it does not know is
    /// inherited, because otherwise the first episode would be the matched
    /// show and the second an anonymous magnet beside it.
    ///
    /// The anime a download is bound to is deliberately *not* a second way
    /// in. A work's later season shares its anime title — the suffix is all
    /// that tells "Yani Neko" from "Yani Neko S2" — so going by the binding
    /// would pour season two into season one's folder.
    public static func join(
        folderName candidate: String?,
        animeID: UUID? = nil,
        animeTitle: String? = nil,
        among existing: [Downloading]
    ) -> Join {
        var joined = Join(folderName: candidate, animeID: animeID, animeTitle: animeTitle)
        guard let candidate, !candidate.isEmpty else { return joined }
        let related = existing
            .filter { namesSameWork($0.folderName, candidate) }
            .sorted { $0.addedAt < $1.addedAt }
        guard let newest = related.last else { return joined }
        joined.folderName = newest.folderName
        if joined.animeID == nil, let linked = related.last(where: { $0.animeID != nil }) {
            joined.animeID = linked.animeID
            joined.animeTitle = linked.animeTitle
        }
        return joined
    }
}
