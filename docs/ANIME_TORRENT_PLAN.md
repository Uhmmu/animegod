# Anime Torrent Search and Download Plan

Status: **Phases 1–3 implemented** (search core, UI, embedded downloads); phases 4–5 pending

This plan ports the useful parts of the separate `magnet-crawler` project
(Python + Flask + pywebview + libtorrent) into AnimeGod as native Swift, keeps
only anime sources, adds more anime sources, and ties everything to the
existing library, metadata, and player. `magnet-crawler` itself is a read-only
reference and is never modified.

## 1. What magnet-crawler has

| Area | magnet-crawler | Worth porting? |
|---|---|---|
| Engines | knaben, torrents-csv, apibay, therarbg, animetosho, yts, fitgirl, sukebei, nyaa, bt4g, bitsearch | Only the anime ones (below) |
| Engine contract | `BaseEngine.search(query, limit) -> [TorrentResult]`, pluggable registry | Yes → `TorrentSearchProvider` protocol |
| BTIH handling | 40-hex / 32-base32 normalization, magnet parse/build, tracker injection | Yes, verbatim semantics |
| Merge | Dedupe by info hash; keep all sources, queries, `.torrent` URLs, trackers; max seeders/leechers; most complete name/size/date | Yes |
| Ranking | Relevance (whole phrase > token coverage > CJK bigram coverage), then seeders | Yes, plus anime-aware ranking (§4) |
| Task scheduler | Per-task deadline (45 s single / 120 s batch), 30 s per engine, per-engine concurrency cap, cancel, retry only failed pairs, incremental results | Yes → Swift structured concurrency (`TaskGroup` + deadlines) |
| Diagnostics | Per (query × engine) status: success / empty / timeout / network / http / parse error, elapsed, HTTP code | Yes, shown in a "Source details" disclosure |
| HTML recognition | An unrecognized page (Cloudflare challenge, layout change) is a parse error, never a silent empty result | Yes |
| `.torrent` fetch | Public caches → registered origin URLs; bounded bencode parse; verify SHA-1 of raw `info` bytes | Yes |
| Built-in BT client | libtorrent session: DHT, PEX, LSD, UPnP/NAT-PMP, tracker-list refresh, reannounce loop, pause/resume/remove/open folder, port-map diagnostics | Yes — see §5 (the one open architectural decision) |
| Download folders | Remember up to 10 folders, fall back to the most recent available one, notify on fallback | Yes → security-scoped bookmarks |
| Search history | Last 50 queries, dedupe case-insensitively, move to top | Yes → database table |
| Security | Loopback-only HTTP API, Origin/Host checks, SSRF-safe downloads | Local server not needed in a native app; keep SSRF-style limits (http/https only, size caps) |

Not ported: the Flask server / web UI / pywebview window, `run.sh`/`.bat`
launchers, `make_app.sh`.

## 2. Sources

### Dropped (non-anime or adult/games)

`sukebei` (adult), `fitgirl` (games), `yts` (movies), `therarbg`,
`apibay`, `torrents-csv`, `bt4g`, `bitsearch` (general-purpose, adult-heavy).
`knaben` is dropped as well: it is a general aggregator whose value in
magnet-crawler was adult coverage; every anime tracker it indexes is covered
directly below.

### Kept

| Source | Endpoint | Notes |
|---|---|---|
| Nyaa | `nyaa.si/?page=rss&c=1_0&q=` (mirror `nyaa.land`) | RSS instead of HTML; category locked to Anime (`1_0`) — never `sukebei` |
| AnimeTosho | `feed.animetosho.org/json?q=` | JSON; has `torrent_url`, NZB, file lists |

### Added (all probed reachable on 2026-09-16)

| Source | Endpoint | Why |
|---|---|---|
| 动漫花园 dmhy | `share.dmhy.org/topics/rss/rss.xml?keyword=` | Largest Chinese fansub index |
| 蜜柑计划 Mikan | `mikanani.me/RSS/Search?searchstr=` | Exact byte size, `.torrent` enclosure; bangumi pages map to **Bangumi subject IDs**, which AnimeGod already stores |
| 萌番组 bangumi.moe | `POST bangumi.moe/api/v2/torrent/search` | JSON with hex info hash, team/tag IDs |
| ACG.RIP | `acg.rip/.xml?term=` | RSS, many Chinese subs |
| ACGNX 末日动漫 | `share.acgnx.se/rss.xml?keyword=` | RSS |
| Anime Garden | `api.animes.garden/resources?search=` | JSON aggregator (dmhy/moe/…) with fansub + type (合集/动画/音乐); good fallback when dmhy is slow |
| TokyoTosho | `tokyotosho.info/rss.php?terms=&type=1` | RSS, anime category |
| SubsPlease | `subsplease.org/api/?f=search&s=` | JSON, per-episode 480/720/1080 magnets |

Each source can be toggled in Settings; all are on by default. Category
filters keep music/manga/games out unless the user opts in (Anime Garden
`type`, Nyaa `1_0`, TokyoTosho `type=1`, dmhy sort id).

## 3. Core layout (AnimeGodCore)

```
Sources/AnimeGodCore/Torrent/
  TorrentInfoHash.swift        # BTIH normalize (hex/base32), magnet parse/build, trackers
  TorrentSearchResult.swift    # result model + parsed release info
  TorrentResultMerger.swift    # dedupe/merge, deterministic
  TorrentRelevance.swift       # phrase / token / CJK-bigram score + anime ranking
  TorrentSearchCoordinator.swift # queries × providers, deadlines, cancel, retry-failed, diagnostics
  RSSTorrentFeedParser.swift   # shared XMLParser for RSS sources
  Bencode.swift                # bounded bencode + info-hash verification
  Providers/                   # Nyaa, AnimeTosho, Dmhy, Mikan, BangumiMoe, AcgRip, Acgnx, AnimeGarden, TokyoTosho, SubsPlease
```

