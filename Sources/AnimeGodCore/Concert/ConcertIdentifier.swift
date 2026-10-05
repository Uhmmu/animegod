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
    func releases(title: String, artist: String?) async throws -> [ConcertRelease]
    /// The full record, with its track list.
    func release(id: String) async throws -> ConcertRelease
}

extension DiscogsConcertProvider: ConcertReleaseSource {}
extension MusicBrainzConcertProvider: ConcertReleaseSource {}

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
public struct ConcertIdentifier: Sendable {
    /// How many of a folder's catalogue numbers to try. A box lists its own
    /// number and each disc's, and they all name the same release, so the first
    /// that answers ends it — but a reader that picked up a false positive
    /// first should not lose the real one behind it.
    static let catalogNumbersToTry = 3

    private let discogs: (any ConcertReleaseSource)?
    private let musicBrainz: (any ConcertReleaseSource)?
    private let bangumi: (any ConcertReleaseSource)?

    public init(
        discogs: (any ConcertReleaseSource)? = nil,
        musicBrainz: (any ConcertReleaseSource)? = nil,
        bangumi: (any ConcertReleaseSource)? = nil
    ) {
        self.discogs = discogs
        self.musicBrainz = musicBrainz
        self.bangumi = bangumi
    }

    public func identify(folderName: String) async -> ConcertIdentification {
        var result = ConcertIdentification()
        let numbers = Array(ConcertCatalogNumber.all(in: folderName).prefix(Self.catalogNumbersToTry))
        guard !numbers.isEmpty else { return result }

        var found: [ConcertRelease] = []
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
            if !found.isEmpty { break }
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

        result.release = ConcertReleaseMerge.merge(found)
        return result
    }
}
