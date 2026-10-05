import Foundation

/// Folds what three sources said about one concert disc into one record.
///
/// Each source is asked for what it is actually good at, which was measured
/// rather than assumed:
///
/// | | |
/// |---|---|
/// | Discogs | the catalogue number, the label, the barcode, the shape of the box — and a cover for everything it holds |
/// | MusicBrainz | the setlist, the song lengths, and the names of the discs |
/// | Bangumi | the hall, when the concert happened, and a score somebody voted on |
/// | setlist.fm | what was played on each night, in the order it was played, with the encore marked |
///
/// The merge is a pure function so the order of preference is testable without
/// a network: getting it wrong is silent, and a field quietly taken from the
/// weaker source is the kind of thing nobody notices until a page is wrong.
public enum ConcertReleaseMerge {
    /// - Parameter sources: every answer, in any order.
    /// - Returns: nil when nothing was found.
    public static func merge(_ sources: [ConcertRelease]) -> ConcertRelease? {
        guard !sources.isEmpty else { return nil }
        let discogs = sources.first { $0.provider == .discogs }
        let musicBrainz = sources.first { $0.provider == .musicBrainz }
        // Bangumi answers twice about the same concert, and the two halves do
        // not overlap: the 演出 subject knows the hall, the 音乐 subject knows
        // the disc.
        let performance = sources.first { $0.provider == .bangumi && $0.isPerformanceRecord }
        let bangumiDisc = sources.first { $0.provider == .bangumi && !$0.isPerformanceRecord }
        /// The release's own folder: its scans, its cue sheet, its catalogue
        /// number. Not a service, and for artwork better than all of them.
        let local = sources.first { $0.provider == .localFiles }
        /// What was played on the night. No lengths and romanised titles, so it
        /// never leads a setlist — but it is the only source that knows the two
        /// nights of a live apart.
        let setlistFM = sources.first { $0.provider == .setlistFM }

        // Whichever source is leading decides the identity the record is
        // stored under, and that is the one with the setlist.
        let lead = musicBrainz ?? discogs ?? bangumiDisc ?? performance ?? setlistFM ?? local!

        var merged = ConcertRelease(
            provider: lead.provider,
            externalID: lead.externalID,
            title: title(musicBrainz: musicBrainz, others: [discogs, bangumiDisc, performance]),
            artistNames: dedupe([
                musicBrainz?.artistNames ?? [], discogs?.artistNames ?? [],
                performance?.artistNames ?? [], setlistFM?.artistNames ?? [],
                local?.artistNames ?? []
            ].flatMap { $0 }),
            releaseDate: first([discogs?.releaseDate, musicBrainz?.releaseDate, bangumiDisc?.releaseDate]),
            country: first([discogs?.country, musicBrainz?.country, performance?.country]),
            labels: dedupe([discogs?.labels ?? [], musicBrainz?.labels ?? []].flatMap { $0 }),
            catalogNumbers: dedupe([
                musicBrainz?.catalogNumbers ?? [], discogs?.catalogNumbers ?? [],
                local?.catalogNumbers ?? []
            ].flatMap { $0 }),
            barcode: first([discogs?.barcode, musicBrainz?.barcode, local?.barcode]),
            genres: dedupe([discogs?.genres ?? [], performance?.genres ?? []].flatMap { $0 }),
            discs: discs(musicBrainz: musicBrainz, bangumi: bangumiDisc, setlistFM: setlistFM,
                         discogs: discogs, local: local),
            coverImageURLs: covers(local: local, performance: performance, bangumiDisc: bangumiDisc,
                                   musicBrainz: musicBrainz, discogs: discogs),
            sourceURL: lead.sourceURL,
            // Bangumi is the only one of the three with a rating a person left,
            // and it has two of them.
            score: rating(performance: performance, disc: bangumiDisc)?.score,
            ratingCount: rating(performance: performance, disc: bangumiDisc)?.count,
            summary: first([bangumiDisc?.summary, performance?.summary, discogs?.summary]),
            // setlist.fm names the hall *and* the city, and it is the venue of
            // the night rather than of the tour, so it leads here.
            venue: first([setlistFM?.venue, performance?.venue, bangumiDisc?.venue]),
            performedOn: first([performance?.performedOn, setlistFM?.performedOn, bangumiDisc?.performedOn]),
            officialSiteURL: first([performance?.officialSiteURL, bangumiDisc?.officialSiteURL]),
            isPerformanceRecord: false,
            // One source saying so is enough: none of them claims it falsely,
            // and only MusicBrainz and Bangumi claim it at all.
            isLiveRecording: sources.contains(where: \.isLiveRecording),
            // Only the folder knows what is in the box.
            extras: local?.extras ?? []
        )
        if merged.title.isEmpty { merged.title = lead.title }
        return merged
    }

