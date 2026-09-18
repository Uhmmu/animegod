import Foundation

/// Subtitle languages AnimeGod distinguishes. Raw values are BCP 47 tags;
/// every provider translates its own codes (`ZH_BG`, `zh-tw`, `langcht` …)
/// into these, so ranking and caching never see provider vocabulary.
public enum SubtitleLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    /// Chinese whose script the provider did not state. Resolved from the
    /// file's own text after download when possible.
    case chinese = "zh"
    case japanese = "ja"
    case english = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .chinese: "中文"
        case .japanese: "日本語"
        case .english: "English"
        }
    }

    public var isChinese: Bool {
        self == .simplifiedChinese || self == .traditionalChinese || self == .chinese
    }

    /// Languages a user can rank; `.chinese` is only ever reported.
    public static let rankable: [SubtitleLanguage] = [.simplifiedChinese, .traditionalChinese, .japanese, .english]

    /// Reads the language of a player track from its (ISO 639 / BCP 47)
    /// language code and its title. Fansub tracks are often titled "简体"
    /// or "CHT" with no language code at all.
    public static func fromTrack(language: String?, title: String?) -> SubtitleLanguage? {
        if let fromTitle = fromLabel(title ?? "") { return fromTitle }
        guard let code = language?.lowercased().replacingOccurrences(of: "_", with: "-"), !code.isEmpty else { return nil }
        switch code {
        case "zh-hans", "zh-cn", "zh-sg", "chs", "sc", "zhs", "zh-chs": return .simplifiedChinese
        case "zh-hant", "zh-tw", "zh-hk", "zh-mo", "cht", "tc", "zht", "zh-cht": return .traditionalChinese
        case "zh", "chi", "zho", "ze", "cmn", "yue": return .chinese
        case "ja", "jpn", "jp": return .japanese
        case "en", "eng": return .english
        default:
            if code.hasPrefix("zh") { return .chinese }
            if code.hasPrefix("en") { return .english }
            if code.hasPrefix("ja") { return .japanese }
            return nil
        }
    }

    /// Language named by a free-form label ("简体中文", "CHT", "繁日双语",
    /// "Chinese (Traditional)"). Returns nil when the label says nothing.
    public static func fromLabel(_ label: String) -> SubtitleLanguage? {
        let folded = label.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if folded.range(of: #"简|簡体|簡體|chs|\bsc\b|\bgb\b|zh-?hans|zh-?cn|simplified|jpsc"#, options: .regularExpression) != nil {
            return .simplifiedChinese
        }
        if folded.range(of: #"繁|cht|\btc\b|big5|zh-?hant|zh-?tw|zh-?hk|traditional|jptc"#, options: .regularExpression) != nil {
            return .traditionalChinese
        }
        if folded.range(of: #"中文|中字|chinese|\bchi\b|\bzho\b"#, options: .regularExpression) != nil { return .chinese }
        if folded.range(of: #"日本語|日语|日語|japanese|\bjpn\b"#, options: .regularExpression) != nil { return .japanese }
        if folded.range(of: #"english|\beng\b|英语|英語"#, options: .regularExpression) != nil { return .english }
        return nil
    }
}

public enum SubtitleFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case ass
    case ssa
    case srt
    case vtt

    public var id: String { rawValue }
    public var displayName: String { rawValue.uppercased() }

    public init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }

    public static func of(fileName: String) -> SubtitleFormat? {
        SubtitleFormat(fileExtension: (fileName as NSString).pathExtension)
    }

    /// Styled formats carry typesetting; libass renders them natively.
    public var isStyled: Bool { self == .ass || self == .ssa }
}

