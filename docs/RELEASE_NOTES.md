# AnimeGod 0.1.1

AnimeGod 0.1.1 completes native HDR and Dolby Vision playback and includes two
player reliability fixes discovered during final validation.

## HDR and Dolby Vision

- Added constant-format 16-bit-float BT.2020 EDR output for HDR10 and HLG on
  capable displays, with automatic SDR fallback and a user-controlled Forced
  SDR mode.
- Dolby Vision is now identified from real `dvvC`/`dvcC` configuration records
  and mpv RPU side data instead of release filenames.
- Eligible Dolby Vision Profile 8.4 `hvc1` MP4/MOV files use AVFoundation's
  native playback path.
- Dolby Vision Profile 8 MKV and Profile 7 use the HDR10-compatible base layer
  and report the fallback honestly in diagnostics.
- The diagnostics panel reports the exact HDR mode, RPU evidence, layer format,
  tone-mapping mode, EDR headroom, active pipeline, and Profile 7 limitation.
- Display changes and fullscreen transitions re-evaluate output capabilities
  without losing playback position, pause state, tracks, volume, speed, or
  subtitle/audio delays.

## Playback fixes

- Fixed large SDR MKV files remaining on “Opening video…” while a Dolby Vision
  container probe scanned the file. MKV playback now starts immediately and a
  bounded probe runs in the background.
- Fixed the pointer remaining visible after entering fullscreen. When playback
  is active, the controls and pointer now hide after 2.8 seconds of inactivity;
  moving the mouse, leaving fullscreen, or switching away restores them.

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
