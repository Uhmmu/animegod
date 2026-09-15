import Foundation

/// Danmaku from Bilibili, as an alternative or a complement to dandanplay.
///
/// Unlike dandanplay, Bilibili has no file-identity API: nothing maps an
/// encode's hash to a video. Identification therefore goes
/// title + episode → search → season/submission → **the part's own `cid`**,
/// and the `cid` is the danmaku pool id from then on.
///
/// The provider is self-contained: the API, the protobuf decoding and the
/// matching all live in `Danmaku/Bilibili/`, and the player only ever sees
/// `DanmakuComment`s. Every failure is a status, never an exception the
/// playback path has to handle.
public struct BilibiliDanmakuProvider: DanmakuProvider {
    public static let providerID = "bilibili"

    public let metadata = DanmakuProviderMetadata(
        id: BilibiliDanmakuProvider.providerID,
        displayName: "Bilibili",
        attribution: "Danmaku from Bilibili (哔哩哔哩)"
    )

    /// Bilibili candidates below the confidence threshold are different
    /// works, not other listings of the same episode, so they are only ever
    /// offered in the match sheet.
    public let bindsAmbiguousMatches = false

    public struct Configuration: Sendable {
        /// How many search hits get expanded into full episode lists. Each
        /// expansion is one more request, so this is deliberately small.
        public var expandedHitLimit = 4
        /// Drops comments below Bilibili's own quality weight. 0 keeps
        /// everything, which is the default: the player has its own filters.
        public var minimumWeight: Int32 = 0
        /// Uses the legacy XML pool when the segmented endpoint yields
        /// nothing. Off by default — the XML pool is a sampled subset.
        public var allowsLegacyXMLFallback = false

        public init() {}
    }

    private let client: BilibiliAPIClient
    private let configuration: Configuration
    private let parser = AnimeFilenameParser()

    public init(session: BilibiliSession, configuration: Configuration = Configuration()) {
        client = BilibiliAPIClient(session: session)
        self.configuration = configuration
    }

    // MARK: - Identification

    public func match(
        fileName: String,
        fileHash: String?,
        fileSize: Int64?,
        videoDuration: Double?
    ) async throws -> DanmakuMatchResult {
        try await match(
            fileName: fileName, fileHash: fileHash, fileSize: fileSize,
            videoDuration: videoDuration, searchContext: nil
        )
    }

    public func match(
        fileName: String,
        fileHash: String?,
        fileSize: Int64?,
        videoDuration: Double?,
        searchContext: DanmakuSearchContext?
    ) async throws -> DanmakuMatchResult {
        // The filename is the fallback source of a title and episode number;
        // library metadata, when the caller has it, is far more reliable.
        let parsed = parser.parse(url: URL(fileURLWithPath: fileName))
        var titles = searchContext?.titleCandidates ?? []
        if !parsed.title.isEmpty { titles.append(parsed.title) }
        let context = BilibiliDanmakuMatcher.Context(
            titleCandidates: deduplicated(titles),
            episodeNumber: searchContext?.episodeNumber ?? parsed.episode,
            episodeKind: searchContext?.episodeKind ?? parsed.episodeKind,
            duration: videoDuration,
            seasonNumber: parsed.season
        )
        let candidates = try await candidates(for: context)
        // "Matched" means confident enough to use without asking. Below the
        // threshold the candidates are still returned, for the match sheet.
        let isMatched = (candidates.first?.score ?? 0) >= BilibiliDanmakuMatcher.automaticSelectionThreshold
        return DanmakuMatchResult(
            isMatched: isMatched,
            candidates: candidates.map(\.matchCandidate)
        )
    }

    /// Runs the full search → expand → rank pipeline. Exposed so callers
    /// that already hold rich metadata can skip filename parsing entirely.
    public func candidates(for context: BilibiliDanmakuMatcher.Context) async throws -> [BilibiliMatchCandidate] {
        let queries = searchQueries(for: context)
        guard !queries.isEmpty else { return [] }

        var hits: [BilibiliSearchHit] = []
        var lastError: Error?
        for query in queries {
            do {
                hits += try await client.searchAll(keyword: query)
            } catch {
                lastError = error
            }
            // One good search page is enough; more queries only add noise.
            if !BilibiliDanmakuMatcher.rankHits(hits, context: context).isEmpty { break }
        }
        if hits.isEmpty, let lastError { throw lastError }

        let ranked = BilibiliDanmakuMatcher.rankHits(deduplicated(hits), context: context)
        var candidates: [BilibiliMatchCandidate] = []
        for entry in ranked.prefix(max(1, configuration.expandedHitLimit)) {
            candidates += (try? await expand(entry.hit, score: entry.score, context: context)) ?? []
        }
        return BilibiliDanmakuMatcher.rank(candidates)
    }

    /// Turns one search hit into its episodes, each with its own `cid`.
    private func expand(
        _ hit: BilibiliSearchHit,
        score: Double,
        context: BilibiliDanmakuMatcher.Context
    ) async throws -> [BilibiliMatchCandidate] {
        switch hit {
        case let .bangumi(item):
            let season = try await client.season(seasonID: item.seasonID)
            return BilibiliDanmakuMatcher.rankSeasonEpisodes(season, seasonScore: score, context: context)
        case let .video(item):
            let video = try await client.video(bvid: item.bvid.isEmpty ? nil : item.bvid, aid: item.aid)
            return BilibiliDanmakuMatcher.rankVideoParts(video, videoScore: score, context: context)
        }
    }

