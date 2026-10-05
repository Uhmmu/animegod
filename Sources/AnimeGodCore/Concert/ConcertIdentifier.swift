import Foundation

/// Anything that can be asked about a concert release.
///
/// A protocol so the order the sources are asked in — which is the whole
/// design — can be tested without three networks.
public protocol ConcertReleaseSource: Sendable {
    var id: ConcertProviderID { get }
    /// Releases filed under a catalogue number. Empty when the source has no
    /// catalogue index at all, which is Bangumi's answer.
    func releases(catalogNumber: ConcertCatalogNumber) async throws -> [ConcertRelease]
    /// A disc's barcode, which a cue sheet carries as its `CATALOG` line and is
    /// as exact a key as the catalogue number.
    func releases(barcode: String) async throws -> [ConcertRelease]
    func releases(title: String, artist: String?) async throws -> [ConcertRelease]
    /// The full record, with its track list.
    func release(id: String) async throws -> ConcertRelease
}

extension DiscogsConcertProvider: ConcertReleaseSource {}
extension MusicBrainzConcertProvider: ConcertReleaseSource {}

public extension ConcertReleaseSource {
    /// Most sources index one; Bangumi indexes neither a barcode nor a
    /// catalogue number, and says so once here rather than at every call site.
    func releases(barcode: String) async throws -> [ConcertRelease] { [] }
}

extension BangumiConcertProvider: ConcertReleaseSource {
    /// Bangumi indexes nothing by catalogue number, so there is nothing to ask
    /// it. Saying so here rather than at the call site keeps the identifier's
    /// order of preference in one place.
    public func releases(catalogNumber: ConcertCatalogNumber) async throws -> [ConcertRelease] { [] }

    public func releases(title: String, artist: String?) async throws -> [ConcertRelease] {
        try await search([title, artist].compactMap { $0 }.joined(separator: " "))
    }

    public func release(id: String) async throws -> ConcertRelease {
        try await release(subjectID: id)
    }
}

/// What a lookup concluded about one disc folder.
public struct ConcertIdentification: Sendable {
    public var release: ConcertRelease?
    /// The catalogue number the folder was recognised by, if any.
    public var catalogNumber: ConcertCatalogNumber?
    /// Sources that threw. Reported rather than swallowed: a disc that looks
    /// unknown because a service was down is a different problem from one no
    /// service has heard of, and only one of them is worth asking about again.
    public var failures: [ConcertProviderID: String] = [:]

    /// Whether this should move the work into the concert section without
    /// anyone being asked. Only a source saying so counts.
    public var isConcert: Bool { release?.isLiveRecording == true }

    /// Nothing was found and nothing failed, so no service has this disc.
    public var isUnknown: Bool { release == nil && failures.isEmpty }
}

/// Identifies a concert disc from the name of the folder it arrived in.
///
/// The order is the design, and it follows what was measured rather than what
/// would be tidy:
///
/// 1. **The catalogue number in the folder name**, against Discogs and then
///    MusicBrainz. It is exact — each answers one release at a perfect score —
///    and it tolerates every way of writing the number.
/// 2. **Nothing**, when there is no catalogue number. A title search is not a
///    fallback here: MusicBrainz answers "MyGO!!!!! 2nd Live" with another
///    artist's release at score 100, and automatically filing a disc under the
///    wrong concert is worse than leaving it unidentified for someone to search
///    by hand.
/// 3. **Bangumi by the title the first two produced**, for the hall and the
///    score. By then the title is a real one from a real release rather than a
///    folder name, which is what makes that search worth making.
/// 4. **setlist.fm by the artist and the dates Bangumi just supplied**, for
///    what was played on each night. It indexes neither a catalogue number nor
///    a title, so it can only be asked once something else has answered — and
///    by then it is an exact question: who played, on which day.
public struct ConcertIdentifier: Sendable {
    /// How many of a folder's catalogue numbers to try. A box lists its own
    /// number and each disc's, and they all name the same release, so the first
    /// that answers ends it — but a reader that picked up a false positive
    /// first should not lose the real one behind it.
    static let catalogNumbersToTry = 3

