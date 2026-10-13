import Foundation

public extension LibraryDatabase {
    /// Uses playable local videos only: the album's CD and a missing second
    /// night must never appear as a BD somebody can open.
    func concertSongs() throws -> [LibraryConcertSong] {
        var appearances: [ConcertSongAppearance] = []
        for concert in try concerts() {
            guard let release = concert.release else { continue }
            for (index, episode) in try episodes(animeID: concert.id).enumerated() {
                let number = episode.episode.numberText.flatMap(Int.init) ?? (index + 1)
                let videos = release.videoDiscs
                // Match the detail page's video ordinal, with the medium's
                // position as fallback. Do not substitute disc one for a
                // numbered disc whose programme is unknown.
                let disc = videos.indices.contains(number - 1) ? videos[number - 1]
                    : videos.first { $0.position == number }
                guard let disc else { continue }
                let timeline = try concertSetlist(episodeID: episode.episode.id)?.alignment
                for track in disc.tracks where track.kind == .song {
                    let time = timeline?.placements.first { $0.trackPosition == track.position }?.startTime
                    appearances.append(ConcertSongAppearance(
                        concert: concert, episode: episode, discNumber: number,
                        discTitle: disc.title, track: track,
                        startTime: time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                        timeline: timeline
                    ))
                }
            }
        }
        return ConcertSongLibrary.songs(from: appearances)
    }
}
