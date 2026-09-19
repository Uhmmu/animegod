# Appearance Plan: Dark Mode and Player Chrome

Status: **G1 and G2 implemented** (G3–G4 planned)

Two problems, split into four goals that each ship and get verified on their
own:

1. The app has no appearance setting, and nothing checks that the library UI
   looks right in dark mode.
2. The player's controls are stock AppKit widgets on a full-width
   `.regularMaterial` bar. In light mode that means a pale grey strip over
   the video; the scrubber is a system `Slider`; menus draw bordered pop-up
   buttons with disclosure arrows; buttons have no hover or pressed state.

Order: **G1 → G2 → G3 → G4**. G1 comes first because it adds the shared
design tokens that G2–G4 use.

## Current state (what the code does today)

- Library window: SwiftUI `WindowGroup`, `NavigationSplitView`. It already
  mostly uses semantic styles (`.background.secondary`, `.quaternary`,
  `.secondary`), so it follows the system appearance. There is **no
  in-app override**, no `AccentColor` asset, and no shared color or spacing
  constants. Every view picks its own radius (4 / 8 / 12 / 14) and tint
  opacity (0.06 / 0.14 / 0.15).
- A few colors are fixed: `DownloadRing` (`LibraryView.swift:148–160`) and
  the poster shadow in `AnimeDetailView.swift:659`.
- Player window (`AnimeGodApp.swift`, `.hiddenTitleBar`): black background
  with a system-appearance control bar (`PlayerScreen.controls`,
  `PlayerScreen.swift:983`). The header draws white text on a gradient;
  the controls use `.primary` on `.regularMaterial`. So in light mode the
  header is dark and the controls are light.
- `DanmakuManagerPanel` already forces `.colorScheme(.dark)` locally. The
  status badges use hand-made `.black.opacity(0.6)` backgrounds, and the
  diagnostics panel uses `.black.opacity(0.72)`. Three different ways to
  draw a dark overlay.

## Constraints every goal must respect

These come from `CLAUDE.md` and past bugs:

- `PlayerScreen` re-renders about 25×/s while playing. Any control with its
  own state (hover, drag, open menu) must be a separate view that does not
  observe `PlayerState` wholesale. Otherwise hover state flickers and menus
  close. Control-bar menus stay inside `StableMenu(key…)`, or use an
  `Equatable` view like `SubtitleMenuButton`.
- Single-key shortcuts go through `playerKey(_:)`.
- Every seek must still go through `PlayerState.seek`, which calls
  `danmaku.playbackSample`. The new scrubber must not call mpv directly.
- Don't touch `CAMetalLayer` configuration or the HDR/EDR pipeline. The
  chrome sits above the video; it never changes the layer.
- Verify each goal by building into `DerivedData/<task>/`, backing up
  `/Applications/AnimeGod.app`, and installing **without re-signing**. Take
  screenshots in-process (`-smokeAppearanceSnapshots` captures the app's
  own windows). `screencapture` has no Screen Recording permission here,
  and mpv itself can't write screenshots.

---

## G1 — Appearance setting and dark-mode audit

**Goal:** the user can choose System / Light / Dark, every library screen
looks deliberate in both, and there is a single set of design tokens.

1. **`AppearanceMode`** (`App/Design/Appearance.swift`):
   `enum AppearanceMode: String { system, light, dark }` in `@AppStorage`.
   Apply it through `NSApp.appearance` (`nil` / `.aqua` / `.darkAqua`), not
   `.preferredColorScheme`. The AppKit route also covers sheets, menus,
   alerts, `NSOpenPanel` and the Settings form, and it takes effect
   immediately without rebuilding the view tree.
2. **Settings → "Appearance" section** at the top of `SettingsView`: a
   segmented picker with three options.
3. **Design tokens** (`App/Design/Theme.swift`): corner radii (`small 6`,
   `card 12`, `panel 14`), card background, tag tint opacity, poster
   placeholder, poster shadow (weaker in dark mode). Replace the scattered
   literal values with these while doing the audit. Only touch lines that
   are visibly wrong or that duplicate a token; no broad rewrites.
4. **`AccentColor` asset** with light and dark variants, so tints like the
   `.accentColor.opacity(0.14)` tags and the Statistics gradients keep their
   contrast on dark backgrounds.
5. **Audit pass, screen by screen, both appearances:** All Anime (poster
   grid, `DownloadingCard`/`DownloadRing`), Anime Detail (hero, episode
   list, poster shadow), Continue Watching, Bangumi Charts, Find Releases
   (`Tag` tints), Rankings / Diary / Statistics (chart colors), Library
   Folders, Episode Cache, Downloads (green/secondary/accent progress
   tints), Subscriptions, Settings, Match Review sheet.
