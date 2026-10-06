import Foundation

/// The application credentials a Discogs request is signed with.
///
/// Discogs serves an unauthenticated search but answers it with nothing — a
/// `200` carrying zero results, which looks exactly like "no such release"
/// (measured, before the key existed). Images are withheld the same way. So
/// the key is not an optimisation; without it the provider silently reports
/// that every disc is unknown.
public struct DiscogsCredentials: Hashable, Sendable {
    public let consumerKey: String
    public let consumerSecret: String

    public init(consumerKey: String, consumerSecret: String) {
        self.consumerKey = consumerKey
        self.consumerSecret = consumerSecret
    }

    public var isComplete: Bool { !consumerKey.isEmpty && !consumerSecret.isEmpty }

    /// Discogs' own application-level scheme. Nothing here acts for a user,
    /// so the full OAuth dance is not needed and the key pair is sent as is.
    var authorizationHeader: String { "Discogs key=\(consumerKey), secret=\(consumerSecret)" }
}

/// Looks a concert disc up on Discogs.
///
/// Its job in this feature is **identity and the release facts**, not the
/// setlist. A catalogue number search returns exactly one release and
/// tolerates every way of writing the number, which no title search manages;
/// but its track lists are entered by hand and do get it wrong — measured on
/// `ANZX-10294`, Discogs lists `ひみつ基地` twice and omits `ラブソングが歌えない`,
/// so aligning its seventeen entries against the disc's chapters would put
/// every song after the fourth one place out. It also publishes no track
/// lengths at all for these releases, which is what the alignment needs. So
/// the setlist comes from MusicBrainz and this fills in the cover, the label,
/// the barcode and the shape of the box.
public struct DiscogsConcertProvider: Sendable {
    public let id: ConcertProviderID = .discogs

    private let credentials: DiscogsCredentials
    private let session: URLSession
    private let baseURL: URL
    private let userAgent: String
    private let pacer: ConcertRequestPacer

    /// Discogs allows sixty requests a minute and says so in
    /// `x-discogs-ratelimit`. One a second keeps a whole library inside it.
    static let minimumInterval: TimeInterval = 1.05
    /// How few of the minute's requests may be left before waiting it out.
    static let reserveBeforePausing = 3
    static let rateLimitPause: TimeInterval = 20
    static let rateLimitRetries = 2

    public init(
        credentials: DiscogsCredentials,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.discogs.com")!,
        userAgent: String = "AnimeGod/0.5 +https://github.com/Uhmmu/animegod"
    ) {
        self.credentials = credentials
        self.session = session
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.pacer = ConcertRequestPacer(minimumInterval: Self.minimumInterval)
    }

    public var isConfigured: Bool { credentials.isComplete }

    // MARK: - Lookups

    /// Every release filed under this catalogue number.
    ///
    /// The variants are tried in turn and the first that answers wins.
    /// Measured, any of them is enough — but a provider that stops folding
    /// separators should cost one extra request, not every match.
    public func releases(catalogNumber: ConcertCatalogNumber) async throws -> [ConcertRelease] {
        for variant in catalogNumber.queryVariants {
            let found = try await search(queryItems: [
                URLQueryItem(name: "catno", value: variant),
                URLQueryItem(name: "type", value: "release")
            ])
            if !found.isEmpty { return found }
        }
        return []
    }

    public func releases(barcode: String) async throws -> [ConcertRelease] {
        let digits = barcode.filter(\.isNumber)
        guard !digits.isEmpty else { return [] }
        return try await search(queryItems: [
            URLQueryItem(name: "barcode", value: digits),
            URLQueryItem(name: "type", value: "release")
        ])
    }

