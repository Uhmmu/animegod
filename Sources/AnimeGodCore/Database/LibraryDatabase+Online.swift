import Foundation
import GRDB

/// Watch records for episodes watched from an online source.
///
/// There is no store of its own here on purpose. An online episode is filed
/// in `anime` / `episode` / `playbackProgress` like any other, and the two
/// tables this adds only say which of those rows a site's page stands for —
/// which is what makes the diary, the statistics and the resume point work
/// for a stream without any of them being taught about streams.
///
/// See `OnlineWatchIdentity` for why the work gets a row of its own rather
/// than joining the one the library already has under that name, and why a
/// numbered episode is one row across a site's several playback lines.
public extension LibraryDatabase {
    /// An online episode as the player needs it: the rows it is filed under,
    /// and where it got to last time.
    struct OnlineEpisodeRecord: Sendable {
        public let animeID: UUID
        public let workName: String
        public let episode: Episode
        public let progress: PlaybackProgress?
    }

    /// The rows this episode is filed under, creating them if this is the
    /// first time it has been played.
    ///
    /// Created on play rather than when the list is drawn: opening a search
    /// result to look at it should not put a work in the database, and an
    /// episode nobody has watched needs no row to be drawn as unwatched.
    func onlineEpisode(for ref: OnlineEpisodeRef) throws -> OnlineEpisodeRecord {
        try database.write { db in
            let identity = OnlineWatchIdentity.episodeIdentity(label: ref.label, index: ref.index)

            let animeID = try Self.findOrCreateOnlineWork(ref, in: db)
            let episodeID: String
            if let bound = try String.fetchOne(
                db,
                sql: "SELECT episodeID FROM onlineEpisode WHERE ruleName = ? AND pageURL = ?",
                arguments: [OnlineSourceRule.identityKey(ref.ruleName), ref.pageURL]
            ) {
                episodeID = bound
            } else if let sibling = try String.fetchOne(
                db,
                sql: "SELECT id FROM episode WHERE animeID = ? AND identityKey = ?",
                arguments: [animeID, identity.key]
            ) {
                // The same episode from another of the site's playback lines.
                episodeID = sibling
            } else {
                episodeID = UUID().uuidString
                try db.execute(
                    sql: """
                        INSERT INTO episode (id, animeID, identityKey, number, numberText, title, kind, sortIndex)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        episodeID, animeID, identity.key, identity.number, identity.numberText,
                        ref.label, identity.kind.rawValue, identity.sortIndex
                    ]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO onlineEpisode (ruleName, pageURL, episodeID, workPageURL, roadName, label, position)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(ruleName, pageURL) DO UPDATE SET
                        episodeID = excluded.episodeID,
                        workPageURL = excluded.workPageURL,
                        roadName = excluded.roadName,
                        label = excluded.label,
                        position = excluded.position
                    """,
                arguments: [
                    OnlineSourceRule.identityKey(ref.ruleName), ref.pageURL, episodeID,
                    ref.workPageURL, ref.roadName, ref.label, ref.index
                ]
            )

            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM episode WHERE id = ?", arguments: [episodeID]
            ), let id = UUID(uuidString: row["id"] as String) else {
                throw DatabaseError(message: "online episode \(episodeID) vanished as it was created")
            }
            let episode = Episode(
                id: id,
                animeID: UUID(uuidString: row["animeID"] as String) ?? UUID(),
                number: row["number"],
                numberText: row["numberText"],
                title: row["title"],
                kind: EpisodeKind(rawValue: row["kind"] as String) ?? .regular,
                sortIndex: row["sortIndex"]
            )
            let progress = try Row.fetchOne(
                db, sql: "SELECT * FROM playbackProgress WHERE episodeID = ?", arguments: [episodeID]
            ).map {
                PlaybackProgress(
                    episodeID: UUID(uuidString: $0["episodeID"]) ?? UUID(),
                    position: $0["position"],
                    duration: $0["duration"],
                    updatedAt: $0["updatedAt"],
                    isWatched: $0["isWatched"]
                )
            }
            return OnlineEpisodeRecord(
                animeID: UUID(uuidString: animeID) ?? UUID(),
                workName: ref.workName,
                episode: episode,
                progress: progress
            )
        }
    }

