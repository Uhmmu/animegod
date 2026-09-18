# AnimeGod 0.2.0

AnimeGod 0.2.0 turns release discovery, downloading, and following a currently
airing show into one native workflow. It also adds Bilibili as a second
danmaku source alongside dandanplay.

## Find releases across ten anime indexes

- **Find Releases** searches ten anime-focused indexes at once: 动漫花园,
  蜜柑计划, 萌番组, Anime Garden, ACG.RIP, 末日动漫, Nyaa's anime
  category, AnimeTosho, SubsPlease, and TokyoTosho.
- Results from different sites that point to the same torrent are merged.
  AnimeGod understands hex and Base32 info hashes and combines the available
  trackers, torrent files, and source links.
- Search from an anime page to use its known Chinese, Japanese, romaji, and
  local-library titles together. Releases containing a missing episode are
  marked **New**.
- Filter by episode or batch, resolution, subtitle language and style, or
  fansub group. Slow and unavailable sources do not hold up the rest, and
  failed sources can be retried on their own.

## Download without another torrent app

- A built-in libtorrent engine downloads magnets and `.torrent` files inside
  AnimeGod. Tasks resume after relaunch and can be paused, re-announced,
  moved to another folder, or removed with or without their files.
- The Downloads screen shows progress, speed, connected seeds and peers,
  estimated time remaining, DHT status, and port-mapping status.
- Save directly into a library folder and a completed release is scanned into
  the library automatically. Active downloads also appear in the library
  immediately with live progress.
- External-drive download folders under `/Volumes` remain writable across app
  launches. If a drive is unplugged or a folder is removed, AnimeGod explains
  the fallback and uses the next available download folder.

## Start watching while it downloads

- Sequential downloads can be played in AnimeGod after the beginning of a
  video is available. The selected file is prioritised so playback stays
  ahead of the download when the connection is fast enough.
- When the completed file enters the library, normal watch progress, episode
  caching, and danmaku matching take over.

## Subscribe to future episodes

- Create an automatic-download rule from a filtered release search or from
  the Subscriptions screen. Rules can specify fansub group, resolution,
  subtitle language, required or excluded words, and a starting episode.
- New subscriptions follow releases published from that point onward by
  default, avoiding an accidental whole-season download. Backfilling older
  episodes is an explicit option.
- AnimeGod chooses one suitable release per episode, avoids episodes already
  in the library or download history, and records every decision in Recent
  Activity. Enabled subscriptions check every 30 minutes while the app runs.

## Bilibili danmaku

- Choose dandanplay, Bilibili, or a merged view of both sources. Comments
  found in both are shown once.
- Bilibili matching uses the anime title and episode number, then fetches the
  correct `cid`, including the selected part of multi-part submissions.
- No Bilibili account is required. An optional `SESSDATA` cookie can be stored
  in the Keychain for content visible to your account; region and membership
  restrictions are reported without interrupting playback.

## Compatibility and privacy

- Requires macOS 14 or later. The supplied DMG contains a Universal app for
  Apple silicon and Intel Macs.
- The app is sandboxed. Version 0.2.0 includes read-write access to mounted
  volumes so an external drive chosen for downloads remains usable after a
  relaunch.
- BitTorrent is a peer-to-peer protocol: peers exchanging data with you can
  see your IP address, just as they can with any other torrent client.
- The app is ad-hoc signed but not Developer ID notarized. Depending on macOS
  security settings, the first launch may require right-clicking the app and
  choosing **Open**.
- Direct MyAnimeList integration still requires an official client ID and is
  not bundled.