    /// The fallback for a folder with no catalogue number in its name. Weaker
    /// on purpose: Discogs' title search found nothing for three of eight real
    /// concert Blu-rays, so an empty answer here means "ask another source",
    /// not "no such disc".
    public func releases(title: String, artist: String? = nil) async throws -> [ConcertRelease] {
        var items = [
            URLQueryItem(name: "q", value: title),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "format", value: "Blu-ray")
        ]
        if let artist, !artist.isEmpty { items.append(URLQueryItem(name: "artist", value: artist)) }
        return try await search(queryItems: items)
    }

    /// The full release, with its track list and images. A search result
    /// carries neither — Discogs does not put them in search output — so this
    /// is a second request and the caller makes it only for the release it
    /// settled on.
    public func release(id: String) async throws -> ConcertRelease {
        let payload: ReleasePayload = try await load(
            baseURL.appending(path: "releases/\(id)")
        )
        return payload.release
    }

    private func search(queryItems: [URLQueryItem]) async throws -> [ConcertRelease] {
        guard isConfigured else { throw MetadataProviderError.serviceMessage(
            String(localized: "Add a Discogs API key in Settings to look concert discs up.", bundle: .module)
        ) }
        var components = URLComponents(
            url: baseURL.appending(path: "database/search"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = queryItems
        let payload: SearchPayload = try await load(components.url!)
        return payload.results.map(\.release)
    }

    // MARK: - Transport

    private func load<T: Decodable>(_ url: URL) async throws -> T {
        for attempt in 0...Self.rateLimitRetries {
            await pacer.wait()
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MetadataProviderError.invalidResponse }

            if http.statusCode == 429 {
                guard attempt < Self.rateLimitRetries else {
                    throw MetadataProviderError.rateLimited(retryAfter: Self.rateLimitPause)
                }
                try await Task.sleep(for: .seconds(Self.rateLimitPause))
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                // Discogs explains itself in the body; the status alone turns
                // a bad key into an indistinguishable failure.
                if let message = (try? JSONDecoder().decode(ErrorPayload.self, from: data))?.message {
                    throw MetadataProviderError.serviceMessage(message)
                }
                throw MetadataProviderError.httpStatus(http.statusCode)
            }
            // Spending the last of the minute's budget costs the next caller
            // a 429, so the wait happens here instead.
            if let remaining = http.value(forHTTPHeaderField: "x-discogs-ratelimit-remaining").flatMap(Int.init),
               remaining <= Self.reserveBeforePausing {
                try await Task.sleep(for: .seconds(Self.rateLimitPause))
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw MetadataProviderError.invalidResponse
            }
        }
        throw MetadataProviderError.rateLimited(retryAfter: Self.rateLimitPause)
    }
}

// MARK: - Wire format

private extension DiscogsConcertProvider {
    struct ErrorPayload: Decodable { let message: String? }

    struct SearchPayload: Decodable {
        let results: [SearchResult]
    }

    struct SearchResult: Decodable {
        let id: Int
        let title: String
        let year: String?
        let country: String?
        let catno: String?
        let format: [String]?
        let label: [String]?
        let genre: [String]?
        let style: [String]?
        let barcode: [String]?
        let coverImage: String?
        let uri: String?

        enum CodingKeys: String, CodingKey {
            case id, title, year, country, catno, format, label, genre, style, barcode, uri
            case coverImage = "cover_image"
        }

