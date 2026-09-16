import Foundation

public enum TorrentSubtitleLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case simplifiedChinese
    case traditionalChinese
    case japanese
    case english

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .simplifiedChinese: "简"
        case .traditionalChinese: "繁"
        case .japanese: "日"
        case .english: "EN"
        }
    }
}

public enum TorrentSubtitleStyle: String, Codable, Sendable {
    /// Burned into the video (内嵌 / hardsub).
    case hardcoded
    /// A selectable track inside the container (内封 / softsub).
    case embeddedTrack
    /// Separate subtitle files (外挂).
    case external

    public var displayName: String {
        switch self {
        case .hardcoded: "内嵌"
        case .embeddedTrack: "内封"
        case .external: "外挂"
        }
    }
}

/// What a release title says about itself: fansub, episodes, and technical
/// tags. Indexes are free-form, so everything is optional.
public struct TorrentReleaseInfo: Hashable, Sendable {
    public var group: String?
    /// Single episode (`first == last`) or an inclusive range for batches.
    public var firstEpisode: Double?
    public var lastEpisode: Double?
    public var season: Int?
    public var isBatch: Bool
    public var resolution: String?
    public var videoCodec: String?
    public var videoSource: String?
    public var subtitleLanguages: Set<TorrentSubtitleLanguage>
    public var subtitleStyle: TorrentSubtitleStyle?

    public init(
        group: String? = nil,
        firstEpisode: Double? = nil,
        lastEpisode: Double? = nil,
        season: Int? = nil,
        isBatch: Bool = false,
        resolution: String? = nil,
        videoCodec: String? = nil,
        videoSource: String? = nil,
        subtitleLanguages: Set<TorrentSubtitleLanguage> = [],
        subtitleStyle: TorrentSubtitleStyle? = nil
    ) {
        self.group = group
        self.firstEpisode = firstEpisode
        self.lastEpisode = lastEpisode
        self.season = season
        self.isBatch = isBatch
        self.resolution = resolution
        self.videoCodec = videoCodec
        self.videoSource = videoSource
        self.subtitleLanguages = subtitleLanguages
        self.subtitleStyle = subtitleStyle
    }

    /// "05", "01–13", or nil.
    public var episodeLabel: String? {
        guard let firstEpisode else { return nil }
        let first = Self.format(firstEpisode)
        guard let lastEpisode, lastEpisode != firstEpisode else { return first }
        return "\(first)–\(Self.format(lastEpisode))"
    }

    public func covers(episode: Double) -> Bool {
        guard let firstEpisode else { return false }
        return episode >= firstEpisode && episode <= (lastEpisode ?? firstEpisode)
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%02d", Int(value)) : String(value)
    }

    // MARK: - Parsing

    public static func parse(title: String) -> TorrentReleaseInfo {
        var info = TorrentReleaseInfo()
        let text = title.replacingOccurrences(of: "_", with: " ")
        info.group = leadingGroup(in: text)
        info.resolution = resolution(in: text)
        info.videoCodec = codec(in: text)
        info.videoSource = source(in: text)
        (info.subtitleLanguages, info.subtitleStyle) = subtitles(in: text)
        info.season = season(in: text)

        // Technical tags contain digits ("2160P", "10bit", "x265", CRC32
        // "[E40B0C28]", dates) that must not read as episodes.
        let stripped = strippingTechnicalTags(from: text)
        if let range = episodeRange(in: stripped) {
            info.firstEpisode = range.0
            info.lastEpisode = range.1
            info.isBatch = range.1 > range.0
        } else if let episode = singleEpisode(in: stripped) {
            info.firstEpisode = episode
            info.lastEpisode = episode
        }
        if text.range(of: #"(?i)合集|全集|全\d+[话話集]|\bbatch\b|\bcomplete\b|\bBD-?BOX\b"#, options: .regularExpression) != nil {
            info.isBatch = true
        }
        return info
    }

