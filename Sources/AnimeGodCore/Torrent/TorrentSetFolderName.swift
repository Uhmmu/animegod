import Foundation

/// Naming the one folder a work's downloads share.
///
/// Started episode by episode, a season otherwise arrives as twelve folders
/// side by side in the download folder — which, when that folder is a
/// library root, is twelve entries in between everything else.
public enum TorrentDownloadFolder {
    /// What to call the folder, or nil to leave every episode in a folder of
    /// its own.
    ///
    /// The library's own title for the anime is the name to use when the
    /// download was started from one. A search that was never bound to an
    /// anime still names the work in every release it found, so the filename
    /// parser reads it back out — the same parser the scanner trusts. The
    /// fansub's name is deliberately not a fallback: every season that team
    /// ever published would land in one folder.
    /// `season` is appended when it is a later one, so the second season of a
    /// show does not land in the first's folder. It is the same suffix
    /// wherever the base name came from: an episode fetched on its own has to
    /// agree with the set it will later be part of, down to the spelling.
    public static func name(animeTitle: String?, releaseNames: [String], season: Int? = nil) -> String? {
        guard let base = baseName(animeTitle: animeTitle, releaseNames: releaseNames) else { return nil }
        guard let season, season > 1 else { return base }
        return "\(base) S\(season)"
    }