    /// How much of the longer title the shorter one has to be before a Bangumi
    /// hit counts as the same concert.
    static let titleMatchThreshold = 0.6

    private let discogs: (any ConcertReleaseSource)?
    private let musicBrainz: (any ConcertReleaseSource)?
    private let bangumi: (any ConcertReleaseSource)?
    /// setlist.fm, asked last and asked differently: by who played and when,
    /// which only the others can tell it.
    private let setlistFM: (any ConcertEventSource)?

    public init(
        discogs: (any ConcertReleaseSource)? = nil,
        musicBrainz: (any ConcertReleaseSource)? = nil,
        bangumi: (any ConcertReleaseSource)? = nil,
        setlistFM: (any ConcertEventSource)? = nil
    ) {
        self.discogs = discogs
        self.musicBrainz = musicBrainz
        self.bangumi = bangumi
        self.setlistFM = setlistFM
    }

    /// Asks setlist.fm what was played, from what the other sources have
    /// already established.
    ///
    /// Last for a reason that is not politeness: it is indexed by artist and
    /// date, and nothing in a folder name is either of those. By this point
    /// Bangumi has usually supplied both — its 演出 subjects carry 主演 and a
    /// 开始/结束 span, and a two-night live's span expands into the two queries
    /// that find both nights.
    private func askSetlistFM(about found: [ConcertRelease]) async -> ConcertRelease? {
        guard let setlistFM, let merged = ConcertReleaseMerge.merge(found) else { return nil }
        guard let artist = merged.artistNames.first, !artist.isEmpty else { return nil }
        // A disc's release date is not the night, so only a performance date
        // becomes a query; the year is a wider net and is allowed to come from
        // either, since a live is released in the year it happened or the next.
        let dates = ConcertEventDates.dates(in: merged.performedOn ?? "")
        let year = ConcertEventDates.year(in: merged.performedOn ?? "")
            ?? ConcertEventDates.year(in: merged.releaseDate ?? "")
        guard !dates.isEmpty || year != nil else { return nil }
        return try? await setlistFM.concert(
            artist: artist,
            isoDates: dates,
            year: year,
            fallbackTitle: merged.title
        )
    }

    /// What can be learned about a concert with no catalogue number anywhere.
    ///
    /// For the release that is only ever a BDRip: no disc, no number in the
    /// folder, and the Blu-ray not indexed by either catalogue — MyGO's
    /// *6th LIVE「見つけた景色、たずさえて」* is in Bangumi and in neither of the
    /// other two. There is no setlist to be had, so there is also no setlist to
    /// get wrong; what Bangumi adds is the hall, the date, the cover and a
    /// score, and losing those because the automatic path had nothing to go on
    /// would leave a page with a folder name on it.
    ///
    /// Only on a title that plainly matches, and only from Bangumi. The
    /// identifier still refuses to take a MusicBrainz title hit, because that
    /// one answers with a different artist's release at a perfect score.
    /// - Parameter requiringPerformance: accept the answer only when Bangumi
    ///   files this as a 演出 — an event that happened in a hall. That is the
    ///   test for "is this a concert at all", as opposed to "tell me more about
    ///   this concert", and it is what makes the automatic pass safe to point at
    ///   every work no provider could match.
    public func identify(title: String, requiringPerformance: Bool = false) async -> ConcertIdentification {
        var result = ConcertIdentification()
        guard let bangumi, !title.isEmpty else { return result }
        let key = ConcertSetlistAligner.normalise(title)
        guard !key.isEmpty else { return result }
        do {
            let subjects = try await bangumi.releases(title: title, artist: nil)
                .filter { ConcertSetlistAligner.titlesMatch(ConcertSetlistAligner.normalise($0.title), key) }
            if requiringPerformance, !subjects.contains(where: \.isPerformanceRecord) { return result }
            var found: [ConcertRelease] = []
            for subject in [
                subjects.first(where: \.isPerformanceRecord),
                subjects.first(where: { !$0.isPerformanceRecord })
            ].compactMap({ $0 }) {
                found.append(try await bangumi.release(id: subject.externalID))
            }
            if let night = await askSetlistFM(about: found) { found.append(night) }
            result.release = ConcertReleaseMerge.merge(found)
        } catch {
            result.failures[bangumi.id] = error.localizedDescription
        }
        return result
    }

