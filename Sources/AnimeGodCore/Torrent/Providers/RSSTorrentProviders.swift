import Foundation

// Providers whose search API is an RSS feed. Each exposes a static `parse`
// so fixtures can be tested without the network.

private func searchURL(_ base: String, _ items: [URLQueryItem]) -> URL {
    var components = URLComponents(string: base)!
    components.queryItems = items
    // "+" is literal in URLComponents; indexes read it as a space either way,
    // but a literal "+" in a title ("Re:Zero +") must survive.
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return components.url!
}

/// dmhy / ACGNX share the 動畫 / 季度全集 / 音樂 taxonomy. Manga, games and
/// novels return nil and are dropped.
private func chineseIndexCategory(_ name: String?) -> TorrentCategory? {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return .other }
    let folded = name.folding(options: .widthInsensitive, locale: nil).uppercased()
    if ["漫畫", "漫画", "港台原版", "日文原版", "遊戲", "游戏", "電腦遊戲", "電視遊戲", "小說", "小说"].contains(where: folded.contains) {
        return nil
    }
    if folded.contains("季度全集") || folded.contains("合集") { return .batch }
    if folded.contains("RAW") { return .raw }
    if folded.contains("音樂") || folded.contains("音乐") { return .music }
    if folded.contains("動畫") || folded.contains("动画") { return .episode }
    return .other
}

public struct DmhyTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.dmhy
    let http: TorrentHTTPClient

    public init(http: TorrentHTTPClient = TorrentHTTPClient()) { self.http = http }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        let url = searchURL("https://share.dmhy.org/topics/rss/rss.xml", [URLQueryItem(name: "keyword", value: query)])
        return Array(try Self.parse(try await http.get(url, accept: "application/rss+xml, application/xml")).prefix(limit))
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        try RSSFeed.items(from: data).compactMap { item in
            guard let title = item["title"],
                  let magnet = item.attributes["enclosure"]?["url"].flatMap(MagnetLink.init),
                  let category = chineseIndexCategory(item["category"]) else { return nil }
            return TorrentObservation(
                source: .dmhy,
                title: title,
                infoHash: magnet.infoHash,
                trackers: magnet.trackers,
                publishedAt: TorrentFieldParser.rfc822Date(item["pubDate"]),
                category: category,
                pageURL: TorrentFieldParser.url(item["link"])
            )
        }
    }
}

public struct MikanTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.mikan
    let http: TorrentHTTPClient

    public init(http: TorrentHTTPClient = TorrentHTTPClient()) { self.http = http }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        let url = searchURL("https://mikanani.me/RSS/Search", [URLQueryItem(name: "searchstr", value: query)])
        return Array(try Self.parse(try await http.get(url, accept: "application/rss+xml, application/xml")).prefix(limit))
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        try RSSFeed.items(from: data).compactMap { item in
            // Mikan's episode page is named by the info hash itself.
            guard let title = item["title"] ?? item["guid"],
                  let hash = TorrentFieldParser.hash(inText: item["link"]) else { return nil }
            let enclosure = item.attributes["enclosure"]
            let length = item["contentLength"].flatMap { Int64($0) } ?? enclosure?["length"].flatMap { Int64($0) }
            return TorrentObservation(
                source: .mikan,
                title: title,
                infoHash: hash,
                size: length,
                // Mikan timestamps carry no zone; the site runs on UTC+8.
                publishedAt: TorrentFieldParser.isoDate(item["pubDate"], defaultTimeZone: TimeZone(secondsFromGMT: 8 * 3600)!),
                category: .episode,
                torrentURL: TorrentFieldParser.url(enclosure?["url"]),
                pageURL: TorrentFieldParser.url(item["link"]),
                sizeIsExact: length != nil
            )
        }
    }
}