        /// A search result's `title` is `"結束バンド* - 結束バンド LIVE-恒星-"`:
        /// the artist, a disambiguation asterisk, then the release. Split so
        /// the two are not shown as one name.
        var release: ConcertRelease {
            let parts = title.components(separatedBy: " - ")
            let artist = parts.count > 1
                ? parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " *")) : ""
            let name = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : title
            return ConcertRelease(
                provider: .discogs,
                externalID: String(id),
                title: name,
                artistNames: artist.isEmpty ? [] : [artist],
                releaseDate: year.flatMap { $0 == "0" ? nil : $0 },
                country: country,
                labels: label ?? [],
                catalogNumbers: catno.map { [$0] } ?? [],
                barcode: barcode?.first,
                genres: (genre ?? []) + (style ?? []),
                coverImageURLs: [coverImage].compactMap { $0 }.compactMap(URL.init(string:)),
                sourceURL: uri.flatMap { $0.hasPrefix("http") ? URL(string: $0) : URL(string: "https://www.discogs.com" + $0) }
            )
        }
    }

    struct ReleasePayload: Decodable {
        let id: Int
        let title: String
        let artists: [Artist]?
        let year: Int?
        let released: String?
        let country: String?
        let labels: [Label]?
        let formats: [Format]?
        let genres: [String]?
        let styles: [String]?
        let identifiers: [Identifier]?
        let images: [Image]?
        let tracklist: [Track]?
        let notes: String?
        let uri: String?

        /// `anv` is the artist *name variation* as the release credits it —
        /// `結束バンド` where `name` is the romanised `Kessoku Band`. A Japanese
        /// concert disc is credited in Japanese, so that is the name to show,
        /// with the romanisation kept behind it for matching.
        struct Artist: Decodable {
            let name: String
            let anv: String?

            var credited: [String] {
                guard let anv, !anv.isEmpty, anv != name else { return [name] }
                return [anv, name]
            }
        }
        struct Label: Decodable { let name: String?; let catno: String? }
        struct Format: Decodable { let name: String?; let qty: String?; let descriptions: [String]? }
        struct Identifier: Decodable { let type: String?; let value: String? }
        struct Image: Decodable { let type: String?; let uri: String?; let width: Int?; let height: Int? }
        struct Track: Decodable {
            let position: String?
            let title: String?
            let duration: String?
            let typeName: String?
            enum CodingKeys: String, CodingKey {
                case position, title, duration
                case typeName = "type_"
            }
        }

        var release: ConcertRelease {
            ConcertRelease(
                provider: .discogs,
                externalID: String(id),
                title: title,
                artistNames: (artists ?? []).flatMap(\.credited),
                releaseDate: released ?? year.flatMap { $0 == 0 ? nil : String($0) },
                country: country,
                labels: (labels ?? []).compactMap(\.name),
                catalogNumbers: (labels ?? []).compactMap(\.catno),
                barcode: (identifiers ?? []).first { $0.type?.lowercased() == "barcode" }?.value,
                genres: (genres ?? []) + (styles ?? []),
                discs: discs,
                coverImageURLs: orderedImageURLs,
                sourceURL: uri.flatMap(URL.init(string:)),
                summary: notes
            )
        }

        /// The primary image is the front of the sleeve; a secondary one may
        /// be the back or the disc itself. Measured on three real concert
        /// Blu-rays, all three had *only* a secondary image, so the order
        /// matters more than the presence of a primary.
        var orderedImageURLs: [URL] {
            let all = images ?? []
            let primary = all.filter { $0.type?.lowercased() == "primary" }
            let rest = all.filter { $0.type?.lowercased() != "primary" }
            return (primary + rest).compactMap(\.uri).compactMap(URL.init(string:))
        }

        /// Groups the flat track list back into discs.
        ///
        /// Discogs numbers a track `1-01` on one release and `CD-1` on the
        /// next, so the disc is whatever the position's first part says it is,
        /// and discs come out in the order they first appear.
        var discs: [ConcertDisc] {
            let singleFormat = (formats ?? []).count == 1 ? formats?.first?.name : nil
            var order: [String] = []
            var grouped: [String: [ConcertTrack]] = [:]
            for entry in tracklist ?? [] {
                // Discogs marks a section heading as a track with no position.
                guard (entry.typeName ?? "track") == "track",
                      let position = ConcertTrackPosition.parse(entry.position ?? ""),
                      let rawTitle = entry.title, !rawTitle.isEmpty
                else { continue }
                let classified = ConcertTrackClassifier.classify(title: rawTitle)
                let track = ConcertTrack(
                    position: position.track ?? ((grouped[position.discKey]?.count ?? 0) + 1),
                    title: classified.title,
                    duration: Self.seconds(from: entry.duration),
                    kind: classified.kind,
                    isEncore: classified.isEncore
                )
                if grouped[position.discKey] == nil { order.append(position.discKey) }
                grouped[position.discKey, default: []].append(track)
            }
            let byPosition = Self.formatsByDisc(formats, discCount: order.count)
            return order.enumerated().map { index, key in
                ConcertDisc(
                    position: Int(key) ?? (index + 1),
                    title: nil,
                    format: byPosition?[index] ?? singleFormat ?? Self.format(fromDiscKey: key),
                    tracks: grouped[key] ?? []
                )
            }
        }

        /// What each disc is, read off `formats` by quantity.
        ///
        /// `formats` lists the media in the order they sit in the box with a
        /// count each — `2 × CD`, then `1 × Blu-ray` — and the track list
        /// numbers its discs `1-`, `2-`, `3-` in that same order, so the two
        /// line up position by position. Without this a mixed release left
        /// every format unset, and a release with no video disc is a release
        /// with no setlist to show and nothing to say it is a concert.
        ///
        /// Measured on `4988031567562` — ずっと真夜中でいいのに。's *沈香学*, a
        /// 2CD+BD album whose **third** disc is the live Blu-ray that is the
        /// only thing in this library's folder. Nothing else in the answer says
        /// which of the three it is.
        ///
        /// Only when the counts agree. A release whose discs are keyed by name
        /// (`CD-1`, `BD-1`) already says what each one is, and a track list
        /// that lists fewer discs than the box holds is one this cannot line
        /// up — both keep the older reading rather than take a guess.
        static func formatsByDisc(_ formats: [Format]?, discCount: Int) -> [String]? {
            guard let formats, !formats.isEmpty, discCount > 0 else { return nil }
            var expanded: [String] = []
            for format in formats {
                guard let name = format.name, !name.isEmpty else { return nil }
                let quantity = max(Int(format.qty ?? "1") ?? 1, 1)
                expanded.append(contentsOf: Array(repeating: name, count: quantity))
                if expanded.count > discCount { return nil }
            }
            return expanded.count == discCount ? expanded : nil
        }

        /// `CD-1` names its medium where `1-01` numbers it.
        static func format(fromDiscKey key: String) -> String? {
            switch key.uppercased() {
            case "BD", "BLU-RAY", "BLURAY": "Blu-ray"
            case "DVD": "DVD"
            case "CD": "CD"
            case "LP", "A", "B": "Vinyl"
            default: nil
            }
        }

        /// `4:12`, `1:02:33`, or empty — Discogs leaves it blank for every
        /// concert Blu-ray measured, so this is written for the day it stops.
        static func seconds(from text: String?) -> TimeInterval? {
            guard let text, !text.isEmpty else { return nil }
            let parts = text.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            let seconds = parts.map { $0! }.reduce(0) { $0 * 60 + $1 }
            return TimeInterval(seconds)
        }
    }
}