    /// What to call the concert.
    ///
    /// A live Blu-ray is often not its own release but a medium inside an
    /// album's — MyGO's *跡暖空* is a CD and two Blu-rays — so the release title
    /// is the album's name and the *medium's* title is the concert's. Measured
    /// on `ANZX-10294`, the media are titled `結束バンドLIVE-恒星-`,
    /// `ぼっち・ざ・ろっく！です。` and nothing, while the release is
    /// `結束バンドLIVE-恒星-`; on a mixed release only the medium gets it right.
    static func title(musicBrainz: ConcertRelease?, others: [ConcertRelease?]) -> String {
        if let discTitle = musicBrainz?.videoDiscs.first?.title, !discTitle.isEmpty {
            // The medium is one night of the concert and is titled as such —
            // `… 見つけた景色、たずさえて」DAY1`. The concert is both nights, so the
            // night comes off the name the same way it comes off a folder's.
            return AnimeFilenameParser.withoutDiscLabel(discTitle)
        }
        if let releaseTitle = musicBrainz?.title, !releaseTitle.isEmpty { return releaseTitle }
        return others.compactMap { $0?.title }.first { !$0.isEmpty } ?? ""
    }

    /// Which of Bangumi's two ratings to show.
    ///
    /// Not a fixed preference between them, because neither is reliably the
    /// better one. The 演出 subject is the concert everybody saw and usually has
    /// the most votes — but plenty have **none at all**, and Bangumi reports
    /// those as a score of 0 (measured: Kalafina's 10th anniversary live is
    /// 0 from nobody). The 音乐 subject is the disc, with fewer voters but real
    /// ones. So the rule is the one more people voted on, and a score nobody
    /// voted on is not a score.
    static func rating(
        performance: ConcertRelease?,
        disc: ConcertRelease?
    ) -> (score: Double, count: Int?)? {
        [performance, disc]
            .compactMap { candidate -> (score: Double, count: Int?)? in
                guard let score = candidate?.score, score > 0 else { return nil }
                return (score, candidate?.ratingCount)
            }
            .max { ($0.count ?? 0) < ($1.count ?? 0) }
    }

    /// The setlist, from whichever source has one worth laying over a timeline.
    ///
    /// MusicBrainz first and not by a little: it is the only one that publishes
    /// song lengths, which is what the chapter alignment works from, and
    /// Discogs' hand-entered lists do contain mistakes — on `ANZX-10294` it
    /// lists `ひみつ基地` twice and omits `ラブソングが歌えない`, which would put
    /// every song after the fourth one place out. Bangumi's prose setlist comes
    /// second because it is at least the right songs in the right order.
    static func discs(
        musicBrainz: ConcertRelease?,
        bangumi: ConcertRelease?,
        setlistFM: ConcertRelease? = nil,
        discogs: ConcertRelease?,
        local: ConcertRelease? = nil
    ) -> [ConcertDisc] {
        // The folder's own cue sheet comes last among track lists, because it
        // describes the bonus CD rather than the programme — twelve songs where
        // each night of the concert ran sixteen. It is still a setlist, and it
        // is the only one with durations on it, so it beats having none.
        // setlist.fm ahead of Discogs: it has no lengths either, but it is a
        // night's own running order with the encore marked, while Discogs'
        // hand-entered lists are measurably wrong on these releases.
        for candidate in [musicBrainz, bangumi, setlistFM, discogs, local] {
            guard let discs = candidate?.discs, !discs.isEmpty,
                  discs.contains(where: { !$0.songs.isEmpty })
            else { continue }
            return discs
        }
        return []
    }

    /// Covers, best first.
    ///
    /// Bangumi's `lain.bgm.tv` images are full-size cover scans; the Cover Art
    /// Archive is next when it has anything at all — two of six real concert
    /// Blu-rays had none; and Discogs is last because every image it had for
    /// these releases was a `secondary` one around 500px, which is as likely to
    /// be the back of the case as the front.
    static func covers(
        local: ConcertRelease? = nil,
        performance: ConcertRelease?,
        bangumiDisc: ConcertRelease?,
        musicBrainz: ConcertRelease?,
        discogs: ConcertRelease?
    ) -> [URL] {
        var seen = Set<URL>()
        // The release's own scans first and by a long way: three-megabyte
        // jacket scans against Discogs' 445×600 photograph of the case.
        return [local, bangumiDisc, performance, musicBrainz, discogs]
            .compactMap { $0?.coverImageURLs }
            .flatMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    private static func first(_ candidates: [String?]) -> String? {
        candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    private static func first(_ candidates: [Double?]) -> Double? {
        candidates.compactMap { $0 }.first
    }

    private static func first(_ candidates: [Int?]) -> Int? {
        candidates.compactMap { $0 }.first
    }

    private static func first(_ candidates: [URL?]) -> URL? {
        candidates.compactMap { $0 }.first
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
