import Foundation

// Providers with a JSON search API. Each exposes a static `parse` so fixtures
// can be tested without the network.

private func jsonURL(_ base: String, _ items: [URLQueryItem]) -> URL {
    var components = URLComponents(string: base)!
    components.queryItems = items
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return components.url!
}

/// Decodes JSON, turning a body that isn't the expected shape into a parse
/// error rather than a silent empty result.
private func decode<T: Decodable>(_ type: T.Type, from data: Data, source: TorrentSourceID) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw TorrentSearchError.parse("\(source.rawValue): \(error.localizedDescription)")
    }
}

public struct AnimeToshoTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.animeTosho
    let http: TorrentHTTPClient

    public init(http: TorrentHTTPClient = TorrentHTTPClient()) { self.http = http }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        let url = jsonURL("https://feed.animetosho.org/json", [URLQueryItem(name: "q", value: query)])
        return Array(try Self.parse(try await http.get(url, accept: "application/json")).prefix(limit))
    }

    private struct Entry: Decodable {
        var title: String?
        var torrent_name: String?
        var link: String?
        var timestamp: Double?
        var torrent_url: String?
        var info_hash: String?
        var magnet_uri: String?
        var seeders: Int?
        var leechers: Int?
        var total_size: Int64?
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        try decode([Entry].self, from: data, source: .animeTosho).compactMap { entry in
            let magnet = entry.magnet_uri.flatMap(MagnetLink.init)
            guard let hash = entry.info_hash.flatMap(TorrentInfoHash.init) ?? magnet?.infoHash,
                  let title = (entry.torrent_name ?? entry.title)?.nilIfEmpty else { return nil }
            return TorrentObservation(
                source: .animeTosho,
                title: title,
                infoHash: hash,
                trackers: magnet?.trackers ?? [],
                size: entry.total_size,
                seeders: entry.seeders,
                leechers: entry.leechers,
                publishedAt: entry.timestamp.map { Date(timeIntervalSince1970: $0) },
                category: .episode,
                torrentURL: entry.torrent_url.flatMap(URL.init(string:)),
                pageURL: entry.link.flatMap(URL.init(string:)),
                sizeIsExact: entry.total_size != nil
            )
        }
    }
}

public struct BangumiMoeTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.bangumiMoe
    let http: TorrentHTTPClient

    public init(http: TorrentHTTPClient = TorrentHTTPClient()) { self.http = http }

    private struct Request: Encodable {
        var query: String
        var p: Int
    }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        let url = URL(string: "https://bangumi.moe/api/v2/torrent/search")!
        let data = try await http.postJSON(url, body: Request(query: query, p: 1))
        return Array(try Self.parse(data).prefix(limit))
    }

    private struct Response: Decodable {
        var torrents: [Entry]
    }

    private struct Entry: Decodable {
        struct Named: Decodable { var name: String? }
        var _id: String?
        var title: String?
        var infoHash: String?
        var magnet: String?
        var size: String?
        var seeders: Int?
        var leechers: Int?
        var publish_time: String?
        var team: Named?
        var category_tag: Named?
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        try decode(Response.self, from: data, source: .bangumiMoe).torrents.compactMap { entry in
            let magnet = entry.magnet.flatMap(MagnetLink.init)
            guard let hash = entry.infoHash.flatMap(TorrentInfoHash.init) ?? magnet?.infoHash,
                  let title = entry.title?.nilIfEmpty else { return nil }
            let category: TorrentCategory
            switch entry.category_tag?.name?.lowercased() ?? "" {
            case "donga", "episode": category = .episode
            case "collection": category = .batch
            case "raw": category = .raw
            case "music", "ost": category = .music
            case "comic", "game", "novel": return nil
            default: category = .other
            }
            return TorrentObservation(
                source: .bangumiMoe,
                title: title,
                infoHash: hash,
                trackers: magnet?.trackers ?? [],
                size: TorrentFieldParser.size(entry.size, decimal: true),
                seeders: entry.seeders,
                leechers: entry.leechers,
                publishedAt: TorrentFieldParser.isoDate(entry.publish_time),
                category: category,
                team: entry.team?.name,
                pageURL: entry._id.flatMap { URL(string: "https://bangumi.moe/torrent/\($0)") }
            )
        }
    }
}

