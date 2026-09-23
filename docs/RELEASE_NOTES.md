# AnimeGod 0.3.1

AnimeGod 0.3.1 makes local playback and downloads more dependable, with
direct Blu-ray image playback, automatic archive extraction, corrected HDR
output and smoother everyday browsing and viewing.

## Blu-ray images and playback

- Open a Blu-ray `.iso` directly from the library. AnimeGod selects the main
  feature and preserves chapters and seeking without mounting or unpacking
  the image first.
- HDR10 and HLG output now use the correct transfer function, fixing video
  that could appear almost black on an HDR display.
- Video continues to fit the window when entering or leaving full screen,
  without reloading the file or losing the current playback position.
- Reopening an episode watched to the end starts it from the beginning instead
  of landing at the final frame.
- The display stays awake while video is playing and can sleep normally when
  playback is paused or closed.

## Better-organized downloads

- Every torrent now gets its own folder, including single-file releases, so a
  library folder no longer fills with loose video files.
- Completed `.rar`, `.zip` and `.7z` releases can be unpacked automatically in
  their download folder. Multi-part archives are recognized, the original
  archive is kept, and automatic extraction can be turned off from the
  download-folder menu.

## Smoother library and player

- Posters are decoded in the background at the size they are displayed,
  reducing stutter while scrolling through the library.
- Download progress now refreshes only the views that show it instead of
  repeatedly redrawing the entire app.
- Playback-position updates and dense danmaku use less main-thread work, making
  controls and comments smoother while preserving precise seeking, history and
  danmaku timing.

## Compatibility

- Requires macOS 14 or later. The supplied DMG contains a Universal app for
  Apple silicon and Intel Macs.
- The app is ad-hoc signed but not Developer ID notarized. Depending on macOS
  security settings, the first launch may require right-clicking the app and
  choosing **Open**.