public enum SubtitleProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case assrt
    case subdl
    case openSubtitles = "opensubtitles"
    case jimaku

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .assrt: "射手网(伪)"
        case .subdl: "SubDL"
        case .openSubtitles: "OpenSubtitles"
        case .jimaku: "Jimaku"
        }
    }

    public var homepage: URL {
        switch self {
        case .assrt: URL(string: "https://assrt.net")!
        case .subdl: URL(string: "https://subdl.com")!
        case .openSubtitles: URL(string: "https://www.opensubtitles.com")!
        case .jimaku: URL(string: "https://jimaku.cc")!
        }
    }

    /// Languages the provider can realistically serve. Jimaku is a
    /// Japanese-subtitle archive; searching it for Chinese wastes quota.
    public var servedLanguages: Set<SubtitleLanguage> {
        switch self {
        case .jimaku: [.japanese]
        default: Set(SubtitleLanguage.allCases)
        }
    }
}

/// How a provider tied a result to the video — the stronger the basis, the
/// more the identity part of the score can be trusted.
public enum SubtitleMatchBasis: String, Codable, Sendable {
    /// A hash of the video's own bytes (OpenSubtitles moviehash).
    case fileHash
    /// An external database ID (AniList, TMDB) the provider indexes by.
    case externalID
    /// Free-text title search; the scorer must verify the title itself.
    case title
}

/// Cross-database IDs for the work being played. Everything is optional:
/// providers use whatever they index by and fall back to titles.
public struct SubtitleAnimeIDs: Codable, Hashable, Sendable {
    public enum TMDBKind: String, Codable, Sendable { case tv, movie }

    public var bangumiID: Int?
    public var aniListID: Int?
    public var malID: Int?
    public var aniDBID: Int?
    public var tmdbID: Int?
    public var tmdbKind: TMDBKind?
    /// TMDB's season number for this work, which differs from the cour
    /// numbering fansubs use when TMDB folds several cours into one season.
    public var tmdbSeason: Int?
    public var imdbID: String?

    public init(
        bangumiID: Int? = nil, aniListID: Int? = nil, malID: Int? = nil, aniDBID: Int? = nil,
        tmdbID: Int? = nil, tmdbKind: TMDBKind? = nil, tmdbSeason: Int? = nil, imdbID: String? = nil
    ) {
        self.bangumiID = bangumiID
        self.aniListID = aniListID
        self.malID = malID
        self.aniDBID = aniDBID
        self.tmdbID = tmdbID
        self.tmdbKind = tmdbKind
        self.tmdbSeason = tmdbSeason
        self.imdbID = imdbID
    }

    /// Fills gaps from another set without overwriting known values.
    public func merging(_ other: SubtitleAnimeIDs) -> SubtitleAnimeIDs {
        SubtitleAnimeIDs(
            bangumiID: bangumiID ?? other.bangumiID,
            aniListID: aniListID ?? other.aniListID,
            malID: malID ?? other.malID,
            aniDBID: aniDBID ?? other.aniDBID,
            tmdbID: tmdbID ?? other.tmdbID,
            tmdbKind: tmdbKind ?? other.tmdbKind,
            tmdbSeason: tmdbSeason ?? other.tmdbSeason,
            imdbID: imdbID ?? other.imdbID
        )
    }
}

/// Everything known about the video a subtitle must fit: which work and
/// episode, and — just as important for timing — which release.
public struct SubtitleVideoIdentity: Codable, Hashable, Sendable {
    /// Work titles, most useful first (library/localized, original, then the
    /// title parsed from the filename).
    public var titles: [String]
    public var season: Int?
    public var episode: Double?
    public var episodeKind: EpisodeKind
    public var isMovie: Bool
    public var releaseGroup: String?
    /// Normalized video source: "BD", "WEB", "DVD" or "TV".
    public var source: String?
    public var resolution: String?
    public var videoCodec: String?
    public var fileName: String
    public var fileSize: Int64
    public var duration: Double?
    public var ids: SubtitleAnimeIDs
    /// OpenSubtitles moviehash of the file, when it could be read.
    public var openSubtitlesHash: String?

