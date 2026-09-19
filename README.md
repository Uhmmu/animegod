# AnimeGod

**English** | [简体中文](README.zh-CN.md)

AnimeGod is a native, local-first anime library and video player for macOS —
**IINA × an anime library manager × Bangumi/AniList × a personal anime diary**,
in one fast SwiftUI application.

> Give a local anime collection memory, structure, context, and history while
> preserving the speed and quality of a native macOS application.

**Current release: 0.2.1.** Videos without Chinese subtitles can now find,
download and load them automatically from online subtitle sites, matched to
the episode and the release. Player menus stay open during playback, and
provider keys no longer ask for your password after every update.

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

### Find releases
- **Find Releases** (Discover sidebar, or the toolbar of any anime) searches
  ten anime torrent indexes at once — 动漫花园, 蜜柑计划, 萌番组, Anime
  Garden, ACG.RIP, 末日动漫, Nyaa (anime category), AnimeTosho, SubsPlease,
  TokyoTosho — and merges listings of the same torrent across sites
  (hex/base32 info hashes unified; sources, trackers and `.torrent` links
  combined). Only anime indexes are offered; adult, game and manga listings
  are dropped while parsing.
- From an anime page the search runs every known name (Bangumi Chinese and
  original titles, AniList romaji, folder title) together, and releases that
  bring an episode your library lacks are tagged **New**; **Missing
  Episodes** keeps only those.
- Each title is parsed for fansub, episode or batch range, resolution,
  codec, source, and subtitle languages/style (简/繁/日, 内嵌/内封/外挂).
  Filter by type, resolution, subtitles and group; sort by best match,
  newest, seeders or size; unrelated listings are hidden by default.
- Results stream in as each source answers; a slow or blocked site never
  holds up the others. **Source Details** shows every source's status and
  time, and **Retry Failed** re-runs only what failed.
- Per release: open in your torrent app, copy magnet link(s), save a
  `.torrent` (verified against its info hash), or open the listing page.
  Recent searches are remembered.

### Downloads
- **Built-in BitTorrent engine** (libtorrent, statically linked): downloading
  a release needs no other app. Downloads resume after a quit, keep their
  place across restarts, and can be paused, resumed, removed (with or without
  their files), or re-announced to widen the peer pool.
- **Downloads can go straight into a library folder**, so a finished
  download is scanned in as a normal episode without moving anything. The
  folder menu lists library folders alongside recent ones, and a task can be
  moved to another folder later without interrupting it.
- **Downloading titles appear in the library immediately**, with an App
  Store-style progress ring that fills as the download completes.
- **Downloads** (Sources sidebar) shows progress, speed, seeds/peers, time
  left, and the download folder. The folder is remembered, and if it is gone
  when a download starts — an unplugged drive, a deleted folder — the next
  usable folder is used instead and says so, falling back to the app's own
  folder.
- **Connectivity is visible**, because it is what limits BitTorrent speed:
  DHT node count and whether UPnP/NAT-PMP opened the port. If the port could
  not be mapped, the panel explains what forwarding it would gain.
- **Play while downloading**: a sequential download becomes playable once
  32 MiB of its start is on disk, and the Play button opens it in AnimeGod's
  own player while the rest keeps arriving. Its file is moved to the front of
  the queue so playback stays ahead of the download. Such a file has no
  library entry, so no watch progress, auto-cache or danmaku match is
  recorded for it — those come once it is in the library.
- **Finished downloads join the library**: a download saved inside a library
  folder is rescanned automatically and appears as a normal episode. One
  saved elsewhere offers "Add Download Folder to Library".
- Tuned like magnet-crawler's engine: DHT with several bootstrap nodes, local
  peer discovery, PEX, announce-to-all-trackers, encryption allowed but not
  forced, IPv4 and IPv6, and community trackers added to every task.

### Subscriptions
- **Follow a show** and new episodes download by themselves. A rule is a
  fansub, a resolution, a subtitle language, keywords to require or avoid,
  and an episode floor — the quickest way to make one is the bell button in
  Find Releases, once the filters show exactly what you want.
- **Following means from now on**: a new subscription takes what appears
  after it was created, so subscribing mid-season does not pull down every
  episode already out. Backfilling is a deliberate switch.
- **One release per episode**, never one already in your library or
  downloaded before, and a release nobody seeds loses to one with peers.
  Releases with no episode number are only taken when the rule names a
  fansub or keyword, so a season pack is never grabbed by accident.
- Collaborations count: a rule naming `LoliHouse` matches
  `[喵萌奶茶屋&LoliHouse]`, which is how fansubs actually release.
