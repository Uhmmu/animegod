# AnimeGod 0.1.2

AnimeGod 0.1.2 adds native danmaku playback and improves everyday video and
subtitle behavior.

## Native danmaku

- Added a native Core Animation danmaku renderer synchronized to the player's
  playback clock, including pause, seek, speed-change, and viewport handling.
- Added official dandanplay Open Danmaku API matching by file identity, manual
  anime/episode matching, local per-episode caching, and offline replay.
- Added player controls for visibility, opacity, font size, display area,
  scrolling speed, comment limits, mode/color filtering, timing offset,
  reload, and rematching. Press `D` to toggle danmaku.
- dandanplay AppId and AppSecret can be configured in Settings and are stored
  in the macOS Keychain.

## Playback and subtitles

- Video now always preserves the source aspect ratio in both windowed and
  fullscreen playback. The complete frame remains visible, with black bars
  when the display and video aspect ratios differ.
- Subtitle selections persist across launches. The same file restores its
  exact track; other episodes match the preferred subtitle by language and
  name even when track IDs differ. Choosing Off is remembered as well.
- Enabled the hardened-runtime permissions required by MPVKit's embedded
  LuaJIT so playback scripts can initialize in packaged builds.

## Compatibility and limitations

- Requires macOS 14 or later. The supplied DMG contains a Universal app for
  Apple silicon and Intel Macs.
- Dolby Vision Profile 7 FEL/MEL enhancement layers are not decoded; the
  HDR10-compatible base layer is used instead.
- The app is ad-hoc signed but not Developer ID notarized. Depending on macOS
  security settings, the first launch may require right-clicking the app and
  choosing **Open**.
- Direct MyAnimeList integration still requires an official client ID and is
  not bundled.
