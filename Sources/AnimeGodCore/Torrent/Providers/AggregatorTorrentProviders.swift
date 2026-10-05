import Foundation

// General indexes, ported from the magnet-crawler project.
//
// Every other provider here is an *anime* index, and for a season that is the
// right place to look. A concert Blu-ray is not filed as anime: the real
// library's live discs come from DBD-Raws, which these three carry and
// several of the anime indexes do not. Knaben is an aggregator over dozens of
// trackers, torrents-csv is a public dump with exact byte counts, and
// BitSearch is a search page scraped for its magnet links.
//
// They answer about everything, not only anime, which is the point and also
// the cost: the relevance scoring is what keeps a search for one concert from
// returning the rest of the internet.

/// knaben.org — one API over dozens of trackers, Nyaa among them.
///
/// `hide_xxx` and `hide_unsafe` are sent true and are not an option: an
/// aggregator with the adult trackers in it has no business answering a
/// search for a live Blu-ray with anything else.
public struct KnabenTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.knaben
    let http: TorrentHTTPClient
    let endpoint: URL

    public init(
        http: TorrentHTTPClient = TorrentHTTPClient(),
        endpoint: URL = URL(string: "https://api.knaben.org/v1")!
    ) {
        self.http = http
        self.endpoint = endpoint
    }

    private struct Request: Encodable {
        let query: String
        let order_by = "seeders"
        let order_direction = "desc"
        let from = 0
        let size: Int
        let hide_unsafe = true
        let hide_xxx = true
    }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        let size = max(10, min(limit, 150))
        // POST first; some networks answer it with an interstitial, and the
        // same query works as a GET.
        do {
            let data = try await http.postJSON(endpoint, body: Request(query: query, size: size))
            let parsed = try Self.parse(data)
            if !parsed.isEmpty { return Array(parsed.prefix(limit)) }
        } catch TorrentSearchError.blocked {
        } catch TorrentSearchError.http {
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "order_by", value: "seeders"),
            URLQueryItem(name: "order_direction", value: "desc"),
            URLQueryItem(name: "from", value: "0"),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "hide_xxx", value: "true"),
            URLQueryItem(name: "hide_unsafe", value: "true")
        ]
        return Array(try Self.parse(try await http.get(components.url!, accept: "application/json")).prefix(limit))
    }

    private struct Payload: Decodable {
        var hits: [Hit]?
        struct Hit: Decodable {
            var hash: String?
            var title: String?
            var magnetUrl: String?
            var link: String?
            var details: String?
            var seeders: Int?
            var peers: Int?
            var bytes: Int64?
            var date: String?
            var category: String?
            var cachedOrigin: String?
            var tracker: String?
        }
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw TorrentSearchError.parse("knaben: \(error.localizedDescription)")
        }
        return (payload.hits ?? []).compactMap { hit in
            let magnet = hit.magnetUrl.flatMap(MagnetLink.init)
            guard let hash = hit.hash.flatMap(TorrentInfoHash.init) ?? magnet?.infoHash,
                  let title = hit.title?.nilIfEmpty
            else { return nil }
            // A torrent file is only offered when the link really is one; the
            // aggregator also puts the tracker's own detail page in `link`.
            let torrentURL = hit.link.flatMap { link -> URL? in
                guard link.contains(".torrent") || link.contains("/dl/") else { return nil }
                return URL(string: link)
            }
            return TorrentObservation(
                source: .knaben,
                title: title,
                infoHash: hash,
                trackers: magnet?.trackers ?? [],
                size: hit.bytes.flatMap { $0 > 0 ? $0 : nil },
                seeders: hit.seeders,
                // Knaben's `peers` is the leecher count.
                leechers: hit.peers,
                publishedAt: hit.date.flatMap(Self.date(from:)),
                category: Self.category(hit.category),
                // Which tracker it was indexed from — worth keeping, since one
                // aggregator hit can stand for several of them.
                team: (hit.cachedOrigin ?? hit.tracker)?.nilIfEmpty,
                torrentURL: torrentURL,
                pageURL: hit.details.flatMap(URL.init(string:)),
                sizeIsExact: hit.bytes != nil
            )
        }
    }

    /// `2024-07-27T00:00:00` or the same with a zone — the aggregator is not
    /// consistent, so both are tried and neither is required.
    static func date(from text: String) -> Date? {
        let withZone = ISO8601DateFormatter()
        withZone.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withZone.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = TimeZone(identifier: "UTC")
        naive.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return naive.date(from: text)
    }

    static func category(_ raw: String?) -> TorrentCategory {
        guard let raw = raw?.lowercased() else { return .other }
        if raw.contains("anime") { return .episode }
        if raw.contains("audio") || raw.contains("music") { return .music }
        return .raw
    }
}

