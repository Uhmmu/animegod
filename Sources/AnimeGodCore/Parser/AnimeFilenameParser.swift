import Foundation

public struct ParsedAnimeFilename: Hashable, Sendable {
    public var title: String
    public var season: Int?
    public var episode: Double?
    public var episodeText: String?
    public var episodeKind: EpisodeKind
    public var releaseGroup: String?
    public var resolution: String?
    public var confidence: Double

    public init(
        title: String,
        season: Int? = nil,
        episode: Double? = nil,
        episodeText: String? = nil,
        episodeKind: EpisodeKind = .regular,
        releaseGroup: String? = nil,
        resolution: String? = nil,
        confidence: Double
    ) {
        self.title = title
        self.season = season
        self.episode = episode
        self.episodeText = episodeText
        self.episodeKind = episodeKind
        self.releaseGroup = releaseGroup
        self.resolution = resolution
        self.confidence = confidence
    }
}

public struct AnimeFilenameParser: Sendable {
    private static let mediaExtensions = Set(["mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts"])

    public init() {}

    public func isSupportedMediaFile(_ url: URL) -> Bool {
        Self.mediaExtensions.contains(url.pathExtension.lowercased())
    }

    /// Detects release part markers (前篇 / 後篇 / 上巻 / Part 2 …). A title
    /// carrying one describes its own work even inside a shared folder.
    public static func partLabel(in title: String) -> String? {
        let patterns = [
            #"前篇|後篇|后篇|前編|後編|前编|后编|上篇|下篇|上巻|下巻|上卷|下卷|前半|後半|后半"#,
            #"(?i)part\s*\d+"#
        ]
        for pattern in patterns {
            if let range = title.range(of: pattern, options: .regularExpression) {
                return String(title[range])
            }
        }
        return nil
    }

    /// Recognises adult-video catalogue codes (SONE-615, 300MIUM-712,
    /// FC2-PPV-1234567) as an entire title. Requiring a full match keeps
    /// ordinary anime titles ("K-ON!", "5-toubun") safe.
    public static func isAVCodeTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pattern = #"(?i)^(?:fc2[ -_]?(?:ppv[ -_]?)?\d{4,}|\d{3,4}[a-z]{3,6}[ -_]\d{2,5}|[a-z]{2,6}[ -_]\d{2,5}(?:[ -_][0-9a-z]{1,3})?)$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    /// Produces a stable anime title from a release folder. Release folders are
    /// a better grouping boundary than individual extras such as PVs and menus.
    public func collectionTitle(from folderName: String) -> String {
        var value = folderName
        if Self.mediaExtensions.contains(URL(fileURLWithPath: value).pathExtension.lowercased()) {
            value = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
        }

        let bracketPattern = #"\[([^\]]+)\]|【([^】]+)】"#
        let groups = allCaptures(bracketPattern, in: value).compactMap { captures in
            captures.dropFirst().first(where: { !$0.isEmpty })
        }
        let bracketTitle = groups.dropFirst().first(where: { !isReleaseNoise($0) })
        if let bracketTitle {
            return normalizedCollectionTitle(bracketTitle)
        }

        var withoutGroups = value.replacingOccurrences(of: bracketPattern, with: " ", options: .regularExpression)
        withoutGroups = withoutGroups.replacingOccurrences(
            of: #"(?i)(?:^|\s)(?:19|20)\d{2}(?:\s|$).*"#,
            with: " ",
            options: .regularExpression
        )
        return normalizedCollectionTitle(withoutGroups)
    }

