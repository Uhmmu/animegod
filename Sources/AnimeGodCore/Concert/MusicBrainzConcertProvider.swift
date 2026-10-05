import Foundation

/// Looks a concert disc up on MusicBrainz, and fetches its cover from the
/// Cover Art Archive.
///
/// This is the source of the **setlist and the song lengths**, which makes it
/// the one the timeline depends on: measured across six real concert Blu-rays,
/// four published a length for every song, and Discogs published one for none
/// of them. Its media are named too, so a three-disc box arrives already split
/// into the live, the bonus event and the making-of rather than as one flat
/// list.
///
/// Two things about it that cost a request each to learn:
///
/// * **A live Blu-ray is often not its own release.** MyGO's *跡暖空* is one
///   release holding a CD and two Blu-rays, and the concert is the Blu-rays.
///   So the thing to match is a *medium*, not a release, and the medium's own
///   title is what names the concert.
/// * **Its search score means very little.** "MyGO!!!!! 2nd Live" returns
///   another artist's *2nd LIVEパラレルタイム* at score 100. Catalogue number and
///   barcode searches return exactly one release and are the only ones trusted
///   without a second opinion.
public struct MusicBrainzConcertProvider: Sendable {
    public let id: ConcertProviderID = .musicBrainz

    private let session: URLSession
    private let baseURL: URL
    private let coverArtBaseURL: URL
    private let userAgent: String
    private let pacer: ConcertRequestPacer

    /// MusicBrainz asks for one request a second and means it: two searches
    /// sent back to back answered `503 Service Temporarily Unavailable`
    /// (measured). The limit is a rate, so retrying is not enough — requests
    /// have to be spaced before they are sent.
    static let minimumInterval: TimeInterval = 1.1
    static let serviceUnavailablePause: TimeInterval = 3
    static let retries = 2

    /// MusicBrainz asks that an application identify itself, and throttles
    /// harder when it does not.
    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://musicbrainz.org/ws/2")!,
        coverArtBaseURL: URL = URL(string: "https://coverartarchive.org")!,
        userAgent: String = "AnimeGod/0.5 ( https://github.com/Uhmmu/animegod )"
    ) {
        self.session = session
        self.baseURL = baseURL
        self.coverArtBaseURL = coverArtBaseURL
        self.userAgent = userAgent
        self.pacer = ConcertRequestPacer(minimumInterval: Self.minimumInterval)
    }

    // MARK: - Lookups

    /// Releases filed under this catalogue number. Exact: measured, `catno`
    /// answers with one release at score 100 or with nothing at all.
    public func releases(catalogNumber: ConcertCatalogNumber) async throws -> [ConcertRelease] {
        for variant in catalogNumber.queryVariants {
            let found = try await search(lucene: "catno:\(quoted(variant))")
            if !found.isEmpty { return found }
        }
        return []
    }

    public func releases(barcode: String) async throws -> [ConcertRelease] {
        let digits = barcode.filter(\.isNumber)
        guard !digits.isEmpty else { return [] }
        return try await search(lucene: "barcode:\(digits)")
    }

    /// The fallback when a folder carries no catalogue number.
    ///
    /// The artist is part of the query rather than a filter applied afterwards
    /// because without it the search is actively misleading — it answers a
    /// title it does not have with a different artist's release at a perfect
    /// score. `format:Blu-ray` keeps CD-only releases of the same concert out.
    public func releases(title: String, artist: String? = nil) async throws -> [ConcertRelease] {
        var clauses = ["\(quoted(title))", "format:Blu-ray"]
        if let artist, !artist.isEmpty { clauses.insert("artist:\(quoted(artist))", at: 1) }
        return try await search(lucene: clauses.joined(separator: " AND "))
    }

    /// The release with its media, tracks and lengths filled in. A search
    /// result has none of that; `inc=recordings` is what adds it.
    public func release(id mbid: String) async throws -> ConcertRelease {
        var components = URLComponents(
            url: baseURL.appending(path: "release/\(mbid)"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "inc", value: "recordings+artist-credits+labels+release-groups"),
            URLQueryItem(name: "fmt", value: "json")
        ]
        let payload: ReleasePayload = try await load(components.url!)
        var release = payload.release
        release.coverImageURLs = (try? await coverArtURLs(releaseID: mbid)) ?? []
        return release
    }

    /// The Cover Art Archive's images for a release, front first.
    ///
    /// A 404 here is ordinary — two of six real concert Blu-rays had no art at
    /// all — so it is reported as "no images", never as a failure. Losing the
    /// cover must not lose the setlist.
    public func coverArtURLs(releaseID mbid: String) async throws -> [URL] {
        let url = coverArtBaseURL.appending(path: "release/\(mbid)")
        do {
            let payload: CoverArtPayload = try await load(url, acceptsNotFound: true)
            let front = payload.images.filter { $0.front == true }
            let rest = payload.images.filter { $0.front != true }
            return (front + rest).compactMap { $0.bestURL }
        } catch MetadataProviderError.httpStatus(404) {
            return []
        }
    }

    private func search(lucene query: String) async throws -> [ConcertRelease] {
        var components = URLComponents(
            url: baseURL.appending(path: "release"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "10")
        ]
        let payload: SearchPayload = try await load(components.url!)
        return payload.releases.map(\.release)
    }

    /// Lucene treats the punctuation a Japanese release title is full of as
    /// syntax, so a title is sent as a phrase.
    private func quoted(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: ""))\""
    }

    // MARK: - Transport

    private func load<T: Decodable>(_ url: URL, acceptsNotFound: Bool = false) async throws -> T {
        for attempt in 0...Self.retries {
            await pacer.wait()
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MetadataProviderError.invalidResponse }

            // 503 here is the rate limiter, not an outage: it is what one
            // request too soon looks like.
            if http.statusCode == 503 || http.statusCode == 429 {
                guard attempt < Self.retries else {
                    throw MetadataProviderError.rateLimited(retryAfter: Self.serviceUnavailablePause)
                }
                try await Task.sleep(for: .seconds(Self.serviceUnavailablePause))
                continue
            }
            if http.statusCode == 404, acceptsNotFound { throw MetadataProviderError.httpStatus(404) }
            guard (200..<300).contains(http.statusCode) else {
                throw MetadataProviderError.httpStatus(http.statusCode)
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw MetadataProviderError.invalidResponse
            }
        }
        throw MetadataProviderError.rateLimited(retryAfter: Self.serviceUnavailablePause)
    }
}

