# AnimeGod

AnimeGod is a native, local-first anime library and video player for macOS —
**IINA × an anime library manager × Bangumi/AniList × a personal anime diary**,
in one fast SwiftUI application.

> Give a local anime collection memory, structure, context, and history while
> preserving the speed and quality of a native macOS application.

**Current release: 0.1.2.** This release adds native dandanplay danmaku,
preserves the complete video frame in windowed and fullscreen playback, and
remembers the user's subtitle selection.

## Features

### Library
- Multiple library roots with security-scoped bookmarks; libraries survive
  volume renames and remounts.
- Non-destructive recursive scanning: files are never renamed, moved, or
  modified; progress is preserved across rescans.
- Anime-oriented filename parsing: `[Group] Title [01][1080p]`,
  `Title.S02E04`, fractional episodes (`13.5`), release versions (`07v2`),
  Chinese patterns (`第三季 第16集`, `第六章`), NCOP/NCED/PV/Menu/MV/SP
  classification, pirate-site ad labels (`【更多蓝光电影访问 www.…】`) and
  technical tails (`2006 RERiP 1080p DTS-WiKi`) stripped from titles, and
  adult-video catalogue codes (`SONE-615`-style) excluded from the library.
- One folder containing two works splits into separate entries (前篇/後篇
  compilation films, bundled movies); bonus folders (`SPs`, `特典`) stay
  attached to their work as specials, not main episodes.
- Alternative encodes of the same film (e.g. DoVi + SDR releases) merge into
  one episode with a version picker in the player; SDR is the default choice.

### Metadata
- Match with **Bangumi** (v0 API: search, posters, synopsis, ratings, studio
  credits; subject shoutbox, community topics/blogs) and **AniList** (GraphQL: search,
  metadata, MAL cross-identifiers, reviews, main studios).
- **Find Metadata** links every unlinked title with its most likely result;
  clearly dubious candidates wait in **Review Matches** for a quick human pass.
  Auto-guessed links show their confidence and are fixable with **Change
  Match**.
- Each provider relationship, metadata payload, and community index is stored
  independently in SQLite; provider outages never hide the local library.
  Community items open their original source page.
- Rename a folder on disk, rescan, and your bindings follow the file —
  identity migration keeps metadata, personal entries, and history attached.

### Translation
- Independent translation service (`AnimeGodCore/Translation`) with a
  **DeepL-compatible provider**: batched requests, free/pro endpoint
  auto-detection, API key stored in the macOS Keychain, results cached in the
  local database.
- Foreign-language reviews show **original text and translation side by
  side** — the original is never replaced.

### Player
- libmpv (MPVKit) embedded playback: H.264/HEVC/AV1, 10-bit, VideoToolbox
  hardware decode, multi audio/subtitle tracks, sidecar subtitle discovery
  (`sub-auto=fuzzy` + `subs/字幕` folders), manual external subtitle loading.
- Chapters, playback speed (0.5×–2×), volume, subtitle/audio delay, timeline,
  keyboard shortcuts (`Space`, `←/→`, `F`, `N/P`, `D`), double-click fullscreen,
  in-player episode navigation with category labels, alternative-encode
  version menu.
- HDR: signal-based HDR10/HLG/Dolby-Vision detection, 16-bit-float BT.2020 EDR
  output on capable displays, automatic HDR-to-SDR tone mapping, and a
  diagnostics panel (**⌘⇧D**). Eligible Dolby Vision Profile 8.4 MP4/MOV files
  use Apple's native playback path; MKV and Profile 7 use the HDR10 base layer.

### Danmaku (弹幕)
- Native renderer over the video (Core Animation layers + display link,
  bitmap-cached text) — synchronized against the player's own clock, so
  pause freezes, seeks rebuild without replaying old comments, and speed
  changes scale movement; it never touches the HDR/EDR video pipeline.
- Official **dandanplay Open Danmaku API**: automatic episode identification
  (MD5-of-first-16MB file hash + filename + size + duration), manual
  anime/episode search when matching fails, comments cached per provider
  episode in the local database (offline replay, no repeated API hits).
- Player-bar controls: on/off (`D`), opacity, font size, display area,
  scrolling speed, max simultaneous comments, per-mode and colored-comment
  filters, ±10 s timing offset, reload, and episode re-matching — all
  persisted. Requires free AppId/AppSecret credentials from
  [dev.dandanplay.com](https://dev.dandanplay.com), stored in the Keychain
  via **Settings**.

### Personal library
- Watch events are recorded from real playback sessions (sub-15 s touches are
  ignored); 90 % completion marks an episode watched and updates tracking
  status automatically.
- Per-anime status, score, notes, review, tags, favorite, rewatch count — and
  **rankings kept strictly separate from scores**, reorderable in **My
  Rankings**.
- **Anime Diary** is generated automatically from watch history.
- **Statistics** turn the year into a report: total watch time, sessions,
  episodes finished, monthly/weekday/hour habits, most-watched anime and
  studios, your highest-rated titles — all computed locally.

## Development

Requirements: macOS 14+, Xcode 26+, XcodeGen.

```sh
swift test
xcodegen generate
xcodebuild -project AnimeGod.xcodeproj -scheme AnimeGod -configuration Release build
```

- `AnimeGodCore` (SPM package) holds models, the GRDB database, the scanner/
  parser, metadata providers, translation, and statistics — independently
  testable.
- The app target is SwiftUI + AppKit with the LGPL build of MPVKit for
  playback. See `THIRD_PARTY_NOTICES.md` before distributing binaries.
- Optional live provider tests: `ANIMEGOD_LIVE_TESTS=1 swift test --filter
  BangumiMetadataProviderTests`.
- Headless player smoke test: run the built binary with `-smokePlayerTest`
  (auto-plays the first episode, toggles fullscreen, prints layout sizes).

## Data & privacy

Everything — library, metadata cache, watch history, personal entries,
statistics, translations, danmaku matches and comment caches — lives in the
local SQLite database (`~/Library/Containers/com.uhmmu.AnimeGod/Data/…`).
Nothing is uploaded. Network is used only for the metadata providers you
invoke, the translation provider you configure, and the dandanplay danmaku
API when danmaku is enabled.
