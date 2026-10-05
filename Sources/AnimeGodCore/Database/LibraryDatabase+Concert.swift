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
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO concertRelease (
                    animeID, provider, externalID, title, artistNames, releaseDate, country,
                    labels, catalogNumbers, barcode, genres, coverImageURLs, sourceURL,
                    score, ratingCount, summary, venue, performedOn, officialSiteURL,
                    discs, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    discs = excluded.discs, updatedAt = excluded.updatedAt
                """, arguments: [
                    animeID.uuidString, release.provider.rawValue, release.externalID,
                    release.title, Self.joined(release.artistNames), release.releaseDate,
                    release.country, Self.joined(release.labels),
                    Self.joined(release.catalogNumbers), release.barcode,
                    Self.joined(release.genres),
                    Self.joined(release.coverImageURLs.map(\.absoluteString)),
                    release.sourceURL?.absoluteString, release.score, release.ratingCount,
                    release.summary, release.venue, release.performedOn,
                    release.officialSiteURL?.absoluteString, discs, Date()
                ])
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
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO concertSetlist (episodeID, method, confidence, placements, isManual, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(episodeID) DO UPDATE SET
                    method = excluded.method,
                    confidence = excluded.confidence,
                    placements = excluded.placements,
                    isManual = excluded.isManual,
                    updatedAt = excluded.updatedAt
                WHERE concertSetlist.isManual = 0 OR excluded.isManual = 1
                """, arguments: [
                    setlist.episodeID.uuidString,
                    setlist.alignment.method.rawValue,
                    setlist.alignment.confidence,
                    placements,
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
            officialSiteURL: (row["officialSiteURL"] as String?).flatMap(URL.init(string:))
        )
    }

    static func decodeStoredSetlist(_ row: Row) -> StoredConcertSetlist? {
        guard let episodeID = (row["episodeID"] as String?).flatMap(UUID.init(uuidString:)),
              let method = ConcertSetlistAlignment.Method(rawValue: row["method"]),
              let data = row["placements"] as Data?,
              let placements = try? JSONDecoder().decode([ConcertSetlistAlignment.Placement].self, from: data)
        else { return nil }
        return StoredConcertSetlist(
            episodeID: episodeID,
            alignment: ConcertSetlistAlignment(
                placements: placements, method: method, confidence: row["confidence"]
            ),
            isManual: row["isManual"],
            updatedAt: row["updatedAt"]
        )
    }
}
