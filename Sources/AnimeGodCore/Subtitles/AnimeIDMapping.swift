import Foundation

/// Maps an anime between databases (AniList / MAL → TMDB, IMDb, AniDB).
///
/// The library already stores AniList and MAL IDs in `externalAnimeID`;
/// subtitle sites index by TMDB or IMDb instead. Rather than a second anime
/// database, this reads the community Fribb anime-lists mapping
/// (github.com/Fribb/anime-lists, ~6 MB, refreshed upstream daily), caches it
/// beside the subtitle cache and refreshes it every two weeks. It is also how
/// the AniDB ID is obtained — without AniDB's rate-limited UDP API.
public actor AnimeIDMappingStore {
    public static let sourceURL = URL(string: "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-mini.json")!

    private let cacheURL: URL
    private let session: URLSession
    private let sourceURL: URL
    private let maximumAge: TimeInterval
    private var byAniList: [Int: SubtitleAnimeIDs]?
    private var byMAL: [Int: SubtitleAnimeIDs] = [:]
    private var loadTask: Task<Void, Never>?

    public init(
        cacheURL: URL,
        session: URLSession = .shared,
        sourceURL: URL = AnimeIDMappingStore.sourceURL,
        maximumAge: TimeInterval = 14 * 24 * 3600
    ) {
        self.cacheURL = cacheURL
        self.session = session
        self.sourceURL = sourceURL
        self.maximumAge = maximumAge
    }

    /// IDs known for the anime, or nil when the mapping has no entry (or
    /// could not be loaded — mapping is an enhancement, never required).
    public func ids(aniListID: Int?, malID: Int?) async -> SubtitleAnimeIDs? {
        guard aniListID != nil || malID != nil else { return nil }
        await loadIfNeeded()
        if let aniListID, let ids = byAniList?[aniListID] { return ids }
        if let malID, let ids = byMAL[malID] { return ids }
        return nil
    }

    private func loadIfNeeded() async {
        if byAniList != nil { return }
        if let loadTask { return await loadTask.value }
        let task = Task { await load() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func load() async {
        let fileManager = FileManager.default
        let modified = (try? fileManager.attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date
        var data = try? Data(contentsOf: cacheURL)
        if data == nil || modified.map({ Date.now.timeIntervalSince($0) > maximumAge }) ?? true {
            if let (fresh, response) = try? await session.data(from: sourceURL),
               (response as? HTTPURLResponse)?.statusCode == 200,
               Self.index(fresh) != nil {
                try? fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fresh.write(to: cacheURL, options: .atomic)
                data = fresh
            }
        }
        guard let data, let index = Self.index(data) else {
            // Stay empty for this run rather than retrying on every episode.
            byAniList = [:]
            return
        }
        byAniList = index.aniList
        byMAL = index.mal
    }

    static func index(_ data: Data) -> (aniList: [Int: SubtitleAnimeIDs], mal: [Int: SubtitleAnimeIDs])? {
        guard let entries = try? JSONDecoder().decode([FribbEntry].self, from: data), !entries.isEmpty else { return nil }
        var aniList: [Int: SubtitleAnimeIDs] = [:]
        var mal: [Int: SubtitleAnimeIDs] = [:]
        for entry in entries {
            let ids = SubtitleAnimeIDs(
                aniListID: entry.anilist_id,
                malID: entry.mal_id,
                aniDBID: entry.anidb_id,
                tmdbID: entry.themoviedb_id?.id,
                tmdbKind: entry.themoviedb_id?.kind,
                tmdbSeason: entry.season?.tmdb,
                imdbID: entry.imdb_id?.first
            )
            if let id = entry.anilist_id { aniList[id] = ids }
            if let id = entry.mal_id { mal[id] = ids }
        }
        return (aniList, mal)
    }
}

/// One record of the Fribb mapping. Fields vary in shape between records
/// (an IMDb ID may be a string or a list), so decoding is lenient.
struct FribbEntry: Decodable {
    struct TMDB: Decodable {
        let id: Int
        let kind: SubtitleAnimeIDs.TMDBKind

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer().decode(Int.self) {
                id = single
                kind = .tv
                return
            }
            let container = try decoder.container(keyedBy: DynamicKey.self)
            if let tv = try? container.decode(Int.self, forKey: DynamicKey("tv")) {
                id = tv
                kind = .tv
            } else if let movie = try? container.decode(Int.self, forKey: DynamicKey("movie")) {
                id = movie
                kind = .movie
            } else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No TMDB id"))
            }
        }
    }

    struct Season: Decodable {
        let tmdb: Int?
    }

    struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    let anilist_id: Int?
    let mal_id: Int?
    let anidb_id: Int?
    let themoviedb_id: TMDB?
    let imdb_id: [String]?
    let season: Season?

    private enum CodingKeys: String, CodingKey {
        case anilist_id, mal_id, anidb_id, themoviedb_id, imdb_id, season
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        anilist_id = try? container.decode(Int.self, forKey: .anilist_id)
        mal_id = try? container.decode(Int.self, forKey: .mal_id)
        anidb_id = try? container.decode(Int.self, forKey: .anidb_id)
        themoviedb_id = try? container.decode(TMDB.self, forKey: .themoviedb_id)
        imdb_id = (try? container.decode([String].self, forKey: .imdb_id))
            ?? (try? container.decode(String.self, forKey: .imdb_id)).map { [$0] }
        season = try? container.decode(Season.self, forKey: .season)
    }
}

/// Picks the AniList entry for a work only known from Bangumi. Accepts a
/// candidate only when a title is near-identical and, where both sides
/// know it, the premiere year agrees — a wrong ID would search for another
/// show's subtitles with high confidence.
public enum SubtitleIdentityResolver {
    public static func bestAniListID(
        candidates: [AnimeMetadataCandidate],
        titles: [String],
        airDate: String?
    ) -> Int? {
        let year = airDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
        var best: (id: Int, similarity: Double)?
        for candidate in candidates where candidate.provider == .anilist {
            guard let id = Int(candidate.externalID) else { continue }
            if let year, let candidateYear = candidate.airDate.flatMap({ $0.count >= 4 ? String($0.prefix(4)) : nil }),
               year != candidateYear { continue }
            let similarity = titles.flatMap { title in
                [candidate.title, candidate.originalTitle].map { DanmakuTitleSimilarity.similarityOfRawTitles(title, $0) }
            }.max() ?? 0
            if similarity >= 0.88, similarity > (best?.similarity ?? 0) { best = (id, similarity) }
        }
        return best?.id
    }
}
