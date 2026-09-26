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
    public static func name(animeTitle: String?, releaseNames: [String]) -> String? {
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
                let title = parser.parse(url: URL(fileURLWithPath: "/" + alias)).title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? nil : title
            }
        guard !aliases.isEmpty else { return nil }
        // The first alias in Latin script, because that is the one fansubs
        // name the files themselves after — so the folder agrees with what
        // is inside it, and with what the scanner will call the work.
        return aliases.first(where: isLatinScript) ?? aliases[0]
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
        let base = TorrentDownloadFolder.name(
            animeTitle: animeTitle,
            releaseNames: entries.map(\.result.title)
        )
        guard let base else { return nil }
        guard let season = variant.season, season > 1 else { return base }
        return "\(base) S\(season)"
    }
}
