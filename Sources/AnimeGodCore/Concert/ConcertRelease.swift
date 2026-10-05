import Foundation

public enum ConcertProviderID: String, Codable, CaseIterable, Sendable {
    case discogs
    case musicBrainz
    case bangumi
    /// setlist.fm: what was played on the night, from the people who were
    /// there. The only source that is about the concert rather than the disc.
    case setlistFM
    /// The release's own folder — its scans, its cue sheet, its catalogue
    /// number. Not a service, but a source, and for artwork the best one.
    case localFiles

    public var displayName: String {
        switch self {
        case .discogs: "Discogs"
        case .musicBrainz: "MusicBrainz"
        case .bangumi: "Bangumi"
        case .setlistFM: "setlist.fm"
        case .localFiles: String(localized: "This release", bundle: .module)
        }
    }
}

/// A field of a concert record, for saying which source answered it.
///
/// A concert page is assembled from four services and the folder on disk, and
/// no two of them answer the same question — so "where did this come from" has
/// no single answer and the page should not pretend otherwise. It is also a
/// condition of using some of them: setlist.fm asks that its data be credited
/// where it is shown, and a credit that appears only when it happens to have
/// led the whole record is not a credit.
///
/// Declared in the order a page should list them: what was played first,
/// because that is what a concert is.
public enum ConcertReleaseField: String, Codable, CaseIterable, Sendable {
    case setlist
    case venue
    case performedOn
    case rating
    case artists
    case title
    case summary
    case covers
    case extras
    case labels
    case catalogNumbers
    case barcode
    case releaseDate
    case country
    case genres
    case officialSite

    public var displayName: String {
        switch self {
        case .setlist: String(localized: "Setlist", bundle: .module)
        case .venue: String(localized: "Venue", bundle: .module)
        case .performedOn: String(localized: "Performance date", bundle: .module)
        case .rating: String(localized: "Rating", bundle: .module)
        case .artists: String(localized: "Artist", bundle: .module)
        case .title: String(localized: "Title", bundle: .module)
        case .summary: String(localized: "Description", bundle: .module)
        case .covers: String(localized: "Artwork", bundle: .module)
        case .extras: String(localized: "What came in the box", bundle: .module)
        case .labels: String(localized: "Label", bundle: .module)
        case .catalogNumbers: String(localized: "Catalogue number", bundle: .module)
        case .barcode: String(localized: "Barcode", bundle: .module)
        case .releaseDate: String(localized: "Release date", bundle: .module)
        case .country: String(localized: "Country", bundle: .module)
        case .genres: String(localized: "Genre", bundle: .module)
        case .officialSite: String(localized: "Official site", bundle: .module)
        }
    }
}

/// So the map encodes as `{"venue": "setlistFM"}` rather than as a flat array
/// of alternating keys and values, which is what `Dictionary`'s own `Codable`
/// does for a key it cannot use as a coding key.
extension ConcertReleaseField: CodingKeyRepresentable {
    public var codingKey: any CodingKey { StringCodingKey(rawValue) }

    public init?<Key: CodingKey>(codingKey: Key) {
        self.init(rawValue: codingKey.stringValue)
    }

    private struct StringCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// One disc of a release.
///
/// A concert box is not one disc and its discs are not interchangeable: the
/// live is on one, the bonus event on another, the making-of on a third.
/// MusicBrainz names each medium, which is where that structure comes from —
/// measured on `ANZX-10294`, the three media are titled `結束バンドLIVE-恒星-`,
/// `ぼっち・ざ・ろっく！です。` and nothing at all.
public struct ConcertDisc: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// 1-based position in the set.
    public var position: Int
    /// What the release calls this disc, when it calls it anything.
    public var title: String?
    /// `Blu-ray`, `DVD`, `CD` — as the provider spells it.
    public var format: String?
    public var tracks: [ConcertTrack]

    public init(
        id: UUID = UUID(),
        position: Int,
        title: String? = nil,
        format: String? = nil,
        tracks: [ConcertTrack] = []
    ) {
        self.id = id
        self.position = position
        self.title = title
        self.format = format
        self.tracks = tracks
    }

    /// Whether this disc is the video the viewer will play. A box's CD is the
    /// same songs again and must not be offered as a timeline for the film.
    public var isVideo: Bool {
        guard let format = format?.lowercased() else { return false }
        return format.contains("blu-ray") || format.contains("bluray")
            || format.contains("dvd") || format.contains("hd dvd")
    }

