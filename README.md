<div align="center">

# AnimeGod

**A native, local-first anime library and player for macOS.**

IINA × a library manager × Bangumi/AniList × your own anime diary — in one SwiftUI app.

[![Latest release](https://img.shields.io/github/v/release/Uhmmu/animegod?label=download&color=brightgreen)](https://github.com/Uhmmu/animegod/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000?logo=apple&logoColor=white)
![Universal](https://img.shields.io/badge/universal-Apple%20silicon%20%2B%20Intel-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)

**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

</div>

---

Point AnimeGod at the folders you already have. It reads the filenames the way
a fansub names them, finds the show on Bangumi and AniList, plays it with
libmpv, puts danmaku over it, and remembers what you watched — all on your own
Mac. Nothing is uploaded, nothing is renamed, nothing is moved.

## Get it

1. **[Download the latest DMG](https://github.com/Uhmmu/animegod/releases/latest)** and drag AnimeGod to Applications.
2. Open it, then **Add Library Folder** and pick where your anime lives — an external drive is fine.
3. Let the scan finish, hit **Find Metadata**, and start watching.

> The app is ad-hoc signed, not notarized. On first launch macOS may need you
> to right-click it and choose **Open**.

**Current release: 0.3.2** — a season downloaded as a set now behaves as the
one show it is: one folder, one card on the home screen with its real cover,
matched to its anime before the first episode has even finished. Finished
releases keep seeding instead of drifting back into the queue, and a download
whose files you moved in the Finder is paused rather than fetched all over
again.

## At a glance

| | |
|---|---|
| 📚 **Library** | Scans your folders without touching them; understands fansub filenames, seasons, specials and `.iso` images |
| 🔗 **Metadata** | Bangumi + AniList, with a human pass over anything doubtful |
| ▶️ **Player** | libmpv, HDR10/HLG/Dolby Vision, Blu-ray images, chapter timeline |
| 💬 **Danmaku** | dandanplay and Bilibili, merged, with filters and a comment manager |
| 🈳 **Subtitles** | Finds and loads Chinese subtitles automatically when a release has none |
| 🧲 **Releases** | Ten anime indexes searched at once, whole seasons assembled per fansub |
| ⬇️ **Downloads** | Built-in BitTorrent engine, a season per folder, play while downloading, auto-unpack |
| 🔔 **Subscriptions** | New episodes arrive by themselves |
| 💾 **Episode cache** | Copies from an external drive so the show survives unplugging it |
| 📔 **Your record** | Status, scores, rankings, an automatic diary, a yearly report |

## Contents

[Library](#library) · [Metadata](#metadata) · [Player](#player) ·
[Danmaku](#danmaku-弹幕) · [Online subtitles](#online-subtitles-在线字幕) ·
[Find releases](#find-releases) · [Downloads](#downloads) ·
[Subscriptions](#subscriptions) · [Episode cache](#episode-cache) ·
[Bangumi charts](#bangumi-charts) · [Your own record](#your-own-record) ·
[Appearance & language](#appearance--language) ·
[Development](#development) · [Data & privacy](#data--privacy)

---

## Library

Your files stay exactly as they are. AnimeGod only reads them.

- **Nothing is renamed, moved or modified** — ever, including across rescans.
- **Fansub filenames are understood**: `[Group] Title [01][1080p]`,
  `Title.S02E04`, `第三季 第16集`, fractional episodes (`13.5`), versions (`07v2`).
- **Multiple library roots**, including external drives, that survive renames
  and remounts.
- **Blu-ray `.iso` images are scanned like any other episode.**

<details>
<summary>More detail</summary>

- Security-scoped bookmarks keep external volumes usable after a rename or a
  remount.
- NCOP/NCED/PV/Menu/MV/SP are classified rather than mixed into the episode
  list; pirate-site ad labels (`【更多蓝光电影访问 www.…】`) and technical tails
  (`2006 RERiP 1080p DTS-WiKi`) are stripped from titles.
- Adult-video catalogue codes (`SONE-615`-style) are excluded from the library.
- One folder holding two works splits into separate entries (前篇/後篇
  compilation films, bundled movies), while bonus folders (`SPs`, `特典`) stay
  attached to their work as specials.
- Alternative encodes of the same film (DoVi + SDR, say) merge into one episode
  with a version picker in the player; SDR is the default choice.
- Rename a folder on disk and rescan: identity migration keeps metadata,
  personal entries and history attached to the file.

</details>

## Metadata

- **Bangumi** (posters, synopsis, ratings, studio credits, shoutbox, topics and
  blogs) and **AniList** (metadata, MAL cross-IDs, reviews, studios).
- **Find Metadata** links every unlinked title with its most likely match, and
  sends anything doubtful to **Review Matches** for a quick human pass.
- **Provider outages never hide your library** — each relationship and payload
  is stored independently in SQLite.

<details>
<summary>More detail</summary>

- Auto-guessed links show their confidence and can be corrected with **Change
  Match**.
- Community items (shoutbox, topics, blogs, reviews) open their original source
  page.
- Bangumi uses the v0 API; AniList uses GraphQL.

</details>

## Player

libmpv (MPVKit) embedded in a native window, with chrome that stays dark over
the video.

- **HDR done properly**: signal-based HDR10/HLG/Dolby Vision detection,
  BT.2020 EDR output on capable displays, automatic tone mapping, and a
  diagnostics panel (**⌘⇧D**).
- **Blu-ray images** open straight into the main feature, with chapters and
  seeking, without mounting anything.
- **Timeline with chapter marks**, a hover bubble showing time and chapter, and
  smooth drag scrubbing.
- **Episode picker** beside the title, grouped into Episodes / SP / Music &
  Credits / Trailers / Extras.

<details>
<summary>Formats, controls and keyboard</summary>

- H.264/HEVC/AV1, 10-bit, VideoToolbox hardware decode, multiple audio and
  subtitle tracks, sidecar subtitle discovery (`sub-auto=fuzzy` plus
  `subs`/`字幕` folders) and manual external subtitle loading.
- Flat icon controls on top and bottom scrims; speed, audio, danmaku, subtitles
  and versions open as bubble panels that grow out of their button.
- Chapter menu, playback speed 0.5×–3×, volume (click to mute, scroll or `↑/↓`),
  subtitle and audio delay.
- Keyboard: `Space`, `F`, `N`/`P`, `D`, `M`, `↑/↓`, and `←/→` — tap to seek
  10 s, hold for 2×, tap-then-hold for 3×. Every one gives on-screen feedback;
  double-click for full screen.
- Eligible Dolby Vision Profile 8.4 MP4/MOV files use Apple's native playback
  path; MKV and Profile 7 use the HDR10 base layer. DVD images are recognised
  and reported rather than played.

</details>

## Danmaku (弹幕)

Comments drawn natively over the video by Core Animation, synchronized against
the player's own clock — pausing freezes them instantly, seeking and speed
changes keep them together with the picture. The HDR pipeline is never touched.

- **Two sources, merged**: dandanplay, Bilibili, or both with duplicates shown
  once.
- **dandanplay** identifies the episode by file hash, so release filenames
  never need to be pasted into a search box.
- **Bilibili needs no account**; an optional `SESSDATA` cookie only widens what
  your own account may see.
- **Danmaku Manager** (`M`): the last 30 seconds or a search over the whole
  episode; click a comment to jump to it, right-click to block its text or its
  sender.

<details>
<summary>Filters, controls and caching</summary>

- Crowded shows: repeated comments within 10 s merge into one with a ×N count, a
  density slider thins the rest evenly, long comments can be hidden, and blocked
  keywords accept plain text or `/regex/`.
- Player-bar controls, all remembered: on/off (`D`), opacity, font size, line
  spacing, display area and max lines, scrolling speed, max simultaneous
  comments, per-mode and colored-comment filters, ±10 s offset, refresh and
  episode re-matching.
- Comments in a lane keep a gap; ones that do not fit are dropped rather than
  overlapped.
- Comments are cached per provider and episode for offline replay; **Refresh
  Danmaku** is the only thing that re-fetches.
- dandanplay needs free AppId/AppSecret credentials from
  [dev.dandanplay.com](https://dev.dandanplay.com), entered in **Settings**.
- Bilibili has no file-identity API, so episodes are found by title and episode
  number and read from the official protobuf endpoint for that episode's own
  `cid` — including the right part of a multi-part submission. Region-locked
  titles say so and leave playback alone.

</details>

## Online subtitles (在线字幕)

When a video has no subtitle in the languages you want (Simplified/Traditional
Chinese by default), AnimeGod works out the anime, season, episode and release,
searches four sites in parallel, and loads the best match by itself — but only
when it is confident. Otherwise a small badge offers the candidates.

- **射手网(伪) assrt.net**, **SubDL**, **OpenSubtitles** and **Jimaku**
  (Japanese only), each with its own key in Settings. One failing never affects
  the others.
- **A BD subtitle is never auto-loaded onto a WEB video**, or the other way
  round.
- Season packs and ZIPs are unpacked to the right episode; GBK/Big5 becomes
  UTF-8; ASS is rendered by libass with the fonts from the subtitle pack.

<details>
<summary>More detail</summary>

- The subtitle menu groups **Embedded**, **External Files** and **Online**
  tracks. **Search Subtitles…** lets you pick by language, format, provider,
  group, match percentage, version and file.
- Downloads are cached per episode and reload on replay without searching again.
- Matching weighs the same episode and a compatible release first, then your
  language and format order (ASS/SSA before SRT).
- Releases whose name says Chinese subtitles are burned in (`[CHT]`,
  `[简日内嵌]`) are skipped by default — a setting.
- Keys live in AnimeGod's local settings file, not the Keychain.

</details>

## Find releases

Ten anime indexes searched at once — 动漫花园, 蜜柑计划, 萌番组, Anime Garden,
ACG.RIP, 末日动漫, Nyaa, AnimeTosho, SubsPlease, TokyoTosho — with listings of
the same torrent merged across sites. Only anime indexes; adult, game and manga
listings are dropped while parsing.

- **Search from an anime** and every known name goes out together (Bangumi
  Chinese and original, AniList romaji, folder title). Releases that bring an
  episode you lack are tagged **New**.
- **Episode Sets is the answer to not wanting a 40 GB batch.** The same results
  regrouped into one row per fansub's season, matched on everything except the
  episode number — fansub, season, resolution, codec, source, subtitle
  languages — so 1080p 简日 never lands in the same pile as 720p 繁日. One
  click starts the lot.
- **Gaps are filled from the fansub next door**: an episode a team never
  published comes from the closest other line, marked as borrowed, never a raw
  for a subtitled season. When nobody covers the whole season alone, one extra
  row assembles it across fansubs.
- **Results stream in** as each source answers; a blocked or slow site never
  holds up the others.

<details>
<summary>Filters, diagnostics and the small print</summary>

- Every title is parsed for fansub, episode or batch range, resolution, codec,
  source and subtitle language/style (简/繁/日, 内嵌/内封/外挂). Filter by type,
  resolution, subtitles and group; sort by best match, newest, seeders or size;
  unrelated listings are hidden by default.
- Each set shows how much of the season it covers, its total size and its
  weakest swarm — one dead episode holds up a season. Episodes already in your
  library are skipped, episodes nobody published are named, and a "season" that
  would be mostly other teams' files is not offered as one.
- Sequels are counted separately: a season tagged S2 and numbered 1–10 is
  measured against its own numbering, not against the teams still counting
  29–38 in the same search.
- **Source Details** shows every source's status and elapsed time; **Retry
  Failed** re-runs only what failed.
- Per release: open in your torrent app, copy magnet links, save a `.torrent`
  (verified against its info hash), or open the listing page. Recent searches
  are remembered.

</details>

## Downloads

A **built-in BitTorrent engine** (libtorrent, statically linked), so downloading
a release needs no other app.

- **Straight into a library folder**, so a finished download is scanned in as a
  normal episode without moving anything.
- **A season lands in one folder**, named after the anime rather than scattered
  as twelve folders side by side.
- **A season is one card in the library**, with its real cover and one progress
  ring, and the card opens the anime's page while the episodes are still
  arriving.
- **Matched before it finishes**: starting a download of something new asks
  which anime it is — once for the whole season — so nothing needs matching by
  hand afterwards.
- **A whole season is queued, not stampeded**: four downloads run at a time
  (1–8 in the folder menu), the rest wait their turn in episode order.
- **Play while downloading**: once 32 MiB of the start is on disk, the Play
  button opens it in AnimeGod's own player while the rest arrives.
- **Archives are unpacked when a download finishes**, so a `.rar`/`.zip`/`.7z`
  release becomes episodes instead of files nothing can open.

<details>
<summary>More detail</summary>

- Downloads resume after a quit and keep their place across restarts; they can
  be paused, resumed, removed (with or without their files) or re-announced.
- Every download gets its own folder, single-file torrents included, so a
  download folder never fills with loose `.mkv`s. Episodes downloaded one at a
  time can be collected into one folder afterwards from the Downloads list;
  the engine moves the files, so seeding carries on, and it removes the folders
  it empties.
- **Finished releases keep seeding.** Seeding is not metered against the
  download limit — it costs upload only, and downloads are always served first.
- **A download whose files have moved is paused, not fetched again.** Moving a
  finished episode in the Finder is an ordinary thing to do; downloading it a
  second time is not a reasonable answer to it.
- The folder menu lists library folders alongside recent ones, and a task can be
  moved elsewhere later without interrupting it. If the folder is gone when a
  download starts — unplugged drive, deleted folder — the next usable one is
  used and says so.
- **Connectivity is visible**, because it is what limits BitTorrent speed: DHT
  node count and whether UPnP/NAT-PMP opened the port, with an explanation of
  what forwarding it would gain.
- A download saved outside a library folder offers **Add Download Folder to
  Library**.
- A file played before it is in the library records no watch progress,
  auto-cache or danmaku match — those come once it is scanned in.
- Engine tuning: DHT with several bootstrap nodes, local peer discovery, PEX,
  announce-to-all-trackers, encryption allowed but not forced, IPv4 and IPv6,
  and community trackers added to every task.

</details>

## Subscriptions

Follow a show and new episodes download by themselves. The quickest way to make
a rule is the bell button in Find Releases, once the filters show exactly what
you want.

- **Following means from now on** — subscribing mid-season does not pull down
  everything already out. Backfilling is a deliberate switch.
- **One release per episode**, never one already in your library or downloaded
  before, and a release nobody seeds loses to one with peers.
- **Every action is listed** under Recent Activity. Automatic downloading is
  only comfortable when it is easy to see and easy to switch off.

<details>
<summary>More detail</summary>

- A rule is a fansub, a resolution, a subtitle language, keywords to require or
  avoid, and an episode floor.
- Releases with no episode number are only taken when the rule names a fansub or
  keyword, so a season pack is never grabbed by accident.
- Collaborations count: a rule naming `LoliHouse` matches `[喵萌奶茶屋&LoliHouse]`,
  which is how fansubs actually release.
- Enabled rules are checked every 30 minutes.

</details>

## Episode cache

For anime that lives on an external drive.

- **Auto-cache**: the first time an episode plays it is copied to this Mac in
  the background, while playback keeps reading from the drive.
- **Watched = freed**: closing an episode at ≥90 % deletes its auto cache. The
  copy is a buffer between first play and finishing, not a duplicate.
- **Offline playback**: unplug the drive and the index stays — cached episodes
  play normally, everything else says 请插入硬盘.

<details>
<summary>More detail</summary>

- Manual caching from any episode row (live progress, cancel) or **Cache All**
  on the anime page; manual copies are never auto-deleted. Asking for an episode
  that is already auto-caching simply claims that copy.
- Playback prefers a finished cache over the drive, so pulling the disk
  mid-series never interrupts the current episode.
- **Cache manager** (Sources → Episode Cache): total size, per-anime grouping
  with watched badges, live progress, cancel, reveal in Finder, per-episode
  delete, clear-all, and toggles for both automatic rules.
- Copies live in `Application Support/AnimeGod/Episode Cache`, reconciled with
  the database at launch and after every rescan; orphans and crashed partials
  are cleaned up.

</details>

## Bangumi charts

Every site-wide ranking Bangumi publishes: all five channels (anime, books,
music, games, live action) and every filter the site offers
(分类/来源/题材/地区/受众/平台/分级…), grouped in one menu per channel.

<details>
<summary>More detail</summary>

- Ranked rows show cover, site rank (gold/silver/bronze podium), score, rating
  count and info line; **Load More** pages through thousands of subjects.
- Subjects already in your library are badged and link to their detail page;
  everything else opens its bgm.tv page.
- Entries come from the read-only `next.bgm.tv/p1/subjects` endpoint
  (`sort=rank`), and the filter taxonomy is discovered from each channel's page,
  so new categories appear without an app update.

</details>

## Your own record

- **Watch events come from real playback** (sub-15 s touches are ignored); 90 %
  marks an episode watched and updates tracking status.
- **Status, score, notes, review, tags, favorite, rewatch count** per anime —
  with **rankings kept strictly separate from scores**, reorderable in My
  Rankings.
- **Anime Diary** is generated from your watch history.
- **Statistics** turn the year into a report: watch time, sessions, episodes
  finished, monthly/weekday/hour habits, most-watched anime and studios, your
  highest-rated titles — all computed locally.

## Translation

A DeepL-compatible translation provider (batched requests, free/pro endpoint
auto-detection, results cached locally) for foreign-language reviews, which are
shown **original and translation side by side** — the original is never
replaced.

## Appearance & language

System, Light or Dark; the player window always stays dark. The interface is
available in **English, 简体中文 and 日本語** (Settings → Language, applies after
a relaunch).

## Development

Requirements: macOS 14+, Xcode 26+, XcodeGen.

```sh
swift test
xcodegen generate
xcodebuild -project AnimeGod.xcodeproj -scheme AnimeGod -configuration Release build
```

- **`AnimeGodCore`** (SPM package) holds models, the GRDB database, the
  scanner/parser, metadata providers, translation and statistics —
  independently testable.
- The **app target** is SwiftUI + AppKit with the LGPL build of MPVKit. See
  `THIRD_PARTY_NOTICES.md` before distributing binaries.
- Interface strings live in String Catalogs. After a command-line build,
  `scripts/sync-localizations.sh DerivedData/<task>` pulls new strings in and
  `scripts/check-localizations.py` lists anything untranslated.
- Optional live provider tests:
  `ANIMEGOD_LIVE_TESTS=1 swift test --filter 'Bangumi.*ProviderTests'`.
- Headless smoke tests on the built binary: `-smokePlayerTest` (plays the first
  episode, toggles full screen, prints layout sizes), `-smokeEpisodeSets
  "<title>"` (assembles seasons from the live indexes),
  `-smokeAppearanceSnapshots`. Add `-AppleLanguages "(ja)"` to run in another
  language.

## Data & privacy

Everything lives on your Mac — library, metadata cache, watch history, personal
entries, statistics, translations, danmaku matches, comment caches and the
episode-cache index all sit in the local SQLite database
(`~/Library/Containers/com.uhmmu.AnimeGod/Data/…`), with cached episode files in
the same container. **Nothing is uploaded.**

The network is used only for what you ask for: the metadata providers you
invoke, Bangumi charts, the translation provider you configure, the danmaku
sources you enable, the subtitle sites you configure (sent the title, IDs,
episode and file name — plus a 128 KiB-derived hash for OpenSubtitles), the
release indexes you search, and the swarms of downloads you start. BitTorrent is
peer-to-peer, so peers you exchange data with see your IP address, as with any
torrent client.
