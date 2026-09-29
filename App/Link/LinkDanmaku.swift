import AnimeGodCore
import Foundation

/// Resolves a danmaku pool for the phone.
///
/// The phone asks for comments and gets comments. It never talks to
/// dandanplay or Bilibili, holds no credentials, implements no WBI signing,
/// and cannot end up bound to a different episode than the Mac is — which is
/// the real reason this runs here rather than there.
///
/// A session is built per request rather than shared: matching writes to the
/// database and the caches make a second request for the same file cheap, so
/// the cost of not reusing one is a few hundred milliseconds on a cache hit.
@MainActor
enum LinkDanmaku {
    /// How long to wait for a match before answering with what there is.
    /// Matching hits two networks; a phone that has already started playing
    /// should not sit on a spinner because Bilibili is slow.
    private static let timeout: Duration = .seconds(25)

    static func pool(mediaFileID: UUID, model: AppModel) async -> LinkDanmakuPool? {
        guard let database = model.libraryDatabase,
              let file = try? await database.mediaFile(id: mediaFileID),
              let located = await model.locateMedia(mediaFileID: mediaFileID)
        else { return nil }
        defer { located.access.stop() }

        guard let episodes = try? await database.episodes(animeID: (try? await database.animeID(forEpisodeID: file.episodeID)) ?? UUID()),
              let media = episodes.first(where: { $0.id == file.episodeID })
        else { return nil }

        let session = DanmakuSession()
        session.attach(preferences: model.danmakuPreferences)
        session.load(
            DanmakuSession.EpisodeRequest(
                fileURL: located.url,
                mediaFileID: mediaFileID,
                fileName: (file.relativePath as NSString).lastPathComponent,
                fileSize: located.size,
                duration: media.progress?.duration ?? 0,
                titleCandidates: titleCandidates(animeID: media.episode.animeID, model: model),
                episodeNumber: media.episode.number,
                episodeKind: media.episode.kind
            ),
            database: database
        )

        let settled = await waitForPhase(session)
        return LinkDanmakuPool(
            mediaFileID: mediaFileID,
            comments: session.comments,
            sources: session.loadedSources.map(\.displayName),
            unmatched: !settled || session.comments.isEmpty
        )
    }

    /// Polls rather than observing: the session publishes through Combine and
    /// this is a one-shot request, not a view.
    private static func waitForPhase(_ session: DanmakuSession) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            switch session.phase {
            case .ready: return true
            case .noMatch, .failed, .disabled, .needsConfiguration: return false
            case .idle, .matching, .loading: break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// The same names the player's own danmaku search uses.
    private static func titleCandidates(animeID: UUID, model: AppModel) -> [String] {
        let metadata = model.metadataByAnimeID[animeID]
        let local = model.library.first(where: { $0.id == animeID })?.anime.title
        return [metadata?.title, metadata?.originalTitle, local]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