public struct AnimeGardenTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.animeGarden
    let http: TorrentHTTPClient

    public init(http: TorrentHTTPClient = TorrentHTTPClient()) { self.http = http }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        // `search` is a JSON array of terms.
        let terms = String(decoding: try JSONEncoder().encode([query]), as: UTF8.self)
        let url = jsonURL("https://api.animes.garden/resources", [
            URLQueryItem(name: "search", value: terms),
            URLQueryItem(name: "pageSize", value: String(min(max(limit, 1), 100)))
        ])
        return Array(try Self.parse(try await http.get(url, accept: "application/json")).prefix(limit))
    }

    private struct Response: Decodable {
        var status: String?
        var resources: [Entry]
    }

    private struct Entry: Decodable {
        struct Named: Decodable { var name: String? }
        var title: String?
        var href: String?
        var type: String?
        var magnet: String?
        var size: Int64?
        var createdAt: String?
        var fansub: Named?
        var publisher: Named?
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        let response = try decode(Response.self, from: data, source: .animeGarden)
        if let status = response.status, status != "OK" {
            throw TorrentSearchError.parse("animeGarden status \(status)")
        }
        return response.resources.compactMap { entry in
            guard let magnet = entry.magnet.flatMap(MagnetLink.init),
                  let title = entry.title?.nilIfEmpty else { return nil }
            let category: TorrentCategory
            switch entry.type ?? "" {
            case "动画": category = .episode
            case "合集": category = .batch
            case "RAW": category = .raw
            case "音乐": category = .music
            case "漫画", "游戏", "小说": return nil
            default: category = .other
            }
            return TorrentObservation(
                source: .animeGarden,
                title: title,
                infoHash: magnet.infoHash,
                trackers: magnet.trackers,
                size: entry.size,
                publishedAt: TorrentFieldParser.isoDate(entry.createdAt),
                category: category,
                team: entry.fansub?.name,
                pageURL: entry.href.flatMap(URL.init(string:)),
                sizeIsExact: entry.size != nil
            )
        }
    }
}

/// SubsPlease publishes one magnet per resolution per episode.
public struct SubsPleaseTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.subsPlease
    let http: TorrentHTTPClient

    public init(http: TorrentHTTPClient = TorrentHTTPClient()) { self.http = http }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        let url = jsonURL("https://subsplease.org/api/", [
            URLQueryItem(name: "f", value: "search"),
            URLQueryItem(name: "tz", value: "UTC"),
            URLQueryItem(name: "s", value: query)
        ])
        return Array(try Self.parse(try await http.get(url, accept: "application/json")).prefix(limit))
    }

    private struct Entry: Decodable {
        struct Download: Decodable {
            var res: String?
            var magnet: String?
        }
        var release_date: String?
        var show: String?
        var episode: String?
        var page: String?
        var downloads: [Download]?
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        // No results come back as `[]` rather than `{}`.
        if (try? JSONDecoder().decode([Entry].self, from: data)) != nil { return [] }
        let entries = try decode([String: Entry].self, from: data, source: .subsPlease)
        return entries.sorted { $0.key < $1.key }.flatMap { _, entry -> [TorrentObservation] in
            let isBatch = entry.episode?.contains("-") ?? false
            return (entry.downloads ?? []).compactMap { download in
                guard let magnet = download.magnet.flatMap(MagnetLink.init) else { return nil }
                let title = magnet.displayName
                    ?? "[SubsPlease] \(entry.show ?? "") - \(entry.episode ?? "") (\(download.res ?? "")p)"
                return TorrentObservation(
                    source: .subsPlease,
                    title: title,
                    infoHash: magnet.infoHash,
                    trackers: magnet.trackers,
                    size: magnet.exactLength,
                    publishedAt: TorrentFieldParser.rfc822Date(entry.release_date),
                    category: isBatch ? .batch : .episode,
                    team: "SubsPlease",
                    pageURL: entry.page.flatMap { URL(string: "https://subsplease.org/shows/\($0)/") },
                    sizeIsExact: magnet.exactLength != nil
                )
            }
        }
    }
}

public enum TorrentProviders {
    /// Every built-in anime index.
    public static func all(http: TorrentHTTPClient = TorrentHTTPClient()) -> [TorrentSourceID: any TorrentSearchProvider] {
        let providers: [any TorrentSearchProvider] = [
            DmhyTorrentProvider(http: http),
            MikanTorrentProvider(http: http),
            BangumiMoeTorrentProvider(http: http),
            AnimeGardenTorrentProvider(http: http),
            AcgRipTorrentProvider(http: http),
            AcgnxTorrentProvider(http: http),
            NyaaTorrentProvider(http: http),
            AnimeToshoTorrentProvider(http: http),
            SubsPleaseTorrentProvider(http: http),
            TokyoToshoTorrentProvider(http: http)
        ]
        return Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
    }
}