- Enabled rules are checked every 30 minutes, and every action is listed
  under **Recent Activity** — automatic downloading is only comfortable when
  it is easy to see and easy to switch off.

### Bangumi charts
- **Bangumi Charts** browses every site-wide ranking Bangumi publishes: all
  five channels (anime, books, music, games, live action) and every filter
  sidebar the site offers (分类/来源/题材/地区/受众/平台/分级…), grouped in
  one menu per channel.
- Entries come from the read-only `next.bgm.tv/p1/subjects` JSON endpoint
  (`sort=rank`); the filter taxonomy is discovered from each channel's
  browser page, so new categories appear without an app update. Filtered
  subpaths are Cloudflare-challenged on bgm.tv, so charts themselves never
  request them.
- Ranked rows show cover, site rank (gold/silver/bronze podium), score,
  rating count, and info line; **Load More** pages through up to thousands
  of ranked subjects. Subjects already matched in the local library are
  badged and link straight to their detail page; everything else opens its
  bgm.tv page.

### Translation
- Independent translation service (`AnimeGodCore/Translation`) with a
  **DeepL-compatible provider**: batched requests, free/pro endpoint
  auto-detection, API key stored in AnimeGod's local settings, results cached in the
  local database.
- Foreign-language reviews show **original text and translation side by
  side** — the original is never replaced.

### Appearance
- System, Light or Dark in Settings; the player window always stays dark.

### Player
- libmpv (MPVKit) embedded playback: H.264/HEVC/AV1, 10-bit, VideoToolbox
  hardware decode, multi audio/subtitle tracks, sidecar subtitle discovery
  (`sub-auto=fuzzy` + `subs/字幕` folders), manual external subtitle loading.
- Player chrome that stays dark over the video: flat icon controls on
  top/bottom scrims, and bubble panels for speed, audio, danmaku, subtitles
  and versions that grow out of their button.
- Timeline with chapter marks, a hover bubble showing time and chapter, and
  smooth drag scrubbing (click the time label for remaining time).
- Episode picker grid beside the title, grouped into Episodes / SP / Music &
  Credits / Trailers / Extras. Chapter menu, playback speed (0.5×–3×),
  volume (click to mute, scroll or `↑/↓` to adjust), subtitle/audio delay.
- Keyboard: `Space`, `F`, `N/P`, `D`, `M`, `↑/↓`, and `←/→`: tap to seek
  10 s, hold for 2×, tap-then-hold for 3× (`←` scans backwards). On-screen
  feedback for each; double-click for full screen.
- HDR: signal-based HDR10/HLG/Dolby-Vision detection, 16-bit-float BT.2020 EDR
  output on capable displays, automatic HDR-to-SDR tone mapping, and a
  diagnostics panel (**⌘⇧D**). Eligible Dolby Vision Profile 8.4 MP4/MOV files
  use Apple's native playback path; MKV and Profile 7 use the HDR10 base layer.

### Episode cache
- **Auto-cache**: the first time an episode on an external drive plays, it is
  copied to this Mac in the background (one copy at a time, chunked with live
  progress); playback keeps reading from the drive until the copy finishes.
- **Watched = freed**: closing an episode at ≥90 % automatically deletes its
  auto cache — the copy is a buffer between first play and finishing, not a
  permanent duplicate. Manual caches are never auto-deleted.
- **Manual caching**: every episode row has a copy-to-Mac button (with live
  progress and cancel), plus **Cache All** on the anime page; a manual request
  for an episode already auto-caching simply claims that copy.
- **Offline playback**: an unplugged drive keeps its full index — cached
  episodes play normally, everything else shows 请插入硬盘. Playback prefers a
  finished cache over the drive, so pulling the disk mid-series never
  interrupts the current episode.
- **Cache manager** (Sources → Episode Cache): total size, per-anime grouping
  with watched badges, live copy progress, cancel, reveal in Finder,
  per-episode delete, clear-all, and toggles for both automatic rules. Copies
  live in `Application Support/AnimeGod/Episode Cache`, reconciled against the
  database at launch and after every rescan (orphaned files and crashed
  partials are cleaned up).

### Danmaku (弹幕)
- Native renderer over the video (Core Animation layers + display link,
  bitmap-cached text), arranged from the top of the picture and synchronized
  against the player's own clock. Pausing freezes comments immediately;
  seeking, changing speed, and resuming keep the video and comments together.
  It never touches the HDR/EDR video pipeline.
