import Foundation
import GRDB

/// The concert store.
///
/// Kept apart from the anime tables because almost nothing is shared: a
/// concert disc has no episodes to count, no season to be partway through and
/// no synopsis to show. What it has instead — a hall, a catalogue number, a
/// setlist and a timeline somebody may have corrected by hand — has no column
/// anywhere else.
public extension LibraryDatabase {
    // MARK: - The section

    /// Every concert in the library, newest first.
    ///
    /// A disc that has been scanned but not yet identified comes back with a
    /// nil release rather than being left out: it is on disk and playable, and
    /// hiding it until a provider answers would look like a failed scan.
    func concerts() throws -> [LibraryConcert] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT anime.*,
                       COUNT(DISTINCT mediaFile.id) AS discCount,
                       MAX(playbackProgress.updatedAt) AS lastPlayedAt
                FROM anime
                JOIN episode ON episode.animeID = anime.id
                JOIN mediaFile ON mediaFile.episodeID = episode.id
                LEFT JOIN playbackProgress ON playbackProgress.episodeID = episode.id
                WHERE anime.kind = ?
                GROUP BY anime.id
                ORDER BY anime.createdAt DESC
                """, arguments: [AnimeKind.live.rawValue])

            let releases = try Self.concertReleases(in: db)
            return rows.map { row in
                let anime = Self.decodeAnime(row)
                return LibraryConcert(
                    anime: anime,
                    release: releases[anime.id],
                    discCount: row["discCount"],
                    lastPlayedAt: row["lastPlayedAt"]
                )
            }
        }
    }

    /// Works whose files are discs, with the folder each arrived in.
    ///
    /// The folder is what carries the catalogue number, so it is what a lookup
    /// needs — not the work's title, which has already had the release tags
    /// stripped out of it. Returned for every disc work whether or not it is a
    /// concert yet: an anime Blu-ray is a disc too, and the lookup is what
    /// decides which it is.
    /// Where a work's files sit: the library root they are under and the folder
    /// they share.
    ///
    /// A release says more about itself in its own folder than any index does —
    /// the catalogue number in a cue sheet's filename, the jacket scans, the
    /// track list — so the lookup needs to be able to open it.
    func releaseFolders() throws -> [(animeID: UUID, rootID: UUID, folderName: String)] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT anime.id AS animeID, mediaFile.libraryRootID AS rootID,
                       MIN(mediaFile.relativePath) AS path
                FROM anime
                JOIN episode ON episode.animeID = anime.id
                JOIN mediaFile ON mediaFile.episodeID = episode.id
                GROUP BY anime.id
                """)
            return rows.compactMap { row in
                guard let id = (row["animeID"] as String?).flatMap(UUID.init(uuidString:)),
                      let rootID = (row["rootID"] as String?).flatMap(UUID.init(uuidString:)),
                      let path: String = row["path"],
                      let folder = path.components(separatedBy: "/").first, !folder.isEmpty
                else { return nil }
                return (id, rootID, folder)
            }
        }
    }

    func discWorks() throws -> [(animeID: UUID, folderName: String, title: String, kind: AnimeKind)] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT anime.id AS animeID, anime.title AS title, anime.kind AS kind,
                       MIN(mediaFile.relativePath) AS path
                FROM anime
                JOIN episode ON episode.animeID = anime.id
                JOIN mediaFile ON mediaFile.episodeID = episode.id
                WHERE mediaFile.relativePath LIKE '%.iso'
                   OR LOWER(mediaFile.relativePath) LIKE '%/bdmv/index.bdmv'
                GROUP BY anime.id
                """)
            return rows.compactMap { row in
                guard let id = (row["animeID"] as String?).flatMap(UUID.init(uuidString:)),
                      let path: String = row["path"],
                      let folder = path.components(separatedBy: "/").first, !folder.isEmpty
                else { return nil }
                return (
                    id, folder, row["title"],
                    AnimeKind(rawValue: row["kind"] ?? "") ?? .unknown
                )
            }
        }
    }

    /// Every work in the library that is not already a concert, with its title.
    ///
    /// For the one case `worksWithNoMetadata()` cannot see: a work a provider
    /// *did* match, wrongly. AniList files
    /// `BanG Dream! 12th☆LIVE DAY2：MyGO!!!!!` as the 2017 TV series — thirteen
    /// episodes, a summary about Kasumi Toyama — and having that match is
    /// exactly what hid the concert from every pass here. A provider's opinion
    /// is not evidence against a name that says `12th☆LIVE`.
    func worksThatAreNotConcerts() throws -> [(animeID: UUID, title: String)] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT anime.id AS animeID, anime.title AS title
                FROM anime
                JOIN episode ON episode.animeID = anime.id
                JOIN mediaFile ON mediaFile.episodeID = episode.id
                WHERE anime.kind <> ?
                GROUP BY anime.id
                """, arguments: [AnimeKind.live.rawValue])
            return rows.compactMap { row in
                guard let id = (row["animeID"] as String?).flatMap(UUID.init(uuidString:)) else { return nil }
                return (id, row["title"])
            }
        }
    }

    /// Works no metadata provider has ever answered about.
    ///
    /// A concert is the usual reason: no anime index lists one, so the match
    /// review asks about it at every launch and can never be satisfied. This is
    /// what lets the concert lookup pick those up — the question is "has any
    /// provider heard of this at all", not "is this a disc".
    func worksWithNoMetadata() throws -> [(animeID: UUID, title: String)] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT anime.id AS animeID, anime.title AS title
                FROM anime
                JOIN episode ON episode.animeID = anime.id
                JOIN mediaFile ON mediaFile.episodeID = episode.id
                LEFT JOIN animeMetadata ON animeMetadata.animeID = anime.id
                WHERE anime.kind <> ? AND animeMetadata.animeID IS NULL
                GROUP BY anime.id
                """, arguments: [AnimeKind.live.rawValue])
            return rows.compactMap { row in
                guard let id = (row["animeID"] as String?).flatMap(UUID.init(uuidString:)) else { return nil }
                return (id, row["title"])
            }
        }
    }

    /// Takes a work back out of the concert section.
    @discardableResult
    func unmarkAnimeAsConcert(id: UUID, becoming kind: AnimeKind = .unknown) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: "UPDATE anime SET kind = ?, updatedAt = ? WHERE id = ? AND kind = ?",
                arguments: [kind.rawValue, Date(), id.uuidString, AnimeKind.live.rawValue]
            )
            return db.changesCount > 0
        }
    }

    // MARK: - The release

    func concertRelease(animeID: UUID) throws -> ConcertRelease? {
        try database.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM concertRelease WHERE animeID = ?",
                arguments: [animeID.uuidString]
            ).flatMap(Self.decodeConcertRelease)
        }
    }

    /// Stores the merged record for a work, replacing whatever was there.
    ///
    /// Replacing rather than merging on purpose: the merge happens before this
    /// is called, where all three providers' answers are in hand. Merging here
    /// would leave a field from a source that has since been corrected.
    func saveConcertRelease(_ release: ConcertRelease, forAnimeID animeID: UUID) throws {
        let discs = try JSONEncoder().encode(release.discs)
        let extras = try JSONEncoder().encode(release.extras)
        let attribution = try JSONEncoder().encode(release.attribution)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO concertRelease (
                    animeID, provider, externalID, title, artistNames, releaseDate, country,
                    labels, catalogNumbers, barcode, genres, coverImageURLs, sourceURL,
                    score, ratingCount, summary, venue, performedOn, officialSiteURL,
                    discs, extras, attribution, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(animeID) DO UPDATE SET
                    provider = excluded.provider, externalID = excluded.externalID,
                    title = excluded.title, artistNames = excluded.artistNames,
                    releaseDate = excluded.releaseDate, country = excluded.country,
                    labels = excluded.labels, catalogNumbers = excluded.catalogNumbers,
                    barcode = excluded.barcode, genres = excluded.genres,
                    coverImageURLs = excluded.coverImageURLs, sourceURL = excluded.sourceURL,
                    score = excluded.score, ratingCount = excluded.ratingCount,
                    summary = excluded.summary, venue = excluded.venue,
                    performedOn = excluded.performedOn, officialSiteURL = excluded.officialSiteURL,
                    discs = excluded.discs, extras = excluded.extras,
                    attribution = excluded.attribution, updatedAt = excluded.updatedAt
                """, arguments: [
                    animeID.uuidString, release.provider.rawValue, release.externalID,
                    release.title, Self.joined(release.artistNames), release.releaseDate,
                    release.country, Self.joined(release.labels),
                    Self.joined(release.catalogNumbers), release.barcode,
                    Self.joined(release.genres),
                    Self.joined(release.coverImageURLs.map(\.absoluteString)),
                    release.sourceURL?.absoluteString, release.score, release.ratingCount,
                    release.summary, release.venue, release.performedOn,
                    release.officialSiteURL?.absoluteString, discs, extras, attribution, Date()
                ])
        }
    }

    /// Files a cover somebody chose themselves.
    ///
    /// `anime.posterPath` has existed since `v1` and nothing has ever written
    /// to it, which makes it exactly the right place: a column already carried
    /// everywhere a work goes, including to the phone.
    @discardableResult
    func setPosterPath(_ path: String?, forAnimeID animeID: UUID) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: "UPDATE anime SET posterPath = ?, updatedAt = ? WHERE id = ?",
                arguments: [path, Date(), animeID.uuidString]
            )
            return db.changesCount > 0
        }
    }

    /// Throws a stored record away, for one that is known to be wrong rather
    /// than merely thin.
    @discardableResult
    func deleteConcertRelease(animeID: UUID) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM concertRelease WHERE animeID = ?",
                arguments: [animeID.uuidString]
            )
            return db.changesCount > 0
        }
    }

    /// Works already filed under one of these catalogue numbers.
    ///
    /// Used before a lookup: a box set's three numbers all name one work, and
    /// re-identifying a disc that is already known would ask three services
    /// about something the library can answer.
    func concertAnimeID(forCatalogNumber number: ConcertCatalogNumber) throws -> UUID? {
        let needle = number.description
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT animeID, catalogNumbers FROM concertRelease")
            for row in rows {
                let stored: String = row["catalogNumbers"]
                let numbers = Self.split(stored).flatMap { ConcertCatalogNumber.all(in: $0) }
                guard numbers.contains(where: { $0.description == needle }) else { continue }
                return (row["animeID"] as String?).flatMap(UUID.init(uuidString:))
            }
            return nil
        }
    }

    // MARK: - The timeline

    func concertSetlist(episodeID: UUID) throws -> StoredConcertSetlist? {
        try database.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM concertSetlist WHERE episodeID = ?",
                arguments: [episodeID.uuidString]
            ).flatMap(Self.decodeStoredSetlist)
        }
    }

    /// Stores a timeline.
    ///
    /// A timeline a person corrected is never overwritten by one that was
    /// worked out — that is what `isManual` is for, and a correction that did
    /// not survive closing the window would be worse than no correction.
    func saveConcertSetlist(_ setlist: StoredConcertSetlist) throws {
        let placements = try JSONEncoder().encode(setlist.alignment.placements)
        let chapters = try JSONEncoder().encode(setlist.chapters)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO concertSetlist (episodeID, method, confidence, placements, chapters, isManual, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(episodeID) DO UPDATE SET
                    method = excluded.method,
                    confidence = excluded.confidence,
                    placements = excluded.placements,
                    chapters = excluded.chapters,
                    isManual = excluded.isManual,
                    updatedAt = excluded.updatedAt
                WHERE concertSetlist.isManual = 0 OR excluded.isManual = 1
                """, arguments: [
                    setlist.episodeID.uuidString,
                    setlist.alignment.method.rawValue,
                    setlist.alignment.confidence,
                    placements,
                    chapters,
                    setlist.isManual,
                    setlist.updatedAt
                ])
        }
    }

    /// Marks a work as a concert, so it leaves the grid and joins the section.
    @discardableResult
    func markAnimeAsConcert(id: UUID) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: "UPDATE anime SET kind = ?, updatedAt = ? WHERE id = ? AND kind <> ?",
                arguments: [AnimeKind.live.rawValue, Date(), id.uuidString, AnimeKind.live.rawValue]
            )
            return db.changesCount > 0
        }
    }
}

// MARK: - Decoding

extension LibraryDatabase {
    /// A newline is the separator: a catalogue number, a label and an artist
    /// name can all contain a comma, and none of them can contain a newline.
    static func joined(_ values: [String]) -> String {
        values.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
    }

    static func split(_ stored: String) -> [String] {
        stored.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    static func concertReleases(in db: Database) throws -> [UUID: ConcertRelease] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM concertRelease")
        var byAnime: [UUID: ConcertRelease] = [:]
        for row in rows {
            guard let animeID = (row["animeID"] as String?).flatMap(UUID.init(uuidString:)),
                  let release = decodeConcertRelease(row)
            else { continue }
            byAnime[animeID] = release
        }
        return byAnime
    }

    static func decodeConcertRelease(_ row: Row) -> ConcertRelease? {
        guard let provider = ConcertProviderID(rawValue: row["provider"]) else { return nil }
        let discs: [ConcertDisc] = (row["discs"] as Data?)
            .flatMap { try? JSONDecoder().decode([ConcertDisc].self, from: $0) } ?? []
        return ConcertRelease(
            provider: provider,
            externalID: row["externalID"],
            title: row["title"],
            artistNames: split(row["artistNames"]),
            releaseDate: row["releaseDate"],
            country: row["country"],
            labels: split(row["labels"]),
            catalogNumbers: split(row["catalogNumbers"]),
            barcode: row["barcode"],
            genres: split(row["genres"]),
            discs: discs,
            coverImageURLs: split(row["coverImageURLs"]).compactMap(URL.init(string:)),
            sourceURL: (row["sourceURL"] as String?).flatMap(URL.init(string:)),
            score: row["score"],
            ratingCount: row["ratingCount"],
            summary: row["summary"],
            venue: row["venue"],
            performedOn: row["performedOn"],
            officialSiteURL: (row["officialSiteURL"] as String?).flatMap(URL.init(string:)),
            extras: (row["extras"] as Data?)
                .flatMap { try? JSONDecoder().decode([ConcertExtra].self, from: $0) } ?? [],
            // Absent on a record stored before the column existed, which the
            // page reads as "not recorded" rather than as "nobody answered".
            attribution: (row["attribution"] as Data?)
                .flatMap { try? JSONDecoder().decode([ConcertReleaseField: ConcertProviderID].self, from: $0) }
                ?? [:]
        )
    }

    static func decodeStoredSetlist(_ row: Row) -> StoredConcertSetlist? {
        guard let episodeID = (row["episodeID"] as String?).flatMap(UUID.init(uuidString:)),
              let method = ConcertSetlistAlignment.Method(rawValue: row["method"]),
              let data = row["placements"] as Data?,
              let placements = try? JSONDecoder().decode([ConcertSetlistAlignment.Placement].self, from: data)
        else { return nil }
        let chapters = (row["chapters"] as Data?)
            .flatMap { try? JSONDecoder().decode([ConcertChapterMark].self, from: $0) } ?? []
        return StoredConcertSetlist(
            episodeID: episodeID,
            alignment: ConcertSetlistAlignment(
                placements: placements, method: method, confidence: row["confidence"]
            ),
            chapters: chapters,
            isManual: row["isManual"],
            updatedAt: row["updatedAt"]
        )
    }
}
