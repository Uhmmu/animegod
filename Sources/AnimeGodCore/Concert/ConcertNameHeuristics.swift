import Foundation

/// Reads a release or folder name and says whether it is a concert.
///
/// This exists because of what asking the user costs. A download that nothing
/// recognises raises the "which anime is this?" sheet, and for a live Blu-ray
/// there is no answer to give: no anime index lists a concert, so the sheet
/// offers twelve wrong shows and whatever is picked is wrong. The catalogue
/// number is the reliable identity (`ConcertCatalogNumber`) but it is almost
/// never in the name a download starts with — it is two levels down in a cue
/// sheet that does not exist yet while the torrent is still fetching metadata.
/// So the name is all there is at the moment the question would be asked.
///
/// **No single word is trusted on its own except the unambiguous ones.** A
/// bare `LIVE` token is diagnostic for a standalone release folder, but it is
/// also in `Love Live!`, in `live action`, and in the fansub group
/// `Live-eviL` — so the title words are suppressed, and the group's own
/// bracket is cut off before anything is read. Weights are set so that one
/// strong signal is enough and one weak one never is: a work wrongly moved
/// into the section leaves the grid and stops being matched, which is worse
/// than one more question.
public enum ConcertNameHeuristics {
    /// Something in a name that suggests a concert, with what it is worth.
    public enum Signal: String, Sendable, CaseIterable, Codable {
        /// `演唱会`, `コンサート`, `CONCERT` — these mean one thing.
        case concertWord
        /// `6th LIVE`, `5th☆LoveLive!`, `First Live` — an ordinal before a
        /// live word, which is how almost every Japanese live disc is titled.
        case ordinalLive
        /// A bare `LIVE` / `ライブ` / `ライヴ` token.
        case liveWord
        /// `TOUR`, `ツアー`, `ワンマン`, `巡演`.
        case tour
        /// `武道館`, `ARENA`, `DOME`, `ZEPP` — a room nobody films a series in.
        case venue
        /// `FES`, `フェス`, `音楽祭`.
        case festival
        /// `SETLIST`, `セットリスト`.
        case setlist
        /// `ENCORE`, `アンコール`.
        case encore
        /// `公演`, `LIVE VIEWING`, `ライブビューイング`.
        case performance
        /// `DAY1` / `DAY 2` / `2DAYS` — a work released per night.
        case dayLabel
        /// A catalogue number sits in the name. Supporting only: an anime
        /// Blu-ray has one too (`ANZX` is Aniplex's anime label as well).
        case catalogNumber

        /// What this signal is worth towards `threshold`.
        public var weight: Double {
            switch self {
            case .concertWord: return 0.9
            case .ordinalLive: return 0.9
            case .liveWord: return 0.7
            case .setlist: return 0.6
            case .tour: return 0.55
            case .festival: return 0.5
            case .encore: return 0.5
            case .performance: return 0.5
            case .venue: return 0.4
            case .dayLabel: return 0.3
            case .catalogNumber: return 0.25
            }
        }
    }

    /// What a name came to, and why — the page shows the reasons, because a
    /// work that moved itself into the section has to be able to say what
    /// moved it.
    public struct Verdict: Sendable, Equatable {
        public let signals: [Signal]
        public let score: Double

        public var isConcert: Bool { score >= ConcertNameHeuristics.threshold }

        /// Reasons in the order they are worth, so the first one is the one
        /// to show when there is only room for one.
        public var reasons: [Signal] { signals.sorted { $0.weight > $1.weight } }

        /// One signal that means a concert on its own — `演唱会`, `CONCERT`,
        /// or an ordinal before a live word.
        ///
        /// The test for overruling something else. A sum of weak signals is
        /// enough to file a download nobody has an opinion about; it is not
        /// enough to contradict a provider that matched the work, however
        /// badly it matched it.
        public var isCertain: Bool { signals.contains { $0.weight >= 0.9 } }
    }

    /// One strong signal passes; one weak one does not.
    public static let threshold = 0.7