    private static func baseName(animeTitle: String?, releaseNames: [String]) -> String? {
        if let animeTitle {
            let cleaned = sanitised(animeTitle)
            if !cleaned.isEmpty { return cleaned }
        }
        guard let parsed = sharedSeriesTitle(of: releaseNames) else { return nil }
        let cleaned = sanitised(parsed)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The series title most of `releaseNames` agree on. With one name, the
    /// series title read out of it.
    ///
    /// A majority rather than all of them: a season assembled across fansubs
    /// borrows an episode or two, and those spell the work differently. One
    /// borrowed episode should not send the other eleven back to a folder
    /// each.
    public static func sharedSeriesTitle(of releaseNames: [String]) -> String? {
        guard !releaseNames.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for name in releaseNames {
            guard let title = seriesTitle(of: name) else { continue }
            counts[title, default: 0] += 1
        }
        guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        return best.value * 2 > releaseNames.count ? best.key : nil
    }

    /// The work one release name is of.
    ///
    /// An indexer's title usually lists every alias at once — "尼古喵喵 /
    /// ヤニねこ / Yani Neko / Chainsmoker Cat - 01 [WebRip…]" — so each alias
    /// is separated out and parsed on its own. That separation is not
    /// optional: a slash is a path separator to anything URL-shaped, and
    /// handing the whole string to the filename parser silently drops every
    /// alias but the last.
    static func seriesTitle(of releaseName: String) -> String? {
        let parser = AnimeFilenameParser()
        let aliases = releaseName
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { alias -> String? in
                let title = parser.parse(url: URL(fileURLWithPath: "/" + withoutTrailingTags(alias))).title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? nil : title
            }
        guard !aliases.isEmpty else { return nil }
        // The first alias in Latin script, because that is the one fansubs
        // name the files themselves after — so the folder agrees with what
        // is inside it, and with what the scanner will call the work.
        return aliases.first(where: isLatinScript) ?? aliases[0]
    }

    /// One alias with its technical tail cut off.
    ///
    /// The filename parser drops the tags it recognises — resolutions,
    /// codecs, CRCs — but an index title is a pile of brackets, and the ones
    /// it does not recognise stay: `[ANi] 藥師少女的獨語 / Kusuriya no
    /// Hitorigoto - 13 [1080P][Baha][WEB-DL][AAC AVC][CHT]` came out as
    /// "Kusuriya no Hitorigoto Baha CHT", which then named the folder, named
    /// the anime row, and was handed to Bangumi as the search query — so the
    /// work never matched. In a release title everything from the first
    /// bracket after the fansub's own is the technical tail, so cutting there
    /// is both simple and right.
    static func withoutTrailingTags(_ alias: String) -> String {
        var value = alias
        var leading = ""
        // The fansub's own leading bracket is not the tail; the parser wants
        // it, because that is where it reads the group from.
        if let close = closingIndexOfLeadingBracket(in: value) {
            leading = String(value[...close])
            value = String(value[value.index(after: close)...])
        }
        let tail = value.firstIndex(where: Self.openingBrackets.contains)
        if let tail { value = String(value[..<tail]) }
        let trimmed = (leading + value).trimmingCharacters(in: .whitespaces)
        // Nothing left outside the brackets: this is the all-bracket style
        // (【字幕组】【4月新番】【鬼灭之刃 Kimetsu no Yaiba】【26】【1920X1080】),
        // where the work's name is one of the groups. Guessing wrong here is
        // not cosmetic — the episode number is a group of its own, so every
        // episode parsed to a different title, no two of the twelve agreed on
        // a folder, and a season downloaded as a set arrived as twelve
        // separate works on the home screen.
        if value.trimmingCharacters(in: .whitespaces).count < 2, let inside = titleInsideBrackets(of: alias) {
            return inside
        }
        return trimmed.isEmpty ? alias : trimmed
    }

    private static let openingBrackets: Set<Character> = ["[", "(", "【", "（"]

    /// The end of the leading bracket group, whichever kind it uses.
    private static func closingIndexOfLeadingBracket(in value: String) -> String.Index? {
        guard let first = value.first else { return nil }
        let closing: Character
        switch first {
        case "[": closing = "]"
        case "【": closing = "】"
        default: return nil
        }
        return value.firstIndex(of: closing)
    }

    /// The group that names the work, out of a title made only of brackets.
    ///
    /// The first group is the fansub. Of the rest, the longest one that
    /// carries letters is the title: the others are an episode number, a
    /// resolution, a container, a language pair or a broadcast season, and
    /// all of those are short.
    private static func titleInsideBrackets(of alias: String) -> String? {
        let pattern = #"[\[【]([^\]】]*)[\]】]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let groups = regex.matches(in: alias, range: NSRange(alias.startIndex..., in: alias))
            .compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: alias) else { return nil }
                return alias[range].trimmingCharacters(in: .whitespaces)
            }
        let candidates = groups.dropFirst().filter { group in
            guard group.count >= 2 else { return false }
            // Anything without a letter is a number, a date or a size.
            guard group.contains(where: { $0.isLetter }) else { return false }
            return !isTechnicalTag(group)
        }
        return candidates.max { ($0.count, $1) < ($1.count, $0) }
    }

    /// Bracket contents that describe the file rather than the work.
    private static func isTechnicalTag(_ group: String) -> Bool {
        let folded = group.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        let pattern = #"(?i)^(?:(?:\d+[xX×]\d+)|(?:(?:2160|1080|720|480)[pi]?)|4k|hdr|uhd|bd(?:rip)?|blu-?ray|web-?(?:dl|rip)?|hevc|avc|av1|x26[45]|10bit|8bit|ma10p|flac|aac|ddp?|dts|truehd|mp4|mkv|gb|big5|gb_?mp4|big5_?mp4|chs|cht|jpsc|jptc|jpn|eng|sc|tc|简[体繁]?[内外]?[封挂]?|繁[体]?[内外]?[封挂]?|简繁[日]?[内外]?[封挂]?(?:字幕)?|中日?双语|字幕|外挂|内[封嵌]|生肉|熟肉|合集|完结|全\d{1,4}话?|第\d+[话話集]|\d+月新番|\d+年\d+月(?:新番)?|[a-z]{2,4}[_ ]?(?:mp4|mkv))$"#
        if folded.range(of: pattern, options: .regularExpression) != nil { return true }
        // A group that is only an episode range ("01-12", "01~12") is not a title.
        return folded.range(of: #"^\d{1,4}\s*[-~–]\s*\d{1,4}$"#, options: .regularExpression) != nil
    }

    /// Written in Latin letters and nothing else a reader would call a
    /// different script. Han, kana and Hangul all disqualify a name.
    private static func isLatinScript(_ value: String) -> Bool {
        var sawLatin = false
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return false
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F:
                sawLatin = true
            default:
                continue
            }
        }
        return sawLatin
    }

    /// `raw` as something every file system AnimeGod writes to will take: no
    /// path separators (`:` is one to the Finder), no control characters, no
    /// leading dot — which would hide the folder — and short enough that the
    /// 255-byte name limit still leaves room for the episode inside it.
    public static func sanitised(_ raw: String) -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar in
            scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
        }))
        var name = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while name.utf8.count > 160 || name.count > 80 { name.removeLast() }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }
}

extension TorrentEpisodeSet {
    /// The one folder this set is downloaded into, so a season arrives as a
    /// season. Nil leaves each episode in a folder named after itself.
    public func suggestedFolderName(animeTitle: String? = nil) -> String? {
        TorrentDownloadFolder.name(
            animeTitle: animeTitle,
            releaseNames: entries.map(\.result.title),
            season: variant.season
        )
    }
}