/// torrents-csv.com — a public dump with exact byte counts and no blocking.
///
/// The simplest of the three and the one most likely to still answer when the
/// others are behind a challenge page: static JSON, no cookies, no key.
public struct TorrentsCsvTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.torrentsCsv
    let http: TorrentHTTPClient
    let endpoint: String

    public init(
        http: TorrentHTTPClient = TorrentHTTPClient(),
        endpoint: String = "https://torrents-csv.com/service/search"
    ) {
        self.http = http
        self.endpoint = endpoint
    }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "size", value: String(max(25, min(limit, 100))))
        ]
        return Array(try Self.parse(try await http.get(components.url!, accept: "application/json")).prefix(limit))
    }

    private struct Payload: Decodable {
        var torrents: [Entry]?
        struct Entry: Decodable {
            var infohash: String?
            var name: String?
            var size_bytes: Int64?
            var seeders: Int?
            var leechers: Int?
            var created_unix: Double?
        }
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw TorrentSearchError.parse("torrents-csv: \(error.localizedDescription)")
        }
        return (payload.torrents ?? []).compactMap { entry in
            guard let hash = entry.infohash.flatMap(TorrentInfoHash.init),
                  let title = entry.name?.nilIfEmpty
            else { return nil }
            return TorrentObservation(
                source: .torrentsCsv,
                title: title,
                infoHash: hash,
                size: entry.size_bytes.flatMap { $0 > 0 ? $0 : nil },
                seeders: entry.seeders,
                leechers: entry.leechers,
                publishedAt: entry.created_unix.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                // `.raw` rather than `.other`: these are raw release
                // files, and `.other` is hidden by the default filter — a
                // source nobody can see is a source nobody added.
                category: .raw,
                sizeIsExact: entry.size_bytes != nil
            )
        }
    }
}

