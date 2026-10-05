import Foundation

/// A Japanese disc catalogue number lifted out of a release or folder name —
/// `ANZX-10294`, `BRMM-10716`, `LABX-8333~4`.
///
/// This is the identity hook for a concert disc, and it is a far better one
/// than the title. A live Blu-ray's title is written a dozen ways (`結束バンド
/// LIVE-恒星-` / `結束バンドLIVE-恒星-` / `Kessoku Band LIVE -Kosei-`), and a
/// fuzzy title search answers confidently with the wrong disc: searching
/// MusicBrainz for "MyGO!!!!! 2nd Live" returns another artist's *2nd
/// LIVEパラレルタイム* at a perfect score. A catalogue number returns exactly
/// one release, from both Discogs and MusicBrainz, and the indexes tolerate
/// every way of writing it (measured: `ANZX-10294`, `ANZX 10294`,
/// `ANZX10294` and `anzx-10294` all answer with the one release, and
/// `LABX-8333` finds the release filed as `LABX-8333~4`).
public struct ConcertCatalogNumber: Hashable, Sendable, CustomStringConvertible {
    /// The label's prefix, upper-cased: `ANZX`.
    public let prefix: String
    /// The first number of the set: `10294`.
    public let number: String
    /// The other discs of a boxed set, when the name lists them —
    /// `ANZX-10294~10296` keeps `10295`, `10296`. Catalogue search uses the
    /// first number only; these exist so a three-disc box can be recognised
    /// as one release rather than three.
    public let continuationNumbers: [String]

    public init(prefix: String, number: String, continuationNumbers: [String] = []) {
        self.prefix = prefix.uppercased()
        self.number = number
        self.continuationNumbers = continuationNumbers
    }

    /// The canonical spelling, which is what to show a human: `ANZX-10294`.
    public var description: String { "\(prefix)-\(number)" }

    /// How many discs the name says the set holds, when it says at all.
    public var discCount: Int? {
        continuationNumbers.isEmpty ? nil : continuationNumbers.count + 1
    }

    /// Spellings to try against an index, most canonical first.
    ///
    /// Both indexes were measured to match any of these, but they are kept
    /// because neither promises to: a provider that stops folding separators
    /// should degrade to one extra request, not to no match at all.
    public var queryVariants: [String] {
        var seen = Set<String>()
        return ["\(prefix)-\(number)", "\(prefix) \(number)", "\(prefix)\(number)"]
            .filter { seen.insert($0).inserted }
    }
}

public extension ConcertCatalogNumber {
    /// Prefixes that look like a catalogue number and are not one. Every
    /// entry is something a release name actually carries: disc capacities
    /// (`BD-50`), codecs and audio layouts (`AAC2`, `MA5`), source tags
    /// (`TV`, `BD`), and the episode-ish markers a bonus disc is labelled
    /// with. Without this list `BD-50` and `AAC2` become catalogue numbers
    /// and the lookup asks an index about a codec.
    static let reservedPrefixes: Set<String> = [
        "BD", "BDMV", "BDRIP", "BR", "DVD", "DVDRIP", "HD", "UHD", "SD", "WEB",
        "AAC", "AC", "DTS", "MA", "EAC", "FLAC", "ALAC", "OPUS", "MP", "PCM",
        "AVC", "HEVC", "VC", "MPEG", "XVID", "DIVX", "YUV", "RGB",
        "TV", "OP", "ED", "NC", "NCOP", "NCED", "PV", "CM", "SP", "OVA", "OAD",
        "EP", "VOL", "DISC", "DISK", "PART", "CH", "FPS", "BIT", "KBPS",
        "MB", "GB", "TB", "KB", "X", "H", "V", "S", "E",
        // Words a concert release name is built out of. Without these,
        // `LIVE 2024` and `TOUR 2019` parse as catalogue numbers — the prefix
        // is the right shape and the year is the right length.
        "LIVE", "TOUR", "CONCERT", "FES", "FEST", "ARENA", "HALL", "DOME",
        "STAGE", "SHOW", "SET", "BOX", "VER", "REV", "RAW", "FIN", "END",
        "SEASON", "MOVIE", "FILM", "MIX", "AUDIO", "VIDEO", "SUB", "DUB",
        "MAIN", "MENU", "EXTRA", "BONUS", "MAKING", "SPECIAL", "DAY", "NIGHT",
        "JPN", "ENG", "CHS", "CHT", "JP", "EN", "ZH", "HI", "LOW"
    ]

    /// Years, for the guard below.
    static let yearRange = 1900...2099

    /// At least two letters and two digits: `X264` has one letter, `AAC2`
    /// one digit, and neither is a catalogue number. Six is past the longest
    /// real prefix (`VPXQ`, `SHBR`, `BCXA`) with room to spare.
    static let letterRange = 2...6
    static let digitRange = 2...6