    /// Reads every name it is given — the work's folder plus, when the
    /// torrent has them, its files — and sums what it finds. A signal counts
    /// once however many names carry it.
    public static func verdict(for names: [String]) -> Verdict {
        var found: Set<Signal> = []
        for name in names {
            for signal in signals(in: name) { found.insert(signal) }
        }
        let score = found.reduce(0) { $0 + $1.weight }
        return Verdict(signals: found.sorted { $0.rawValue < $1.rawValue }, score: score)
    }

    public static func verdict(for name: String) -> Verdict { verdict(for: [name]) }

    public static func isConcert(_ names: [String]) -> Bool { verdict(for: names).isConcert }

    // MARK: - Reading one name

    private static func signals(in rawName: String) -> Set<Signal> {
        let name = withoutGroupTag(rawName)
        let folded = name.lowercased()
        var found: Set<Signal> = []

        if containsAny(folded, concertWords) { found.insert(.concertWord) }
        if hasOrdinalLive(folded) { found.insert(.ordinalLive) }
        // The live word is the one that needs protecting: suppressed when it
        // belongs to a title (`Love Live!`) or to something that is not a
        // concert at all (`live action`). The ordinal form is read separately
        // and survives, which is what keeps `Aqours 5th LoveLive!` a concert.
        if hasLiveWord(folded), !found.contains(.ordinalLive) { found.insert(.liveWord) }
        if containsAny(folded, tourWords) { found.insert(.tour) }
        if containsAny(folded, venueWords) || containsAny(name, venueWordsCJK) { found.insert(.venue) }
        if containsAny(folded, festivalWords) { found.insert(.festival) }
        if containsAny(folded, setlistWords) { found.insert(.setlist) }
        if containsAny(folded, encoreWords) { found.insert(.encore) }
        if containsAny(folded, performanceWords) || name.contains("公演") { found.insert(.performance) }
        if hasDayLabel(folded) { found.insert(.dayLabel) }
        if ConcertCatalogNumber.first(in: name) != nil { found.insert(.catalogNumber) }
        return found
    }

