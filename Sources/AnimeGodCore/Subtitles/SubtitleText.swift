import Foundation

/// Decodes subtitle bytes into text. Chinese fansub files are still often
/// GBK or Big5 rather than UTF-8, and libass needs UTF-8, so every cached
/// subtitle is decoded here and rewritten as UTF-8.
public enum SubtitleTextDecoder {
    public enum Encoding: String, Sendable {
        case utf8, utf16LittleEndian, utf16BigEndian, big5, gb18030, latin1
    }

    public static func decode(_ data: Data) -> (text: String, encoding: Encoding)? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return (text, .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return (text, .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return (text, .utf16BigEndian)
        }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        // BOM-less UTF-16 is recognizable by its zero bytes in ASCII text.
        if let encoding = bomlessUTF16(data), let text = String(data: data, encoding: encoding == .utf16LittleEndian ? .utf16LittleEndian : .utf16BigEndian) {
            return (text, encoding)
        }
        // GBK and Big5 overlap: either decoder often "succeeds" on the
        // other's bytes. The right one produces everyday characters; the
        // wrong one produces rare ones, so both are decoded and scored.
        let big5 = String(data: data, encoding: cfEncoding(.big5_HKSCS_1999))
        let gb18030 = String(data: data, encoding: cfEncoding(.GB_18030_2000))
        switch (big5, gb18030) {
        case let (big5?, gb18030?):
            return commonCharacterShare(big5) > commonCharacterShare(gb18030) ? (big5, .big5) : (gb18030, .gb18030)
        case let (big5?, nil) where plausibleCJK(big5):
            return (big5, .big5)
        case let (nil, gb18030?):
            return (gb18030, .gb18030)
        default:
            break
        }
        if let text = String(data: data, encoding: .isoLatin1) { return (text, .latin1) }
        return nil
    }

    private static func cfEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    private static func bomlessUTF16(_ data: Data) -> Encoding? {
        let sample = [UInt8](data.prefix(512))
        guard sample.count >= 16 else { return nil }
        let evenZeros = stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
        let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
        let half = sample.count / 2
        if oddZeros > half * 6 / 10, evenZeros < half / 10 { return .utf16LittleEndian }
        if evenZeros > half * 6 / 10, oddZeros < half / 10 { return .utf16BigEndian }
        return nil
    }

    /// The most frequent Chinese characters in both scripts. Real dialogue
    /// is roughly a third these; text decoded with the wrong code page is
    /// almost none.
    private static let commonCharacters = Set(
        "的一是不了人我在有他这這个個们們中来來上大为為和到以说說时時要就出会會可也你对對生能而子那得于於着著下自之年过過发發后後作里裡用道行所然家事成方多经經么麼去法学學如都同现現当當没沒动動面起看定天分还還进進好小部其些主样樣理心她本前开開但因只从從想实實吗嗎呢吧啊哦嗯什谁誰这這很再真知走回别別让讓给給把被等快已"
    )

    private static func commonCharacterShare(_ text: String) -> Double {
        var common = 0
        var total = 0
        for scalar in text.unicodeScalars where scalar.value > 0x7F {
            total += 1
            if commonCharacters.contains(Character(scalar)) { common += 1 }
        }
        return total == 0 ? 0 : Double(common) / Double(total)
    }

    /// Rejects a "successful" decode that produced mostly private-use or
    /// compatibility code points — the signature of the wrong code page.
    private static func plausibleCJK(_ text: String) -> Bool {
        var common = 0
        var odd = 0
        for scalar in text.unicodeScalars where scalar.value > 0x7F {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3000...0x30FF, 0xFF00...0xFFEF: common += 1
            default: odd += 1
            }
        }
        return common + odd == 0 || Double(common) / Double(common + odd) > 0.9
    }
}

/// Checks that downloaded text really is a subtitle — providers sometimes
/// answer with an HTML error page or an empty file — and reports its
/// actual format, which may differ from the file extension.
public enum SubtitleValidator {
    public static func detectFormat(of text: String) -> SubtitleFormat? {
        let head = String(text.prefix(4096))
        if head.range(of: #"(?im)^\s*\[Script Info\]"#, options: .regularExpression) != nil
            || text.range(of: #"(?m)^\s*Dialogue\s*:"#, options: .regularExpression) != nil {
            if head.range(of: #"(?im)^\s*ScriptType\s*:\s*v4\.00\+"#, options: .regularExpression) != nil
                || head.range(of: #"(?im)^\s*\[V4\+ Styles\]"#, options: .regularExpression) != nil {
                return .ass
            }
            if head.range(of: #"(?im)^\s*\[V4 Styles\]|ScriptType\s*:\s*v4\.00\s*$"#, options: .regularExpression) != nil {
                return .ssa
            }
            return .ass
        }
        if head.range(of: #"^\s*WEBVTT"#, options: .regularExpression) != nil { return .vtt }
        if text.range(of: #"\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}"#, options: .regularExpression) != nil {
            return .srt
        }
        return nil
    }

    /// True when the text has at least one timed event.
    public static func hasEvents(_ text: String, format: SubtitleFormat) -> Bool {
        switch format {
        case .ass, .ssa: text.range(of: #"(?m)^\s*Dialogue\s*:"#, options: .regularExpression) != nil
        case .srt, .vtt: text.contains("-->")
        }
    }
}

/// Tells Simplified from Traditional Chinese by the characters a text
/// actually uses. Providers mislabel files and many say only "Chinese";
/// the text itself is the authority.
public enum ChineseScriptDetector {
    // Frequent characters that exist in only one script. Pairs are aligned
    // (这/這, 个/個 …) so neither side is favoured by list length.
    private static let simplifiedOnly = Set("这个们来时会为对过说还没么话发经见头长样问开关让从动实现进学气给间听觉认边当车门东风爱写书觉号飞马鸟难亲")
    private static let traditionalOnly = Set("這個們來時會為對過說還沒麼話發經見頭長樣問開關讓從動實現進學氣給間聽覺認邊當車門東風愛寫書覺號飛馬鳥難親")

    public static func detect(_ text: String) -> SubtitleLanguage? {
        var simplified = 0
        var traditional = 0
        var han = 0
        // Japanese writes many of the "traditional" forms (時, 間, 見 …), so
        // lines with kana — the Japanese half of a 简日双语 file — are
        // left out of the count.
        // ASS puts both halves of a bilingual event on one line, split by \N.
        let lines = text.replacingOccurrences(of: #"\\[Nn]"#, with: "\n", options: .regularExpression)
        for line in lines.split(whereSeparator: \.isNewline) {
            if line.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { continue }
            for character in line {
                if simplifiedOnly.contains(character) { simplified += 1 }
                if traditionalOnly.contains(character) { traditional += 1 }
                if let scalar = character.unicodeScalars.first, (0x4E00...0x9FFF).contains(scalar.value) { han += 1 }
            }
        }
        guard han >= 20 else { return nil }
        let total = simplified + traditional
        guard total >= 5 else { return .chinese }
        let ratio = Double(simplified) / Double(total)
        if ratio >= 0.8 { return .simplifiedChinese }
        if ratio <= 0.2 { return .traditionalChinese }
        // Both scripts in quantity: a bilingual 简繁 file.
        return .chinese
    }
}