    public func parse(url: URL, libraryRoot: URL? = nil) -> ParsedAnimeFilename {
        let baseName = url.deletingPathExtension().lastPathComponent
        // Dots act as word separators in scene names, but keep dots that sit
        // between digits so fractional episodes like "13.5" survive.
        var working = baseName.replacingOccurrences(
            of: #"(?<!\d)\.(?!\d)"#,
            with: " ",
            options: .regularExpression
        )
        let releaseGroup = leadingBracket(in: working)
        if releaseGroup != nil, let close = working.firstIndex(of: "]") {
            working = String(working[working.index(after: close)...])
        }

        let resolution = firstMatch(#"(?i)(2160p|1080p|720p|480p|4K)"#, in: working, group: 1)
        let special = specialKind(in: working)
        let seasonEpisode = captures(#"(?i)\bS(\d{1,2})E(\d{1,4}(?:\.\d+)?)\b"#, in: working)
        let chineseSeason = firstMatch(#"第\s*([一二三四五六七八九十百\d]+)\s*季"#, in: working, group: 1)
        let chineseEpisode = firstMatch(#"第\s*(\d+(?:\.\d+)?)\s*[集话話]"#, in: working, group: 1)
        let chineseChapter = firstMatch(#"第\s*([一二三四五六七八九十百\d]+(?:\.\d+)?)\s*[章回]"#, in: working, group: 1)

        var season: Int?
        var episode: Double?
        var episodeText: String?
        var matchedToken: String?

        if seasonEpisode.count == 3 {
            season = Int(seasonEpisode[1])
            episode = Double(seasonEpisode[2])
            episodeText = seasonEpisode[2]
            matchedToken = seasonEpisode[0]
        } else if let chineseEpisode {
            episode = Double(chineseEpisode)
            episodeText = chineseEpisode
            matchedToken = firstMatch(#"第\s*\d+(?:\.\d+)?\s*[集话話]"#, in: working, group: 0)
            if let chineseSeason { season = parseChineseNumber(chineseSeason) }
        } else if let chineseChapter, let number = parseChineseNumber(chineseChapter) {
            episode = chineseChapter.contains(".") ? Double(chineseChapter) : Double(number)
            episodeText = chineseChapter
            matchedToken = firstMatch(#"第\s*[一二三四五六七八九十百\d]+(?:\.\d+)?\s*[章回]"#, in: working, group: 0)
            if let chineseSeason { season = parseChineseNumber(chineseSeason) }
        } else if let match = bestDelimitedEpisode(in: working) {
            episode = Double(match.value)
            episodeText = match.value
            matchedToken = match.token
        }

        // Specials keep their release number (SP01 → "01") so the episode
        // list can label them beyond a bare "Special".
        if episode == nil, special != .regular,
           let number = firstMatch(#"(?i)(?:SP|Special|Trailer|PV|Teaser|NCOP|NCED|MV)s?[\s._-]?(\d+)"#, in: working, group: 1) {
            episodeText = number
        }

        let parentTitle = inferredParentTitle(for: url, root: libraryRoot)
        var title = cleanTitle(working, removing: matchedToken)
        if title.isEmpty || title.range(of: #"(?i)^(episode|ep)\s*\d+$"#, options: .regularExpression) != nil {
            title = parentTitle ?? title
        }
        if let parentTitle, isGenericFilename(baseName) {
            title = parentTitle
        }

        let confidence: Double
        if episode != nil && !title.isEmpty {
            confidence = parentTitle == nil ? 0.82 : 0.92
        } else if special != .regular && !title.isEmpty {
            confidence = 0.75
        } else {
            confidence = parentTitle == nil ? 0.42 : 0.62
        }

        return ParsedAnimeFilename(
            title: title.isEmpty ? baseName : title,
            season: season,
            episode: episode,
            episodeText: episodeText,
            episodeKind: special,
            releaseGroup: releaseGroup,
            resolution: resolution,
            confidence: confidence
        )
    }

    private func leadingBracket(in value: String) -> String? {
        firstMatch(#"^\[([^\]]+)\]"#, in: value, group: 1)
    }

    private func bestDelimitedEpisode(in value: String) -> (token: String, value: String)? {
        // Release versions ("07v2") point at the same episode, not a new one.
        let patterns = [
            #"(?i)\b(?:EP?|Episode)\s*[-_. ]?\s*(\d{1,4}(?:\.\d+)?)(?:v\d+)?\b"#,
            #"\s-\s(\d{1,4}(?:\.\d+)?)(?:v\d+)?(?:\s|$)"#,
            #"\[(\d{1,4}(?:\.\d+)?)\]"#,
            #"^\s*(\d{1,4}(?:\.\d+)?)\s*$"#
        ]
        for pattern in patterns {
            let found = captures(pattern, in: value)
            if found.count > 1 { return (found[0], found[1]) }
        }
        return nil
    }

    private func specialKind(in value: String) -> EpisodeKind {
        // Numbered clips ("PV1", "[NCOP2]") are as common as bare tags, so
        // every marker accepts a trailing release number.
        if value.range(of: #"(?i)(?:^|[\s._\[\]-])NCOP[\s._-]?\d*(?:[\s._\[\]-]|$)"#, options: .regularExpression) != nil { return .opening }
        if value.range(of: #"(?i)(?:^|[\s._\[\]-])NCED[\s._-]?\d*(?:[\s._\[\]-]|$)"#, options: .regularExpression) != nil { return .ending }
        if value.range(of: #"(?i)(?:^|[\s._-])MVs?(?:[\s._-]?\d+)?(?:[\s._-]|$)|music\s*video"#, options: .regularExpression) != nil { return .music }
        if value.range(of: #"(?i)(?:^|[\s._\[\]-])Menu(?:[\s._\[\]-]?\d+)?(?:[\s._\[\]-]|$)"#, options: .regularExpression) != nil { return .extra }
        if value.range(of: #"(?i)\b(?:PV|Trailer|Teaser)\s*\d*\b"#, options: .regularExpression) != nil { return .trailer }
        if value.range(of: #"(?i)\b(?:SP|Special)\s*\d*\b"#, options: .regularExpression) != nil { return .special }
        return .regular
    }

    private func inferredParentTitle(for url: URL, root: URL?) -> String? {
        let parent = url.deletingLastPathComponent()
        guard parent != root, !parent.lastPathComponent.isEmpty else { return nil }
        return cleanTitle(parent.lastPathComponent.replacingOccurrences(of: ".", with: " "), removing: nil)
    }

    private func isGenericFilename(_ value: String) -> Bool {
        value.range(of: #"(?i)^\s*(?:EP?|Episode)?\s*\d{1,4}(?:\.\d+)?\s*$"#, options: .regularExpression) != nil ||
            value.range(of: #"(?i)^\s*(?:movie|ova|special|sp)\s*\d*\s*$"#, options: .regularExpression) != nil
    }

    private func cleanTitle(_ value: String, removing token: String?) -> String {
        var result = value
        if let token { result = result.replacingOccurrences(of: token, with: " ") }
        // Pirate-site ads (【更多蓝光电影访问 www.xxx.com】) and subtitle
        // spec brackets never belong to a work's title.
        let adBracket = #"(?i)[【\[][^】\]]*(?:https?|www\.|\.com|\.net|\.cc|\.xyz|\.org|首发|更多|注册|会员|无限制|下载|资源|高清|蓝光|影视|访问|简繁|简体|繁体|中字|中文字幕|双语|内封|外挂|官校|特效|生肉|熟肉)[^】\]]*[】\]]"#
        result = result.replacingOccurrences(of: adBracket, with: " ", options: .regularExpression)
        // A release year followed by technical tags marks the start of the
        // technical tail ("Paprika 2006 RERiP 1080p …" → "Paprika").
        let yearTail = #"(?i)[\s\-·–.]*(?:19|20)\d{2}(?=[\s\-·–.]*\b(?:2160p|1080p|720p|480p|4k|x26[45]|hevc|avc|av1|bluray|blu-?ray|bu-?ray|bdrip|uhdbdrip|dvdrip|webrip|web-?dl|remux|rerip|repack|proper|remaster\w*|dts|truehd|flac|aac|ddp?|ac3|10bit|ma10p|hdr|uhd|60fps)\b)[\s\-·–.]*.*$"#
        result = result.replacingOccurrences(of: yearTail, with: " ", options: .regularExpression)
        let noisePatterns = [
            #"(?i)\[[^\]]*(?:1080p|720p|2160p|480p|x26[45]|hevc|av1|flac|aac|[A-F0-9]{6,10})[^\]]*\]"#,
            #"(?i)\([^\)]*(?:1080p|720p|2160p|480p|x26[45]|hevc|av1)[^\)]*\)"#,
            #"(?i)\((?:19|20)\d{2}\)"#,
            #"(?i)\b(?:2160p|1080p|720p|480p|4K|x26[45]|HEVC|AV1|FLAC|AAC|Blu-?ray|Bu-?ray|BDRip|UHDBDRip|DVDRip|WEBRip|WEB-?DL|REMUX|DTS|DDP|AC3|TrueHD|REMASTER\w*|RERiP|REPACK|PROPER|10bit|HDR|UHD|60FPS)\b"#,
            #"第\s*[一二三四五六七八九十百\d]+\s*季"#,
            #"(?i)\bS\d{1,2}\b"#
        ]
        for pattern in noisePatterns {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: #"[\[\](){}]+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s*[-–—]\s*$"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.")))
    }

    private func captures(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return [] }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }

    private func allCaptures(_ pattern: String, in value: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: value) else { return "" }
                return String(value[range])
            }
        }
    }

    private func isReleaseNoise(_ value: String) -> Bool {
        let folded = value.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        let technical = #"(?i)(?:^|[^a-z0-9])(?:4k|hdr|uhd|2160p?|1080p?|720p?|480p?|bd(?:rip)?|blu-?ray|web(?:-?dl)?|hevc|x26[45]|avc|av1|10bit|ma10p|flac|aac|ddp|dts|mkv|mp4|chs|cht|jpn|eng|gb|简繁|字幕|外挂|内封)(?:[^a-z0-9]|$)"#
        // "前篇+后篇"-style bracket labels describe the release set, not a work.
        let partSet = ["前篇", "前編", "后篇", "後編", "上巻", "下巻", "上卷", "下卷"]
        return folded.range(of: technical, options: .regularExpression) != nil ||
            partSet.contains { folded.contains($0) } ||
            folded.contains("www.") || folded.contains(".com") || folded.contains("首发") || folded.contains("更多")
    }

    /// Words that describe what a release folder bundles ("Scans&OST&Special")
    /// rather than the work itself.
    private static let releaseContentWords: Set<String> = [
        "scan", "scans", "ost", "osts", "soundtrack", "cd", "cds", "bk", "booklet",
        "sp", "sps", "special", "specials", "extra", "extras", "bonus", "menu", "menus",
        "pv", "pvs", "cm", "cms", "ncop", "nced", "nc", "trailer", "trailers", "font", "fonts",
        "sub", "subs", "subtitle", "subtitles", "fin", "complete", "tv", "movie", "ova", "oad",
        "特典", "映像特典", "扫图", "掃圖", "原声", "原聲", "字体", "字幕", "外挂", "内封"
    ]

    /// Removes parenthesised groups that only list release contents or
    /// technical tags. Groups holding anything else (a year, a subtitle) stay.
    private func removingReleaseContentGroups(_ value: String) -> String {
        let pattern = #"[(（]([^()（）]*)[)）]"#
        var result = value
        for captures in allCaptures(pattern, in: value).reversed() {
            let content = captures[1]
            let tokens = content
                .folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
                .split(whereSeparator: { "&+,、/;".contains($0) || $0.isWhitespace })
                .map(String.init)
            guard !tokens.isEmpty,
                  tokens.allSatisfy({ Self.releaseContentWords.contains($0) || isReleaseNoise($0) }),
                  let range = result.range(of: captures[0], options: .backwards) else { continue }
            result.replaceSubrange(range, with: " ")
        }
        return result
    }

    private func normalizedCollectionTitle(_ value: String) -> String {
        var result = removingReleaseContentGroups(value).replacingOccurrences(of: ".", with: " ")
        result = result.replacingOccurrences(of: #"(?i)\b(?:movie|bdrip|uhdbrip|web-?dl|1080p|2160p|720p|4k)\b.*$"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_[]【】")))
    }

    private func firstMatch(_ pattern: String, in value: String, group: Int) -> String? {
        let found = captures(pattern, in: value)
        guard found.indices.contains(group) else { return nil }
        return found[group]
    }

    private func parseChineseNumber(_ value: String) -> Int? {
        if let number = Int(value) { return number }
        let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if value == "十" { return 10 }
        if value.contains("十") {
            let parts = value.split(separator: "十", omittingEmptySubsequences: false)
            let tens = parts.first?.first.flatMap { digits[$0] } ?? 1
            let ones = parts.count > 1 ? (parts[1].first.flatMap { digits[$0] } ?? 0) : 0
            return tens * 10 + ones
        }
        return value.first.flatMap { digits[$0] }
    }
}