    /// Cuts a leading `[Group]` off, because a group's own name is not a
    /// statement about the work: `[Live-eviL]` subbed ordinary series, and
    /// its bracket would otherwise make every one of them a concert.
    private static func withoutGroupTag(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.first, open == "[" || open == "【" || open == "(",
              let close = trimmed.firstIndex(where: { $0 == "]" || $0 == "】" || $0 == ")" })
        else { return trimmed }
        return String(trimmed[trimmed.index(after: close)...])
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    /// A live word that is not part of a longer word, not part of a title, and
    /// not a phrase that means something else.
    ///
    /// **Latin and Japanese are matched differently and have to be.** `live`
    /// needs a word boundary or `alive` and `delivery` are concerts. `ライブ`
    /// must *not* have one, because Japanese does not put spaces anywhere: the
    /// real queue in this library holds
    /// `MyGO!!!!!×Ave Mujica 合同ライブ「わかれ道の、その先へ」`, and requiring a
    /// boundary there recognised nothing at all. `ワンマンライブ` and `単独ライブ`
    /// are the same shape. The one Japanese string that contains `ライブ` and is
    /// not a concert is `ラブライブ`, which the negations already hold.
    private static func hasLiveWord(_ folded: String) -> Bool {
        if containsAny(folded, liveNegations) { return false }
        if containsAny(folded, compoundLiveWords) { return true }
        return latinLiveWords.contains { hasToken($0, in: folded) }
    }

    private static func hasToken(_ token: String, in folded: String) -> Bool {
        var search = folded.startIndex..<folded.endIndex
        while let range = folded.range(of: token, range: search) {
            let before = range.lowerBound == folded.startIndex
                ? nil
                : folded[folded.index(before: range.lowerBound)]
            let after = range.upperBound == folded.endIndex ? nil : folded[range.upperBound]
            if !isWordCharacter(before) && !isWordCharacter(after) { return true }
            search = range.upperBound..<folded.endIndex
        }
        return false
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }

    /// `6th live`, `1st live`, `first live`, `5th☆lovelive!`, `2nd ワンマン`.
    private static func hasOrdinalLive(_ folded: String) -> Bool {
        for ordinal in writtenOrdinals {
            for live in ordinalLiveWords where folded.contains("\(ordinal) \(live)") { return true }
        }
        let scalars = Array(folded)
        var index = 0
        while index < scalars.count {
            guard scalars[index].isNumber else { index += 1; continue }
            var end = index
            while end < scalars.count, scalars[end].isNumber { end += 1 }
            let rest = String(scalars[end...])
            if let tail = numericOrdinalSuffixes.first(where: { rest.hasPrefix($0) }) {
                let afterSuffix = String(rest.dropFirst(tail.count)).drop(while: { isOrdinalFiller($0) })
                if ordinalLiveWords.contains(where: { afterSuffix.hasPrefix($0) }) { return true }
            }
            index = end
        }
        return false
    }

    /// What release names put between the ordinal and the live word:
    /// `11th☆LIVE`, `6th・LIVE`, `2nd LIVE`.
    private static func isOrdinalFiller(_ character: Character) -> Bool {
        character.isWhitespace || "☆★・･-–—_.°·".contains(character)
    }

    /// `day1`, `day 2`, `2days`, `day01` — only as a supporting signal, since
    /// a single night is also how a two-part film is labelled.
    private static func hasDayLabel(_ folded: String) -> Bool {
        if folded.contains("2days") || folded.contains("両日") { return true }
        var search = folded.startIndex..<folded.endIndex
        while let range = folded.range(of: "day", range: search) {
            let after = folded[range.upperBound...].drop { $0 == " " || $0 == "." || $0 == "_" }
            if let first = after.first, first.isNumber { return true }
            search = range.upperBound..<folded.endIndex
        }
        return false
    }

    // MARK: - The words themselves

    private static let concertWords = [
        "演唱会", "演唱會", "コンサート", "concert", "音乐会", "音樂會", "ライブツアー", "live tour",
        "livetour", "演奏会", "リサイタル", "recital",
    ]
    private static let latinLiveWords = ["live"]
    /// Written without separators, so a word boundary would hide them.
    /// Deliberately **not** `現場` / `现场`: the Japanese word means the site or
    /// the scene of something, not a concert, and `LIVE` or `演唱会` carries the
    /// cases it would have caught.
    private static let compoundLiveWords = ["ライブ", "ライヴ"]
    /// Phrases in which `live` is not a concert. `live a live` is a game,
    /// `live action` is a film, and `love live` is a series — the series only
    /// loses the bare word, because its own concerts are titled with an
    /// ordinal (`Aqours 5th LoveLive!`) and that is read separately.
    private static let liveNegations = [
        "live action", "live-action", "liveaction", "真人版", "실사",
        "live a live", "live-a-live",
        "love live", "lovelive", "ラブライブ", "love-live",
    ]
    private static let ordinalLiveWords = [
        "live", "lovelive", "love live", "ライブ", "ライヴ", "concert", "コンサート",
        "ワンマン", "tour", "ツアー", "fes", "anniversary",
    ]
    private static let writtenOrdinals = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
        "ninth", "tenth", "final",
    ]
    private static let numericOrdinalSuffixes = ["st", "nd", "rd", "th", "回", "周年", "周年記念"]
    private static let tourWords = ["tour", "ツアー", "ワンマン", "巡演", "巡回", "巡迴"]
    private static let venueWords = [
        "budokan", "arena", "dome", "zepp", "stadium", "hall", "pacifico", "makuhari",
        "yokohama arena", "tokyo garden theater",
    ]
    private static let venueWordsCJK = [
        "武道館", "アリーナ", "ドーム", "体育館", "体育馆", "国立競技場", "ホール", "会館", "劇場",
        "ぴあアリーナ", "横浜アリーナ", "さいたまスーパーアリーナ", "日本武道館",
    ]
    private static let festivalWords = [
        "フェス", "音楽祭", "music festival", "festival", "fes.", "fes ", "-fes", "fes]",
        "rock in japan", "animelo", "アニサマ",
    ]
    private static let setlistWords = ["setlist", "set list", "セットリスト", "曲目"]
    private static let encoreWords = ["encore", "アンコール", "安可"]
    private static let performanceWords = ["live viewing", "ライブビューイング", "無観客", "有観客"]
}
