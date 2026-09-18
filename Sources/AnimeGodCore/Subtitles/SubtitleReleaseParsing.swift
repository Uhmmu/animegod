import Foundation

/// Filename and release-name helpers shared by providers, the scorer and
/// the archive file selector. They wrap the library's existing parsers
/// rather than adding a third one.
public enum SubtitleReleaseParsing {
    /// Parses a bare file or release name (no directory) with the library
    /// filename parser. A placeholder parent keeps the parser from treating
    /// the filesystem root as the work's folder.
    public static func parseFileName(_ name: String) -> ParsedAnimeFilename {
        let base = strippingTagBrackets((name as NSString).lastPathComponent)
        let hasMediaExtension = AnimeFilenameParser().isSupportedMediaFile(URL(fileURLWithPath: base))
            || SubtitleFormat.of(fileName: base) != nil
        let fileName = hasMediaExtension ? base : base + ".mkv"
        var parsed = AnimeFilenameParser().parse(url: URL(fileURLWithPath: "/\u{1F}/" + fileName))
        if parsed.title == "\u{1F}" { parsed.title = "" }
        return parsed
    }

    /// Removes bracketed tags that only describe the encode — platform,
    /// codecs, subtitle languages — after the leading group bracket. The
    /// library parser keeps such tags in titles ("Frieren Baha CHT"), which
    /// is harmless for grouping but noise for subtitle searches.
    static func strippingTagBrackets(_ value: String) -> String {
        let tag = #"(?i)^(?:.*\b(?:\d{3,4}p|4k|web(?:-?dl|-?rip)?|baha|cr|b-global|bilibili|abema|netflix|amzn|hulu|bd(?:rip)?|blu-?ray|aac|avc|hevc|x26[45]|flac|opus|mp4|mkv|10-?bit|8-?bit|ma10p|hi10p|chs|cht|gb|big5|jpsc|jptc|srt(?:x\d)?|ass(?:x\d)?|v\d)\b.*|.*(?:简体|简中|簡體|簡中|繁体|繁體|繁中|简繁|簡繁|简日|繁日|簡日|中日|日语|日語|日文|双语|雙語|内嵌|內嵌|内封|內封|外挂|外掛|字幕).*|简|繁|簡)$"#
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]*)\]|【([^】]*)】"#) else { return value }
        var result = value
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: value), whole.lowerBound != value.startIndex else { continue }
            let content = String(value[whole].dropFirst().dropLast())
            guard content.range(of: tag, options: .regularExpression) != nil,
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: " ")
        }
        return result
    }

    /// The episode a subtitle file is for, trying the library parser first
    /// and then the release-title parser (which knows batch ranges).
    public static func episode(inFileName name: String) -> Double? {
        let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        // "Title.chs.ass" / "Title.14.sc.ass": drop trailing language tags
        // so they do not read as episode text.
        let cleaned = stem.replacingOccurrences(
            of: #"(?i)[._\[\( -](?:chs|cht|sc|tc|gb|big5|jpsc|jptc|zh(?:-?(?:hans|hant|cn|tw))?|chi|ja|jpn?|en|eng?|default|forced)(?:[&+_-](?:chs|cht|sc|tc|ja|jpn?|en|eng?))*[\]\)]?$"#,
            with: "", options: .regularExpression
        )
        if let episode = parseFileName(cleaned).episode { return episode }
        let release = TorrentReleaseInfo.parse(title: cleaned)
        if release.isBatch { return nil }
        if let episode = release.firstEpisode { return episode }
        // Last resort for bare names inside subtitle packs ("Frieren.14",
        // "Frieren 14 v2"): the last standalone one-to-three-digit number.
        let spaced = cleaned.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[\s\[\-])(\d{1,3})(?:v\d)?(?=[\s\]\-]|$)"#) else { return nil }
        let matches = regex.matches(in: spaced, range: NSRange(spaced.startIndex..., in: spaced))
        return matches.last.flatMap { Range($0.range(at: 1), in: spaced) }.flatMap { Double(spaced[$0]) }
    }

    /// Language tags carried by a subtitle filename ("xxx.chs.ass",
    /// "[简日双语]", "xxx.zh-Hant.srt").
    public static func language(inFileName name: String) -> SubtitleLanguage? {
        let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        // Only the trailing dotted tags and bracketed tags describe the
        // subtitle; the rest is the video's name.
        let tail = stem.split(separator: ".").suffix(2).joined(separator: " ")
        let brackets = allMatches(#"\[([^\]]*)\]|【([^】]*)】|\(([^)]*)\)"#, in: stem).joined(separator: " ")
        return SubtitleLanguage.fromLabel(tail + " " + brackets)
    }

    /// Case-folded alphanumeric tokens, for comparing release names.
    public static func tokens(_ value: String) -> Set<String> {
        let folded = value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let stem = SubtitleFormat.of(fileName: folded) != nil || AnimeFilenameParser().isSupportedMediaFile(URL(fileURLWithPath: folded))
            ? (folded as NSString).deletingPathExtension : folded
        return Set(stem.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 || $0.first?.isNumber == true })
    }

    /// 0...1 Jaccard similarity of two release names' tokens.
    public static func releaseSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = tokens(lhs)
        let right = tokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    /// Group names compare case- and width-insensitively, ignoring
    /// punctuation ("Lilith-Raws" == "lilith raws").
    public static func normalizedGroup(_ group: String?) -> String? {
        guard let group else { return nil }
        let value = group
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
        return value.isEmpty ? nil : value
    }

    /// Keeps the first spelling of case-insensitively duplicated, non-empty
    /// strings.
    public static func distinct(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            (1..<match.numberOfRanges).lazy.compactMap { index in
                Range(match.range(at: index), in: text).flatMap { $0.isEmpty ? nil : String(text[$0]) }
            }.first
        }
    }
}
