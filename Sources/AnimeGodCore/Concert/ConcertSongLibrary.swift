import Foundation

/// A song and every local concert disc on which it was performed.
/// Derived from the current programmes, so editing a setlist needs no second
/// song database to keep in sync.
public struct LibraryConcertSong: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let appearances: [ConcertSongAppearance]

    public var artists: [String] {
        Array(Set(appearances.compactMap { ConcertShelves.band(of: $0.concert) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public var discCount: Int { Set(appearances.map { $0.episode.id }).count }
}

public struct ConcertSongAppearance: Identifiable, Hashable, Sendable {
    public let concert: LibraryConcert
    public let episode: EpisodeMedia
    /// The video's ordinal, rather than its medium number in a CD/BD box.
    public let discNumber: Int
    public let discTitle: String?
    public let track: ConcertTrack
    public let startTime: TimeInterval?
    public let timeline: ConcertSetlistAlignment?

    public var id: String { "\(episode.id):\(track.position)" }
}

public enum ConcertSongLibrary {
    private struct NamedAppearance {
        let appearance: ConcertSongAppearance
        let title: String
        let key: String
        let aliases: [String]
    }
    /// Older pasted programmes called every chapter a song. Keep their
    /// original timeline untouched, but omit explicit stage cues here.
    static func songTitle(for track: ConcertTrack) -> String? {
        guard track.kind == .song else { return nil }
        let classified = ConcertTrackClassifier.classify(title: track.title)
        guard classified.kind == .song else { return nil }
        let title = classified.title.replacingOccurrences(
            of: #"\s*[（(\[【]\s*(?:encore|アンコール|安可)\s*[）)\]】]\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = key(for: title).filter { $0.isLetter || $0.isNumber }
        guard !bare.isEmpty else { return nil }
        let stageCues = ["安可环节", "安可環節", "谢幕", "謝幕"]
        if stageCues.contains(bare) { return nil }
        if bare.range(
            of: #"^(?:(?:安可|アンコール|encore)|第[一二三四五六七八九十0-9]+(?:段|次)?)?mc(?:[0-9]+|环节|環節|新情报|新情報)?$"#,
            options: .regularExpression
        ) != nil { return nil }
        if bare.range(of: #"^encorestartnarration[0-9]*$"#, options: .regularExpression) != nil { return nil }
        if ["opening", "ending"].contains(bare), title.first.map({ "—―–-".contains($0) }) == true {
            return nil
        }
        return title
    }

    /// The name before a version note or alias, including incomplete pasted
    /// parentheses and stray closing brackets.
    static func keywordTitle(_ rawTitle: String) -> String {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-—―– "))
        if let bracket = title.firstIndex(where: { "()（）[]【】".contains($0) }) {
            let prefix = title[..<bracket].trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { title = prefix }
        }
        title = title.replacingOccurrences(
            of: #"(?i)\s+(?:acoustic|unplugged|piano|music box|live|instrumental)(?:\s|$|[-.]).*$|\s*(?:不插电|不插電|钢琴版|鋼琴版|アコースティック|ピアノver).*$"#,
            with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? rawTitle.trimmingCharacters(in: .whitespacesAndNewlines) : title
    }

    private static func spellingKey(_ title: String) -> String {
        title.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func key(for title: String) -> String {
        spellingKey(keywordTitle(title))
    }

    /// A short Latin name must match a word, while CJK titles are keywords
    /// inside annotations such as 迷星叫前奏. One-character titles still merge
    /// their versions, but do not absorb unrelated longer song names.
    private static func containsKeyword(_ title: String, _ keyword: String) -> Bool {
        if title == keyword { return true }
        guard keyword.count >= 2, let range = title.range(of: keyword) else { return false }
        if keyword.unicodeScalars.allSatisfy({ $0.isASCII }) {
            let before = range.lowerBound == title.startIndex ? nil : title[title.index(before: range.lowerBound)]
            let after = range.upperBound == title.endIndex ? nil : title[range.upperBound]
            return (before.map { !$0.isLetter && !$0.isNumber } ?? true)
                && (after.map { !$0.isLetter && !$0.isNumber } ?? true)
        }
        return true
    }

    private static func withoutArtistPrefix(_ title: String, appearance: ConcertSongAppearance) -> String {
        let artists = (appearance.concert.release?.artistNames ?? [])
            + [ConcertShelves.band(of: appearance.concert)].compactMap { $0 }
        for artist in artists.sorted(by: { $0.count > $1.count }) where !artist.isEmpty {
            guard let range = title.range(of: artist, options: [.anchored, .caseInsensitive, .widthInsensitive]) else { continue }
            let suffix = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard suffix.first.map({ "-—–:：".contains($0) }) == true else { continue }
            return suffix.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    private static func aliases(in title: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"[（(\[【）)]([^）)\]】（(\[【]+)"#)
        let matches = expression.matches(in: title, range: NSRange(title.startIndex..., in: title))
        return matches.flatMap { match -> [String] in
            guard let range = Range(match.range(at: 1), in: title) else { return [] }
            return title[range].components(separatedBy: "/").compactMap { alias in
                let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                let annotation = spellingKey(clean)
                guard !annotation.isEmpty,
                      annotation.range(of: #"\b(?:ver|version|acoustic|unplugged|piano|encore|mix)\b|不插电|不插電|即興|即兴|安可|アコースティック|アンコール|music box"#, options: .regularExpression) == nil
                else { return nil }
                return clean
            }
        }
    }

    public static func songs(from appearances: [ConcertSongAppearance]) -> [LibraryConcertSong] {
        let named: [NamedAppearance] = appearances.compactMap { appearance in
            guard let title = songTitle(for: appearance.track) else { return nil }
            let name = withoutArtistPrefix(title, appearance: appearance)
            let base = keywordTitle(name)
            return NamedAppearance(appearance: appearance, title: base, key: key(for: base), aliases: aliases(in: name))
        }
        let allKeys = Set(named.map { $0.key })
        let keywords: [String] = allKeys.sorted { left, right in
            if left.count != right.count { return left.count < right.count }
            return left < right
        }
        func rootKey(_ name: String) -> String {
            keywords.first { containsKeyword(name, $0) } ?? name
        }
        // A parenthetical reading or translation also links a standalone
        // alias. Kana readings can supply the romaji without an online lookup.
        var aliasRoots: [String: Set<String>] = [:]
        for item in named {
            for alias in item.aliases {
                var spellings = [key(for: alias)]
                if let latin = alias.applyingTransform(.toLatin, reverse: false)?
                    .applyingTransform(.stripDiacritics, reverse: false) {
                    spellings.append(key(for: latin).replacingOccurrences(of: " ", with: ""))
                }
                for spelling in spellings { aliasRoots[spelling, default: []].insert(rootKey(item.key)) }
            }
        }
        func groupKey(_ name: String) -> String {
            let root = rootKey(name)
            if let roots = aliasRoots[root], roots.count == 1, let aliasRoot = roots.first {
                return aliasRoot
            }
            return root
        }
        let grouped = Dictionary(grouping: named, by: { groupKey($0.key) })
        let displayNames = Dictionary(grouping: named, by: \.key).mapValues {
            $0.map(\.title).sorted().first!
        }
        return grouped.map { key, items in
            let ordered = items.map(\.appearance).sorted { left, right in
                if left.concert.sortDate != right.concert.sortDate {
                    return (left.concert.sortDate ?? "") > (right.concert.sortDate ?? "")
                }
                if left.concert.id != right.concert.id {
                    let comparison = left.concert.displayTitle.localizedStandardCompare(right.concert.displayTitle)
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                    return left.concert.id.uuidString < right.concert.id.uuidString
                }
                if left.discNumber != right.discNumber { return left.discNumber < right.discNumber }
                return left.track.position < right.track.position
            }
            return LibraryConcertSong(id: key, title: displayNames[key] ?? keywordTitle(ordered[0].track.title), appearances: ordered)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