    public init(
        titles: [String],
        season: Int? = nil,
        episode: Double? = nil,
        episodeKind: EpisodeKind = .regular,
        isMovie: Bool = false,
        releaseGroup: String? = nil,
        source: String? = nil,
        resolution: String? = nil,
        videoCodec: String? = nil,
        fileName: String,
        fileSize: Int64 = 0,
        duration: Double? = nil,
        ids: SubtitleAnimeIDs = SubtitleAnimeIDs(),
        openSubtitlesHash: String? = nil
    ) {
        self.titles = titles
        self.season = season
        self.episode = episode
        self.episodeKind = episodeKind
        self.isMovie = isMovie
        self.releaseGroup = releaseGroup
        self.source = source
        self.resolution = resolution
        self.videoCodec = videoCodec
        self.fileName = fileName
        self.fileSize = fileSize
        self.duration = duration
        self.ids = ids
        self.openSubtitlesHash = openSubtitlesHash
    }

    /// Builds the release half of the identity from the filename alone,
    /// with both existing parsers: `AnimeFilenameParser` for the work and
    /// episode, `TorrentReleaseInfo` for source and codec tags.
    public static func fromFileName(
        _ fileName: String,
        titles: [String] = [],
        episode: Double? = nil,
        episodeKind: EpisodeKind? = nil,
        fileSize: Int64 = 0
    ) -> SubtitleVideoIdentity {
        let parsed = SubtitleReleaseParsing.parseFileName(fileName)
        let release = TorrentReleaseInfo.parse(title: fileName)
        var allTitles = titles
        if !parsed.title.isEmpty { allTitles.append(parsed.title) }
        return SubtitleVideoIdentity(
            titles: SubtitleReleaseParsing.distinct(allTitles),
            season: parsed.season ?? release.season,
            episode: episode ?? parsed.episode,
            episodeKind: episodeKind ?? parsed.episodeKind,
            isMovie: (episode ?? parsed.episode) == nil && (episodeKind ?? parsed.episodeKind) == .regular,
            releaseGroup: parsed.releaseGroup ?? release.group,
            source: release.videoSource,
            resolution: release.resolution ?? parsed.resolution.map { $0.lowercased() },
            videoCodec: release.videoCodec,
            fileName: fileName,
            fileSize: fileSize
        )
    }

    /// The season providers should be asked for.
    public var effectiveSeason: Int {
        season ?? titles.lazy.compactMap(DanmakuTitleSimilarity.seasonNumber(in:)).first ?? 1
    }

    /// "S01E14", "E14", "SP02" or "Movie" — used for cache folders and UI.
    public var episodeLabel: String {
        guard let episode else { return episodeKind == .regular ? "Movie" : episodeKind.rawValue.capitalized }
        let number = episode.rounded() == episode ? String(format: "%02d", Int(episode)) : String(episode)
        switch episodeKind {
        case .special: return "SP\(number)"
        case .regular: return String(format: "S%02dE", effectiveSeason) + number
        default: return "\(episodeKind.rawValue.uppercased())\(number)"
        }
    }
}

/// What to search for. Built from the identity, optionally overridden by
/// the user's own text in the manual search sheet.
public struct SubtitleQuery: Sendable {
    public var identity: SubtitleVideoIdentity
    /// Preferred languages, best first.
    public var languages: [SubtitleLanguage]
    /// Manual search text replacing the automatic title queries.
    public var customText: String?

