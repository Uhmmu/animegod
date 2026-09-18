import Foundation

/// A subtitle ready to cache: decoded to UTF-8, validated, and labelled
/// with the language its own text shows.
public struct PreparedSubtitle: Sendable {
    public var fileName: String
    public var text: String
    public var format: SubtitleFormat
    public var language: SubtitleLanguage?
    public var sourceEncoding: SubtitleTextDecoder.Encoding
    /// Fonts shipped in the same archive (fansub packs often include the
    /// typesetting fonts); libass can use them from the fonts directory.
    public var fonts: [SubtitleDownloadedFile]
}

/// Turns whatever a provider downloaded — one file, a ZIP, a season pack —
/// into the single subtitle that fits the playing episode.
public struct SubtitleFileSelector: Sendable {
    public var preferences: SubtitleRankingPreferences

    public init(preferences: SubtitleRankingPreferences = .default) {
        self.preferences = preferences
    }

    public static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    public func prepare(
        _ downloaded: [SubtitleDownloadedFile],
        for video: SubtitleVideoIdentity,
        claimedLanguages: [SubtitleLanguage]
    ) throws -> PreparedSubtitle {
        let files = try SubtitleArchive.expand(downloaded)
        let fonts = files.filter { Self.fontExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }

        struct Candidate {
            let file: SubtitleDownloadedFile
            let text: String
            let format: SubtitleFormat
            let language: SubtitleLanguage?
            let encoding: SubtitleTextDecoder.Encoding
            let episode: Double?
        }

        var candidates: [Candidate] = []
        for file in files {
            let declared = SubtitleFormat.of(fileName: file.name)
            // Unknown extensions are still inspected: some providers serve
            // files named after the page rather than the format.
            guard declared != nil || (file.name as NSString).pathExtension.isEmpty || (file.name as NSString).pathExtension.lowercased() == "txt",
                  let decoded = SubtitleTextDecoder.decode(file.data),
                  let format = SubtitleValidator.detectFormat(of: decoded.text),
                  SubtitleValidator.hasEvents(decoded.text, format: format) else { continue }
            // The name says what the uploader believed; for the Chinese
            // script the text itself decides.
            let named = SubtitleReleaseParsing.language(inFileName: file.name)
            let detected = ChineseScriptDetector.detect(decoded.text)
            let language: SubtitleLanguage?
            if let detected, detected != .chinese, named == nil || named?.isChinese == true {
                language = detected
            } else {
                language = named ?? detected
            }
            candidates.append(Candidate(
                file: file, text: decoded.text, format: format, language: language,
                encoding: decoded.encoding, episode: SubtitleReleaseParsing.episode(inFileName: file.name)
            ))
        }
        guard !candidates.isEmpty else {
            throw files.isEmpty ? SubtitleProviderError.invalidSubtitle : SubtitleProviderError.noSuitableFile
        }

        // In a pack, files that name an episode must name ours. A pack of
        // numbered files without ours is the wrong pack, not a fallback.
        var pool = candidates
        if candidates.count > 1, let wanted = video.episode {
            let numbered = candidates.filter { $0.episode != nil }
            if !numbered.isEmpty {
                pool = numbered.filter { $0.episode == wanted }
                guard !pool.isEmpty else { throw SubtitleProviderError.noSuitableFile }
            }
        }

        let best = pool.max { lhs, rhs in
            rank(language: lhs.language ?? claimedLanguages.first, format: lhs.format)
                < rank(language: rhs.language ?? claimedLanguages.first, format: rhs.format)
        }!
        return PreparedSubtitle(
            fileName: (best.file.name as NSString).lastPathComponent,
            text: best.text,
            format: best.format,
            language: best.language ?? (claimedLanguages.count == 1 ? claimedLanguages.first : nil),
            sourceEncoding: best.encoding,
            fonts: fonts
        )
    }

    /// Language outranks format: a Simplified SRT beats a Japanese ASS when
    /// Simplified is preferred, matching the user's list order.
    private func rank(language: SubtitleLanguage?, format: SubtitleFormat) -> Double {
        var value = 0.0
        if let language {
            if let index = preferences.languages.firstIndex(of: language) {
                value += Double(100 - index * 10)
            } else if language == .chinese,
                      preferences.languages.contains(where: \.isChinese) {
                value += 85
            }
        }
        if let index = preferences.formats.firstIndex(of: format) {
            value += Double(8 - index * 2)
        }
        return value
    }
}