public struct AcgnxTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.acgnx
    let http: TorrentHTTPClient

    public init(http: TorrentHTTPClient = TorrentHTTPClient()) { self.http = http }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        let url = searchURL("https://share.acgnx.se/rss.xml", [URLQueryItem(name: "keyword", value: query)])
        return Array(try Self.parse(try await http.get(url, accept: "application/rss+xml, application/xml")).prefix(limit))
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        try RSSFeed.items(from: data).compactMap { item in
            guard let title = item["title"],
                  let category = chineseIndexCategory(item["category"]) else { return nil }
            let magnet = item.attributes["enclosure"]?["url"].flatMap(MagnetLink.init)
            guard let hash = magnet?.infoHash ?? TorrentFieldParser.hash(inText: item["link"]) else { return nil }
            // Description: "<a>team | title</a> | 9.4GB | 季度全集 | hash"
            let size = item["description"]?.components(separatedBy: " | ").lazy.compactMap { part -> Int64? in
                part.count < 16 ? TorrentFieldParser.size(part) : nil
            }.first
            // `author` is the uploading account (often a mirror bot such as
            // 動漫花園鏡像), not the fansub, so it is not used as the team.
            return TorrentObservation(
                source: .acgnx,
                title: title,
                infoHash: hash,
                trackers: magnet?.trackers ?? [],
                size: size,
                publishedAt: TorrentFieldParser.rfc822Date(item["pubDate"]),
                category: category,
                pageURL: TorrentFieldParser.url(item["link"])
            )
        }
    }
}

public struct NyaaTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.nyaa
    let http: TorrentHTTPClient
    let mirrors: [String]

    public init(http: TorrentHTTPClient = TorrentHTTPClient(), mirrors: [String] = ["https://nyaa.si", "https://nyaa.land"]) {
        self.http = http
        self.mirrors = mirrors
    }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        var lastError: Error = TorrentSearchError.network("no mirror reachable")
        for mirror in mirrors {
            // c=1_0 is the Anime category; sukebei is a different host and
            // is never queried.
            let url = searchURL("\(mirror)/", [
                URLQueryItem(name: "page", value: "rss"),
                URLQueryItem(name: "c", value: "1_0"),
                URLQueryItem(name: "f", value: "0"),
                URLQueryItem(name: "q", value: query)
            ])
            do {
                return Array(try Self.parse(try await http.get(url, accept: "application/rss+xml, application/xml")).prefix(limit))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        try RSSFeed.items(from: data).compactMap { item in
            guard let title = item["title"],
                  let hash = item["nyaa:infoHash"].flatMap(TorrentInfoHash.init) else { return nil }
            let categoryID = item["nyaa:categoryId"] ?? ""
            // Only the Anime subcategories: 1_1 AMV, 1_2 English, 1_3 non-English, 1_4 Raw.
            guard categoryID.hasPrefix("1_") else { return nil }
            let category: TorrentCategory = switch categoryID {
            case "1_4": .raw
            case "1_1": .other
            default: .episode
            }
            return TorrentObservation(
                source: .nyaa,
                title: title,
                infoHash: hash,
                trackers: ["http://nyaa.tracker.wf:7777/announce"],
                size: TorrentFieldParser.size(item["nyaa:size"]),
                seeders: item["nyaa:seeders"].flatMap { Int($0) },
                leechers: item["nyaa:leechers"].flatMap { Int($0) },
                publishedAt: TorrentFieldParser.rfc822Date(item["pubDate"]),
                category: category,
                torrentURL: TorrentFieldParser.url(item["link"]),
                pageURL: TorrentFieldParser.url(item["guid"])
            )
        }
    }
}

