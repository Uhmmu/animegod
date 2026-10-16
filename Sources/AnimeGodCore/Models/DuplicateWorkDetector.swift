import Foundation

/// One work filed twice, found by asking the metadata providers rather than
/// by comparing names.
///
/// A season in its first week cannot be downloaded as a set — one episode is
/// out — so episode one arrives on its own, in a folder named after whichever
/// team published it, and the rest of the season arrives a week later named
/// after another. The two names are not spellings of each other:
/// `FX Senshi Kurumi-chan JPSC` and `FX Senshi Kurumi-chan CHS_JP&CHT_JP`
/// carry the teams' subtitle-language tags, so `TorrentWorkIdentity` quite
/// correctly says they are different works, and the library shows two cards —
/// one holding episode 1, the other episodes 1 and 2.
///
/// Names cannot settle this; a provider can. Bangumi answered `622288` for
/// both of those rows and for a third, the parked row the download created
/// before any file existed. **A subject id landing on two works is the one
/// piece of evidence that does not depend on how anybody spells anything**,
/// and it is evidence somebody already checked: these links are made by the
/// matcher, and a manual one by the viewer.
///
/// This only ever *reports*. Merging collapses two cards into one and moves
/// watch history across; it is not something to do to a library unasked, so
/// the decision stays with the viewer.
public enum DuplicateWorkDetector {
    /// A work as this needs to see it: enough to group the rows and to pick
    /// which of them the others should be merged into.
    public struct Work: Sendable, Hashable {
        public var id: UUID
        public var title: String
        public var kind: AnimeKind
        /// Files on disk under this row. The row that holds the most of them
        /// is the one to keep: merging into it moves the fewest episodes, and
        /// it is the card the viewer has been using.
        public var fileCount: Int
        public var createdAt: Date

        public init(id: UUID, title: String, kind: AnimeKind, fileCount: Int, createdAt: Date) {
            self.id = id
            self.title = title
            self.kind = kind
            self.fileCount = fileCount
            self.createdAt = createdAt
        }
    }

    /// A provider's answer about one work: the subject it was matched to.
    public struct Link: Sendable, Hashable {
        public var animeID: UUID
        public var provider: MetadataProviderID
        public var externalID: String

        public init(animeID: UUID, provider: MetadataProviderID, externalID: String) {
            self.animeID = animeID
            self.provider = provider
            self.externalID = externalID
        }
    }

    /// Several library rows that the providers say are one work.
    public struct Group: Sendable, Identifiable, Hashable {
        /// The row to merge the others into — the one holding the most files.
        public var primary: Work
        /// The rows that would be dissolved into `primary`, in the order they
        /// should be shown: most files first, so the biggest loss is obvious.
        public var duplicates: [Work]
        /// Which providers said so, and what they said. Shown to the viewer
        /// because "Bangumi 622288" is checkable and "they look the same" is
        /// not.
        public var evidence: [Evidence]

        public struct Evidence: Sendable, Hashable {
            public var provider: MetadataProviderID
            public var externalID: String
        }

        /// Stable across runs, so a group the viewer dismissed stays
        /// dismissed: the ids of every row in it, sorted.
        public var id: String {
            works.map(\.id.uuidString).sorted().joined(separator: "+")
        }

        public var works: [Work] { [primary] + duplicates }
    }

    /// Every set of rows that share at least one provider subject.
    ///
    /// Grouping is transitive: the Kurumi case is three rows sharing one
    /// Bangumi subject, and two of them also share an AniList id and a
    /// MyAnimeList id. Reporting that as three overlapping pairs would ask
    /// the viewer the same question three times.
    ///
    /// Rows of different kinds are never grouped. A concert and an anime can
    /// both carry a Bangumi subject, and a live Blu-ray belongs in its own
    /// section — merging it into the series it is a concert of would be
    /// losing a work, not joining one.
    public static func groups(works: [Work], links: [Link]) -> [Group] {
        let worksByID = Dictionary(works.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parent: [UUID: UUID] = [:]
        for work in works { parent[work.id] = work.id }

        func root(_ id: UUID) -> UUID {
            var current = id
            while let next = parent[current], next != current { current = next }
            return current
        }
        func union(_ one: UUID, _ other: UUID) {
            let a = root(one), b = root(other)
            guard a != b else { return }
            parent[b] = a
        }

        // Only links about works this was given, and only between works of
        // one kind.
        var bySubject: [String: [UUID]] = [:]
        for link in links where worksByID[link.animeID] != nil {
            bySubject["\(link.provider.rawValue):\(link.externalID)", default: []].append(link.animeID)
        }
        for (_, ids) in bySubject {
            guard ids.count > 1 else { continue }
            for pair in zip(ids, ids.dropFirst()) {
                guard let one = worksByID[pair.0], let other = worksByID[pair.1], one.kind == other.kind else { continue }
                union(pair.0, pair.1)
            }
        }

        var members: [UUID: [Work]] = [:]
        for work in works { members[root(work.id), default: []].append(work) }

        return members.values.compactMap { group -> Group? in
            guard group.count > 1 else { return nil }
            // Most files wins; a tie goes to the row that has been there
            // longest, and then to the id, so the answer does not move
            // between runs.
            let ranked = group.sorted {
                if $0.fileCount != $1.fileCount { return $0.fileCount > $1.fileCount }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            let ids = Set(group.map(\.id))
            var evidence: Set<Group.Evidence> = []
            for (subject, linked) in bySubject {
                let inGroup = linked.filter(ids.contains)
                guard inGroup.count > 1 else { continue }
                let parts = subject.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let provider = MetadataProviderID(rawValue: String(parts[0])) else { continue }
                evidence.insert(Group.Evidence(provider: provider, externalID: String(parts[1])))
            }
            return Group(
                primary: ranked[0],
                duplicates: Array(ranked.dropFirst()),
                evidence: evidence.sorted {
                    $0.provider.rawValue == $1.provider.rawValue
                        ? $0.externalID < $1.externalID
                        : $0.provider.rawValue < $1.provider.rawValue
                }
            )
        }
        .sorted { $0.primary.title.localizedStandardCompare($1.primary.title) == .orderedAscending }
    }
}

/// What a merge actually moved.
///
/// Returned rather than discarded because a merge is irreversible and the
/// counts are the only account of it: an episode that was absorbed into
/// another took its file, its position and its history with it, and
/// "6 episodes, 2 of them merged into existing ones" is the difference
/// between that having worked and having quietly dropped something.
public struct WorkMergeSummary: Sendable, Hashable {
    /// Episodes whose anime simply changed.
    public var episodesMoved = 0
    /// Episodes the target already had under the same identity — two teams'
    /// episode 1 is one episode with two files — so the source's row was
    /// dissolved into it.
    public var episodesAbsorbed = 0
    public var mediaFilesMoved = 0
    public var providerLinksMoved = 0
    public var watchEventsMoved = 0
    public var downloadsMoved = 0
    public var subscriptionsMoved = 0
    public var subtitlesMoved = 0
    public var adoptedPoster = false
    public var adoptedKind = false
    public var adoptedConcertRelease = false
    public var adoptedProfile = false

    public init() {}
}