Tests use recorded fixtures (no network); live tests behind
`ANIMEGOD_LIVE_TESTS=1`, like the Bangumi providers.

Search history is a per-user convenience and lives in UserDefaults (last
50, case-insensitive dedupe, most recent first). Database: `v8_torrents`
(phase 3) adds `torrentDownload` (info hash, magnet, name, save-folder
bookmark, state, linked `animeID` / episode, added/completed dates) and
`torrentSubscription` (§6).

As built, the files are `TorrentInfoHash.swift`, `TorrentModels.swift`,
`TorrentReleaseInfo.swift`, `TorrentResultMerger.swift` (relevance + merge +
sort), `TorrentHTTP.swift` (provider protocol, HTTP client, RSS parser),
`TorrentFile.swift` (bencode), `TorrentSearchCoordinator.swift`, and
`Providers/{RSS,JSON}TorrentProviders.swift`. Notes from live probing:
TokyoTosho ignores its `type` filter and mixes in hentai/JAV, so categories
are filtered by name; ACG.RIP's feed has no hash, so each `.torrent` (capped
at 30) is fetched and hashed; ACGNX's `author` is the uploading account, not
the fansub; bangumi.moe sizes are decimal.

## 4. Improvements over magnet-crawler

1. **Search from an anime.** "Find Releases" on the detail page searches
   with the Bangumi Chinese name, original name, and aliases as a batch, so
   users don't retype titles.
2. **Anime-aware results.** Reuse `AnimeFilenameParser` on every title to
   extract group, episode / range / batch, resolution, codec, subtitle
   language (简/繁/内封/内嵌/CHS/CHT), source (BD/WEB). Filter chips and
   grouping by fansub; highlight episodes missing from the local library.
3. **Match guard.** Apply the danmaku lesson: an exact episode number never
   rescues a weak title match, so "Ave Mujica" doesn't surface "YUME∞MITA".
4. **Library integration.** A completed download inside a library root is
   picked up by the scanner and bound to the anime it was searched from.
5. **Play while downloading** (if the built-in engine is chosen): sequential
   piece priority for the selected file and a growing-file open in mpv.
6. **Subscriptions** (§6): follow a fansub + resolution + language for an
   anime and download new episodes automatically.
7. **Native diagnostics**: per-source status and elapsed time, retry failed
   sources only, and sources that return challenge pages marked as blocked.
8. **Per-episode tracker refresh** from `ngosang/trackerslist`, cached 6 h.

## 5. Download engine

The sandbox currently has `network.client` and
`files.user-selected.read-only`. Any download adds
`files.user-selected.read-write` (download folder) and, for incoming BT
peers, `network.server`.

| Option | Pros | Cons |
|---|---|---|
| **A. Embed libtorrent-rasterbar** (C++ via an Objective-C++ shim, built as a Universal xcframework) | Same engine and tuning as magnet-crawler; DHT/PEX/UPnP/uTP/encryption; play-while-downloading via piece priority | Largest effort: Boost + OpenSSL build for x86_64+arm64, C++ interop, bigger app; BSD license (OK with LGPL MPVKit) |
| **B. Hand off to an external client** (magnet via `NSWorkspace`, optional qBittorrent Web API / Transmission RPC for progress) | Small, no new native deps, no `network.server` | Requires the user to install a client; no play-while-downloading unless via its API |
| **C. Both**: A as default, B as a setting | Most flexible | Most code |

**Decided (2026-09-17): A — embed libtorrent.** Phases 1–2 (search + UI)
ship first with copy magnet / open in the system handler / save `.torrent`;
the embedded engine replaces those as the primary action in phase 3.

## 6. Subscriptions (after the engine)

Rules per anime: source set, fansub, resolution, subtitle language,
include/exclude keywords. Polling uses RSS where available (Mikan per-bangumi
RSS, dmhy, Nyaa), at most every 30 min, and never downloads the same info hash
twice.

## 7. Phases

1. Core: hashes, bencode, merger, relevance, coordinator, 10 providers, tests.
2. App: "Find Releases" sidebar section with search, filters, source
   details, history; "Find Releases" on anime detail; magnet copy / open /
   save `.torrent`. *(Done: `App/Torrent/TorrentSearchModel.swift`,
   `App/Views/ReleaseSearchView.swift`; the entitlement moved from
   `files.user-selected.read-only` to `read-write` for saving.)*
3. Download engine per §5, download-folder memory, `v8_torrents`. *(Done:
   `scripts/build-libtorrent.sh` builds libtorrent 2.0.14 + OpenSSL 3.5.8 as
   Universal static libraries into `Vendor/` (gitignored, not committed);
   `App/Torrent/Engine/AGTorrentEngine.{h,mm}` is the Objective-C++ bridge;
   `TorrentDownloadManager` + `DownloadFolderStore` + `DownloadsView` are the
   Swift side; migration `v8_torrent_downloads` remembers downloads. The
   sandbox gained `network.server` for incoming peers. Verified offline with
   `-smokeTorrentLoopback`: one engine seeds, another downloads, bytes match,
   resume data is written on shutdown.)*
4. Play-while-downloading and library auto-binding.
5. Subscriptions.