/// bitsearch.to — a search page, read for the magnet links in it.
///
/// The only one of the three with no API, so it is scraped: every `magnet:`
/// link on the page, with the title taken from the link's own `dn` rather
/// than from the markup around it. That part cannot rot — a magnet link
/// carries its own name — while the size and the seed counts are read out of
/// the surrounding text and are best-effort by construction.
public struct BitSearchTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.bitSearch
    let http: TorrentHTTPClient
    let base: String

    public init(
        http: TorrentHTTPClient = TorrentHTTPClient(),
        base: String = "https://bitsearch.to/search"
    ) {
        self.http = http
        self.base = base
    }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        var components = URLComponents(string: base)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: "seeders")
        ]
        let data = try await http.get(components.url!, accept: "text/html")
        return Array(try Self.parse(data).prefix(limit))
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        // The page writes its magnets with entities — `xt&#x3D;urn:btih:` and
        // `&amp;dn&#x3D;` — so a scan for the literal `magnet:?xt=urn:btih:`
        // finds nothing at all on a page full of them. Measured against the
        // real page, which also redirects `.to` to `.eu`.
        let html = decodingHTMLEntities(String(decoding: data, as: UTF8.self))
        let marker = "magnet:?xt=urn:btih:"
        var found: [TorrentObservation] = []
        var seen = Set<TorrentInfoHash>()
        var cursor = html.startIndex
        var cardStart = html.startIndex
        while let range = html.range(of: marker, range: cursor..<html.endIndex) {
            let tail = html[range.lowerBound...]
            // The magnet ends where its attribute does, and **which quote that
            // is matters**: once the entities are decoded a `dn` can contain an
            // apostrophe (`It's MyGO!!!!!`), so stopping at every quote cut the
            // name in half. The opening quote is the one just before the
            // `magnet:`, so that is the one to stop at.
            let opening: Character? = range.lowerBound > html.startIndex
                ? html[html.index(before: range.lowerBound)]
                : nil
            let stop = tail.firstIndex { character in
                if let opening, opening == "\"" || opening == "'" { return character == opening }
                return character == "\"" || character == "<" || character == " " || character == "\n"
            } ?? tail.endIndex
            let raw = String(tail[tail.startIndex..<stop])
            // Everything since the last magnet is this listing's own card, and
            // that is where its swarm counts are.
            let card = html[cardStart..<range.lowerBound]
            cursor = stop
            defer { cardStart = stop }
            guard let magnet = MagnetLink(raw),
                  seen.insert(magnet.infoHash).inserted,
                  let title = Self.withoutSiteTag(magnet.displayName)?.nilIfEmpty
            else { continue }
            found.append(TorrentObservation(
                source: .bitSearch,
                title: title,
                infoHash: magnet.infoHash,
                trackers: magnet.trackers,
                // The magnet rarely carries `xl`, so the card's own
                // `327.55 MB` stands in — rounded, and flagged as such.
                size: magnet.exactLength ?? Self.size(in: card),
                // Best-effort by construction: the hash and the name come out
                // of the magnet and cannot rot, while these are read off the
                // markup around it and will the day the page is restyled.
                seeders: number(before: "seeders", in: card),
                leechers: number(before: "leechers", in: card),
                category: .raw,
                torrentURL: URL(string: "https://bitsearch.eu/download/torrent/\(magnet.infoHash.hex.uppercased())"),
                sizeIsExact: magnet.exactLength != nil
            ))
        }
        guard !found.isEmpty else {
            let lowered = html.lowercased()
            if lowered.contains("no results") || lowered.contains("no torrents found") { return [] }
            throw TorrentSearchError.parse("bitsearch: no magnet links in the page")
        }
        return found
    }

    /// The site stamps its own name into every magnet's `dn`. That belongs to
    /// the site, not to the release, and leaving it on would put it in front
    /// of every title and in everything that reads one.
    static func withoutSiteTag(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for tag in ["[Bitsearch.to]", "[bitsearch.to]", "[BitSearch.to]", "[Bitsearch.eu]", "[bitsearch.eu]"]
        where trimmed.hasPrefix(tag) {
            return String(trimmed.dropFirst(tag.count)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    /// The human-written size in a card — `327.55 MB`, `4.3 GB`.
    ///
    /// The **last** one in the card, not the first: a card's slice runs from
    /// the previous listing's magnet, so it can carry the tail of that listing
    /// too, and taking the first match read the wrong torrent's size. Rounded
    /// by the page either way, so it is never reported as exact.
    static func size(in card: Substring) -> Int64? {
        let units: [(String, Double)] = [
            ("tib", 1_099_511_627_776), ("gib", 1_073_741_824), ("mib", 1_048_576), ("kib", 1024),
            ("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3)
        ]
        let text = card.lowercased()
        var best: (index: String.Index, scale: Double)?
        for (unit, scale) in units {
            var search = text.startIndex..<text.endIndex
            while let range = text.range(of: unit, range: search) {
                search = range.upperBound..<text.endIndex
                // The unit has to end a word, or `mb` matches inside one.
                if range.upperBound < text.endIndex, text[range.upperBound].isLetter { continue }
                if best == nil || range.lowerBound > best!.index {
                    best = (range.lowerBound, scale)
                }
            }
        }
        guard let best else { return nil }
        var digits = ""
        var index = best.index
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if character.isNumber || character == "." {
                digits.insert(character, at: digits.startIndex)
            } else if character == " ", digits.isEmpty {
                continue
            } else {
                break
            }
        }
        guard let value = Double(digits), value > 0 else { return nil }
        return Int64(value * best.scale)
    }

    /// The number closest in front of a word — `405</span><span>seeders`.
    static func number(before label: String, in card: Substring) -> Int? {
        guard let labelRange = card.range(of: label, options: .backwards) else { return nil }
        var digits = ""
        var index = labelRange.lowerBound
        var sawDigit = false
        while index > card.startIndex {
            index = card.index(before: index)
            let character = card[index]
            if character.isNumber {
                digits.insert(character, at: digits.startIndex)
                sawDigit = true
            } else if sawDigit {
                break
            } else if digits.count > 400 {
                return nil
            }
        }
        return Int(digits)
    }

    /// Enough of HTML's escaping to read a page: the named entities a listing
    /// title actually carries, plus numeric ones in both bases.
    static func decodingHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<amp]
            rest = rest[amp...]
            guard let semicolon = rest.prefix(12).firstIndex(of: ";") else {
                out.append("&")
                rest = rest.dropFirst()
                continue
            }
            let entity = String(rest[rest.index(after: rest.startIndex)..<semicolon])
            rest = rest[rest.index(after: semicolon)...]
            switch entity.lowercased() {
            case "amp": out.append("&")
            case "lt": out.append("<")
            case "gt": out.append(">")
            case "quot": out.append("\"")
            case "apos": out.append("'")
            case "nbsp": out.append(" ")
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    if let value = UInt32(entity.dropFirst(2), radix: 16),
                       let scalar = Unicode.Scalar(value) {
                        out.unicodeScalars.append(scalar)
                    }
                } else if entity.hasPrefix("#") {
                    if let value = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(value) {
                        out.unicodeScalars.append(scalar)
                    }
                } else {
                    out += "&\(entity);"
                }
            }
        }
        out += rest
        return out
    }
}

