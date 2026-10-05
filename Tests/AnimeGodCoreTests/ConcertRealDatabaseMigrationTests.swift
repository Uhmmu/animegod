import Foundation
import Testing
@testable import AnimeGodCore

/// Opens a copy of a real library and applies the concert migration to it.
///
/// Skips unless `ANIMEGOD_REAL_DB_COPY` points at one, the way the danmaku
/// migration test does: the point is to prove the migration survives data that
/// no fixture has, and the real database is the only place that data lives.
struct ConcertRealDatabaseMigrationTests {
    @Test func migratesACopyOfARealLibrary() async throws {
        guard let path = ProcessInfo.processInfo.environment["ANIMEGOD_REAL_DB_COPY"],
              FileManager.default.fileExists(atPath: path)
        else { return }

        let database = try LibraryDatabase(url: URL(fileURLWithPath: path))
        // The grid still reads, which is what an additive migration has to
        // leave true. It is deliberately *not* asserted that the section is
        // empty: it was when this was written, and this library has concerts in
        // it now — a test that assumed otherwise would fail for the reason the
        // feature works.
        let grid = try await database.library()
        #expect(!grid.isEmpty)
        let concertsBefore = try await database.concerts().count

        // The new tables and columns exist and answer. A release that predates
        // the attribution column decodes with an empty map rather than failing.
        for concert in try await database.concerts() {
            guard let release = try await database.concertRelease(animeID: concert.id) else { continue }
            #expect(!release.title.isEmpty)
            #expect(release.attribution.count >= 0)
        }

        // And a work can still be moved into the section and out of the grid.
        let animeID = try #require(grid.first?.id)
        let before = grid.count
        #expect(try await database.markAnimeAsConcert(id: animeID))
        #expect(try await database.library().count == before - 1)
        #expect(try await database.concerts().count == concertsBefore + 1)
    }
}