    /// What the section's grid needs to draw: the state of every episode of
    /// one work that has ever been played, keyed by its page URL.
    ///
    /// Asked for a whole line at once rather than row by row — the grid is
    /// redrawn whenever a resolution starts or ends, and twenty-four
    /// single-row reads per redraw is a query the section does not need.
    func onlineWatchStates(ruleName: String, pageURLs: [String]) throws -> [String: OnlineWatchState] {
        guard !pageURLs.isEmpty else { return [:] }
        return try database.read { db in
            var states: [String: OnlineWatchState] = [:]
            // SQLite's parameter limit is comfortably above a season, but a
            // site that lists a thousand episodes in one line exists.
            for chunk in stride(from: 0, to: pageURLs.count, by: 400).map({
                Array(pageURLs[$0..<min($0 + 400, pageURLs.count)])
            }) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                var arguments: [DatabaseValueConvertible] = [OnlineSourceRule.identityKey(ruleName)]
                arguments.append(contentsOf: chunk)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT onlineEpisode.pageURL AS pageURL,
                           playbackProgress.position AS position,
                           playbackProgress.duration AS duration,
                           playbackProgress.isWatched AS isWatched
                    FROM onlineEpisode
                    JOIN playbackProgress ON playbackProgress.episodeID = onlineEpisode.episodeID
                    WHERE onlineEpisode.ruleName = ? AND onlineEpisode.pageURL IN (\(placeholders))
                    """, arguments: StatementArguments(arguments))
                for row in rows {
                    states[row["pageURL"]] = OnlineWatchState(
                        position: row["position"],
                        duration: row["duration"],
                        isWatched: row["isWatched"]
                    )
                }
            }
            return states
        }
    }

    /// Says outright whether an online episode has been seen.
    ///
    /// The row has to exist first — "mark as watched" on an episode nobody
    /// has opened is as much a statement as marking one you have.
    func setOnlineWatched(_ isWatched: Bool, for ref: OnlineEpisodeRef) throws {
        let record = try onlineEpisode(for: ref)
        try setWatched(episodeID: record.episode.id, isWatched: isWatched)
    }

    private static func findOrCreateOnlineWork(_ ref: OnlineEpisodeRef, in db: Database) throws -> String {
        let key = OnlineSourceRule.identityKey(ref.ruleName)
        let normalized = OnlineWatchIdentity.workIdentity(ruleName: ref.ruleName, pageURL: ref.workPageURL)
        if let existing = try String.fetchOne(
            db,
            sql: "SELECT animeID FROM onlineWork WHERE ruleName = ? AND pageURL = ?",
            arguments: [key, ref.workPageURL]
        ) {
            try db.execute(
                sql: "UPDATE onlineWork SET name = ?, lastOpenedAt = ? WHERE ruleName = ? AND pageURL = ?",
                arguments: [ref.workName, Date.now, key, ref.workPageURL]
            )
            // The site renamed it, or it was first seen under a search
            // result's shorter spelling. The history already written keeps
            // the name it was written with; what is shown follows the site.
            try db.execute(
                sql: "UPDATE anime SET title = ?, sortTitle = ?, updatedAt = ? WHERE id = ?",
                arguments: [ref.workName, ref.workName, Date.now, existing]
            )
            return existing
        }
        let animeID = UUID().uuidString
        try db.execute(
            sql: """
                INSERT INTO anime (id, title, normalizedTitle, sortTitle, kind, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                animeID, ref.workName, normalized, ref.workName,
                AnimeKind.unknown.rawValue, Date.now, Date.now
            ]
        )
        try db.execute(
            sql: "INSERT INTO onlineWork (ruleName, pageURL, animeID, name, lastOpenedAt) VALUES (?, ?, ?, ?, ?)",
            arguments: [key, ref.workPageURL, animeID, ref.workName, Date.now]
        )
        return animeID
    }
}
