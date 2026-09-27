import Foundation

/// Reading an episode number back out of a release name, and writing one out
/// the way the release names themselves do.
///
/// A download knows its episode from the search that started it, but only
/// while that search is on screen: after a relaunch all the library has is
/// the torrent's own name. Showing a season that is still arriving in
/// episode order needs the number back, so it is parsed the same way the
/// search parsed it.
public enum TorrentEpisodeGuess {
    /// The single episode a release name is of, or nil for a batch, a movie,
    /// or anything the parser could not read a number out of.
    public static func number(in releaseName: String) -> Double? {
        let release = TorrentReleaseInfo.parse(title: releaseName)
        guard !release.isBatch, let first = release.firstEpisode else { return nil }
        guard (release.lastEpisode ?? first) == first else { return nil }
        guard first >= 0, first <= TorrentEpisodeSetBuilder.maximumEpisode else { return nil }
        return first
    }

    /// "05", "12.5" — the same shape the release titles use.
    public static func text(for episode: Double) -> String {
        episode.rounded() == episode
            ? String(format: "%02d", Int(episode))
            : String(episode)
    }
}
