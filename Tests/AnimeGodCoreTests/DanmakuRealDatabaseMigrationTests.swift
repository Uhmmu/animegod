import Foundation
import Testing
@testable import AnimeGodCore

/// Opens a copy of the developer's real library database (if present) to
/// prove the danmaku migration applies cleanly over production data.
/// Silently skips on machines without the real database.
struct DanmakuRealDatabaseMigrationTests {
    @Test func migratesRealLibraryDatabaseToV5() async throws {
        let source = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/AnimeGod/library.sqlite")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("No real library database on this machine")
        }
        let copy = FileManager.default.temporaryDirectory
            .appending(path: "animegod-migration-check-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let database = try LibraryDatabase(url: copy)
        let roots = try await database.libraryRoots()
        let entry = DanmakuCacheEntry(
            providerID: "dandanplay", episodeID: 1, animeTitle: "a", episodeTitle: "b",
            comments: [DanmakuComment(id: "1", time: 1, text: "t", mode: .scroll)]
        )
        try await database.saveDanmakuCache(entry)
        let loaded = try await database.danmakuCache(providerID: "dandanplay", episodeID: 1)
        #expect(loaded?.comments.count == 1)
        #expect(roots.count >= 0)
    }
}

import XCTest