public struct TokyoToshoTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.tokyoTosho
    let http: TorrentHTTPClient

    public init(http: TorrentHTTPClient = TorrentHTTPClient()) { self.http = http }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        let url = searchURL("https://www.tokyotosho.info/rss.php", [URLQueryItem(name: "terms", value: query)])
        return Array(try Self.parse(try await http.get(url, accept: "application/rss+xml, application/xml")).prefix(limit))
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        try RSSFeed.items(from: data).compactMap { item in
            // The feed mixes every category regardless of the `type`
            // parameter, hentai and JAV included, so filter by name here.
            let category: TorrentCategory
            switch item["category"] ?? "" {
            case "Anime", "Non-English": category = .episode
            case "Batch": category = .batch
            case "Raws": category = .raw
            case "Music", "Music Video": category = .music
            case "Drama", "Other": category = .other
            default: return nil
            }
            guard let title = item["title"], let description = item["description"],
                  let magnetText = TorrentReleaseInfo.firstCapture(#"href="(magnet:\?[^"]+)""#, in: description),
                  let magnet = MagnetLink(magnetText.replacingOccurrences(of: "&amp;", with: "&")) else { return nil }
            return TorrentObservation(
                source: .tokyoTosho,
                title: title,
                infoHash: magnet.infoHash,
                trackers: magnet.trackers,
                size: TorrentReleaseInfo.firstCapture(#"Size:\s*([^<]+)"#, in: description).flatMap { TorrentFieldParser.size($0) },
                publishedAt: TorrentFieldParser.rfc822Date(item["pubDate"]),
                category: category,
                torrentURL: TorrentFieldParser.url(item["link"]),
                pageURL: TorrentFieldParser.url(item["guid"])
            )
        }
    }
}

/// ACG.RIP's feed has no info hash or magnet, only `.torrent` links, so the
/// hash comes from downloading each torrent (a few KB) and hashing its
/// `info` dictionary. Fetches are capped and run a few at a time.
public struct AcgRipTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.acgRip
    let http: TorrentHTTPClient
    let maximumTorrentFetches: Int

    public init(http: TorrentHTTPClient = TorrentHTTPClient(), maximumTorrentFetches: Int = 30) {
        self.http = http
        self.maximumTorrentFetches = maximumTorrentFetches
    }

    struct Listing: Sendable {
        var title: String
        var torrentURL: URL
        var pageURL: URL?
        var size: Int64?
        var publishedAt: Date?
    }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        let url = searchURL("https://acg.rip/.xml", [URLQueryItem(name: "term", value: query)])
        let listings = Array(try Self.parse(try await http.get(url, accept: "application/rss+xml, application/xml"))
            .prefix(min(limit, maximumTorrentFetches)))
        let client = http
        var resolved: [Int: TorrentObservation] = [:]
        try await withThrowingTaskGroup(of: (Int, TorrentObservation?).self) { group in
            var next = 0
            func enqueue() {
                guard next < listings.count else { return }
                let index = next
                let listing = listings[index]
                next += 1
                group.addTask {
                    guard let data = try? await client.get(listing.torrentURL, accept: "application/x-bittorrent"),
                          let file = try? TorrentFile(data: data) else { return (index, nil) }
                    return (index, TorrentObservation(
                        source: .acgRip,
                        title: listing.title,
                        infoHash: file.infoHash,
                        trackers: file.announce,
                        size: listing.size ?? file.totalSize,
                        publishedAt: listing.publishedAt,
                        category: .episode,
                        torrentURL: listing.torrentURL,
                        pageURL: listing.pageURL,
                        sizeIsExact: true
                    ))
                }
            }
            for _ in 0..<4 { enqueue() }
            while let (index, observation) = try await group.next() {
                try Task.checkCancellation()
                if let observation { resolved[index] = observation }
                enqueue()
            }
        }
        return resolved.sorted { $0.key < $1.key }.map(\.value)
    }

    static func parse(_ data: Data) throws -> [Listing] {
        try RSSFeed.items(from: data).compactMap { item in
            guard let title = item["title"],
                  let torrentURL = TorrentFieldParser.url(item.attributes["enclosure"]?["url"]) else { return nil }
            return Listing(
                title: title,
                torrentURL: torrentURL,
                pageURL: TorrentFieldParser.url(item["link"]),
                size: item["torrent:contentLength"].flatMap { Int64($0) },
                publishedAt: TorrentFieldParser.rfc822Date(item["pubDate"])
            )
        }
    }
}
