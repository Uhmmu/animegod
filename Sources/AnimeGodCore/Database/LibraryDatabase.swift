import CryptoKit
import Foundation
import GRDB

public actor LibraryDatabase {
    private let database: any DatabaseWriter

    public init(url: URL) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        database = try DatabasePool(path: url.path, configuration: configuration)
        try Self.migrator.migrate(database)
    }

    public init(inMemory: Bool) throws {
        database = try DatabaseQueue()
        try Self.migrator.migrate(database)
    }

    public func libraryRoots() throws -> [LibraryRoot] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM libraryRoot ORDER BY displayName COLLATE NOCASE").map(Self.decodeRoot)
        }
    }

    public func save(root: LibraryRoot) throws {
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO libraryRoot (id, displayName, lastKnownPath, bookmarkData, addedAt, lastScannedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    displayName = excluded.displayName,
                    lastKnownPath = excluded.lastKnownPath,
                    bookmarkData = excluded.bookmarkData,
                    lastScannedAt = excluded.lastScannedAt
                """,
                arguments: [root.id.uuidString, root.displayName, root.lastKnownPath, root.bookmarkData, root.addedAt, root.lastScannedAt]
            )
        }
    }

    public func removeLibraryRoot(id: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM libraryRoot WHERE id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM episode WHERE id NOT IN (SELECT episodeID FROM mediaFile)")
            try db.execute(sql: """
                DELETE FROM anime
                WHERE id NOT IN (SELECT animeID FROM episode)
                  AND id NOT IN (SELECT animeID FROM animeProfile)
                  AND id NOT IN (SELECT animeID FROM watchEvent)
                """)
        }
    }

    public func importScan(_ result: LibraryScanResult) throws {
        try database.write { db in
            var root = result.root
            root.lastScannedAt = .now
            try db.execute(
                sql: "UPDATE libraryRoot SET lastScannedAt = ?, lastKnownPath = ? WHERE id = ?",
                arguments: [root.lastScannedAt, root.lastKnownPath, root.id.uuidString]
            )

            let existingRows = try Row.fetchAll(
                db,
                sql: "SELECT id, relativePath, episodeID FROM mediaFile WHERE libraryRootID = ?",
                arguments: [root.id.uuidString]
            )
            let existing = Dictionary(uniqueKeysWithValues: existingRows.map { row in
                (row["relativePath"] as String, (mediaID: row["id"] as String, episodeID: row["episodeID"] as String))
            })
            let seenPaths = Set(result.files.map(\.relativePath))
            // Files that moved from one work to another (renamed titles,
            // folder splits) take their provider bindings, personal entry,
            // and history with them — a rescan must never demand re-matching.
            var successors: [String: Set<String>] = [:]

            for scanned in result.files {
                let animeID = try Self.findOrCreateAnime(title: scanned.parsed.title, in: db)
                let episodeID = try Self.findOrCreateEpisode(parsed: scanned.parsed, animeID: animeID, relativePath: scanned.relativePath, in: db)
                let previous = existing[scanned.relativePath]
                let mediaID = previous?.mediaID ?? UUID().uuidString
                if let previous, previous.episodeID != episodeID {
                    if let progress = try Row.fetchOne(
                        db,
                        sql: "SELECT position, duration, updatedAt, isWatched FROM playbackProgress WHERE episodeID = ?",
                        arguments: [previous.episodeID]
                    ) {
                        try db.execute(sql: """
                            INSERT INTO playbackProgress (episodeID, position, duration, updatedAt, isWatched)
                            VALUES (?, ?, ?, ?, ?)
                            ON CONFLICT(episodeID) DO UPDATE SET
                                position = excluded.position,
                                duration = excluded.duration,
                                updatedAt = excluded.updatedAt,
                                isWatched = excluded.isWatched
                            WHERE excluded.updatedAt > playbackProgress.updatedAt
                            """, arguments: [
                                episodeID,
                                progress["position"] as Double,
                                progress["duration"] as Double,
                                progress["updatedAt"] as Date,
                                progress["isWatched"] as Bool
                            ])
                    }
                    if let oldAnimeID = try String.fetchOne(
                        db,
                        sql: "SELECT animeID FROM episode WHERE id = ?",
                        arguments: [previous.episodeID]
                    ), oldAnimeID != animeID {
                        successors[oldAnimeID, default: []].insert(animeID)
                    }
                }
                try db.execute(
                    sql: """
                    INSERT INTO mediaFile (id, libraryRootID, episodeID, relativePath, fileSize, modifiedAt, discoveredAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(libraryRootID, relativePath) DO UPDATE SET
                        episodeID = excluded.episodeID,
                        fileSize = excluded.fileSize,
                        modifiedAt = excluded.modifiedAt
                    """,
                    arguments: [mediaID, root.id.uuidString, episodeID, scanned.relativePath, scanned.fileSize, scanned.modifiedAt, Date.now]
                )
            }

            for (path, _) in existing where !seenPaths.contains(path) {
                try db.execute(
                    sql: "DELETE FROM mediaFile WHERE libraryRootID = ? AND relativePath = ?",
                    arguments: [root.id.uuidString, path]
                )
            }
            try db.execute(sql: "DELETE FROM episode WHERE id NOT IN (SELECT episodeID FROM mediaFile)")
            try db.execute(sql: "DELETE FROM danmakuMatch WHERE mediaFileID NOT IN (SELECT id FROM mediaFile)")
            try Self.migrateIdentityOnRegroup(successors: successors, in: db)
            // Folder renames on disk change relative paths, so regrouping was
            // never observed; reconcile parked bindings by title instead.
            try Self.reconcileParkedBindings(in: db)
            try db.execute(sql: """
                DELETE FROM anime
                WHERE id NOT IN (SELECT animeID FROM episode)
                  AND id NOT IN (SELECT animeID FROM animeProfile)
                  AND id NOT IN (SELECT animeID FROM watchEvent)
                  AND id NOT IN (SELECT animeID FROM externalAnimeID)
                """)
        }
    }

    /// Moves provider bindings, the personal entry, and watch history from a
    /// dissolved anime to its single successor. Ambiguous regroupings (one
    /// work splitting into several) park the data on the old row instead of
    /// guessing where it belongs.
    private static func migrateIdentityOnRegroup(successors: [String: Set<String>], in db: Database) throws {
        for (oldID, targets) in successors {
            guard targets.count == 1, let newID = targets.first, oldID != newID else { continue }
            // Only migrate when the old work really dissolved (no files left).
            let stillHasFiles = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM mediaFile
                    JOIN episode ON episode.id = mediaFile.episodeID
                    WHERE episode.animeID = ?
                )
                """,
                arguments: [oldID]
            ) ?? false
            guard !stillHasFiles else { continue }
            try migrateIdentity(from: oldID, to: newID, in: db)
        }
    }

    /// Finds anime rows that lost all files but still hold provider bindings
    /// and reattaches them to the one anime whose title clearly continues
    /// theirs (e.g. after a folder rename or an earlier orphaning scan).
    private static func reconcileParkedBindings(in db: Database) throws {
        let parked = try Row.fetchAll(db, sql: """
            SELECT id, normalizedTitle FROM anime a
            WHERE a.normalizedTitle != ''
              AND EXISTS (SELECT 1 FROM externalAnimeID x WHERE x.animeID = a.id)
              AND NOT EXISTS (
                  SELECT 1 FROM episode e JOIN mediaFile m ON m.episodeID = e.id
                  WHERE e.animeID = a.id
              )
            """)
        for row in parked {
            let parkedID: String = row["id"]
            let parkedTitle: String = row["normalizedTitle"]
            let candidates = try String.fetchAll(db, sql: """
                SELECT a.id FROM anime a
                WHERE a.id != ? AND a.normalizedTitle != ''
                  AND EXISTS (
                      SELECT 1 FROM episode e JOIN mediaFile m ON m.episodeID = e.id
                      WHERE e.animeID = a.id
                  )
                  AND (a.normalizedTitle LIKE '%' || ? || '%' OR ? LIKE '%' || a.normalizedTitle || '%')
                """, arguments: [parkedID, parkedTitle, parkedTitle])
            guard candidates.count == 1, let target = candidates.first else { continue }
            try migrateIdentity(from: parkedID, to: target, in: db)
        }
    }

    private static func migrateIdentity(from oldID: String, to newID: String, in db: Database) throws {
        let providers = try String.fetchAll(
            db,
            sql: """
            SELECT provider FROM externalAnimeID
            WHERE animeID = ? AND provider NOT IN (SELECT provider FROM externalAnimeID WHERE animeID = ?)
            """,
            arguments: [oldID, newID]
        )
        for provider in providers {
            try db.execute(
                sql: "INSERT INTO externalAnimeID (animeID, provider, externalID, matchConfidence, isManual, linkedAt) SELECT ?, provider, externalID, matchConfidence, isManual, linkedAt FROM externalAnimeID WHERE animeID = ? AND provider = ?",
                arguments: [newID, oldID, provider]
            )
            try db.execute(
                sql: "INSERT INTO animeMetadata (animeID, provider, externalID, payload, fetchedAt) SELECT ?, provider, externalID, payload, fetchedAt FROM animeMetadata WHERE animeID = ? AND provider = ?",
                arguments: [newID, oldID, provider]
            )
            try db.execute(
                sql: "INSERT INTO communityPost (animeID, provider, postID, kind, payload, publishedAt) SELECT ?, provider, postID, kind, payload, publishedAt FROM communityPost WHERE animeID = ? AND provider = ?",
                arguments: [newID, oldID, provider]
            )
            // Cascades to the old animeMetadata and communityPost rows.
            try db.execute(
                sql: "DELETE FROM externalAnimeID WHERE animeID = ? AND provider = ?",
                arguments: [oldID, provider]
            )
        }
        try db.execute(sql: """
            INSERT INTO animeProfile
                (animeID, status, score, notes, review, tags, isFavorite, ranking,
                 firstWatchedAt, completedAt, rewatchCount, updatedAt)
            SELECT ?, status, score, notes, review, tags, isFavorite, ranking,
                 firstWatchedAt, completedAt, rewatchCount, updatedAt
            FROM animeProfile WHERE animeID = ?
            ON CONFLICT(animeID) DO NOTHING
            """, arguments: [newID, oldID])
        try db.execute(
            sql: "UPDATE watchEvent SET animeID = ? WHERE animeID = ?",
            arguments: [newID, oldID]
        )
    }

    public func library() throws -> [LibraryAnime] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT anime.*,
                       COUNT(DISTINCT episode.id) AS totalCount,
                       COUNT(DISTINCT CASE WHEN episode.kind = ? THEN episode.id END) AS episodeCount,
                       COUNT(DISTINCT CASE WHEN episode.kind = ? AND COALESCE(playbackProgress.isWatched, 0) = 0 THEN episode.id END) AS unwatchedCount
                FROM anime
                JOIN episode ON episode.animeID = anime.id
                JOIN mediaFile ON mediaFile.episodeID = episode.id
                LEFT JOIN playbackProgress ON playbackProgress.episodeID = episode.id
                GROUP BY anime.id
                ORDER BY anime.sortTitle COLLATE NOCASE
                """, arguments: [EpisodeKind.regular.rawValue, EpisodeKind.regular.rawValue])
            return rows.map { row in
                let regularCount: Int = row["episodeCount"]
                let totalCount: Int = row["totalCount"]
                return LibraryAnime(
                    anime: Self.decodeAnime(row),
                    // SPs and creditless clips stay inside the anime but do
                    // not inflate its headline episode count.
                    episodeCount: regularCount > 0 ? regularCount : totalCount,
                    unwatchedCount: row["unwatchedCount"]
                )
            }
        }
    }

    public func episodes(animeID: UUID) throws -> [EpisodeMedia] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT episode.*,
                       mediaFile.id AS mediaID, mediaFile.libraryRootID, mediaFile.relativePath,
                       mediaFile.fileSize, mediaFile.modifiedAt, mediaFile.discoveredAt,
                       playbackProgress.position, playbackProgress.duration,
                       playbackProgress.updatedAt AS progressUpdatedAt, playbackProgress.isWatched
                FROM episode
                JOIN mediaFile ON mediaFile.episodeID = episode.id
                LEFT JOIN playbackProgress ON playbackProgress.episodeID = episode.id
                WHERE episode.animeID = ?
                ORDER BY episode.sortIndex, mediaFile.relativePath COLLATE NOCASE
                """, arguments: [animeID.uuidString])
            return Self.deduplicateVersions(rows.map(Self.decodeEpisodeMedia))
        }
    }

    public func continueWatching(limit: Int = 12) throws -> [EpisodeMedia] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT episode.*,
                       mediaFile.id AS mediaID, mediaFile.libraryRootID, mediaFile.relativePath,
                       mediaFile.fileSize, mediaFile.modifiedAt, mediaFile.discoveredAt,
                       playbackProgress.position, playbackProgress.duration,
                       playbackProgress.updatedAt AS progressUpdatedAt, playbackProgress.isWatched
                FROM playbackProgress
                JOIN episode ON episode.id = playbackProgress.episodeID
                JOIN mediaFile ON mediaFile.episodeID = episode.id
                WHERE playbackProgress.position > 0 AND playbackProgress.isWatched = 0
                ORDER BY playbackProgress.updatedAt DESC
                LIMIT ?
                """, arguments: [limit])
            return Self.deduplicateVersions(rows.map(Self.decodeEpisodeMedia))
        }
    }

    /// Multiple encodes of the same episode (DoVi + SDR releases, for
    /// example) share one episode row. SDR leads by default — macOS players
    /// cannot render Dolby Vision metadata — otherwise the largest file does.
    private static func deduplicateVersions(_ items: [EpisodeMedia]) -> [EpisodeMedia] {
        func prefersSDR(_ a: MediaFile, _ b: MediaFile) -> Bool {
            let aSDR = a.relativePath.lowercased().contains("sdr") ? 0 : 1
            let bSDR = b.relativePath.lowercased().contains("sdr") ? 0 : 1
            if aSDR != bSDR { return aSDR < bSDR }
            return a.fileSize > b.fileSize
        }
        var merged: [String: EpisodeMedia] = [:]
        var order: [String] = []
        for item in items {
            let key = item.episode.id.uuidString
            if var existing = merged[key] {
                let files = (existing.versions + [item.mediaFile]).sorted(by: prefersSDR)
                existing = EpisodeMedia(
                    episode: existing.episode,
                    mediaFile: files[0],
                    progress: existing.progress ?? item.progress,
                    versions: files
                )
                merged[key] = existing
            } else {
                merged[key] = item
                order.append(key)
            }
        }
        return order.compactMap { merged[$0] }
    }

    public func save(progress: PlaybackProgress) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO playbackProgress (episodeID, position, duration, updatedAt, isWatched)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(episodeID) DO UPDATE SET
                    position = excluded.position,
                    duration = excluded.duration,
                    updatedAt = excluded.updatedAt,
                    isWatched = excluded.isWatched
                """, arguments: [progress.episodeID.uuidString, progress.position, progress.duration, progress.updatedAt, progress.isWatched])
        }
    }

    public func profiles() throws -> [AnimeProfile] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM animeProfile ORDER BY updatedAt DESC").compactMap(Self.decodeProfile)
        }
    }

    public func profile(animeID: UUID) throws -> AnimeProfile? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM animeProfile WHERE animeID = ?", arguments: [animeID.uuidString])
                .flatMap(Self.decodeProfile)
        }
    }

    public func save(profile: AnimeProfile) throws {
        let normalizedTags = Array(Set(profile.tags.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let tags = try JSONEncoder().encode(normalizedTags)
        try database.write { db in
            let previousRanking = try Int.fetchOne(
                db,
                sql: "SELECT ranking FROM animeProfile WHERE animeID = ?",
                arguments: [profile.animeID.uuidString]
            )
            if previousRanking != profile.ranking {
                switch (previousRanking, profile.ranking) {
                case let (old?, new?) where new < old:
                    try db.execute(
                        sql: "UPDATE animeProfile SET ranking = ranking + 1 WHERE ranking >= ? AND ranking < ? AND animeID != ?",
                        arguments: [new, old, profile.animeID.uuidString]
                    )
                case let (old?, new?) where new > old:
                    try db.execute(
                        sql: "UPDATE animeProfile SET ranking = ranking - 1 WHERE ranking > ? AND ranking <= ? AND animeID != ?",
                        arguments: [old, new, profile.animeID.uuidString]
                    )
                case let (nil, new?):
                    try db.execute(
                        sql: "UPDATE animeProfile SET ranking = ranking + 1 WHERE ranking >= ?",
                        arguments: [new]
                    )
                case let (old?, nil):
                    try db.execute(
                        sql: "UPDATE animeProfile SET ranking = ranking - 1 WHERE ranking > ?",
                        arguments: [old]
                    )
                default:
                    break
                }
            }
            try db.execute(sql: """
                INSERT INTO animeProfile
                    (animeID, status, score, notes, review, tags, isFavorite, ranking,
                     firstWatchedAt, completedAt, rewatchCount, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(animeID) DO UPDATE SET
                    status = excluded.status,
                    score = excluded.score,
                    notes = excluded.notes,
                    review = excluded.review,
                    tags = excluded.tags,
                    isFavorite = excluded.isFavorite,
                    ranking = excluded.ranking,
                    firstWatchedAt = excluded.firstWatchedAt,
                    completedAt = excluded.completedAt,
                    rewatchCount = excluded.rewatchCount,
                    updatedAt = excluded.updatedAt
                """, arguments: [
                    profile.animeID.uuidString,
                    profile.status.rawValue,
                    profile.score,
                    profile.notes,
                    profile.review,
                    tags,
                    profile.isFavorite,
                    profile.ranking,
                    profile.firstWatchedAt,
                    profile.completedAt,
                    max(profile.rewatchCount, 0),
                    profile.updatedAt
                ])
        }
    }

    public func record(event: WatchEvent) throws {
        guard event.watchedDuration >= 15 else { return }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO watchEvent
                    (id, animeID, episodeID, animeTitle, episodeLabel, startedAt, endedAt,
                     watchedDuration, completion, completedEpisode)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    event.id.uuidString,
                    event.animeID.uuidString,
                    event.episodeID?.uuidString,
                    event.animeTitle,
                    event.episodeLabel,
                    event.startedAt,
                    event.endedAt,
                    event.watchedDuration,
                    event.completion,
                    event.completedEpisode
                ])

            let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM animeProfile WHERE animeID = ?",
                arguments: [event.animeID.uuidString]
            ).flatMap(Self.decodeProfile)
            var profile = existing ?? AnimeProfile(animeID: event.animeID, status: .watching)
            if profile.firstWatchedAt == nil { profile.firstWatchedAt = event.startedAt }
            if profile.status == .planning { profile.status = .watching }
            if event.completedEpisode {
                let remaining: Int = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*)
                    FROM episode
                    LEFT JOIN playbackProgress ON playbackProgress.episodeID = episode.id
                    WHERE episode.animeID = ? AND episode.kind = ?
                      AND COALESCE(playbackProgress.isWatched, 0) = 0
                    """, arguments: [event.animeID.uuidString, EpisodeKind.regular.rawValue]) ?? 0
                if remaining == 0 {
                    profile.status = .completed
                    profile.completedAt = profile.completedAt ?? event.endedAt
                }
            }
            profile.updatedAt = event.endedAt
            let normalizedTags = try JSONEncoder().encode(profile.tags)
            try db.execute(sql: """
                INSERT INTO animeProfile
                    (animeID, status, score, notes, review, tags, isFavorite, ranking,
                     firstWatchedAt, completedAt, rewatchCount, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(animeID) DO UPDATE SET
                    status = excluded.status,
                    firstWatchedAt = COALESCE(animeProfile.firstWatchedAt, excluded.firstWatchedAt),
                    completedAt = COALESCE(animeProfile.completedAt, excluded.completedAt),
                    updatedAt = excluded.updatedAt
                """, arguments: [
                    profile.animeID.uuidString, profile.status.rawValue, profile.score,
                    profile.notes, profile.review, normalizedTags, profile.isFavorite,
                    profile.ranking, profile.firstWatchedAt, profile.completedAt,
                    profile.rewatchCount, profile.updatedAt
                ])
        }
    }

    public func watchEvents(limit: Int = 500) throws -> [WatchEvent] {
        try database.read { db in
            return try Row.fetchAll(
                db,
                sql: "SELECT * FROM watchEvent ORDER BY endedAt DESC LIMIT ?",
                arguments: [max(1, min(limit, 5_000))]
            ).map(Self.decodeWatchEvent)
        }
    }

    /// Full history for statistics; ordered oldest-first so yearly
    /// aggregations read chronologically.
    public func allWatchEvents() throws -> [WatchEvent] {
        try database.read { db in
            return try Row.fetchAll(
                db,
                sql: "SELECT * FROM watchEvent ORDER BY endedAt ASC"
            ).map(Self.decodeWatchEvent)
        }
    }

    public func diarySummary(from start: Date? = nil, through end: Date? = nil) throws -> DiarySummary {
        try database.read { db in
            var conditions: [String] = []
            var arguments = StatementArguments()
            if let start {
                conditions.append("endedAt >= ?")
                arguments += [start]
            }
            if let end {
                conditions.append("endedAt < ?")
                arguments += [end]
            }
            let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(watchedDuration), 0) AS totalWatchTime,
                       COUNT(*) AS sessionCount,
                       COALESCE(SUM(CASE WHEN completedEpisode = 1 THEN 1 ELSE 0 END), 0) AS completedEpisodeCount,
                       COUNT(DISTINCT animeID) AS animeCount
                FROM watchEvent \(filter)
                """, arguments: arguments)!
            return DiarySummary(
                totalWatchTime: row["totalWatchTime"],
                sessionCount: row["sessionCount"],
                completedEpisodeCount: row["completedEpisodeCount"],
                animeCount: row["animeCount"]
            )
        }
    }

    public func metadata() throws -> [AnimeMetadata] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT payload FROM animeMetadata ORDER BY fetchedAt DESC").compactMap { row in
                let payload: Data = row["payload"]
                return try? JSONDecoder().decode(AnimeMetadata.self, from: payload)
            }
        }
    }

    public func metadata(animeID: UUID, provider: MetadataProviderID = .bangumi) throws -> AnimeMetadata? {
        try database.read { db in
            guard let payload = try Data.fetchOne(
                db,
                sql: "SELECT payload FROM animeMetadata WHERE animeID = ? AND provider = ?",
                arguments: [animeID.uuidString, provider.rawValue]
            ) else { return nil }
            return try JSONDecoder().decode(AnimeMetadata.self, from: payload)
        }
    }

    public func metadataSources(animeID: UUID) throws -> [AnimeMetadata] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT payload FROM animeMetadata WHERE animeID = ? ORDER BY fetchedAt DESC",
                arguments: [animeID.uuidString]
            ).compactMap { row in
                let payload: Data = row["payload"]
                return try? JSONDecoder().decode(AnimeMetadata.self, from: payload)
            }
        }
    }

    public func externalReferences(animeID: UUID) throws -> [ExternalAnimeReference] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT provider, externalID FROM externalAnimeID WHERE animeID = ? ORDER BY provider",
                arguments: [animeID.uuidString]
            ).compactMap { row in
                guard let provider = MetadataProviderID(rawValue: row["provider"] as String) else { return nil }
                return ExternalAnimeReference(provider: provider, externalID: row["externalID"])
            }
        }
    }

    public func matchLinks(animeID: UUID) throws -> [MetadataProviderID: MatchLink] {
        try database.read { db in
            var links: [MetadataProviderID: MatchLink] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT provider, matchConfidence, isManual FROM externalAnimeID WHERE animeID = ?",
                arguments: [animeID.uuidString]
            ) {
                guard let provider = MetadataProviderID(rawValue: row["provider"] as String) else { continue }
                links[provider] = MatchLink(
                    provider: provider,
                    confidence: row["matchConfidence"] ?? 1,
                    isManual: row["isManual"] ?? true
                )
            }
            return links
        }
    }

    public func communityPosts(animeID: UUID, provider: MetadataProviderID? = nil) throws -> [CommunityPost] {
        try database.read { db in
            let providerFilter = provider == nil ? "" : " AND provider = ?"
            var arguments: StatementArguments = [animeID.uuidString]
            if let provider { arguments += [provider.rawValue] }
            return try Row.fetchAll(
                db,
                sql: "SELECT payload FROM communityPost WHERE animeID = ?\(providerFilter) ORDER BY publishedAt DESC",
                arguments: arguments
            ).compactMap { row in
                let payload: Data = row["payload"]
                return try? JSONDecoder().decode(CommunityPost.self, from: payload)
            }
        }
    }

    public func save(
        metadata: AnimeMetadata,
        communityPosts: [CommunityPost],
        matchConfidence: Double,
        isManualMatch: Bool
    ) throws {
        let metadataPayload = try JSONEncoder().encode(metadata)
        try database.write { db in
            // A provider-reported type (TV / movie / OVA / …) classifies the
            // local entry; it never overwrites user-created data.
            if let kind = metadata.kind, kind != .unknown {
                try db.execute(
                    sql: "UPDATE anime SET kind = ?, updatedAt = ? WHERE id = ?",
                    arguments: [kind.rawValue, Date.now, metadata.animeID.uuidString]
                )
            }
            try db.execute(sql: """
                INSERT INTO externalAnimeID (animeID, provider, externalID, matchConfidence, isManual, linkedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(animeID, provider) DO UPDATE SET
                    externalID = excluded.externalID,
                    matchConfidence = excluded.matchConfidence,
                    isManual = excluded.isManual,
                    linkedAt = excluded.linkedAt
                """, arguments: [
                    metadata.animeID.uuidString,
                    metadata.provider.rawValue,
                    metadata.externalID,
                    matchConfidence,
                    isManualMatch,
                    Date.now
                ])
            for reference in metadata.externalReferences ?? [] where reference.provider != metadata.provider {
                try db.execute(sql: """
                    INSERT INTO externalAnimeID (animeID, provider, externalID, matchConfidence, isManual, linkedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(animeID, provider) DO UPDATE SET
                        externalID = excluded.externalID,
                        matchConfidence = excluded.matchConfidence,
                        isManual = excluded.isManual,
                        linkedAt = excluded.linkedAt
                    """, arguments: [
                        metadata.animeID.uuidString,
                        reference.provider.rawValue,
                        reference.externalID,
                        matchConfidence,
                        isManualMatch,
                        Date.now
                    ])
            }
            try db.execute(sql: """
                INSERT INTO animeMetadata (animeID, provider, externalID, payload, fetchedAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(animeID, provider) DO UPDATE SET
                    externalID = excluded.externalID,
                    payload = excluded.payload,
                    fetchedAt = excluded.fetchedAt
                """, arguments: [
                    metadata.animeID.uuidString,
                    metadata.provider.rawValue,
                    metadata.externalID,
                    metadataPayload,
                    metadata.fetchedAt
                ])
            try db.execute(
                sql: "DELETE FROM communityPost WHERE animeID = ? AND provider = ?",
                arguments: [metadata.animeID.uuidString, metadata.provider.rawValue]
            )
            for post in communityPosts {
                let payload = try JSONEncoder().encode(post)
                try db.execute(sql: """
                    INSERT INTO communityPost
                        (animeID, provider, postID, kind, payload, publishedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        metadata.animeID.uuidString,
                        post.provider.rawValue,
                        post.postID,
                        post.kind.rawValue,
                        payload,
                        post.publishedAt
                    ])
            }
        }
    }

    public func removeMetadataMatch(animeID: UUID, provider: MetadataProviderID = .bangumi) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM externalAnimeID WHERE animeID = ? AND provider = ?",
                arguments: [animeID.uuidString, provider.rawValue]
            )
        }
    }

    // MARK: - Danmaku cache

    /// Returns the cached comments for a provider episode, if present.
    /// Cached data keeps danmaku working offline; freshness is checked by
    /// the caller, never here.
    public func danmakuCache(providerID: String, episodeID: Int64) throws -> DanmakuCacheEntry? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT payload FROM danmakuCache WHERE cacheKey = ?",
                arguments: ["\(providerID):\(episodeID)"]
            ) else { return nil }
            let payload: Data = row["payload"]
            return try? JSONDecoder().decode(DanmakuCacheEntry.self, from: payload)
        }
    }

    public func saveDanmakuCache(_ entry: DanmakuCacheEntry) throws {
        let payload = try JSONEncoder().encode(entry)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO danmakuCache (cacheKey, providerID, episodeID, animeTitle, episodeTitle, commentCount, payload, fetchedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(cacheKey) DO UPDATE SET
                    providerID = excluded.providerID,
                    episodeID = excluded.episodeID,
                    animeTitle = excluded.animeTitle,
                    episodeTitle = excluded.episodeTitle,
                    commentCount = excluded.commentCount,
                    payload = excluded.payload,
                    fetchedAt = excluded.fetchedAt
                """, arguments: [
                    "\(entry.providerID):\(entry.episodeID)",
                    entry.providerID,
                    entry.episodeID,
                    entry.animeTitle,
                    entry.episodeTitle,
                    entry.comments.count,
                    payload,
                    entry.fetchedAt
                ])
        }
    }

    /// The provider episode a media file was matched to, if any.
    public func danmakuMatch(mediaFileID: UUID) throws -> DanmakuMatchBinding? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT providerID, episodeID, animeTitle, episodeTitle, shift, isManual, matchedAt FROM danmakuMatch WHERE mediaFileID = ?",
                arguments: [mediaFileID.uuidString]
            ) else { return nil }
            return DanmakuMatchBinding(
                mediaFileID: mediaFileID,
                providerID: row["providerID"],
                episodeID: row["episodeID"],
                animeTitle: row["animeTitle"] ?? "",
                episodeTitle: row["episodeTitle"] ?? "",
                shift: row["shift"] ?? 0,
                isManual: row["isManual"],
                matchedAt: row["matchedAt"]
            )
        }
    }

    public func saveDanmakuMatch(_ binding: DanmakuMatchBinding) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO danmakuMatch
                    (mediaFileID, providerID, episodeID, animeTitle, episodeTitle, shift, isManual, matchedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(mediaFileID) DO UPDATE SET
                    providerID = excluded.providerID,
                    episodeID = excluded.episodeID,
                    animeTitle = excluded.animeTitle,
                    episodeTitle = excluded.episodeTitle,
                    shift = excluded.shift,
                    isManual = excluded.isManual,
                    matchedAt = excluded.matchedAt
                """, arguments: [
                    binding.mediaFileID.uuidString,
                    binding.providerID,
                    binding.episodeID,
                    binding.animeTitle,
                    binding.episodeTitle,
                    binding.shift,
                    binding.isManual,
                    binding.matchedAt
                ])
        }
    }

    public func removeDanmakuMatch(mediaFileID: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM danmakuMatch WHERE mediaFileID = ?", arguments: [mediaFileID.uuidString])
        }
    }

    // MARK: - Episode cache

    /// All cached episode copies, joined with their library labels for the
    /// cache manager. Orphaned rows cannot exist: the media-file foreign key
    /// cascades them away.
    public func cacheEntries() throws -> [EpisodeCacheEntry] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT episodeCache.*,
                       anime.title AS animeTitle,
                       episode.kind AS episodeKind, episode.number AS episodeNumber,
                       episode.numberText AS episodeNumberText,
                       COALESCE(playbackProgress.isWatched, 0) AS isWatched
                FROM episodeCache
                JOIN mediaFile ON mediaFile.id = episodeCache.mediaFileID
                JOIN episode ON episode.id = mediaFile.episodeID
                JOIN anime ON anime.id = episode.animeID
                LEFT JOIN playbackProgress ON playbackProgress.episodeID = episode.id
                ORDER BY anime.sortTitle COLLATE NOCASE, episode.sortIndex, episodeCache.relativePath
                """)
            return rows.map(Self.decodeCacheEntry)
        }
    }

    public func cacheEntry(mediaFileID: UUID) throws -> EpisodeCacheEntry? {
        try database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM episodeCache WHERE mediaFileID = ?",
                arguments: [mediaFileID.uuidString]
            ).map(Self.decodeCacheEntry)
        }
    }

    public func saveCacheEntry(_ entry: EpisodeCacheEntry) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO episodeCache
                    (mediaFileID, libraryRootID, relativePath, fileName, fileSize,
                     bytesCopied, state, policy, createdAt, completedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(mediaFileID) DO UPDATE SET
                    fileSize = excluded.fileSize,
                    bytesCopied = excluded.bytesCopied,
                    state = excluded.state,
                    policy = excluded.policy,
                    completedAt = excluded.completedAt
                """, arguments: [
                    entry.mediaFileID.uuidString,
                    entry.libraryRootID.uuidString,
                    entry.relativePath,
                    entry.fileName,
                    entry.fileSize,
                    entry.bytesCopied,
                    entry.state.rawValue,
                    entry.policy.rawValue,
                    entry.createdAt,
                    entry.completedAt
                ])
        }
    }

    /// Progress ticks during a copy; touches nothing but the byte counter so
    /// frequent updates stay cheap.
    public func updateCacheProgress(mediaFileID: UUID, bytesCopied: Int64) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE episodeCache SET bytesCopied = ? WHERE mediaFileID = ?",
                arguments: [bytesCopied, mediaFileID.uuidString]
            )
        }
    }

    /// Marks a copy playable offline and records the final size the source
    /// actually had, guarding against a source that changed mid-copy.
    public func markCacheComplete(mediaFileID: UUID, fileSize: Int64) throws {
        try database.write { db in
            try db.execute(sql: """
                UPDATE episodeCache
                SET state = ?, bytesCopied = ?, fileSize = ?, completedAt = ?
                WHERE mediaFileID = ?
                """, arguments: [EpisodeCacheState.complete.rawValue, fileSize, fileSize, Date.now, mediaFileID.uuidString])
        }
    }

    /// Upgrades an in-flight auto cache to manual when the user explicitly
    /// asked to keep the episode; the running copy simply changes owner.
    public func setCachePolicy(mediaFileID: UUID, policy: EpisodeCachePolicy) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE episodeCache SET policy = ? WHERE mediaFileID = ?",
                arguments: [policy.rawValue, mediaFileID.uuidString]
            )
        }
    }

    public func removeCacheEntry(mediaFileID: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM episodeCache WHERE mediaFileID = ?",
                arguments: [mediaFileID.uuidString]
            )
        }
    }

    public func removeCacheEntries(libraryRootID: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM episodeCache WHERE libraryRootID = ?",
                arguments: [libraryRootID.uuidString]
            )
        }
    }

    private static func decodeCacheEntry(_ row: Row) -> EpisodeCacheEntry {
        // Joined label columns only exist on the list query, so read them all
        // optionality; a bare single-row select just reports no labels.
        let kind = (row["episodeKind"] as String?).flatMap(EpisodeKind.init(rawValue:))
        let numberText: String? = row["episodeNumberText"]
        let isWatched: Bool? = row["isWatched"]
        return EpisodeCacheEntry(
            mediaFileID: UUID(uuidString: row["mediaFileID"])!,
            libraryRootID: UUID(uuidString: row["libraryRootID"])!,
            relativePath: row["relativePath"],
            fileName: row["fileName"],
            fileSize: row["fileSize"],
            bytesCopied: row["bytesCopied"],
            state: EpisodeCacheState(rawValue: row["state"]) ?? .copying,
            policy: EpisodeCachePolicy(rawValue: row["policy"]) ?? .auto,
            createdAt: row["createdAt"],
            completedAt: row["completedAt"],
            animeTitle: row["animeTitle"],
            episodeLabel: kind.map { Episode.displayLabel(kind: $0, numberText: numberText) },
            isEpisodeWatched: isWatched ?? false
        )
    }

    // MARK: - Translation cache

    public func cachedTranslations(provider: String, targetLanguage: String, texts: [String]) throws -> [Int: String] {
        guard !texts.isEmpty else { return [:] }
        return try database.read { db in
            var result: [Int: String] = [:]
            for (index, text) in texts.enumerated() {
                let key = Self.translationCacheKey(provider: provider, targetLanguage: targetLanguage, text: text)
                if let translated = try String.fetchOne(
                    db,
                    sql: "SELECT translatedText FROM translationCache WHERE cacheKey = ?",
                    arguments: [key]
                ) {
                    result[index] = translated
                }
            }
            return result
        }
    }

    public func saveTranslations(provider: String, targetLanguage: String, pairs: [(text: String, translated: String)]) throws {
        guard !pairs.isEmpty else { return }
        try database.write { db in
            for pair in pairs {
                try db.execute(sql: """
                    INSERT INTO translationCache (cacheKey, provider, targetLanguage, sourceText, translatedText, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(cacheKey) DO UPDATE SET
                        translatedText = excluded.translatedText,
                        createdAt = excluded.createdAt
                    """, arguments: [
                        Self.translationCacheKey(provider: provider, targetLanguage: targetLanguage, text: pair.text),
                        provider,
                        targetLanguage,
                        pair.text,
                        pair.translated,
                        Date.now
                    ])
            }
        }
    }

    /// Persists translated fields back onto cached community posts. The
    /// original title/body always remain untouched alongside the translation.
    public func saveCommunityPostTranslations(
        animeID: UUID,
        provider: MetadataProviderID,
        translationsByPostID: [String: (title: String?, body: String?)]
    ) throws {
        guard !translationsByPostID.isEmpty else { return }
        try database.write { db in
            for (postID, translation) in translationsByPostID {
                guard let payload = try Data.fetchOne(
                    db,
                    sql: "SELECT payload FROM communityPost WHERE animeID = ? AND provider = ? AND postID = ?",
                    arguments: [animeID.uuidString, provider.rawValue, postID]
                ), var post = try? JSONDecoder().decode(CommunityPost.self, from: payload) else { continue }
                post.translatedTitle = translation.title ?? post.translatedTitle
                post.translatedBody = translation.body ?? post.translatedBody
                if let updated = try? JSONEncoder().encode(post) {
                    try db.execute(
                        sql: "UPDATE communityPost SET payload = ? WHERE animeID = ? AND provider = ? AND postID = ?",
                        arguments: [updated, animeID.uuidString, provider.rawValue, postID]
                    )
                }
            }
        }
    }

    private static func translationCacheKey(provider: String, targetLanguage: String, text: String) -> String {
        let digest = CryptoKit.SHA256.hash(data: Data("\(provider)|\(targetLanguage)|\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func findOrCreateAnime(title: String, in db: Database) throws -> String {
        let normalized = normalize(title)
        if let id = try String.fetchOne(db, sql: "SELECT id FROM anime WHERE normalizedTitle = ?", arguments: [normalized]) {
            return id
        }
        let id = UUID().uuidString
        try db.execute(
            sql: "INSERT INTO anime (id, title, normalizedTitle, sortTitle, kind, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [id, title, normalized, title, AnimeKind.unknown.rawValue, Date.now, Date.now]
        )
        return id
    }

    private static func findOrCreateEpisode(parsed: ParsedAnimeFilename, animeID: String, relativePath: String, in db: Database) throws -> String {
        let identity: String
        if let episode = parsed.episodeText {
            // Non-regular kinds namespace their numbers so "SP01" can never
            // collide with regular episode 1.
            let prefix = parsed.episodeKind == .regular ? "" : "\(parsed.episodeKind.rawValue.uppercased())-"
            identity = parsed.season.map { "S\($0)-E\(episode)" } ?? "\(prefix)E\(episode)"
        } else if parsed.episodeKind == .regular {
            // Numberless main files of one work are alternative encodes of
            // the same content (DoVi + SDR), so they share one slot.
            identity = "MOVIE"
        } else {
            identity = relativePath
        }
        let sortIndex = parsed.episode ?? (parsed.episodeKind == .regular ? 100_000 : 200_000)
        if let id = try String.fetchOne(
            db,
            sql: "SELECT id FROM episode WHERE animeID = ? AND identityKey = ?",
            arguments: [animeID, identity]
        ) {
            // Parser improvements (e.g. newly recognised MV / SP kinds) must
            // reach episodes that were imported by an older scan.
            try db.execute(
                sql: "UPDATE episode SET kind = ?, sortIndex = ? WHERE id = ?",
                arguments: [parsed.episodeKind.rawValue, sortIndex, id]
            )
            return id
        }
        let id = UUID().uuidString
        try db.execute(
            sql: "INSERT INTO episode (id, animeID, identityKey, number, numberText, kind, sortIndex) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [id, animeID, identity, parsed.episode, parsed.episodeText, parsed.episodeKind.rawValue, sortIndex]
        )
        return id
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }

    private static func decodeRoot(_ row: Row) -> LibraryRoot {
        LibraryRoot(
            id: UUID(uuidString: row["id"])!,
            displayName: row["displayName"],
            lastKnownPath: row["lastKnownPath"],
            bookmarkData: row["bookmarkData"],
            addedAt: row["addedAt"],
            lastScannedAt: row["lastScannedAt"]
        )
    }

    private static func decodeAnime(_ row: Row) -> Anime {
        Anime(
            id: UUID(uuidString: row["id"])!,
            title: row["title"],
            sortTitle: row["sortTitle"],
            kind: AnimeKind(rawValue: row["kind"]) ?? .unknown,
            posterPath: row["posterPath"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"]
        )
    }

    private static func decodeEpisodeMedia(_ row: Row) -> EpisodeMedia {
        let episodeID = UUID(uuidString: row["id"] as String)!
        let episode = Episode(
            id: episodeID,
            animeID: UUID(uuidString: row["animeID"] as String)!,
            number: row["number"],
            numberText: row["numberText"],
            title: row["title"],
            kind: EpisodeKind(rawValue: row["kind"] as String) ?? .regular,
            sortIndex: row["sortIndex"]
        )
        let media = MediaFile(
            id: UUID(uuidString: row["mediaID"] as String)!,
            libraryRootID: UUID(uuidString: row["libraryRootID"] as String)!,
            episodeID: episodeID,
            relativePath: row["relativePath"],
            fileSize: row["fileSize"],
            modifiedAt: row["modifiedAt"],
            discoveredAt: row["discoveredAt"]
        )
        let position: Double? = row["position"]
        let progress = position.map {
            PlaybackProgress(
                episodeID: episodeID,
                position: $0,
                duration: row["duration"],
                updatedAt: row["progressUpdatedAt"],
                isWatched: row["isWatched"]
            )
        }
        return EpisodeMedia(episode: episode, mediaFile: media, progress: progress)
    }

    private static func decodeProfile(_ row: Row) -> AnimeProfile? {
        guard let animeID = UUID(uuidString: row["animeID"] as String) else { return nil }
        let tagsData: Data = row["tags"]
        return AnimeProfile(
            animeID: animeID,
            status: WatchStatus(rawValue: row["status"] as String) ?? .planning,
            score: row["score"],
            notes: row["notes"],
            review: row["review"],
            tags: (try? JSONDecoder().decode([String].self, from: tagsData)) ?? [],
            isFavorite: row["isFavorite"],
            ranking: row["ranking"],
            firstWatchedAt: row["firstWatchedAt"],
            completedAt: row["completedAt"],
            rewatchCount: row["rewatchCount"],
            updatedAt: row["updatedAt"]
        )
    }

    private static func decodeWatchEvent(_ row: Row) -> WatchEvent {
        let episodeIDValue: String? = row["episodeID"]
        return WatchEvent(
            id: UUID(uuidString: row["id"] as String)!,
            animeID: UUID(uuidString: row["animeID"] as String)!,
            episodeID: episodeIDValue.flatMap(UUID.init(uuidString:)),
            animeTitle: row["animeTitle"],
            episodeLabel: row["episodeLabel"],
            startedAt: row["startedAt"],
            endedAt: row["endedAt"],
            watchedDuration: row["watchedDuration"],
            completion: row["completion"],
            completedEpisode: row["completedEpisode"]
        )
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "libraryRoot") { table in
                table.column("id", .text).primaryKey()
                table.column("displayName", .text).notNull()
                table.column("lastKnownPath", .text).notNull()
                table.column("bookmarkData", .blob)
                table.column("addedAt", .datetime).notNull()
                table.column("lastScannedAt", .datetime)
            }
            try db.create(table: "anime") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("normalizedTitle", .text).notNull().unique()
                table.column("sortTitle", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("posterPath", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "episode") { table in
                table.column("id", .text).primaryKey()
                table.column("animeID", .text).notNull().references("anime", onDelete: .cascade)
                table.column("identityKey", .text).notNull()
                table.column("number", .double)
                table.column("numberText", .text)
                table.column("title", .text)
                table.column("kind", .text).notNull()
                table.column("sortIndex", .double).notNull()
                table.uniqueKey(["animeID", "identityKey"])
            }
            try db.create(table: "mediaFile") { table in
                table.column("id", .text).primaryKey()
                table.column("libraryRootID", .text).notNull().references("libraryRoot", onDelete: .cascade)
                table.column("episodeID", .text).notNull().references("episode", onDelete: .cascade)
                table.column("relativePath", .text).notNull()
                table.column("fileSize", .integer).notNull()
                table.column("modifiedAt", .datetime).notNull()
                table.column("discoveredAt", .datetime).notNull()
                table.uniqueKey(["libraryRootID", "relativePath"])
            }
            try db.create(table: "playbackProgress") { table in
                table.column("episodeID", .text).primaryKey().references("episode", onDelete: .cascade)
                table.column("position", .double).notNull()
                table.column("duration", .double).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.column("isWatched", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "mediaFile_root", on: "mediaFile", columns: ["libraryRootID"])
            try db.create(index: "episode_anime_sort", on: "episode", columns: ["animeID", "sortIndex"])
            try db.create(index: "progress_recent", on: "playbackProgress", columns: ["isWatched", "updatedAt"])
        }
        migrator.registerMigration("v2_metadata") { db in
            try db.create(table: "externalAnimeID") { table in
                table.column("animeID", .text).notNull().references("anime", onDelete: .cascade)
                table.column("provider", .text).notNull()
                table.column("externalID", .text).notNull()
                table.column("matchConfidence", .double).notNull()
                table.column("isManual", .boolean).notNull().defaults(to: false)
                table.column("linkedAt", .datetime).notNull()
                table.primaryKey(["animeID", "provider"])
            }
            try db.create(table: "animeMetadata") { table in
                table.column("animeID", .text).notNull().references("anime", onDelete: .cascade)
                table.column("provider", .text).notNull()
                table.column("externalID", .text).notNull()
                table.column("payload", .blob).notNull()
                table.column("fetchedAt", .datetime).notNull()
                table.primaryKey(["animeID", "provider"])
                table.foreignKey(["animeID", "provider"], references: "externalAnimeID", columns: ["animeID", "provider"], onDelete: .cascade)
            }
            try db.create(table: "communityPost") { table in
                table.column("animeID", .text).notNull().references("anime", onDelete: .cascade)
                table.column("provider", .text).notNull()
                table.column("postID", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("payload", .blob).notNull()
                table.column("publishedAt", .datetime)
                table.primaryKey(["animeID", "provider", "postID"])
                table.foreignKey(["animeID", "provider"], references: "externalAnimeID", columns: ["animeID", "provider"], onDelete: .cascade)
            }
            try db.create(index: "communityPost_anime_date", on: "communityPost", columns: ["animeID", "publishedAt"])
        }
        migrator.registerMigration("v3_personal_library") { db in
            try db.create(table: "animeProfile") { table in
                table.column("animeID", .text).primaryKey().references("anime", onDelete: .cascade)
                table.column("status", .text).notNull()
                table.column("score", .double)
                table.column("notes", .text).notNull().defaults(to: "")
                table.column("review", .text).notNull().defaults(to: "")
                table.column("tags", .blob).notNull()
                table.column("isFavorite", .boolean).notNull().defaults(to: false)
                table.column("ranking", .integer)
                table.column("firstWatchedAt", .datetime)
                table.column("completedAt", .datetime)
                table.column("rewatchCount", .integer).notNull().defaults(to: 0)
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "watchEvent") { table in
                table.column("id", .text).primaryKey()
                table.column("animeID", .text).notNull().references("anime", onDelete: .cascade)
                table.column("episodeID", .text).references("episode", onDelete: .setNull)
                table.column("animeTitle", .text).notNull()
                table.column("episodeLabel", .text).notNull()
                table.column("startedAt", .datetime).notNull()
                table.column("endedAt", .datetime).notNull()
                table.column("watchedDuration", .double).notNull()
                table.column("completion", .double).notNull()
                table.column("completedEpisode", .boolean).notNull()
            }
            try db.create(index: "animeProfile_ranking", on: "animeProfile", columns: ["ranking"])
            try db.create(index: "watchEvent_recent", on: "watchEvent", columns: ["endedAt"])
            try db.create(index: "watchEvent_anime", on: "watchEvent", columns: ["animeID", "endedAt"])
        }
        migrator.registerMigration("v4_translation") { db in
            try db.create(table: "translationCache") { table in
                table.column("cacheKey", .text).primaryKey()
                table.column("provider", .text).notNull()
                table.column("targetLanguage", .text).notNull()
                table.column("sourceText", .text).notNull()
                table.column("translatedText", .text).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "translationCache_recent", on: "translationCache", columns: ["createdAt"])
        }
        migrator.registerMigration("v5_danmaku") { db in
            // Danmaku payload cache keyed by provider + episode identity —
            // never by local filename — so replays work offline.
            try db.create(table: "danmakuCache") { table in
                table.column("cacheKey", .text).primaryKey()
                table.column("providerID", .text).notNull()
                table.column("episodeID", .integer).notNull()
                table.column("animeTitle", .text).notNull().defaults(to: "")
                table.column("episodeTitle", .text).notNull().defaults(to: "")
                table.column("commentCount", .integer).notNull().defaults(to: 0)
                table.column("payload", .blob).notNull()
                table.column("fetchedAt", .datetime).notNull()
            }
            try db.create(index: "danmakuCache_provider", on: "danmakuCache", columns: ["providerID", "episodeID"])
            // Media-file → provider-episode binding. The mediaFile UUID is
            // stable across rescans, so bindings survive renames/regrouping.
            // No FK: matches may be written while a scan is mid-flight;
            // dangling rows are swept during scans.
            try db.create(table: "danmakuMatch") { table in
                table.column("mediaFileID", .text).primaryKey()
                table.column("providerID", .text).notNull()
                table.column("episodeID", .integer).notNull()
                table.column("animeTitle", .text).notNull().defaults(to: "")
                table.column("episodeTitle", .text).notNull().defaults(to: "")
                table.column("shift", .double).notNull().defaults(to: 0)
                table.column("isManual", .boolean).notNull().defaults(to: false)
                table.column("matchedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v6_episode_cache") { db in
            // Local copies of episodes that live on an external drive. Keyed by
            // the media file (stable across rescans) so cache rows disappear
            // with their source and the store reconciles orphaned files.
            try db.create(table: "episodeCache") { table in
                table.column("mediaFileID", .text).primaryKey().references("mediaFile", onDelete: .cascade)
                table.column("libraryRootID", .text).notNull().references("libraryRoot", onDelete: .cascade)
                table.column("relativePath", .text).notNull()
                table.column("fileName", .text).notNull()
                table.column("fileSize", .integer).notNull()
                table.column("bytesCopied", .integer).notNull().defaults(to: 0)
                table.column("state", .text).notNull().defaults(to: EpisodeCacheState.copying.rawValue)
                table.column("policy", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("completedAt", .datetime)
            }
            try db.create(index: "episodeCache_root", on: "episodeCache", columns: ["libraryRootID"])
        }
        return migrator
    }
}