// MARK: - Wire format

private extension MusicBrainzConcertProvider {
    struct SearchPayload: Decodable {
        let releases: [ReleasePayload]
    }

    struct CoverArtPayload: Decodable {
        let images: [Image]
        struct Image: Decodable {
            let front: Bool?
            let image: String?
            let thumbnails: [String: String]?

            /// The archive serves originals that run to several megabytes. A
            /// 500px thumbnail is what a poster is drawn at, so it is
            /// preferred when one exists.
            var bestURL: URL? {
                let candidates = [thumbnails?["500"], thumbnails?["large"], image, thumbnails?["250"]]
                return candidates.compactMap { $0 }.compactMap(Self.secureURL(from:)).first
            }

            /// The archive publishes its image links as `http://` (measured),
            /// which App Transport Security refuses outright. The host serves
            /// the same paths over TLS.
            static func secureURL(from string: String) -> URL? {
                guard var components = URLComponents(string: string) else { return nil }
                if components.scheme == "http" { components.scheme = "https" }
                return components.url
            }
        }
    }

    struct ReleasePayload: Decodable {
        let id: String
        let title: String
        let date: String?
        let country: String?
        let barcode: String?
        let media: [Medium]?
        let artistCredit: [Credit]?
        let labelInfo: [LabelInfo]?
        let releaseGroup: ReleaseGroup?

        enum CodingKeys: String, CodingKey {
            case id, title, date, country, barcode, media
            case artistCredit = "artist-credit"
            case labelInfo = "label-info"
            case releaseGroup = "release-group"
        }

        struct Credit: Decodable {
            let name: String?
            let artist: Artist?
            struct Artist: Decodable { let name: String? }
        }

        struct LabelInfo: Decodable {
            let catalogNumber: String?
            let label: Label?
            struct Label: Decodable { let name: String? }
            enum CodingKeys: String, CodingKey {
                case label
                case catalogNumber = "catalog-number"
            }
        }

        struct ReleaseGroup: Decodable {
            let primaryType: String?
            let secondaryTypes: [String]?
            enum CodingKeys: String, CodingKey {
                case primaryType = "primary-type"
                case secondaryTypes = "secondary-types"
            }
        }

        struct Medium: Decodable {
            let position: Int?
            let format: String?
            let title: String?
            let trackCount: Int?
            let tracks: [Track]?

            enum CodingKeys: String, CodingKey {
                case position, format, title, tracks
                case trackCount = "track-count"
            }

            struct Track: Decodable {
                let position: Int?
                let number: String?
                let title: String?
                /// Milliseconds, and often absent.
                let length: Int?
            }
        }

        var release: ConcertRelease {
            ConcertRelease(
                provider: .musicBrainz,
                externalID: id,
                title: title,
                artistNames: (artistCredit ?? []).compactMap { $0.artist?.name ?? $0.name },
                releaseDate: date,
                country: country,
                labels: (labelInfo ?? []).compactMap { $0.label?.name },
                catalogNumbers: (labelInfo ?? []).compactMap(\.catalogNumber),
                barcode: barcode,
                genres: [],
                discs: discs,
                sourceURL: URL(string: "https://musicbrainz.org/release/\(id)"),
                isLiveRecording: isLive
            )
        }

        /// Whether the release group is marked as a live recording. A `Live`
        /// secondary type is the only machine-readable "this is a concert"
        /// any of the three sources publishes.
        var isLive: Bool {
            (releaseGroup?.secondaryTypes ?? []).contains { $0.caseInsensitiveCompare("Live") == .orderedSame }
        }

        var discs: [ConcertDisc] {
            (media ?? []).enumerated().map { index, medium in
                var position = 1
                let tracks: [ConcertTrack] = (medium.tracks ?? []).compactMap { track in
                    guard let rawTitle = track.title, !rawTitle.isEmpty else { return nil }
                    let classified = ConcertTrackClassifier.classify(title: rawTitle)
                    defer { position += 1 }
                    return ConcertTrack(
                        // A box's second disc numbers its tracks 23…41, which
                        // is the position in the set rather than on the disc.
                        // The disc's own numbering is what a setlist shows.
                        position: position,
                        title: classified.title,
                        duration: track.length.map { TimeInterval($0) / 1000 },
                        kind: classified.kind,
                        isEncore: classified.isEncore
                    )
                }
                return ConcertDisc(
                    position: medium.position ?? (index + 1),
                    title: medium.title?.isEmpty == false ? medium.title : nil,
                    format: medium.format,
                    tracks: tracks
                )
            }
        }
    }
}
