import Foundation
import Testing
@testable import AnimeGodCore

struct DanmakuCacheTests {
    @Test func roundTripsCacheEntriesByIdentity() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let entry = DanmakuCacheEntry(
            providerID: "dandanplay",
            episodeID: 10080010001,
            animeTitle: "孤独摇滚！",
            episodeTitle: "第01话 転校生",
            comments: [
                DanmakuComment(id: "1", time: 12.34, text: "前方高能", mode: .scroll, color: 0xFFFFFF, senderID: "7"),
                DanmakuComment(id: "2", time: 45.6, text: "顶部", mode: .top, color: 0xFF0000),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        try await database.saveDanmakuCache(entry)

        let loaded = try await database.danmakuCache(providerID: "dandanplay", episodeID: 10080010001)
        let decoded = try #require(loaded)
        #expect(decoded == entry)
        #expect(decoded.comments[0].time == 12.34)
    }

    @Test func cacheMissReturnsNil() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let loaded = try await database.danmakuCache(providerID: "dandanplay", episodeID: 1)
        #expect(loaded == nil)
    }

    @Test func cacheIsKeyedByProviderAndEpisodeNotFilename() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let entry = DanmakuCacheEntry(
            providerID: "dandanplay", episodeID: 42,
            animeTitle: "A", episodeTitle: "1", comments: [], fetchedAt: .now
        )
        try await database.saveDanmakuCache(entry)
        // Same episode from another provider/file misses; same identity hits.
        #expect(try await database.danmakuCache(providerID: "other", episodeID: 42) == nil)
        #expect(try await database.danmakuCache(providerID: "dandanplay", episodeID: 43) == nil)
        #expect(try await database.danmakuCache(providerID: "dandanplay", episodeID: 42) != nil)
    }

    @Test func refetchOverwritesTheSameCacheSlot() async throws {
        let database = try LibraryDatabase(inMemory: true)
        for count in [10, 25] {
            try await database.saveDanmakuCache(DanmakuCacheEntry(
                providerID: "dandanplay", episodeID: 7,
                animeTitle: "A", episodeTitle: "1",
                comments: (0..<count).map {
                    DanmakuComment(id: "\($0)", time: Double($0), text: "t", mode: .scroll)
                },
                fetchedAt: .now
            ))
        }
        let loaded = try #require(try await database.danmakuCache(providerID: "dandanplay", episodeID: 7))
        #expect(loaded.comments.count == 25)
    }

    @Test func matchBindingRoundTripsAndReplaces() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let fileID = UUID()
        let binding = DanmakuMatchBinding(
            mediaFileID: fileID,
            providerID: "dandanplay",
            episodeID: 100,
            animeTitle: "A",
            episodeTitle: "1",
            shift: 0.5,
            isManual: false
        )
        try await database.saveDanmakuMatch(binding)
        var loaded = try #require(try await database.danmakuMatch(mediaFileID: fileID))
        #expect(loaded.episodeID == 100)
        #expect(loaded.shift == 0.5)
        #expect(loaded.isManual == false)

        // A manual re-match replaces the binding for the same file.
        let manual = DanmakuMatchBinding(
            mediaFileID: fileID, episodeRef: DanmakuEpisodeRef(
                providerID: "dandanplay", episodeID: 200, animeTitle: "B", episodeTitle: "2"
            ),
            isManual: true
        )
        try await database.saveDanmakuMatch(manual)
        loaded = try #require(try await database.danmakuMatch(mediaFileID: fileID))
        #expect(loaded.episodeID == 200)
        #expect(loaded.isManual == true)
        #expect(loaded.episodeRef.animeTitle == "B")

        try await database.removeDanmakuMatch(mediaFileID: fileID)
        #expect(try await database.danmakuMatch(mediaFileID: fileID) == nil)
    }

    @Test func cachePayloadsSurviveLargeCommentSets() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let comments: [DanmakuComment] = (0..<5000).map { index in
            let mode: DanmakuMode = index % 5 == 0 ? .top : .scroll
            let color: Int = index % 3 == 0 ? 0xFF0000 : 0xFFFFFF
            return DanmakuComment(
                id: "\(index)", time: Double(index) * 0.7, text: "弹幕内容 \(index)",
                mode: mode, color: color
            )
        }
        try await database.saveDanmakuCache(DanmakuCacheEntry(
            providerID: "dandanplay", episodeID: 9,
            animeTitle: "A", episodeTitle: "1", comments: comments, fetchedAt: .now
        ))
        let loaded = try #require(try await database.danmakuCache(providerID: "dandanplay", episodeID: 9))
        #expect(loaded.comments.count == 5000)
        #expect(loaded.comments[4999].time == 4999 * 0.7)
    }
}

struct DanmakuFileHasherTests {
    @Test func hashesFirst16MBAsLowercaseMD5() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "animegod-danmaku-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "video.mkv")
        var payload = Data()
        // 16 MB + 1 KB: content after the 16 MB mark must not affect the hash.
        let pattern = Data((0..<1024).map { UInt8($0 % 251) })
        for _ in 0..<(16 * 1024 + 1) { payload.append(pattern) }
        try payload.write(to: url)

        let hash = try #require(try DanmakuFileHasher.hashFile(at: url))
        let expected = CryptoKitInsecureMD5.hash(data: Data(payload.prefix(16 * 1024 * 1024)))
            .map { String(format: "%02x", $0) }.joined()
        #expect(hash == expected)
        #expect(hash == hash.lowercased())
        #expect(hash.count == 32)
    }

    @Test func smallFilesReturnNoHash() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "animegod-small-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0xAB, count: 1024).write(to: url)
        #expect(try DanmakuFileHasher.hashFile(at: url) == nil)
    }
}

import CryptoKit
typealias CryptoKitInsecureMD5 = CryptoKit.Insecure.MD5
