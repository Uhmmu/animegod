import AnimeGodCore
import Foundation

/// Turns what the Mac already has into what the wire carries.
///
/// The one thing here that is not a straight copy is `displayTitle`: the Mac
/// sorts the grid over the title the metadata gave the work, while
/// `anime.sortTitle` holds the folder's romaji name. Sending the stored column
/// and letting the phone sort would put the same works in a different order on
/// the two screens.
@MainActor
enum LinkPayloads {
    static func work(_ entry: LibraryAnime, model: AppModel) -> LinkWork {
        let metadata = model.metadataByAnimeID[entry.id]
        let title = metadata?.title.isEmpty == false ? metadata!.title : entry.anime.title
        return LinkWork(
            id: entry.id,
            displayTitle: title,
            originalTitle: metadata?.originalTitle,
            sortKey: title,
            kind: metadata?.kind ?? entry.anime.kind,
            posterPath: entry.anime.posterPath,
            score: averageScore(for: entry.id, model: model),
            episodeCount: entry.episodeCount,
            watchedCount: entry.watchedCount,
            unwatchedCount: entry.unwatchedCount,
            lastWatchedAt: entry.lastWatchedAt,
            lastPlayedAt: entry.lastPlayedAt,
            createdAt: entry.anime.createdAt
        )
    }

    /// The mean of the providers' scores; both report out of ten.
    private static func averageScore(for animeID: UUID, model: AppModel) -> Double? {
        let scores = (model.metadataSourcesByAnimeID[animeID] ?? []).compactMap(\.score).filter { $0 > 0 }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    static func library(model: AppModel) -> LinkLibrary {
        LinkLibrary(works: model.library.map { work($0, model: model) })
    }

    static func episode(_ media: EpisodeMedia) -> LinkEpisode {
        LinkEpisode(
            id: media.episode.id,
            animeID: media.episode.animeID,
            label: media.episode.displayLabel,
            title: media.episode.title,
            kind: media.episode.kind,
            sortIndex: media.episode.sortIndex,
            mediaFileID: media.mediaFile.id,
            fileSize: media.mediaFile.fileSize,
            position: media.progress?.position ?? 0,
            duration: media.progress?.duration ?? 0,
            isWatched: media.progress?.isWatched ?? false,
            updatedAt: media.progress?.updatedAt
        )
    }

    static func continueWatching(model: AppModel) -> [LinkEpisode] {
        model.continueWatching.map(episode)
    }

    static func detail(animeID: UUID, model: AppModel) async -> LinkAnimeDetail? {
        guard let entry = model.library.first(where: { $0.id == animeID }) else { return nil }
        let episodes = await model.episodes(for: entry.anime)
        let sources = (model.metadataSourcesByAnimeID[animeID] ?? []).map {
            LinkMetadataSource(
                provider: $0.provider.rawValue,
                displayName: $0.provider.displayName,
                score: $0.score,
                ratingCount: $0.ratingCount,
                sourceURL: $0.sourceURL
            )
        }
        return LinkAnimeDetail(
            work: work(entry, model: model),
            summary: model.metadataByAnimeID[animeID]?.summary ?? "",
            episodes: episodes.map(episode),
            sources: sources
        )
    }
}