    private static func leadingGroup(in text: String) -> String? {
        guard let captured = firstCapture(#"^\s*(?:\[([^\]]+)\]|【([^】]+)】)"#, in: text) else { return nil }
        let value = captured.trimmingCharacters(in: .whitespaces)
        // "[01月新番]" / "[2026.06.17]" / "[1080p]" are not teams.
        if value.range(of: #"(?i)新番|^\d{4}[.\-年]|^\d+p$|^\d+$"#, options: .regularExpression) != nil { return nil }
        return value
    }

    private static func resolution(in text: String) -> String? {
        if text.range(of: #"(?i)2160p|\b4K\b|3840\s*[x×]\s*2160"#, options: .regularExpression) != nil { return "2160p" }
        if text.range(of: #"(?i)1080p|1920\s*[x×]\s*1080|\bFHD\b"#, options: .regularExpression) != nil { return "1080p" }
        if text.range(of: #"(?i)720p|1280\s*[x×]\s*720"#, options: .regularExpression) != nil { return "720p" }
        if text.range(of: #"(?i)480p|\bSD\b"#, options: .regularExpression) != nil { return "480p" }
        return nil
    }

    private static func codec(in text: String) -> String? {
        if text.range(of: #"(?i)\bHEVC\b|[xh]\.?265"#, options: .regularExpression) != nil { return "HEVC" }
        if text.range(of: #"(?i)\bAV1\b"#, options: .regularExpression) != nil { return "AV1" }
        if text.range(of: #"(?i)\bAVC\b|[xh]\.?264"#, options: .regularExpression) != nil { return "AVC" }
        return nil
    }

    private static func source(in text: String) -> String? {
        if text.range(of: #"(?i)\bBD(?:Rip|MV|-?BOX)?\b|Blu-?ray|\bBDRemux\b"#, options: .regularExpression) != nil { return "BD" }
        if text.range(of: #"(?i)\bWEB(?:-?DL|-?Rip)?\b|\bBaha\b|\bCR\b|\bB-Global\b|Bilibili|\bABEMA\b|\bNetflix\b|\bAMZN\b"#, options: .regularExpression) != nil { return "WEB" }
        if text.range(of: #"(?i)\bDVD(?:Rip)?\b"#, options: .regularExpression) != nil { return "DVD" }
        if text.range(of: #"(?i)\bTV-?Rip\b|\bHDTV\b"#, options: .regularExpression) != nil { return "TV" }
        return nil
    }

    private static func subtitles(in text: String) -> (Set<TorrentSubtitleLanguage>, TorrentSubtitleStyle?) {
        var languages: Set<TorrentSubtitleLanguage> = []
        var style: TorrentSubtitleStyle?
        // Only bracketed tags talk about subtitles; "日" or "繁" in a title
        // ("日常", "繁花") must not count.
        let brackets = allCaptures(#"\[([^\]]*)\]|【([^】]*)】|\(([^)]*)\)"#, in: text)
        let subtitleMarker = #"(?i)字幕|双语|雙語|内嵌|內嵌|内封|內封|外挂|外掛|CHS|CHT|\bGB\b|BIG5|JPSC|JPTC|简|簡|繁|Multi-?Subs?|\bENG\b|中字|中文"#
        for tag in brackets where tag.range(of: subtitleMarker, options: .regularExpression) != nil {
            if tag.range(of: #"(?i)简|簡|CHS|\bGB\b|SC\b"#, options: .regularExpression) != nil { languages.insert(.simplifiedChinese) }
            if tag.range(of: #"(?i)繁|CHT|BIG5|TC\b"#, options: .regularExpression) != nil { languages.insert(.traditionalChinese) }
            if tag.range(of: #"(?i)日|\bJP(?:N|SC|TC)?\b"#, options: .regularExpression) != nil { languages.insert(.japanese) }
            if tag.range(of: #"(?i)英|\bENG?\b|English"#, options: .regularExpression) != nil { languages.insert(.english) }
            if tag.range(of: #"中文|中字"#, options: .regularExpression) != nil, languages.isEmpty { languages.insert(.simplifiedChinese) }
            if tag.range(of: #"内封|內封|softsub"#, options: [.regularExpression, .caseInsensitive]) != nil { style = .embeddedTrack }
            else if tag.range(of: #"内嵌|內嵌|hardsub"#, options: [.regularExpression, .caseInsensitive]) != nil { style = .hardcoded }
            else if tag.range(of: #"外挂|外掛"#, options: .regularExpression) != nil { style = .external }
        }
        return (languages, style)
    }

    private static func season(in text: String) -> Int? {
        if let value = firstCapture(#"(?i)\bS(\d{1,2})(?:E\d+|\b)"#, in: text) { return Int(value) }
        if let value = firstCapture(#"第\s*([一二三四五六七八九十\d]+)\s*[季期]"#, in: text) { return chineseNumber(value) }
        if let value = firstCapture(#"(?i)\b(\d)(?:st|nd|rd|th)\s+Season\b"#, in: text) { return Int(value) }
        if let value = firstCapture(#"(?i)\bSeason\s*(\d{1,2})\b"#, in: text) { return Int(value) }
        return nil
    }

    private static func strippingTechnicalTags(from text: String) -> String {
        let patterns = [
            #"(?i)\b(?:2160|1080|720|480)[pi]\b"#,
            #"(?i)\d{3,4}\s*[x×]\s*\d{3,4}"#,
            #"(?i)\b(?:[xh]\.?26[45]|10-?bit|8-?bit|Ma10p|Hi10p|AAC\d?(?:\.\d)?|FLAC|OPUS|AC3|DDP?\d(?:\.\d)?|E-?AC-?3|HDR10\+?|DTS(?:-HD)?|60fps|v\d)\b"#,
            #"\[[0-9A-Fa-f]{8}\]"#,
            #"(?:19|20)\d{2}[.\-/年]\d{1,2}(?:[.\-/月]\d{1,2}日?)?"#,
            #"(?i)\b\d{1,2}月新番\b|\d{1,2}月新番"#,
            #"(?i)\bS\d{1,2}\b"#,
            #"第\s*[一二三四五六七八九十\d]+\s*[季期]"#
        ]
        return patterns.reduce(text) { $0.replacingOccurrences(of: $1, with: " ", options: .regularExpression) }
    }

    private static func episodeRange(in text: String) -> (Double, Double)? {
        let patterns = [
            #"(?i)\bS\d{1,2}E(\d{1,4})\s*[-~～]\s*(?:S\d{1,2})?E(\d{1,4})\b"#,
            #"第\s*(\d{1,4})\s*[-~～]\s*(\d{1,4})\s*[话話集]"#,
            #"[\[【(（\s](\d{1,4})\s*[-~～]\s*(\d{1,4})(?:\s*(?:Fin|END|合集|全集|完|\+\s*\w+))?\s*[\]】)）\s]"#,
            #"(?i)\bEP?(\d{1,4})\s*[-~～]\s*EP?(\d{1,4})\b"#
        ]
        for pattern in patterns {
            let found = allGroups(pattern, in: " \(text) ")
            if found.count == 2, let first = Double(found[0]), let last = Double(found[1]), last > first, last - first < 2000 {
                return (first, last)
            }
        }
        return nil
    }

    private static func singleEpisode(in text: String) -> Double? {
        let patterns = [
            #"(?i)\bS\d{1,2}E(\d{1,4}(?:\.\d)?)\b"#,
            #"第\s*(\d{1,4}(?:\.\d)?)\s*[话話集]"#,
            #"(?i)\b(?:EP|Episode|E)\s?(\d{1,4}(?:\.\d)?)(?:v\d)?\b"#,
            #"\s[-–]\s(\d{1,4}(?:\.\d)?)(?:v\d)?(?:\s|$|\.|\()"#,
            #"[\[【](\d{1,4}(?:\.\d)?)(?:v\d)?(?:\s*END)?[\]】]"#,
            #"#(\d{1,4})\b"#
        ]
        for pattern in patterns {
            if let value = firstCapture(pattern, in: " \(text) "), let number = Double(value) {
                return number
            }
        }
        return nil
    }

    private static func chineseNumber(_ value: String) -> Int? {
        if let number = Int(value) { return number }
        let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if value == "十" { return 10 }
        if value.hasPrefix("十") { return 10 + (value.last.flatMap { digits[$0] } ?? 0) }
        if value.contains("十") {
            let parts = value.split(separator: "十", omittingEmptySubsequences: false)
            return (parts[0].first.flatMap { digits[$0] } ?? 1) * 10 + (parts.count > 1 ? parts[1].first.flatMap { digits[$0] } ?? 0 : 0)
        }
        return value.first.flatMap { digits[$0] }
    }

    // MARK: - Regex helpers

    /// First non-empty capture group of the first match.
    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for index in 1..<max(match.numberOfRanges, 1) {
            if let range = Range(match.range(at: index), in: text), !range.isEmpty {
                return String(text[range])
            }
        }
        return nil
    }

    /// All non-empty capture groups of the first match, in order.
    private static func allGroups(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<max(match.numberOfRanges, 1)).compactMap { index in
            Range(match.range(at: index), in: text).flatMap { $0.isEmpty ? nil : String(text[$0]) }
        }
    }

    /// The first non-empty capture group of every match.
    private static func allCaptures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            (1..<max(match.numberOfRanges, 1)).lazy.compactMap { index in
                Range(match.range(at: index), in: text).flatMap { $0.isEmpty ? nil : String(text[$0]) }
            }.first
        }
    }
}
