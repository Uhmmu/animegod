import CryptoKit
import Foundation

/// A source of danmaku. Providers translate their own API into the models
/// in DanmakuModels.swift; the engine and renderer only ever see those, so
/// additional providers can be added without touching rendering.
public protocol DanmakuProvider: Sendable {
    var metadata: DanmakuProviderMetadata { get }

    /// Identifies a local video file and returns candidate episodes.
    func match(
        fileName: String,
        fileHash: String?,
        fileSize: Int64?,
        videoDuration: Double?
    ) async throws -> DanmakuMatchResult

    /// Searches anime by title for manual episode selection.
    func searchAnime(query: String) async throws -> [DanmakuSearchedAnime]

    /// Fetches the comment list for one provider episode.
    func fetchComments(episodeID: Int64) async throws -> [DanmakuComment]
}

/// Computes the file identity hash providers ask for. dandanplay's
/// specification: the MD5 digest of the first 16 MB of the file, sent as a
/// lowercase hex string; files smaller than 16 MB hash their entire content.
public enum DanmakuFileHasher {
    public static let hashedByteCount = 16 * 1024 * 1024

    public static func hashFile(at url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= hashedByteCount else { return nil }
        try handle.seek(toOffset: 0)
        var hasher = Insecure.MD5()
        var remaining = hashedByteCount
        let chunkSize = 1024 * 1024
        while remaining > 0 {
            let chunk = try handle.read(upToCount: min(chunkSize, remaining))
            guard let chunk, !chunk.isEmpty else { return nil }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