    /// Reads every catalogue number out of a release or folder name, in the
    /// order they appear.
    ///
    /// A name may carry more than one — a box set lists the set's number and
    /// each disc's — so the caller decides which to use rather than this
    /// returning a guess.
    static func all(in name: String) -> [ConcertCatalogNumber] {
        var found: [ConcertCatalogNumber] = []
        var seen = Set<String>()
        for candidate in tokenise(name) {
            guard let parsed = parse(token: candidate.token, joined: candidate.joined),
                  seen.insert(parsed.description).inserted
            else { continue }
            found.append(parsed)
        }
        return found
    }

    /// The one catalogue number to look a name up by: the first, which in
    /// every real naming scheme is the set's own.
    static func first(in name: String) -> ConcertCatalogNumber? {
        all(in: name).first
    }

    /// Splits a name on everything that cannot be inside a catalogue number.
    ///
    /// `-`, `~` and `/` stay in, because they join a prefix to its number and
    /// one number to the next; brackets, dots and spaces around a token are
    /// cut away. A space *inside* a token (`ANZX 10294`) survives as two
    /// tokens, so adjacent pairs are re-joined below.
    private static func tokenise(_ name: String) -> [(token: String, joined: Bool)] {
        let separators = CharacterSet(charactersIn: "[]()【】（）{}<>《》、,，。.!！?？:：;；_+＋*\"'`|\\ \t\n　")
        let raw = name.components(separatedBy: separators).filter { !$0.isEmpty }
        // `ANZX 10294` is one catalogue number written with a space. Offer
        // every adjacent pair as a candidate too, so the hyphenless spelling
        // is read rather than discarded as a bare prefix and a bare number.
        var candidates: [(token: String, joined: Bool)] = []
        for (index, token) in raw.enumerated() {
            candidates.append((token, false))
            if index + 1 < raw.count { candidates.append((token + "-" + raw[index + 1], true)) }
        }
        return candidates
    }

    private static func parse(token: String, joined: Bool = false) -> ConcertCatalogNumber? {
        // A CRC stamped into a folder name (`E7E8AD1D`) is eight hex digits
        // and nothing else. `ABCD1234` would otherwise parse as a perfectly
        // shaped catalogue number, and the lookup would ask an index about a
        // checksum.
        let bare = token.replacingOccurrences(of: "-", with: "")
        if bare.count == 8, bare.allSatisfy({ $0.isHexDigit }) { return nil }

        let scalars = Array(token.uppercased())
        var index = 0
        var prefix = ""
        while index < scalars.count, scalars[index].isLetter, scalars[index].isASCII {
            prefix.append(scalars[index])
            index += 1
        }
        guard letterRange.contains(prefix.count), !reservedPrefixes.contains(prefix) else { return nil }

        // One optional separator between the prefix and the number.
        if index < scalars.count, scalars[index] == "-" { index += 1 }

        var number = ""
        while index < scalars.count, scalars[index].isNumber, scalars[index].isASCII {
            number.append(scalars[index])
            index += 1
        }
        guard digitRange.contains(number.count) else { return nil }
        // `ZEPP 2023`, `BUDOKAN 2019`: a prefix this reader has never heard of
        // followed by a year, written with a space. A real catalogue number
        // written with a space does not carry a year as its number, so the
        // guard costs nothing and stops an unknown venue name from becoming
        // a lookup.
        if joined, number.count == 4, let value = Int(number), yearRange.contains(value) { return nil }

        // A box set writes its range as `~10296`, `~6`, `/10295` or `,10295`.
        // A trailing `~6` is shorthand for "same number, last digit 6", so
        // it is widened against the first number before being kept.
        var continuations: [String] = []
        while index < scalars.count, scalars[index] == "~" || scalars[index] == "/" {
            index += 1
            var tail = ""
            while index < scalars.count, scalars[index].isNumber, scalars[index].isASCII {
                tail.append(scalars[index])
                index += 1
            }
            guard !tail.isEmpty else { return nil }
            continuations.append(widen(tail, like: number))
        }
        // Anything left over means the token was not a catalogue number but
        // something that merely starts like one (`BRMM-10716REV`, `S01E02`).
        guard index == scalars.count else { return nil }

        // `~10294` or a range that runs backwards is not a set.
        let expanded = expand(from: number, through: continuations)
        return ConcertCatalogNumber(prefix: prefix, number: number, continuationNumbers: expanded)
    }

    /// `ANZX-10294~6` means `10296`, not `6`.
    private static func widen(_ tail: String, like number: String) -> String {
        guard tail.count < number.count else { return tail }
        return String(number.prefix(number.count - tail.count)) + tail
    }

    /// A `~` range names its last disc, not each one. Fills the set in so a
    /// three-disc box reports three discs.
    private static func expand(from number: String, through continuations: [String]) -> [String] {
        guard continuations.count == 1,
              let start = Int(number), let end = Int(continuations[0]),
              end > start, end - start <= 16
        else { return continuations.filter { $0 != number } }
        let width = number.count
        return ((start + 1)...end).map { String(format: "%0\(width)d", $0) }
    }
}