6. **The player window is always dark.** Set the player `NSWindow`'s
   `appearance = .darkAqua`, whatever the app setting is. Video chrome is a
   dark surface by nature, and this makes menus, sheets (Danmaku settings,
   Subtitle search, Danmaku match) and materials in the player consistent.
   After that, the local `.colorScheme(.dark)` in `DanmakuManagerPanel` and
   the `.foregroundStyle(.white)` workarounds can go.

**Outcome (G1):** the audit (`AnimeGod -smokeAppearanceSnapshots`, which
writes a light and a dark PNG of every sidebar section plus a detail page)
found the library already correct in dark: it uses semantic styles
throughout. Items 3 and 4 were therefore dropped: there is no library
color to fix, and the system accent color already adapts to dark, so a
custom `AccentColor` would only override the user's choice. The player
tokens move to G2, where they are first used. Item 6 uses
`.preferredColorScheme(.dark)` on the player scene: setting
`NSWindow.appearance` from inside the view is overridden by SwiftUI. The
smoke test confirms the player is DarkAqua while the library window next
to it stays Aqua.

**Done when:** switching the setting restyles every open window live; each
screen listed above has light and dark screenshots with no unreadable text,
invisible separators, or glaring white blocks; and the player looks the same
whatever the app setting is.

---

## G2 — Player control bar redesign

**Goal:** replace the stock-widget strip with player chrome that matches
IINA or QuickTime: floating, dark and translucent, with consistent icon
buttons.

1. **Layout:** remove the full-width `.regularMaterial` bar. Add a bottom
   scrim (`LinearGradient` black 0 → 0.7) mirroring the header's top scrim.
   Controls sit on the scrim in three groups:
   - **Left:** previous episode · back 10 s · **play/pause (larger)** ·
     forward 10 s · next episode, then elapsed / total time.
   - **Right:** episode list · chapters · version · danmaku · subtitles ·
     audio · speed · volume · fullscreen.
   - The timeline gets its own row above (restyled in G3; G2 keeps the
     system `Slider` inside the new layout).
2. **`PlayerIconButtonStyle`** (`App/Player/Chrome/`): 32 pt hit target,
   hierarchical SF Symbols, a rounded white hover highlight at 0.12, a
   pressed scale of 0.92, disabled at 0.35 opacity. Tooltips (`.help`)
   show the shortcut, as they do now.
3. **Menus:** `.menuStyle(.button)` + `.menuIndicator(.hidden)` +
   `.buttonStyle(PlayerIconButtonStyle())`, so episode/chapter/version/
   audio/speed/danmaku/subtitle menus look like the plain buttons. Keep
   `StableMenu` and the equatable `SubtitleMenuButton`/`DanmakuMenuButton`
   exactly as they are; only the label and style change. The speed label
   becomes a small capsule (`1.5×`) that only stands out when the speed is
   not 1×.
4. **Stateful icons:**
   - The volume icon follows the level (`speaker.slash` / `wave.1` /
     `wave.2` / `wave.3`). Clicking it toggles mute and remembers the
     previous level.
   - The volume slider appears when hovering over the icon.
   - Fullscreen switches between enter and exit icons.
   - Play/pause uses `.contentTransition(.symbolEffect(.replace))`.
5. **Header:** same type scale as the controls; the episode counter becomes
   a subtle capsule. Keep the 84 pt leading inset for the traffic lights.
6. **Show/hide:** keep the current reveal/hide/cursor logic. Switch to a
   combined opacity and small offset transition, and keep controls visible
   while a menu is open or the pointer is over them (already partly done
   through `isHoveringControls`).

**Split `controls` into its own view file** (`PlayerControlBar.swift`) that
takes plain values and closures, in the same pattern as `SubtitleMenuButton`.
This is also what keeps hover states steady under the 25 Hz re-render.

**Outcome (G2):** the chrome lives in `App/Player/Chrome/PlayerChrome.swift`
(`PlayerChrome` tokens, `PlayerIconButtonStyle`, `PlayerMenuStyle`,
`PlayerVolumeControl`). The bar was restyled in place rather than moved
into its own file: hover state lives in each button's own style body, which
keeps its identity across the 25 Hz re-render, so the extraction wasn't
needed for that. The danmaku button lost its `primaryAction` (click =
Match Episode). With the disclosure arrow hidden, a primary action would
have left the menu reachable only by long-press. Match Episode stays in
the menu and the on-screen badge.

After a first look, the user asked for a calmer bar, so the layout changed:
- **Header, next to the title:** the episode picker and the chapter menu
  (icon only). The episode picker is `PlayerEpisodePicker`, a popover grid
  grouped by `EpisodeCategory`. It uses more columns for bigger groups
  (≤ 10), and tiles read `12`, `SP3`, `OP1`, `PV2`. A kind with any
  unnumbered file is numbered by position.
- **Bottom bar:** previous · play/pause · next · time on the left;
  version · danmaku · subtitles · audio · speed · volume · fullscreen on
  the right.