    /// - Parameter files: what the release's own folder says about itself.
    ///
    ///   The catalogue number is usually in there rather than in the folder's
    ///   name. Measured on a real download: the folder was called
    ///   `[DBD-Raws][MyGO!!!!! 6th LIVE…][1080P][BDRip][HEVC-10bit][FLAC][MKV]`
    ///   and carried no number at all, while `BRMM-10876` was the name of a cue
    ///   sheet two levels down — and that number answers with the release and
    ///   both nights' setlists.
    public func identify(
        folderName: String,
        files: ConcertReleaseFiles = ConcertReleaseFiles()
    ) async -> ConcertIdentification {
        var result = ConcertIdentification()
        var seenNumbers = Set<String>()
        let numbers = (ConcertCatalogNumber.all(in: folderName) + files.catalogNumbers)
            .filter { seenNumbers.insert($0.description).inserted }
            .prefix(Self.catalogNumbersToTry)
        // What the folder itself knows is worth keeping even when no service
        // answers: the scans are the artwork, and a cue sheet is a track list.
        let local = files.release(fallbackTitle: folderName)
        guard !numbers.isEmpty || files.barcode != nil else {
            result.release = local
            return result
        }

        var found: [ConcertRelease] = local.map { [$0] } ?? []
        for number in numbers {
            for source in [discogs, musicBrainz].compactMap({ $0 }) {
                guard !found.contains(where: { $0.provider == source.id }) else { continue }
                do {
                    guard let summary = try await source.releases(catalogNumber: number).first else { continue }
                    found.append(try await source.release(id: summary.externalID))
                    result.catalogNumber = result.catalogNumber ?? number
                } catch {
                    result.failures[source.id] = error.localizedDescription
                }
            }
            if found.contains(where: { $0.provider != .localFiles }) { break }
        }
        // The barcode is one more exact key, and worth one more request when
        // the numbers found nothing.
        if !found.contains(where: { $0.provider != .localFiles }), let barcode = files.barcode {
            for source in [discogs, musicBrainz].compactMap({ $0 }) {
                do {
                    guard let summary = try await source.releases(barcode: barcode).first else { continue }
                    found.append(try await source.release(id: summary.externalID))
                } catch {
                    result.failures[source.id] = error.localizedDescription
                }
            }
        }
        guard !found.isEmpty else { return result }

        // Only now is there a title worth searching Bangumi with: a real
        // release's, not the folder's.
        if let bangumi, let query = ConcertReleaseMerge.merge(found)?.title, !query.isEmpty {
            do {
                let subjects = try await bangumi.releases(title: query, artist: nil)
                // Both halves: the 演出 subject has the hall, the 音乐 subject has
                // the setlist and a score. Neither has the other's.
                for subject in [
                    subjects.first(where: \.isPerformanceRecord),
                    subjects.first(where: { !$0.isPerformanceRecord })
                ].compactMap({ $0 }) {
                    found.append(try await bangumi.release(id: subject.externalID))
                }
            } catch {
                result.failures[bangumi.id] = error.localizedDescription
            }
        }

        // And last, what was played: by now the artist and the dates are known,
        // which is the only way in that setlist.fm has.
        if let night = await askSetlistFM(about: found) { found.append(night) }

        result.release = ConcertReleaseMerge.merge(found)
        return result
    }
}
