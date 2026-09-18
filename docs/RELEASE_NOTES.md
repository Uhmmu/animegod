# AnimeGod 0.2.1

AnimeGod 0.2.1 finds Chinese subtitles for videos that have none. It
identifies the episode and the release being played, searches online subtitle
sites, and loads a match on its own when it is confident. Player menus now
stay open during playback, and provider keys are no longer kept in the
Keychain.

## Online Chinese subtitles

- When a video has no subtitle in your preferred languages (Simplified, then
  Traditional Chinese by default), AnimeGod identifies the anime, season,
  episode and release (fansub or encode group, BD or WEB source,
  resolution), searches every configured subtitle site in parallel, and loads
  the best result automatically. When no result is confident enough, a small
  badge offers the candidates instead.
- Sources: **射手网(伪) assrt.net** (Chinese fansub archive, ASS),
  **SubDL** (searched by TMDB ID, season and episode), **OpenSubtitles**
  (exact-file hash matches; SRT only) and **Jimaku** (Japanese, used only
  when Japanese is a preferred language). Each needs its own API key in
  Settings → Online Subtitles. One source failing, timing out or hitting its
  rate limit never affects the others.
- Matching checks the episode and the release first. Subtitles for a
  different episode or season, a different title, or a different source (a
  BD subtitle on a WEB video, or the reverse) are never loaded automatically.
  Your language and format order (ASS/SSA before SRT) ranks the rest.
- Library titles and AniList/MAL IDs are mapped to TMDB, IMDb and AniDB IDs,
  so sites indexed by those find the right show.
- Season packs and ZIP archives are unpacked to the right episode. GBK, Big5
  and UTF-16 files are converted to UTF-8, and Simplified and Traditional
  Chinese are told apart from the text itself. Fonts included in subtitle
  packs are used for ASS typesetting.
- The subtitle menu now groups **Embedded**, **External Files** and
  **Online** tracks. **Online Subtitles** offers Auto-Match, **Search
  Subtitles…** (language, format, source, group, match score, version and
  file name) and a list of downloaded subtitles.
- Downloaded subtitles are cached per episode and reload on replay without
  another search. The cache can be cleared in Settings.
- Releases whose names say Chinese subtitles are burned into the picture
  (for example `[CHT]` or `[简日内嵌]`) are not searched by default. This
  can be changed in Settings.

## Fixes

- **Player menus:** subtitle, delay, speed, audio, chapter, episode, version
  and danmaku menus no longer close by themselves or ignore clicks while a
  video is playing.
- **External subtitles:** subtitles loaded with **Load External Subtitle…**
  are no longer lost when entering or leaving full screen, or when the HDR
  output changes.
- **Provider keys:** DeepL, dandanplay, Bilibili and subtitle-site keys are
  now stored in AnimeGod's own local settings instead of the Keychain, so
  updating the app no longer asks for your password once per key. Keys saved
  by 0.2.0 stay in the Keychain until you choose **Import Keys Saved in the
  Keychain** in Settings → Online Subtitles, or enter them again.

## Compatibility and privacy

- Requires macOS 14 or later. The supplied DMG contains a Universal app for
  Apple silicon and Intel Macs.
- A subtitle search sends the anime's title, IDs, episode number and the
  video's file name to the subtitle sites you configured. OpenSubtitles also
  receives a hash computed from 128 KiB of the file.
- Subtitles are not shown while a video uses the native Dolby Vision
  (AVFoundation) path. Press ⌘⇧H to switch to mpv.
- The app is ad-hoc signed but not Developer ID notarized. Depending on macOS
  security settings, the first launch may require right-clicking the app and
  choosing **Open**.