    // MARK: - Manual search

    public func searchAnime(query: String) async throws -> [DanmakuSearchedAnime] {
        let hits = deduplicated(try await client.searchAll(keyword: query))
        var results: [DanmakuSearchedAnime] = []
        for hit in hits.prefix(max(1, configuration.expandedHitLimit)) {
            switch hit {
            case let .bangumi(item):
                guard let season = try? await client.season(seasonID: item.seasonID) else { continue }
                results.append(DanmakuSearchedAnime(
                    animeID: season.seasonID,
                    animeTitle: season.title.isEmpty ? item.title : season.title,
                    typeDescription: season.seasonTypeName,
                    episodes: season.episodes
                        .filter { $0.cid > 0 }
                        .map { episode in
                            DanmakuSearchedEpisode(
                                episodeID: episode.cid,
                                episodeTitle: episode.displayTitle,
                                providerContext: BilibiliDanmakuContext(
                                    cid: episode.cid,
                                    aid: episode.aid > 0 ? episode.aid : nil,
                                    bvid: episode.bvid.isEmpty ? nil : episode.bvid,
                                    seasonID: season.seasonID,
                                    episodeID: episode.episodeID > 0 ? episode.episodeID : nil,
                                    duration: episode.duration > 0 ? episode.duration : nil
                                ).encoded()
                            )
                        },
                    providerID: metadata.id
                ))
            case let .video(item):
                guard let video = try? await client.video(bvid: item.bvid.isEmpty ? nil : item.bvid, aid: item.aid) else { continue }
                results.append(DanmakuSearchedAnime(
                    animeID: video.aid,
                    animeTitle: video.title.isEmpty ? item.title : video.title,
                    typeDescription: video.typeName,
                    episodes: video.parts
                        .filter { $0.cid > 0 }
                        .map { part in
                            DanmakuSearchedEpisode(
                                episodeID: part.cid,
                                episodeTitle: part.title.isEmpty ? "P\(part.page)" : part.title,
                                providerContext: BilibiliDanmakuContext(
                                    cid: part.cid,
                                    aid: video.aid > 0 ? video.aid : nil,
                                    bvid: video.bvid.isEmpty ? nil : video.bvid,
                                    duration: part.duration > 0 ? part.duration : nil
                                ).encoded()
                            )
                        },
                    providerID: metadata.id
                ))
            }
        }
        return results
    }

    // MARK: - Comments

    /// Downloads every six-minute segment of one pool and converts it.
    ///
    /// `episodeID` is the `cid`. The stored provider context supplies `aid`
    /// (sent as `pid`) and Bilibili's own duration; the caller's media
    /// duration wins when both are known, since it describes the file
    /// actually being played.
    public func fetchComments(episodeID: Int64, context: DanmakuFetchContext) async throws -> [DanmakuComment] {
        let stored = BilibiliDanmakuContext.decode(context.providerContext)
        let cid = stored?.cid ?? episodeID
        guard cid > 0 else { throw DanmakuProviderError.invalidResponse }
        let duration = context.mediaDuration ?? stored?.duration

        var seen = Set<String>()
        var elements: [BilibiliDanmakuElem] = []
        let plannedSegments = duration.map { BilibiliAPIClient.segmentCount(forDuration: $0) }
            ?? BilibiliAPIClient.maximumSegments

        for index in 1...plannedSegments {
            // nil means "no such segment": the pool ends here.
            guard let segment = try await client.danmakuSegment(cid: cid, aid: stored?.aid, index: index) else { break }
            for element in segment where seen.insert(element.stableID).inserted {
                elements.append(element)
            }
            // Without a known duration the only stop signal is an empty
            // segment, so the sweep cannot run away.
            if duration == nil, segment.isEmpty { break }
        }

        if elements.isEmpty, configuration.allowsLegacyXMLFallback {
            elements = (try? await client.legacyXMLDanmaku(cid: cid)) ?? []
        }

        let minimumWeight = configuration.minimumWeight
        return elements
            .filter { minimumWeight <= 0 || $0.weight >= minimumWeight }
            .compactMap { $0.makeComment(providerID: metadata.id) }
            .sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    }

    // MARK: - Helpers

    private func searchQueries(for context: BilibiliDanmakuMatcher.Context) -> [String] {
        DanmakuAutoMatcher.searchQueries(
            for: DanmakuSearchContext(
                titleCandidates: context.titleCandidates,
                episodeNumber: context.episodeNumber,
                episodeKind: context.episodeKind
            ),
            limit: 3
        )
    }

    private func deduplicated(_ titles: [String]) -> [String] {
        var seen = Set<String>()
        return titles.filter { title in
            let key = DanmakuTitleSimilarity.normalize(title)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private func deduplicated(_ hits: [BilibiliSearchHit]) -> [BilibiliSearchHit] {
        var seen = Set<BilibiliSearchHit>()
        return hits.filter { seen.insert($0).inserted }
    }
}