- Two sources, selectable in Settings — **dandanplay**, **Bilibili**, or both
  merged:
  - Official **dandanplay Open Danmaku API**: automatic episode identification
    by file hash, plus a metadata-assisted episode chooser that opens directly
    from the danmaku button. Suggestions are ranked by title, episode number,
    and media type, so release filenames do not need to be copied into a
    search box. Manual title search remains available for unusual releases.
  - **Bilibili**: no account needed. Because Bilibili has no file-identity
    API, episodes are found by title and episode number, then read from the
    official protobuf segment endpoint for that episode's own `cid` —
    including the correct part of a multi-part submission. Titles a
    dandanplay search cannot place often still resolve here. An optional
    `SESSDATA` cookie (Settings, stored locally) only widens what
    your account may see; region-locked or members-only titles report that
    and leave playback untouched.
  - **Merged**: both pools are fetched and combined, with comments that
    appear in both shown once.
- Downloaded comments are cached in the local database by provider and episode
  for offline replay and to avoid repeated requests. Use **Refresh Danmaku**
  when you explicitly want a fresh copy.
- Player-bar controls: on/off (`D`), opacity, font size, line spacing,
  display area and max lines, scrolling speed, max simultaneous comments,
  per-mode and colored-comment filters, ±10 s timing offset, refresh, and
  episode re-matching — all persisted. Comments in a lane keep a gap, and
  comments that don't fit are dropped instead of overlapping. Requires free
  AppId/AppSecret credentials from
  [dev.dandanplay.com](https://dev.dandanplay.com), entered in **Settings**
  and stored locally.
- Filters for crowded shows: repeated comments within 10 seconds merge into
  one with a ×N count, a density slider thins the rest evenly (often-repeated
  comments are always kept), long comments can be hidden, and blocked keywords
  accept plain text or `/regex/` patterns.
- **Danmaku Manager** (`M`, or the danmaku menu): a panel beside the video
  listing the last 30 seconds of comments or searching the whole episode.
  Click a comment to jump to it; right-click to block its text or its sender.
  Hidden comments show which rule hid them, and blocked keywords and users can
  be managed in the panel or in Danmaku Settings.

### Online subtitles (在线字幕)
- When a video has no subtitle in your preferred languages (Simplified /
  Traditional Chinese by default), AnimeGod identifies the anime, season,
  episode and release (group, BD/WEB source, resolution), searches the
  configured subtitle sites in parallel, and loads the best match on its own
  — only when it is confident. Otherwise a small badge offers the candidates.
- Sources, each with its own key in Settings (stored in AnimeGod's local
  settings, not the Keychain):
  **射手网(伪) assrt.net** (Chinese fansub archive, ASS), **SubDL** (searched
  by TMDB ID + season/episode), **OpenSubtitles** (exact-file hash matches;
  SRT only) and **Jimaku** (Japanese, used only when Japanese is preferred).
  One source failing never affects the others.
- Matching weighs the same episode and a compatible release first — a BD
  subtitle is never loaded automatically on a WEB video, or vice versa — then
  your language and format order (ASS/SSA before SRT). Season packs and ZIPs
  are unpacked to the right episode; GBK/Big5 files are converted to UTF-8.
- The subtitle menu groups **Embedded**, **External Files** and **Online**
  tracks, and **Online Subtitles** offers auto-match, **Search Subtitles…**
  (language, format, provider, group, match %, version, file) and downloaded
  subtitles. Downloads are cached per episode and reload on replay without a
  search. ASS is rendered by libass, with fonts from subtitle packs.
- Releases whose name says Chinese subtitles are burned in (e.g. `[CHT]`,
  `[简日内嵌]`) are not searched by default; this is a setting.

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
  'Bangumi.*ProviderTests'`.
- Headless player smoke test: run the built binary with `-smokePlayerTest`
  (auto-plays the first episode, toggles fullscreen, prints layout sizes).

## Data & privacy

Everything — library, metadata cache, watch history, personal entries,
statistics, translations, danmaku matches, comment caches, and the
episode-cache index — lives in the
local SQLite database (`~/Library/Containers/com.uhmmu.AnimeGod/Data/…`);
cached episode files sit in the same container's Application Support folder.
Nothing is uploaded. Network is used only for the metadata providers you
invoke, the Bangumi charts section, the translation provider you configure,
the danmaku sources you enable (dandanplay and/or Bilibili), the subtitle
sites you configure (sent the anime's title, IDs, episode and file name —
plus a 128 KiB-derived hash for OpenSubtitles), the release sources you search, and the BitTorrent swarms of downloads you start —
BitTorrent is peer-to-peer, so peers you exchange data with see your IP
address, as with any torrent client.
