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
        // leave true, and nothing in a library of anime is a concert yet.
        let grid = try await database.library()
        #expect(!grid.isEmpty)
        #expect(try await database.concerts().isEmpty)

        // The new tables exist and answer.
        let animeID = try #require(grid.first?.id)
        #expect(try await database.concertRelease(animeID: animeID) == nil)

        // And a work can be moved into the section and back out of the grid.
        let before = grid.count
        #expect(try await database.markAnimeAsConcert(id: animeID))
        #expect(try await database.library().count == before - 1)
        #expect(try await database.concerts().count == 1)
    }
}