    /// The songs — what a timeline can be laid over.
    public var songs: [ConcertTrack] {
        tracks.filter { $0.kind.belongsOnTimeline }
    }
}

/// Everything a provider could say about one concert release.
///
/// Deliberately one type for all three sources even though no source fills it
/// in: the sources are complementary rather than alternative, and which one
/// answered a given field is worth keeping so a page can be honest about it.
/// Measured division of labour — Discogs answers a catalogue number exactly
/// and carries the release facts, MusicBrainz is the only one of the three
/// that publishes song lengths, and Bangumi is the only one that knows which
/// hall the concert was in.
public struct ConcertRelease: Codable, Hashable, Sendable, Identifiable {
    public let provider: ConcertProviderID
    public let externalID: String
    public var title: String
    public var artistNames: [String]
    /// `2023-11-22`, as published — a partial date is normal and parsing it
    /// into a `Date` would invent a precision the source does not have.
    public var releaseDate: String?
    public var country: String?
    public var labels: [String]
    public var catalogNumbers: [String]
    public var barcode: String?
    public var genres: [String]
    public var discs: [ConcertDisc]
    public var coverImageURLs: [URL]
    public var sourceURL: URL?
    /// Out of ten, as every provider here reports it.
    public var score: Double?
    public var ratingCount: Int?
    public var summary: String?
    /// The hall. Bangumi's 演出 subjects carry it and nothing else does.
    public var venue: String?
    /// When the concert happened, which is not when the disc shipped.
    public var performedOn: String?
    public var officialSiteURL: URL?
    /// This record is about the *concert*, not about a disc of it.
    ///
    /// Bangumi files the two separately — a 演出 subject knows the hall and the
    /// date and has no track list, while the 音乐 subject for the Blu-ray has
    /// the track list and knows nothing about the hall — so a merge has to be
    /// able to tell them apart. Without the flag a performance record looks
    /// like a release with no discs, which is also what a failed lookup looks
    /// like.
    public var isPerformanceRecord: Bool = false
    /// The source says this is a live recording.
    ///
    /// The only machine-readable "this is a concert" any of the three
    /// publishes: MusicBrainz marks the release group `Live` as a secondary
    /// type, and Bangumi writes `类型: Live` on a 演出 subject. Discogs says
    /// nothing of the sort. It is what moves a work into the concert section
    /// without anyone having to say so.
    public var isLiveRecording: Bool = false
    /// What else came in the box, read off the folder it arrived in. A page
    /// that can say "and five bonus CDs and 27 scans" is describing what the
    /// viewer owns rather than what a catalogue happens to list.
    public var extras: [ConcertExtra] = []
    /// Which source answered each field, filled in by the merge.
    ///
    /// Empty on a provider's own answer — there it would say the same thing
    /// about every field — and empty on a record stored before this existed,
    /// which the page treats as "not recorded" rather than as "nobody".
    public var attribution: [ConcertReleaseField: ConcertProviderID] = [:]

    /// Whether the numbers this record was filed under are still catalogue
    /// numbers.
    ///
    /// A record matched by a key that no longer parses was matched by
    /// something that was never a key — `IMG015` off a folder of scans, which
    /// Discogs happens to have a compilation filed under. Nothing can repair
    /// such a record, so the pass that would otherwise leave it alone for ever
    /// throws it away and asks again. True when there are no numbers at all: a
    /// Bangumi record was never matched by one.
    public var wasFiledUnderARealCatalogueNumber: Bool {
        guard !catalogNumbers.isEmpty else { return true }
        return catalogNumbers.contains { ConcertCatalogNumber.first(in: $0) != nil }
    }

    /// The sources that answered something, each with what it gave, in the
    /// order a page should list them: most fields first, and the folder on disk
    /// last because it is not a service.
    public var credits: [(provider: ConcertProviderID, fields: [ConcertReleaseField])] {
        var byProvider: [ConcertProviderID: [ConcertReleaseField]] = [:]
        for field in ConcertReleaseField.allCases {
            guard let provider = attribution[field] else { continue }
            byProvider[provider, default: []].append(field)
        }
        return byProvider
            .map { (provider: $0.key, fields: $0.value) }
            .sorted { first, second in
                if (first.provider == .localFiles) != (second.provider == .localFiles) {
                    return second.provider == .localFiles
                }
                if first.fields.count != second.fields.count {
                    return first.fields.count > second.fields.count
                }
                return first.provider.rawValue < second.provider.rawValue
            }
    }

