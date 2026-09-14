# AnimeGod 0.1.3

AnimeGod 0.1.3 makes danmaku easier to use, adds reliable offline playback for
anime stored on removable drives, and brings more of Bangumi into the app.

## Danmaku that finds the right episode

- Click the danmaku button to see automatically ranked episode suggestions.
  AnimeGod uses your library metadata, episode number, and media type instead
  of asking you to paste a release filename into a search field.
- The selected episode is clearly marked as the current match, so trying a
  different result gives immediate, visible confirmation.
- Comments now start at the top of the picture and stay locked to the video.
  Pausing freezes them immediately, while seeking, changing speed, and
  resuming keep the timelines synchronized.
- Every downloaded comment set is cached locally. Replaying the same episode
  uses the cache without another network request; **Refresh Danmaku** in the
  player menu or episode chooser fetches a new copy only when you ask for it.
- Updated compatibility with the current dandanplay API response format.

## Offline episode playback

- Episodes on an external drive can be cached automatically while you watch or
  saved manually in advance with **Cache All** and per-episode controls.
- Cached episodes remain playable when the drive is disconnected. Uncached
  episodes stay visible in the library and tell you when the drive is needed.
- Finished auto-cached episodes are removed at 90% watched to reclaim space;
  manually saved copies remain until you delete them.
- A new cache manager shows storage use, copy progress, watched status, and
  controls for cancelling, revealing, or deleting cached episodes.

## More Bangumi discovery and community

- Browse Bangumi rankings across anime, books, music, games, and live action,
  including the site's category filters and paginated results.
- Ranked entries show covers, rank, score, rating count, and whether the title
  is already connected to your local library.
- Anime pages now include Bangumi's subject shoutbox alongside existing
  community topics and blogs.

## HDR and Dolby Vision

- Improved HDR and Dolby Vision luminance mapping on compatible displays so
  highlights retain their intended brightness without double tone mapping.
- Dolby Vision Profile 8 playback continues to use its HDR-compatible path;
  Profile 7 enhancement layers remain unsupported and use the HDR10 base
  layer.

## Compatibility and limitations

- Requires macOS 14 or later. The supplied DMG contains a Universal app for
  Apple silicon and Intel Macs.
- The app is ad-hoc signed but not Developer ID notarized. Depending on macOS
  security settings, the first launch may require right-clicking the app and
  choosing **Open**.
- Direct MyAnimeList integration still requires an official client ID and is
  not bundled.
