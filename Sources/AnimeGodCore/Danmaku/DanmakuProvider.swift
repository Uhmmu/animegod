import CryptoKit
import Foundation

/// Everything a provider may need to fetch one episode beyond its id.
/// Providers that identify an episode entirely by id ignore it.
public struct DanmakuFetchContext: Hashable, Sendable {
    /// The opaque state this provider stored on the match/episode
    /// (`DanmakuEpisodeRef.providerContext`).
    public var providerContext: String?
    /// Duration of the local file in seconds, when known. Bilibili's
    /// segmented endpoint needs it to know how many segments exist.
    public var mediaDuration: Double?

    public init(providerContext: String? = nil, mediaDuration: Double? = nil) {
        self.providerContext = providerContext
        self.mediaDuration = mediaDuration
    }

    public static let none = DanmakuFetchContext()
}

/// A source of danmaku. Providers translate their own API into the models
/// in DanmakuModels.swift; the engine and renderer only ever see those, so
/// additional providers can be added without touching rendering.
public protocol DanmakuProvider: Sendable {
    var metadata: DanmakuProviderMetadata { get }

    /// Whether the top candidate of an unconfirmed match (`isMatched ==
    /// false`) may still be bound without asking.
    ///
    /// It depends on what "ambiguous" means for the service. dandanplay's
    /// ambiguous candidates are usually the same episode listed under
    /// several entries, so binding the first is right and is the long-
    /// standing behavior. Bilibili's are different works that happen to
    /// share words in their titles, so binding one would put another show's
    /// comments over the video.
    var bindsAmbiguousMatches: Bool { get }

    /// Identifies a local video file and returns candidate episodes.
    func match(
        fileName: String,
        fileHash: String?,
        fileSize: Int64?,
        videoDuration: Double?
    ) async throws -> DanmakuMatchResult

    /// Identification enriched with what the local library already knows
    /// about the title. Providers that identify files by hash ignore it;
    /// providers that can only search (Bilibili) depend on it, because a
    /// release filename is a poor search query.
    func match(
        fileName: String,
        fileHash: String?,
        fileSize: Int64?,
        videoDuration: Double?,
        searchContext: DanmakuSearchContext?
    ) async throws -> DanmakuMatchResult

    /// Searches anime by title for manual episode selection.
    func searchAnime(query: String) async throws -> [DanmakuSearchedAnime]

    /// Fetches the comment list for one provider episode.
    func fetchComments(episodeID: Int64, context: DanmakuFetchContext) async throws -> [DanmakuComment]
}

public extension DanmakuProvider {
    var bindsAmbiguousMatches: Bool { true }

    /// Default: providers that gain nothing from local metadata fall back
    /// to plain file identification.
    func match(
        fileName: String,
        fileHash: String?,
        fileSize: Int64?,
        videoDuration: Double?,
        searchContext: DanmakuSearchContext?
    ) async throws -> DanmakuMatchResult {
        try await match(fileName: fileName, fileHash: fileHash, fileSize: fileSize, videoDuration: videoDuration)
    }

    /// Convenience for providers and callers that need no extra context.
    func fetchComments(episodeID: Int64) async throws -> [DanmakuComment] {
        try await fetchComments(episodeID: episodeID, context: .none)
    }

    /// Fetches the comments a ref points at, replaying the provider state
    /// the ref carries.
    func fetchComments(for ref: DanmakuEpisodeRef, mediaDuration: Double? = nil) async throws -> [DanmakuComment] {
        try await fetchComments(
            episodeID: ref.episodeID,
            context: DanmakuFetchContext(providerContext: ref.providerContext, mediaDuration: mediaDuration)
        )
    }
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
