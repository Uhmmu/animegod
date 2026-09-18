# Online Subtitles

Search, download and automatically load Chinese subtitles for videos that
have none. Implemented; this note records the design and the provider
research behind it (checked against the live API docs, September 2026).

## Flow

```
file loads → first track list (embedded + sidecar tracks)
  ├─ cached download marked active for this file → load it, done (no network)
  ├─ user's last subtitle choice was "Off"        → nothing
  ├─ a track in a preferred language exists        → nothing
  ├─ filename says Chinese is burned in ([CHT] …)  → nothing (setting)
  └─ automatic search on and a provider configured
       identity: library titles + filename parse + AniList/MAL IDs
                 → Fribb mapping → TMDB (+ TMDB season), IMDb, AniDB
       all providers in parallel (25 s each) → merge → dedupe → score
       ├─ top result auto-loadable → download → unpack → decode → cache → load
       └─ otherwise → badge "N subtitles found — click to choose"
```

`SubtitleSession` (App) owns this per player window; everything testable is
in `Sources/AnimeGodCore/Subtitles/`.

## Pieces

| Core type | Role |
|---|---|
| `SubtitleProvider` | `search(query)` / `download(result, for: video)` → raw bytes |
| `SubtitleManager` | parallel search with per-provider timeout, merge, cross-provider dedupe, ranking, download + preparation |
| `SubtitleMatchScorer` | the score (below) |
| `SubtitleFileSelector` | ZIP/pack → the episode's file in the preferred language/format; fonts collected |
| `SubtitleArchive` | ZIP (stored/deflate via Compression, GBK names, size limits); RAR/7z rejected clearly |
| `SubtitleTextDecoder` | UTF-8/16 BOMs, BOM-less UTF-16, GBK vs Big5 by common-character share |
| `ChineseScriptDetector` | Simplified vs Traditional from the text (kana lines skipped for 简日双语) |
| `SubtitleCacheStore` | `Application Support/AnimeGod/Subtitles/{anime-id}/{S01E14}/{provider}-{id}.{ext}`, `Fonts/`, ID mapping cache |
| `AnimeIDMappingStore` | Fribb anime-lists (AniList/MAL → TMDB/IMDb/AniDB), cached, refreshed every 14 days |
| `SubtitleTranslationProvider` | protocol only — future JA/EN → ZH fallback, decoupled from search |

Database: migration `v10_subtitle_downloads` (`subtitleDownload`), one row per
downloaded subtitle per video (`videoKey` = `media:<uuid>` or `file:<name>`),
exactly one `isActive` per video.

Player: `MPVPlayerController` remembers subtitles added with `sub-add` and
re-adds them after `loadfile` — before this, a fullscreen/HDR renderer
rebuild silently dropped every added subtitle (including "Load External
Subtitle…"). `sub-add` waits for `FILE_LOADED` and never reports failure as a
playback failure. `sub-fonts-dir` points libass at fonts from subtitle packs.
ASS itself is rendered by mpv's libass; no custom renderer. The native Dolby
Vision (AVFoundation) path shows no subtitles; the status says so (⌘⇧H
switches to mpv).

## Score (points of 100)

| Part | Max | Notes |
|---|---|---|
| Identity | 25 | hash 25 · external ID 22 + title · title search 22 × similarity; < 0.45 → *titleMismatch*, cap 35 % |
| Episode | 25 | exact 25 · pack containing it 17 · unstated 7 (*unknownEpisode*) · other episode → cap 15 % |
| Release | 25 | base 5; same group +12 / different −4; same source +7 / BD↔WEB −12 (*sourceMismatch*); resolution +1; release-name token similarity ×5 |
| Language | 15 | preference rank 15/12/9/7/5; script-less "Chinese" = rank − 3; unpreferred 2 |
| Format | 7 | preference rank 7/5.5/3/2; unknown (archive) 4 |
| Quality | 3 | log10(downloads); machine translated −10 |

A different season caps at 30 %. Automatic loading needs the top result to
reach the threshold (default 70 %, a setting) **and** carry none of: wrong
episode/season, title mismatch, BD/WEB mismatch, unstated episode,
unpreferred language, machine translation.

## Providers

| Provider | API | Chinese | ASS | Auth | Limits | Status |
|---|---|---|---|---|---|---|
| assrt.net 射手网(伪) | official v1 (`api.assrt.net`, alt `api.makedie.me`) | 简/繁/双语 | yes (+ per-file download from inside RAR/7z) | user token | 20 req/min per token+IP; credit "字幕服务由assrt.net提供" required | implemented |
| SubDL | official v1 | `ZH` = 简 (GB), `ZH_BG` = 繁 (Big5) | mostly SRT | free API key | 2,000 searches/day; 300 anonymous downloads/day/IP | implemented |
| OpenSubtitles | official REST v1 | `zh-cn`, `zh-tw`, `ze` (bilingual) | converted to SRT | app `Api-Key` + optional user login | search unlimited; 5 downloads/day without login | implemented |
| Jimaku | official (OpenAPI) | none | yes | account key | `x-ratelimit-*` per IP | implemented, Japanese only |
| AnimeTosho | JSON feed | English-translated releases only | – | – | – | not used |
| Zimuku, SubHD | none (CAPTCHA) | – | – | – | – | rejected: scraping + CAPTCHA |
| Xunlei/Shooter hash APIs | undocumented | – | – | – | – | rejected: no documentation/terms |
| AniDB | UDP API (registered client + user login, ED2K of the whole file) | – | – | – | 1 req / 2 s | IDs come from the Fribb mapping instead |

OpenSubtitles bans applications that ask each user for their own consumer
key; the key belongs to the app's developer and is supplied through the
Keychain field or `ANIMEGOD_OPENSUBTITLES_API_KEY`, never the repository.

## Configuration

Settings → Online Subtitles: automatic search, burned-in skip, language and
format order, auto-load threshold, per-provider toggles and keys, cache size
and "Clear Subtitle Cache". Keys: Keychain service
`com.uhmmu.AnimeGod.subtitles`, or environment variables
`ANIMEGOD_ASSRT_TOKEN`, `ANIMEGOD_SUBDL_API_KEY`,
`ANIMEGOD_OPENSUBTITLES_API_KEY` / `_USERNAME` / `_PASSWORD`,
`ANIMEGOD_JIMAKU_API_KEY` (Keychain wins).

Headless check against the live sites (environment keys only):

```bash
AnimeGod.app/Contents/MacOS/AnimeGod -smokeSubtitles "<video file>" "<title>" -anilist <id> [-download]
```

## Open

- Live search/download results have only been verified against error
  responses; a real run needs provider keys.
- `api.assrt.net` and its alternate domain were unreachable from the
  development network (the website was reachable).
- Translation fallback: `SubtitleTranslationProvider` exists as the seam;
  no implementation.
- No per-subtitle timing auto-correction (e.g. audio-based sync); the manual
  subtitle delay remains the fix for a slightly shifted release.
