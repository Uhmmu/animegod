# Third-party notices

## GRDB.swift

- Source: https://github.com/groue/GRDB.swift
- License: MIT

## MPVKit

- Source: https://github.com/mpvkit/MPVKit
- Selected product: `MPVKit` (not `MPVKit-GPL`)
- License: LGPL-3.0, including bundled libmpv/FFmpeg frameworks

Distribution must preserve the applicable notices and LGPL relinking/replacement rights. Do not switch to the `MPVKit-GPL` product without deliberately accepting GPL-3.0 obligations.

## libtorrent-rasterbar

- Source: https://github.com/arvidn/libtorrent (2.0.14)
- License: BSD-3-Clause
- Usage: statically linked into AnimeGod as the embedded BitTorrent download
  engine. Built by `scripts/build-libtorrent.sh`; the notice and copyright of
  the original authors must be preserved in distributed binaries.

## OpenSSL

- Source: https://www.openssl.org/ (3.5.8)
- License: Apache-2.0
- Usage: statically linked through libtorrent for HTTPS trackers and
  protocol encryption.

## Boost (headers)

- Source: https://www.boost.org/ (1.92, headers only)
- License: Boost Software License 1.0
- Usage: compile-time dependency of libtorrent's public headers; no Boost
  library code is linked beyond what libtorrent inlines.

## Anime torrent indexes

- Sources: 动漫花园, 蜜柑计划, 萌番组, Anime Garden, ACG.RIP, 末日动漫, Nyaa,
  AnimeTosho, SubsPlease, TokyoTosho
- Usage: public search endpoints (RSS/JSON) are queried on the user's
  explicit action, one page per query, with no bulk crawling and no
  redistribution of their indexes. AnimeGod stores only what the user
  downloads. Users are responsible for their own use of the material these
  indexes link to.

## dandanplay Open Danmaku Network

- API documentation: https://doc.dandanplay.com/open/
- Usage: danmaku (bullet comments) are fetched from the official Open
  Danmaku API v2 with user-supplied AppId/AppSecret credentials
  (dev.dandanplay.com), cached locally, and credited in the danmaku UI.
- Terms: no bulk downloading/scraping of the danmaku database; caching is
  per-episode and refreshed only on explicit user action; commercial use
  requires separate authorization from dandanplay.

