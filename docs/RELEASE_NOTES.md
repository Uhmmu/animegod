# AnimeGod 0.1.4

AnimeGod 0.1.4 keeps danmaku readable on even the busiest shows, adds an
in-player Danmaku Manager, and fixes how some release folders are grouped in
the library.

## Danmaku that stays readable

- The **Font Size** setting now takes effect, and a new **Line Spacing**
  option (Compact, Standard, Relaxed) packs comments closer together.
  Standard spacing is noticeably tighter than before.
- **Max Lines** limits scrolling comments to a set number of rows, in
  addition to the existing display-area choice.
- Comments in the same row keep a gap instead of following each other edge
  to edge, and comments that don't fit are skipped rather than drawn on top
  of each other.

## Filters for crowded shows

- **Merge Duplicate Comments** (on by default) shows a comment repeated within
  10 seconds once, with a ×N count. Case, spacing, punctuation, and long
  runs like "哈哈哈哈" are ignored when comparing.
- **Density** thins comments evenly from 100% down to 20%. The same comments
  stay visible after seeking, and comments repeated three or more times are
  always kept.
- **Hide Long Comments** hides comments over 15, 20, 30, or 50 characters.
- **Blocked Keywords** accept plain text or `/regex/` patterns.
- Your existing danmaku settings carry over unchanged.

## Danmaku Manager

- Press `M`, or choose **Manage Danmaku…** from the danmaku menu, to open a
  panel beside the video.
- **Nearby** lists the last 30 seconds of comments as they play; **Search**
  finds comments anywhere in the episode. Click a comment to jump to it.
- Right-click a comment to block its text or its sender, copy it, or undo a
  block. Hidden comments are struck through with the rule that hid them.
- **Blocked** manages keywords and users in one place; blocked users also
  appear in Danmaku Settings.
- Player shortcuts such as Space and `F` pause while you type in the panel,
  so searching never pauses playback or toggles fullscreen.

## Library fixes

- Numbered clips such as `PV1` or `[NCOP1]` stay grouped with their release
  instead of splitting a folder into several works.
- Bundled-contents notes like `(Scans&OST&Special)` are removed from work
  titles; parentheses with other information, such as a year, are kept.

## Compatibility and limitations

- Requires macOS 14 or later. The supplied DMG contains a Universal app for
  Apple silicon and Intel Macs.
- The app is ad-hoc signed but not Developer ID notarized. Depending on macOS
  security settings, the first launch may require right-clicking the app and
  choosing **Open**.
- Direct MyAnimeList integration still requires an official client ID and is
  not bundled.
