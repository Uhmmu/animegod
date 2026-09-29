import AnimeGodCore
import Foundation

/// The last good answer to each read route, on disk.
///
/// Not a database — see §5 of the plan. The Mac has already run the queries
/// and resolved the display titles; what comes back is the answer, and the
/// phone's job is to keep the most recent one so the app opens instantly and
/// still reads with the Mac asleep.
struct LinkCache {
    private static var directory: URL {
        URL.documentsDirectory.appending(path: "LinkCache", directoryHint: .isDirectory)
    }

    private static func url(_ name: String) -> URL {
        directory.appending(path: "\(name).json")
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? LinkCoding.decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? LinkCoding.encoder.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Posters

    private static var posterDirectory: URL {
        directory.appending(path: "posters", directoryHint: .isDirectory)
    }

    static func posterURL(animeID: UUID) -> URL {
        posterDirectory.appending(path: "\(animeID.uuidString).img")
    }

    static func poster(animeID: UUID) -> Data? {
        try? Data(contentsOf: posterURL(animeID: animeID))
    }

    static func savePoster(_ data: Data, animeID: UUID) {
        try? FileManager.default.createDirectory(at: posterDirectory, withIntermediateDirectories: true)
        try? data.write(to: posterURL(animeID: animeID), options: .atomic)
    }
}

/// Writes the phone made that the Mac has not accepted yet.
///
/// The Mac's database is the single source of truth, so a progress write is
/// not applied locally and then reconciled — it is queued, sent, and the
/// answer is what counts. Queued writes survive a relaunch because the common
/// case for one failing is the Mac being asleep.
struct LinkOutbox {
    struct Entry: Codable, Identifiable, Sendable {
        let id: UUID
        let episodeID: UUID
        let update: LinkProgressUpdate
        let queuedAt: Date

        init(episodeID: UUID, update: LinkProgressUpdate) {
            self.id = UUID()
            self.episodeID = episodeID
            self.update = update
            self.queuedAt = .now
        }
    }

    private static let name = "outbox"

    static func pending() -> [Entry] {
        LinkCache.load([Entry].self, name) ?? []
    }

    /// One entry per episode: a later position supersedes an earlier one, and
    /// replaying every autosave from a whole episode would be pointless work.
    static func enqueue(_ entry: Entry) {
        var entries = pending().filter { $0.episodeID != entry.episodeID }
        entries.append(entry)
        LinkCache.save(entries, name)
    }

    static func remove(id: UUID) {
        LinkCache.save(pending().filter { $0.id != id }, name)
    }

    static func clear() {
        LinkCache.save([Entry](), name)
    }
}