    public init(identity: SubtitleVideoIdentity, languages: [SubtitleLanguage], customText: String? = nil) {
        self.identity = identity
        self.languages = languages
        self.customText = customText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Titles to search with: the custom text alone when given.
    public var searchTitles: [String] {
        if let customText { return [customText] }
        return identity.titles
    }
}

/// One subtitle (or subtitle archive) as a provider reported it.
public struct SubtitleResult: Identifiable, Codable, Hashable, Sendable {
    public var provider: SubtitleProviderID
    /// The provider's own identifier.
    public var providerSubtitleID: String
    /// The work as the provider names it, for display and title checks.
    public var title: String
    /// Extra names the provider lists (aliases, native titles).
    public var alternativeTitles: [String]
    /// The video release this subtitle was timed to, as named by the
    /// provider — the single most important signal for correct timing.
    public var releaseName: String?
    public var fileName: String?
    public var languages: [SubtitleLanguage]
    /// Nil when the format is only known after unpacking an archive.
    public var format: SubtitleFormat?
    public var season: Int?
    public var episode: Double?
    /// Last episode for season packs; `episode` is then the first.
    public var episodeRangeEnd: Double?
    public var isPack: Bool
    public var basis: SubtitleMatchBasis
    /// Who made or uploaded the subtitle (a fansub group, a user).
    public var author: String?
    public var downloadCount: Int?
    public var isMachineTranslated: Bool
    /// The provider matched the video's own hash.
    public var isHashMatch: Bool
    public var uploadedAt: Date?
    public var pageURL: URL?
    /// Opaque provider state needed to download this result.
    public var downloadContext: String

    public var id: String { "\(provider.rawValue):\(providerSubtitleID)" }

    public init(
        provider: SubtitleProviderID,
        providerSubtitleID: String,
        title: String,
        alternativeTitles: [String] = [],
        releaseName: String? = nil,
        fileName: String? = nil,
        languages: [SubtitleLanguage],
        format: SubtitleFormat? = nil,
        season: Int? = nil,
        episode: Double? = nil,
        episodeRangeEnd: Double? = nil,
        isPack: Bool = false,
        basis: SubtitleMatchBasis,
        author: String? = nil,
        downloadCount: Int? = nil,
        isMachineTranslated: Bool = false,
        isHashMatch: Bool = false,
        uploadedAt: Date? = nil,
        pageURL: URL? = nil,
        downloadContext: String
    ) {
        self.provider = provider
        self.providerSubtitleID = providerSubtitleID
        self.title = title
        self.alternativeTitles = alternativeTitles
        self.releaseName = releaseName
        self.fileName = fileName
        self.languages = languages
        self.format = format
        self.season = season
        self.episode = episode
        self.episodeRangeEnd = episodeRangeEnd
        self.isPack = isPack
        self.basis = basis
        self.author = author
        self.downloadCount = downloadCount
        self.isMachineTranslated = isMachineTranslated
        self.isHashMatch = isHashMatch
        self.uploadedAt = uploadedAt
        self.pageURL = pageURL
        self.downloadContext = downloadContext
    }

    /// The release the subtitle claims to be timed to, parsed with the same
    /// parser the video goes through.
    public var timedRelease: TorrentReleaseInfo {
        TorrentReleaseInfo.parse(title: releaseName ?? fileName ?? "")
    }

    /// Display group: the video release group when the provider names one,
    /// otherwise whoever made the subtitle.
    public var displayGroup: String? {
        timedRelease.group ?? author
    }
}

/// A file a provider returned: a subtitle, a font, or an archive of both.
public struct SubtitleDownloadedFile: Sendable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public enum SubtitleProviderError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded(String?)
    case httpStatus(Int)
    case invalidResponse
    case serviceMessage(String)
    case unsupportedArchive(String)
    case noSuitableFile
    case invalidSubtitle

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Not configured — add its API key in Settings."
        case .unauthorized: "The API key or login was rejected."
        case let .rateLimited(retryAfter):
            retryAfter.map { "Rate limited — try again in \(Int($0.rounded(.up)))s." } ?? "Rate limited — try again shortly."
        case let .quotaExceeded(message): message ?? "The daily download quota is used up."
        case let .httpStatus(code): "The service answered HTTP \(code)."
        case .invalidResponse: "The service returned an unexpected response."
        case let .serviceMessage(message): message
        case let .unsupportedArchive(kind): "The subtitle is packed as \(kind), which AnimeGod cannot open."
        case .noSuitableFile: "The download contains no subtitle for this episode."
        case .invalidSubtitle: "The downloaded file is not a readable subtitle."
        }
    }
}
