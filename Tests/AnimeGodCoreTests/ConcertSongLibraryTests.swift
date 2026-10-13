import Foundation
import Testing
@testable import AnimeGodCore

struct ConcertSongLibraryTests {
    private func fixture(names: [String] = ["Band 1st LIVE"]) async throws -> (LibraryDatabase, [UUID]) {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Live", lastKnownPath: "/concerts")
        try await database.save(root: root)
        try await database.importScan(LibraryScanResult(root: root, files: names.map { title in
            ScannedMediaFile(
                relativePath: "\(title)/live.iso", fileSize: 1000, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: title, episode: nil, confidence: 1)
            )
        }, skippedUnreadableCount: 0))
        let works = try await database.library()
        let ids = names.compactMap { name in works.first { $0.anime.title == name }?.id }
        for id in ids { try await database.markAnimeAsConcert(id: id) }
        return (database, ids)
    }

    private func release(tracks: [ConcertTrack], extraDiscs: [ConcertDisc] = []) -> ConcertRelease {
        ConcertRelease(
            provider: .localFiles, externalID: "local", title: "Live", artistNames: ["Band"],
            discs: [ConcertDisc(position: 2, format: "Blu-ray", tracks: tracks)] + extraDiscs
        )
    }

    @Test func groupsSharedSongsAndKeepsEveryLocalBD() async throws {
        let (database, ids) = try await fixture(names: ["Band 1st LIVE", "Band 2nd LIVE"])
        #expect(ids.count == 2)
        for (index, id) in ids.enumerated() {
            try await database.saveConcertRelease(release(tracks: [
                ConcertTrack(position: 1, title: index == 0 ? "Ｆｉｒｅ  Song" : "fire song")
            ]), forAnimeID: id)
        }
        let songs = try await database.concertSongs()
        #expect(songs.count == 1)
        #expect(songs.first?.discCount == 2)
        #expect(songs.first?.artists == ["Band"])
        #expect(Set(songs[0].appearances.map { $0.concert.id }) == Set(ids))
    }

    @Test func excludesTalkExtrasCDsAndUnavailableNights() async throws {
        let (database, ids) = try await fixture()
        try await database.saveConcertRelease(release(tracks: [
            ConcertTrack(position: 1, title: "Song"),
            ConcertTrack(position: 2, title: "MC", kind: .talk),
            ConcertTrack(position: 3, title: "Making", kind: .bonus),
            ConcertTrack(position: 4, title: "Commentary", kind: .commentary),
            ConcertTrack(position: 5, title: "  ")
        ], extraDiscs: [
            ConcertDisc(position: 1, format: "CD", tracks: [ConcertTrack(position: 1, title: "Album only")]),
            ConcertDisc(position: 3, format: "Blu-ray", tracks: [ConcertTrack(position: 1, title: "Missing night")])
        ]), forAnimeID: ids[0])
        let songs = try await database.concertSongs()
        #expect(songs.map(\.title) == ["Song"])
        #expect(songs[0].appearances[0].discNumber == 1)
        #expect(songs[0].appearances[0].startTime == nil)
    }

    @Test func matchesTimesByPositionAfterProviderRecreatesTrackIDs() async throws {
        let (database, ids) = try await fixture()
        let episode = try #require(try await database.episodes(animeID: ids[0]).first)
        let oldTrack = ConcertTrack(position: 2, title: "Song")
        try await database.saveConcertSetlist(StoredConcertSetlist(
            episodeID: episode.id,
            alignment: ConcertSetlistAlignment(placements: [
                .init(trackID: oldTrack.id, trackPosition: 2, startTime: 123.5, chapterIndex: nil)
            ], method: .pasted, confidence: 1), isManual: true
        ))
        try await database.saveConcertRelease(release(tracks: [
            ConcertTrack(position: 2, title: "Song")
        ]), forAnimeID: ids[0])
        let appearance = try #require(try await database.concertSongs().first?.appearances.first)
        #expect(appearance.track.id != oldTrack.id)
        #expect(appearance.startTime == 123.5)
        #expect(appearance.timeline?.method == .pasted)
    }

    @Test func editsAndReclassificationUpdateTheDerivedLibrary() async throws {
        let (database, ids) = try await fixture()
        try await database.saveConcertRelease(release(tracks: [ConcertTrack(position: 1, title: "Old")]), forAnimeID: ids[0])
        #expect(try await database.concertSongs().map(\.title) == ["Old"])
        try await database.saveConcertRelease(release(tracks: [ConcertTrack(position: 1, title: "New")]), forAnimeID: ids[0])
        #expect(try await database.concertSongs().map(\.title) == ["New"])
        try await database.unmarkAnimeAsConcert(id: ids[0], manually: true)
        #expect(try await database.concertSongs().isEmpty)
    }

    @Test func keysPreserveDifferentSongsAndNormalizeUnicodeSpelling() {
        #expect(ConcertSongLibrary.key(for: "まだ") == ConcertSongLibrary.key(for: "まだ".decomposedStringWithCanonicalMapping))
        #expect(ConcertSongLibrary.key(for: "A-B") != ConcertSongLibrary.key(for: "AB"))
        #expect(ConcertSongLibrary.key(for: "é") != ConcertSongLibrary.key(for: "e"))
        #expect(ConcertSongLibrary.key(for: "Song (Acoustic)") == ConcertSongLibrary.key(for: "Song"))
    }

    @Test func keywordGroupingCombinesVersionsReadingsAndUnbalancedBrackets() async throws {
        let (database, ids) = try await fixture()
        let titles = ["迷星叫", "迷星叫）不插电版本", "迷星叫 ）miyuta", "迷星叫 (不插电版本", "迷星叫(まよいうた", "迷星叫前奏", "迷星叫 Piano ver", "迷星叫不插电版本", "迷星叫 (Mayoiuta)", "Band - Mayoiuta", "影色舞"]
        let tracks = titles.enumerated().map { ConcertTrack(position: $0.offset + 1, title: $0.element) }
        try await database.saveConcertRelease(release(tracks: tracks), forAnimeID: ids[0])
        let episode = try #require(try await database.episodes(animeID: ids[0]).first)
        try await database.saveConcertSetlist(StoredConcertSetlist(
            episodeID: episode.id,
            alignment: ConcertSetlistAlignment(placements: tracks.map {
                .init(trackID: $0.id, trackPosition: $0.position, startTime: Double($0.position * 100), chapterIndex: nil)
            }, method: .pasted, confidence: 1), isManual: true
        ))
        let songs = try await database.concertSongs()
        #expect(Set(songs.map(\.title)) == Set(["迷星叫", "影色舞"]))
        let song = try #require(songs.first { $0.title == "迷星叫" })
        #expect(song.appearances.count == 10)
        #expect(Set(song.appearances.map(\.track.title)) == Set(titles.dropLast()))
        #expect(Set(song.appearances.compactMap(\.startTime)) == Set((1...10).map { Double($0 * 100) }))
    }

    @Test func kanaAliasConnectsRomajiAndLatinKeywordsHaveWordBoundaries() async throws {
        let (database, ids) = try await fixture()
        let titles = ["迷星叫(まよいうた", "Band - Mayoiuta", "Fire", "Fire (Acoustic)", "Firefly", "形", "人の形", "é", "e"]
        try await database.saveConcertRelease(release(tracks: titles.enumerated().map {
            ConcertTrack(position: $0.offset + 1, title: $0.element)
        }), forAnimeID: ids[0])
        let songs = try await database.concertSongs()
        #expect(songs.first { $0.title == "迷星叫" }?.appearances.count == 2)
        #expect(songs.first { $0.title == "Fire" }?.appearances.count == 2)
        #expect(songs.first { $0.title == "Firefly" }?.appearances.count == 1)
        #expect(songs.contains { $0.title == "形" })
        #expect(songs.contains { $0.title == "人の形" })
        #expect(songs.contains { $0.title == "é" })
        #expect(songs.contains { $0.title == "e" })
    }

    @Test func oldPastedStageCuesAreExcludedAndEncoreSongsAreCombined() async throws {
        let (database, ids) = try await fixture()
        let titles = ["― MC ―", "― MC+新情报 ―", "― MC1―", "安可MC", "安可环节", "第二段MC", "谢幕", "― ending ―", "Encore Start - Narration 6", "音一会", "音一会 (ENCORE)", "Talk to Me"]
        try await database.saveConcertRelease(release(tracks: titles.enumerated().map {
            ConcertTrack(position: $0.offset + 1, title: $0.element)
        }), forAnimeID: ids[0])
        let songs = try await database.concertSongs()
        #expect(Set(songs.map(\.title)) == Set(["音一会", "Talk to Me"]))
        let encore = try #require(songs.first { $0.title == "音一会" })
        #expect(encore.appearances.count == 2)
        #expect(encore.discCount == 1)
    }

    @Test func secondNightUsesItsOwnVideoAndTimeAfterTheAlbumCD() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = LibraryRoot(displayName: "Live", lastKnownPath: "/concerts")
        try await database.save(root: root)
        try await database.importScan(LibraryScanResult(root: root, files: [1, 2].map { night in
            ScannedMediaFile(
                relativePath: "Band LIVE/DAY\(night)/live.iso", fileSize: 1000, modifiedAt: .now,
                parsed: ParsedAnimeFilename(title: "Band LIVE", episode: Double(night), episodeText: String(night), confidence: 1)
            )
        }, skippedUnreadableCount: 0))
        let id = try #require(try await database.library().first?.id)
        try await database.markAnimeAsConcert(id: id)
        let first = ConcertTrack(position: 1, title: "First night")
        let second = ConcertTrack(position: 1, title: "Second night")
        try await database.saveConcertRelease(ConcertRelease(
            provider: .localFiles, externalID: "box", title: "Album", discs: [
                ConcertDisc(position: 1, format: "CD", tracks: [ConcertTrack(position: 1, title: "Album")]),
                ConcertDisc(position: 2, format: "Blu-ray", tracks: [first]),
                ConcertDisc(position: 3, format: "Blu-ray", tracks: [second])
            ]
        ), forAnimeID: id)
        let episode = try #require(try await database.episodes(animeID: id).first { $0.episode.numberText == "2" })
        try await database.saveConcertSetlist(StoredConcertSetlist(
            episodeID: episode.id,
            alignment: ConcertSetlistAlignment(placements: [
                .init(trackID: second.id, trackPosition: 1, startTime: 456, chapterIndex: nil)
            ], method: .pasted, confidence: 1), isManual: true
        ))
        let songs = try await database.concertSongs()
        let appearance = try #require(songs.first { $0.title == "Second night" }?.appearances.first)
        #expect(appearance.episode.id == episode.id)
        #expect(appearance.discNumber == 2)
        #expect(appearance.startTime == 456)
        #expect(songs.count == 2)
    }
}