    public var id: String { "\(provider.rawValue):\(externalID)" }

    public init(
        provider: ConcertProviderID,
        externalID: String,
        title: String,
        artistNames: [String] = [],
        releaseDate: String? = nil,
        country: String? = nil,
        labels: [String] = [],
        catalogNumbers: [String] = [],
        barcode: String? = nil,
        genres: [String] = [],
        discs: [ConcertDisc] = [],
        coverImageURLs: [URL] = [],
        sourceURL: URL? = nil,
        score: Double? = nil,
        ratingCount: Int? = nil,
        summary: String? = nil,
        venue: String? = nil,
        performedOn: String? = nil,
        officialSiteURL: URL? = nil,
        isPerformanceRecord: Bool = false,
        isLiveRecording: Bool = false,
        extras: [ConcertExtra] = [],
        attribution: [ConcertReleaseField: ConcertProviderID] = [:]
    ) {
        self.provider = provider
        self.externalID = externalID
        self.title = title
        self.artistNames = artistNames
        self.releaseDate = releaseDate
        self.country = country
        self.labels = labels
        self.catalogNumbers = catalogNumbers
        self.barcode = barcode
        self.genres = genres
        self.discs = discs
        self.coverImageURLs = coverImageURLs
        self.sourceURL = sourceURL
        self.score = score
        self.ratingCount = ratingCount
        self.summary = summary
        self.venue = venue
        self.performedOn = performedOn
        self.officialSiteURL = officialSiteURL
        self.isPerformanceRecord = isPerformanceRecord
        self.isLiveRecording = isLiveRecording
        self.extras = extras
        self.attribution = attribution
    }

    /// The discs worth playing, in order.
    public var videoDiscs: [ConcertDisc] {
        discs.filter(\.isVideo).sorted { $0.position < $1.position }
    }

    /// Every song on every video disc — what the setlist on the page is.
    public var songCount: Int {
        videoDiscs.reduce(0) { $0 + $1.songs.count }
    }

    /// The disc an episode of this work stands for.
    ///
    /// A single-disc release has one answer. A box numbers its episodes after
    /// its disc folders — `DISC2`, `Day2` — so the number matches a medium's
    /// position, and falls back to the order the media came in when a release
    /// numbers its media differently from the way the folders were named.
    public func videoDisc(forDiscNumber number: Int?) -> ConcertDisc? {
        let discs = videoDiscs
        guard let number else { return discs.first }
        // By order, not by the medium's own position. A release whose video
        // discs are media 2 and 3 — an album with a CD in front of them, which
        // is how `BRMM-10876` holds both nights — would otherwise hand the
        // second night the first night's setlist.
        let index = number - 1
        if discs.indices.contains(index) { return discs[index] }
        return discs.first { $0.position == number } ?? discs.first
    }

    /// How long the music runs, when the source published lengths.
    public var totalSongDuration: TimeInterval? {
        let lengths = videoDiscs.flatMap(\.songs).compactMap(\.duration)
        guard !lengths.isEmpty else { return nil }
        return lengths.reduce(0, +)
    }
}

/// Spaces requests out so a provider stays inside a published rate.
///
/// Both services limit a *rate* rather than a quota, and they say so
/// differently: MusicBrainz asks for one request a second and answers 503 to
/// the second one (measured — two back-to-back searches failed), while
/// Discogs allows sixty a minute and reports the budget in
/// `x-discogs-ratelimit`. Retrying after a refusal is not enough for either;
/// the requests have to be spaced before they are sent.
actor ConcertRequestPacer {
    private let minimumInterval: TimeInterval
    private var nextFreeSlot: Date = .distantPast

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    /// Returns once it is this caller's turn. Callers are served in the order
    /// they arrive, because each reserves its slot before sleeping.
    func wait() async {
        let now = Date()
        let slot = max(now, nextFreeSlot)
        nextFreeSlot = slot.addingTimeInterval(minimumInterval)
        let delay = slot.timeIntervalSince(now)
        guard delay > 0 else { return }
        try? await Task.sleep(for: .seconds(delay))
    }
}