- **Removed:** the ±10 s buttons (←/→ still seek, through hidden
  shortcuts).
- **One button size** (36 pt target, 18 pt glyph), with
  `.symbolVariant(.fill)` and monochrome rendering throughout. `-smokePlayerTest` captures its own window
into the container's `tmp/` (`ag_windowed.png`, `ag_fullscreen.png`)
instead of calling `screencapture`.

**Done when:** every control keeps its current function and shortcut; menus
stay open and clickable during playback (regression check for 7ef451d); the
bar looks the same in light and dark system appearance; and a windowed and a
fullscreen screenshot show no system-grey widgets.

---

## G3 — Custom timeline scrubber

**Goal:** a timeline that carries information, not a system `Slider`.

1. **`PlayerTimeline` view:** 4 pt track that grows to 8 pt on hover,
   rounded, with three layers: background (white 0.2), **buffered range**
   (white 0.4), played (accent or white). The knob only appears on hover or
   drag.
2. **Buffered range:** observe mpv `demuxer-cache-time` (or
   `demuxer-cache-state` → `seekable-ranges`) in `MPVPlayerController` and
   publish it through `PlayerState`. This is useful for network and
   torrent playback, where it shows how far ahead is downloaded. For local
   files it is simply full.
3. **Chapter markers:** small gaps in the track at each chapter start (data
   already in `state.chapters`).
4. **Hover tooltip:** a time bubble above the pointer, with the chapter name
   when the pointer is inside a chapter.
5. **Scrubbing semantics:** click to seek. While dragging, send throttled
   keyframe seeks (≈ every 100 ms) and update the time label locally; send
   one exact seek on release. All of it goes through `PlayerState.seek`, so
   danmaku re-anchors. Add `seek(to:exact:)` if keyframe mode needs a
   parameter. While dragging, the knob follows the pointer, not the 25 Hz
   position updates, so it doesn't jump back.
6. **Time labels:** clicking the right label switches between remaining
   and total time (remembered in `@AppStorage`).

Not in scope: **thumbnail previews while hovering**. They need a second,
headless mpv instance decoding keyframes; that is a separate project with
its own performance and HDR concerns. It can come back as G3b later.

**Done when:** dragging is smooth with no snap-back; danmaku stays in sync
after scrubbing (check with the Danmaku Manager open); the buffered range
moves during a torrent play-while-downloading; and chapter markers line up
with the chapter menu's times.

---

## G4 — Overlays, feedback and panel consistency

**Goal:** everything that floats over the video uses the same visual style,
and keyboard actions give visible feedback.

1. **`PlayerOSD`:** a short-lived center/top HUD for keyboard and scroll
   actions: `+10 s` / `−10 s`, volume percentage with a bar, speed, subtitle
   and audio delay, "Danmaku off", chapter jumps. One slot, replaced rather
   than stacked, fades after about 0.8 s. Driven by a small
   `@MainActor ObservableObject` so it doesn't depend on the `PlayerScreen`
   re-render.
2. **Play/pause flash:** a large center icon that briefly appears and
   scales out when toggled with a click or Space.
3. **Unify surfaces:** a `PlayerPanelBackground` modifier (dark material +
   hairline border + radius from G1's tokens). Use it for the danmaku and
   subtitle status badges, the loading indicator (replace the
   `.regularMaterial` `ProgressView` box with a minimal spinner), the error
   state (`ContentUnavailableView` on a scrim), the Danmaku Manager, and
   the diagnostics panel.
4. **Sheets opened from the player** (Danmaku settings, Danmaku match,
   Subtitle search) inherit the dark window appearance from G1.6. Check
   their layout and spacing once in dark.
5. **Scroll-wheel volume** over the video (optional; mpv-style) with OSD
   feedback.

**Done when:** every overlay has the same corner radius, material and
border; each shortcut in the `playerKey` set and each delay nudge shows an
OSD; and neither the OSD nor the flash affects playback timing or danmaku
sync.

---

## Delivery

| Goal | Main files | Commit(s) |
|------|------------|-----------|
| G1 | `App/Design/*` (new), `SettingsView`, `AnimeGodApp`, `Assets.xcassets`, audit touch-ups in `App/Views/*` | `feat: add appearance setting and dark-mode pass` |
| G2 | `App/Player/Chrome/*` (new), `PlayerScreen.swift` | `feat: redesign player control bar` |
| G3 | `PlayerTimeline.swift` (new), `MPVPlayerController` (cache property), `PlayerState` | `feat: custom player timeline with buffer and chapters` |
| G4 | `PlayerOSD.swift` (new), badges, Danmaku Manager, diagnostics | `feat: player OSD and unified overlays` |

After G4, update `README.md` and `README.zh-CN.md` (appearance setting,
player features) and the release notes for the next version.