/// therarbg.to — JSON over a path-shaped query, strong on films and shows.
///
/// Only the plain keyword path is asked. The engine this was ported from also
/// queries an `category:XXX` path; that one is not wanted here and is not
/// sent.
public struct TheRarbgTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.theRarbg
    let http: TorrentHTTPClient
    let base: String

    public init(
        http: TorrentHTTPClient = TorrentHTTPClient(),
        base: String = "https://therarbg.to/get-posts"
    ) {
        self.http = http
        self.base = base
    }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trimmed
        guard let url = URL(string: "\(base)/keywords:\(encoded)/?format=json") else { return [] }
        return Array(try Self.parse(try await http.get(url, accept: "application/json")).prefix(limit))
    }

    private struct Payload: Decodable {
        var results: [Entry]?
        struct Entry: Decodable {
            /// The index abbreviates every field.
            var h: String?
            var n: String?
            var s: Int64?
            var se: Int?
            var le: Int?
            var a: Double?
            var c: String?
        }
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw TorrentSearchError.parse("therarbg: \(error.localizedDescription)")
        }
        return (payload.results ?? []).compactMap { entry in
            guard let hash = entry.h.flatMap(TorrentInfoHash.init), let title = entry.n?.nilIfEmpty
            else { return nil }
            // An adult listing is dropped here rather than filtered later: it
            // must not reach the result type at all.
            guard !(entry.c ?? "").uppercased().contains("XXX") else { return nil }
            return TorrentObservation(
                source: .theRarbg,
                title: title,
                infoHash: hash,
                size: entry.s.flatMap { $0 > 0 ? $0 : nil },
                seeders: entry.se,
                leechers: entry.le,
                publishedAt: entry.a.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                category: .raw,
                sizeIsExact: entry.s != nil
            )
        }
    }
}

/// apibay.org — The Pirate Bay's own JSON. Old, plain, and still answering.
///
/// It reports "no results" as a single row with id `0`, which has to be
/// recognised or every empty search comes back with one listing called
/// *No results returned*.
public struct ApiBayTorrentProvider: TorrentSearchProvider {
    public let id = TorrentSourceID.apiBay
    let http: TorrentHTTPClient
    let endpoint: String

    public init(
        http: TorrentHTTPClient = TorrentHTTPClient(),
        endpoint: String = "https://apibay.org/q.php"
    ) {
        self.http = http
        self.endpoint = endpoint
    }

    public func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            // 200 is Video; the adult categories are 500 and are never asked
            // for. Leaving the category empty would return them.
            URLQueryItem(name: "cat", value: "200")
        ]
        return Array(try Self.parse(try await http.get(components.url!, accept: "application/json")).prefix(limit))
    }

    private struct Entry: Decodable {
        var id: String?
        var name: String?
        var info_hash: String?
        var seeders: String?
        var leechers: String?
        var size: String?
        var added: String?
        var category: String?
    }

    static func parse(_ data: Data) throws -> [TorrentObservation] {
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            throw TorrentSearchError.parse("apibay: \(error.localizedDescription)")
        }
        return entries.compactMap { entry in
            // The empty-result sentinel, and a hash of all zeroes with it.
            guard let identifier = entry.id, identifier != "0" else { return nil }
            guard let raw = entry.info_hash, raw.contains(where: { $0 != "0" }),
                  let hash = TorrentInfoHash(raw), let title = entry.name?.nilIfEmpty
            else { return nil }
            // 500 is the adult category; it is not asked for and not accepted.
            if let category = entry.category, category.hasPrefix("5") { return nil }
            return TorrentObservation(
                source: .apiBay,
                title: title,
                infoHash: hash,
                size: entry.size.flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil },
                seeders: entry.seeders.flatMap(Int.init),
                leechers: entry.leechers.flatMap(Int.init),
                publishedAt: entry.added.flatMap(Double.init).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                category: .raw,
                torrentURL: URL(string: "https://apibay.org/t.php?id=\(identifier)"),
                sizeIsExact: entry.size != nil
            )
        }
    }
}
