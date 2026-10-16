import Foundation

/// Which subtitle languages a release carries — `[CHS_JP&CHT_JP]`, `[JPSC]`,
/// `[简繁日内封]` — and never part of the work's name.
///
/// This exists because a title is an identity. Two teams released episode 1 and
/// episode 2 of one show into one folder, and because the language tag stayed
/// on each filename's title the library read
/// `FX Senshi Kurumi-chan CHS_JP&CHT_JP` and `FX Senshi Kurumi-chan JPSC` as two
/// different works — three cards for three files, with the subscription
/// following one of them. The scanner is right to let diverging filenames
/// inside one folder mean several works (a folder really can hold two shows);
/// what was wrong is that the names it compared described the subtitles.
///
/// There is no catalogue of spellings to match against, so the rule is
/// structural: a tag is a run that is **nothing but** language codes. Requiring
/// the whole run keeps ordinary titles safe — `[END]` is a finale tag, not
/// `en` + `d`, and `言叶之庭` holds characters this set does not.
public enum SubtitleLanguageTag {
    /// Latin codes, longest spellings first so the whole run is consumed
    /// greedily. Deliberately missing: `ko`/`kor`, which would make a bare
    /// `Koko` a tag, and anything shorter than two characters.
    private static let latinCodes = [
        "chs", "cht", "chi", "chn", "zhs", "zht", "jpn", "big5", "gbk",
        "eng", "subs", "sub", "zh", "cn", "sc", "tc", "gb", "jp", "ja", "en"
    ]

    /// The characters a Chinese-language tag is written with: 简体 / 繁体 /
    /// 日语 / 双语 / 中字 / 内封 / 外挂, and the words for subtitles
    /// themselves. Every character of the run has to be in here, which is what
    /// keeps `中二病` and `あの日見た花…` out of it.
    private static let chineseTagCharacters = Set("简繁体中日英语言字幕内封外挂掛双文粤")

    /// What joins codes together: `CHS_JP&CHT_JP`, `CHI_JPN_ENG`,
    /// `简繁日/双语`.
    private static let separators = CharacterSet(charactersIn: "_&+/\\,;-.·、＆ \t　")

    /// Bare spellings that appear outside brackets and cannot be mistaken for a
    /// word. A separator-joined or Chinese run speaks for itself; a short Latin
    /// run does not — `Chi` is a 2024 series and `GB` is also a unit of
    /// storage — so those are listed rather than inferred.
    private static let bareLatinSpellings: Set<String> = [
        "chs", "cht", "jpn", "jpsc", "jptc", "scjp", "tcjp", "chsjp", "chtjp",
        "big5", "gbk", "chssub", "chtsub", "engsub", "jpsub"
    ]

    private static let pattern: String = {
        let codes = latinCodes.joined(separator: "|")
        let characters = String(chineseTagCharacters)
        return "^(?:\(codes)|[\(NSRegularExpression.escapedPattern(for: characters))])+$"
    }()

    /// Whether a bracketed or parenthesised group is a language tag and nothing
    /// else. Two characters minimum: a lone `日` is as likely to be part of a
    /// name as a language.
    public static func isTag(_ value: String) -> Bool {
        let folded = value
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: separators)
            .joined()
        guard folded.count >= 2 else { return false }
        return folded.range(of: pattern, options: .regularExpression) != nil
    }

    /// Whether a run of text standing on its own — outside any bracket — is a
    /// language tag. Stricter than `isTag`, because here a wrong answer eats a
    /// word out of somebody's title.
    public static func isBareTag(_ value: String) -> Bool {
        guard isTag(value) else { return false }
        let folded = value.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        if folded.rangeOfCharacter(from: separators) != nil { return true }
        if folded.allSatisfy({ chineseTagCharacters.contains($0) }) { return true }
        return bareLatinSpellings.contains(folded)
    }

    /// Removes every bracketed or parenthesised language tag from a release
    /// name, then every bare one left between the words.
    static func removingTags(from value: String) -> String {
        var result = value
        for pattern in [#"\[([^\[\]]*)\]"#, #"【([^【】]*)】"#, #"[(（]([^()（）]*)[)）]"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: result),
                      let inner = Range(match.range(at: 1), in: result),
                      isTag(String(result[inner]))
                else { continue }
                result.replaceSubrange(whole, with: " ")
            }
        }
        let kept = result
            .components(separatedBy: CharacterSet.whitespaces)
            .filter { !isBareTag($0) }
        return kept.joined(separator: " ")
    }
}
