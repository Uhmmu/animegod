import AnimeGodCore
import Foundation

/// The More tab's payloads.
///
/// Four of these are the phone's own screens over the Mac's data (diary,
/// statistics, rankings, charts) and two are the phone acting as a remote
/// control (downloads, subscriptions). The remote-control pair send a
/// flattened row rather than the real record: the phone has no torrent engine
/// and no business holding a subscription rule.
@MainActor
enum LinkMorePayloads {
    static func diary(model: AppModel) -> LinkDiary {
        LinkDiary(events: model.watchHistory, summary: model.diarySummary)
    }

    static func statistics(model: AppModel, year: Int?) async -> StatisticsReport? {
        await model.loadStatistics(year: year)
        return model.statisticsReport
    }

    /// The viewer's own ordering. Works with nothing recorded are left out —
    /// an unranked, unscored, unreviewed title is not an entry in a ranking.
    static func rankings(model: AppModel) -> [LinkRankedWork] {
        model.library.compactMap { entry in
            guard let profile = model.profilesByAnimeID[entry.id] else { return nil }
            let hasSomething = profile.ranking != nil || profile.score != nil
                || profile.isFavorite || !profile.review.isEmpty
                || profile.status != .planning
            guard hasSomething else { return nil }
            return LinkRankedWork(
                animeID: entry.id,
                displayTitle: LinkPayloads.work(entry, model: model).displayTitle,
                ranking: profile.ranking,
                score: profile.score,
                status: profile.status,
                isFavorite: profile.isFavorite,
                review: profile.review
            )
        }
        .sorted { a, b in
            switch (a.ranking, b.ranking) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.score ?? -1) > (b.score ?? -1)
            }
        }
    }

    static func downloads(model: AppModel) -> [LinkDownload] {
        model.downloads.items.map { item in
            LinkDownload(
                infoHash: item.record.infoHash,
                title: item.title,
                animeTitle: item.record.animeTitle,
                progress: item.progress,
                totalBytes: item.totalBytes,
                downloadRate: Int64(item.snapshot?.downloadRate ?? 0),
                uploadRate: Int64(item.snapshot?.uploadRate ?? 0),
                peers: Int(item.snapshot?.connectedPeers ?? 0),
                state: item.snapshot.map { String(describing: $0.state) } ?? "unknown",
                isPaused: item.isPaused,
                isComplete: item.isComplete,
                isAutomatic: item.record.isAutomatic
            )
        }
    }

    static func subscriptions(model: AppModel) -> [LinkSubscription] {
        model.subscriptions.subscriptions.map { rule in
            LinkSubscription(
                id: rule.id,
                animeID: rule.animeID,
                title: rule.title,
                summary: rule.ruleSummary,
                isEnabled: rule.isEnabled,
                isSeasonComplete: rule.isSeasonComplete,
                nextEpisode: rule.nextEpisode,
                estimatedNextAt: rule.estimatedNextEpisodeAt(),
                waitingCount: model.subscriptions.candidates(for: rule.id).count
            )
        }
    }
}
