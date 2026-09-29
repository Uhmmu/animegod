# AnimeGod for iPhone — Plan

Status: **Phases 0–3 done.** Phase 4, the handoff, is next.
Written 2026-09-29.

The phone app is called AnimeGod too. It is not a second library and not a
second player: it is **the same library and the same player with one extra
layer underneath — a transport from the phone to the Mac**. Every screen the
Mac has, the phone has; every episode row, poster, rating and watch flag is
the same row out of the same database. What the phone adds is a way to reach
it, and what it must get exactly right is the handoff: *the Mac is playing
episode 7 at 14:32, I pick up my phone, I tap once, it plays from 14:32 and
the Mac stops.*

---

## 0. What the codebase already gives us

Three facts settle most of the architecture, and all three were checked
against the tree at `994ca14`, not assumed.

| Fact | Why it matters |
|---|---|
| **`AnimeGodCore` imports nothing but Foundation, GRDB, CryptoKit, Compression and CLibArchive** — 69 files, **zero AppKit, zero SwiftUI** | The whole core layer compiles for iOS as is. This was not inferred from the imports — it was **compiled against the iOS 26.5 SDK on 2026-09-29: 250 files, no errors** (§10, Phase 0). Models, `LibraryDatabase`, the parser, the matcher, the danmaku engine, the subtitle scorer, even `ArchiveExtractor`: all portable. |
| **MPVKit 1.0.0 — the version this project already pins — declares `platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .visionOS(.v1)]`** and the same LGPL `MPVKit` product | The phone runs **the same player core**. No transcoding subsystem, no HLS packager, no AVFoundation. See §4. |
| **The Mac app already holds `com.apple.security.network.server`** (the BitTorrent engine listens for incoming peers) | Running an HTTP server needs no entitlement change and no new sandbox prompt. |

One caveat found at the same time: MPVKit builds **LuaJIT for macOS only**
(`.target(name: "Libluajit", condition: .when(platforms: [.macOS]))`). On iOS
there is no Lua, so mpv's built-in scripts — `osc`, `ytdl_hook` — are absent.
AnimeGod never used them (the chrome is all SwiftUI), so this costs nothing,
but it also means `allow-jit` has no iOS equivalent to worry about.

---

## 1. Shape of the thing

```
┌─────────────────────── Mac ────────────────────────┐     ┌──────── iPhone ─────────┐
│                                                     │     │                          │
│  AnimeGod.app                                       │     │  AnimeGod.app (iOS)      │
│  ├─ AppModel ── LibraryDatabase (the real library)  │     │  ├─ LinkClient           │
│  ├─ PlayerScreen / MPVPlayerController              │     │  ├─ LibraryDatabase      │
│  └─ LinkServer  ◄───────── HTTP + SSE ──────────────┼─────┼──►   (read-through       │
│       :47380                                        │     │  │     mirror, same      │
│                                                     │     │  │     migrations)       │
└─────────────────────────────────────────────────────┘     │  └─ MPVPlayerController  │
                     ▲                                       │       (same libmpv)      │
                     │                                       └──────────────────────────┘
        ┌────────────┴────────────┬──────────────┬───────────────┐
     Bonjour        pinned LAN IP      Tailscale       peer-to-peer Wi-Fi
   (same Wi-Fi)    (mDNS blocked)     (anywhere)          (no router)
```

**Three layers, two of them already exist:**

1. **`AnimeGodCore`** — unchanged in substance, gains `.iOS` as a platform.
2. **`AnimeGodLink`** — *new*, lives inside AnimeGodCore. The wire protocol:
   request/response DTOs, the client, and the server's request routing. Both
   apps link the same file, so there is exactly one definition of every
   payload and a field can never drift between the two sides.
3. **App targets** — `AnimeGod` (macOS, exists) and `AnimeGodMobile` (iOS,
   new), both generated from `project.yml`.

The UI code does **not** get shared. SwiftUI-for-both is a trap here: the Mac
player is `NSViewControllerRepresentable` over a `CAMetalLayer` with AppKit
fullscreen transitions and `NSEvent` key handling, and the phone wants none of
that. The phone gets its own views over the same models. Sharing the *models*
and the *protocol* is what keeps the two honest; sharing the views would just
make both worse.

---

## 2. The transport ladder — "多几个传输方式总没错"

This is the part worth getting structurally right, because it is what makes
adding a fourth or fifth route cheap.

**Every transport produces the same thing: a base URL that reaches the Mac's
`LinkServer`.** Nothing above the transport layer knows or cares which one
won. A transport is therefore a *discovery strategy*, not a protocol — adding
one is ~50 lines, not a subsystem.

```swift
protocol LinkTransport: Sendable {
    var id: LinkTransportID { get }       // .bonjour, .pinned, .tailscale, .peerToPeer
    var rank: Int { get }                 // lower wins ties
    /// Candidate endpoints this strategy can currently offer.
    func candidates(for peer: PairedPeer) async -> [LinkEndpoint]
}
```

`LinkResolver` races every candidate's `GET /health` in a `TaskGroup`, keeps
the first that answers, and re-races on `NWPathMonitor` change (Wi-Fi ⇄
cellular ⇄ VPN up/down). A successful endpoint is remembered per Wi-Fi SSID,
so walking back into the flat reconnects on the fast path without a race.

| Rank | Transport | How the endpoint is found | Works when | Throughput |
|---|---|---|---|---|
| 1 | **Bonjour / mDNS** | `NWBrowser` for `_animegod._tcp` | Same Wi-Fi, no client isolation | Full LAN — 100+ Mbps |
| 2 | **Pinned LAN address** | `host:port` stored at pairing, re-probed | Same Wi-Fi, mDNS/multicast filtered but unicast allowed | Full LAN |
| 3 | **Tailscale** | MagicDNS name (`mac-mini.tailnet-xxxx.ts.net`) or `100.x.y.z`, stored at pairing | Anywhere with internet, including cellular and a hostile campus network | Direct: full. DERP relay: unpredictable — see below |
| 4 | **Peer-to-peer Wi-Fi (AWDL)** | `NWBrowser`/`NWListener` with `includePeerToPeer = true` | No usable router at all; same room | Tens of Mbps, but see the caveats |
| 5 | **iPhone hotspot** | Mac joins the phone's hotspot; falls out as case 2 | Anywhere; local traffic costs no cellular data | Full |

### On Tailscale specifically

The user's network is **Glide** student accommodation broadband. Glide
isolates devices by default, but offers a free **Home Network** product that
puts one account's devices on their own VLAN where they *can* see each other —
sign in, add it to the basket (it costs nothing), check out. Up to 25 devices.
With Home Network on, transports 1 and 2 work and Tailscale is only needed
off-site.

Without it, Tailscale is the answer. Notes that matter for the implementation:

- **No SDK, no entitlement, no integration work.** Tailscale on iOS is a
  NetworkExtension VPN; once it is up, `100.x.y.z` and MagicDNS names simply
  resolve and route. The app makes an ordinary `URLSession` request. Embedding
  `tsnet` is possible and is **not** recommended: it is Go, it complicates the
  license story, and it duplicates what the user already has installed.
- **Tailscale does not trigger iOS's Local Network permission.** Traffic goes
  over a `utun` interface, which is not the local network. Only transports 1,
  2 and 4 need `NSLocalNetworkUsageDescription`. Worth knowing, because it
  means a Tailscale-only setup works even if the user denies that prompt.
- **Tailscale's control plane is HTTPS on 443**, so campus firewalls
  essentially cannot block it; direct WireGuard wants UDP 41641 and STUN on
  3478.
- **The honest risk: a relayed connection may not sustain 1080p.** If both
  devices sit behind the same isolating AP, NAT traversal can fail and the
  session falls back to a DERP relay, whose bandwidth is not guaranteed and
  whose nearest node may be far away. A 1080p anime episode is 5–15 Mbps.
  Mitigation is the transcode path in Phase 6, not wishful thinking — and the
  UI must *say* which transport it is on, so a stuttering stream has a visible
  cause.

### On peer-to-peer Wi-Fi

Worth having because it is the only route that works with no infrastructure at
all, but it is the flakiest, so it ranks last. Known problems, from Apple's
own developer forums:

- AWDL **shares the radio with the infrastructure Wi-Fi connection** by time
  slicing. Holding it open degrades normal browsing, and Apple's guidance is
  explicit: stop peer-to-peer operations the moment you are done.
- Throughput is **choppy until something elevates the link to "realtime"
  mode**, and there is no clean public API to force that.
- You **cannot ask `Network.framework` to prefer peer-to-peer**. When both
  devices are on the same infrastructure Wi-Fi it decides for itself; the
  awdl0 endpoint only really gets used when the `en0` path fails.

So: implement it, rank it last, show it in the UI as "Direct (no network)",
and do not be surprised when it is worse than the LAN.

---

## 3. The handoff — the feature this exists for

> 电脑看到哪里，手机点续播就从那里开始，电脑自动关闭。

The naive version — phone reads `playbackProgress` from the database — is
wrong twice over:

1. **The database is up to 10 seconds stale.** `PlayerScreen` autosaves on a
   `Task.sleep(for: .seconds(10))` loop. You would lose up to ten seconds, and
   ten seconds is exactly enough to be annoying.
2. **The Mac would keep playing.** Two copies of the same episode running in
   two rooms, both writing progress, is worse than no feature.

So the handoff is an explicit, stateful transaction.

### `POST /handoff/claim`

```jsonc
// →
{ "episodeID": "…", "deviceName": "Jiale's iPhone" }

// ←
{
  "position": 872.4,          // livePosition, NOT the throttled `position`
  "duration": 1440.0,
  "isWatched": false,
  "keepsUnwatched": false,
  "speed": 1.0,
  "audioTrackID": 2,
  "subtitleTrackID": 4,
  "subtitleDelay": 0.0,
  "danmakuEnabled": true,
  "wasPlayingHere": true      // false ⇒ Mac wasn't playing it; this is just stored progress
}
```

What the Mac does, in this order — the order is the design:

1. **Read `livePosition`, not `position`.** `PlayerScreen` throttles the
   published `position` to 5 Hz for SwiftUI's sake and keeps the unthrottled
   value in `livePosition` for the danmaku anchor and seeks. The handoff is a
   seek, so it uses the live one.
2. **Pause.** Immediately, before anything else can advance the clock.
3. **Flush progress synchronously** via `AppModel.saveProgress(...)`, passing
   `isWatched:` and `overridesWatched:` from `PlayerState` exactly as the
   autosave does — otherwise a handoff out of an episode the viewer had marked
   unwatched would silently re-mark it.
4. **End the session properly.** Call `endSession()` and record the
   `WatchEvent`. Skipping this is the subtle bug waiting to happen: the diary
   and the statistics screen would quietly lose every session that ended in a
   handoff.
5. **Close the player window**, then clear `model.playerRequest`.
6. Mark the episode **claimed** by that device, and publish it on `/events`.

The phone then opens the stream at `position` and starts playing. It does not
re-derive the start point from its own mirror — the claim response is
authoritative, precisely because it is fresher than any row.

### `POST /handoff/release`

Sent when the phone pauses for more than ~30 s, backgrounds, or the user taps
"Send back to Mac". Clears the claim, writes the phone's final position, and —
if the user asked for it — reopens the player on the Mac at that point. The
transaction is symmetric, so **phone → Mac handoff comes free**; no extra
protocol.

### Claims and conflicts

A claim is `(episodeID, deviceID, expiresAt)` held in memory on the Mac with a
60-second lease the playing device renews. If the phone dies on the bus, the
lease lapses and the Mac is free again. If a second device claims an episode
already claimed, the server returns `409` with the current holder's name and
the phone offers "Take over anyway" — better than silently stealing.

### Where "Resume Watching" points

The phone's big button uses the **same rule as the Mac**: `continueTarget` in
`AnimeDetailView` — the first main episode not yet watched, at its own saved
breakpoint, falling back to "Play Again" from the top once everything is seen.
Do not reimplement this on the phone. Move it into `AnimeGodCore` as a free
function over `[EpisodeMedia]` and call it from both sides, or the two screens
*will* disagree eventually.

---

## 4. Playback on the phone: libmpv over HTTP Range

**Decision: the phone runs libmpv (MPVKit) and points it straight at an HTTP
URL on the Mac. Nothing is transcoded.**

Why this and not the obvious alternatives:

| Approach | Verdict |
|---|---|
| **AVPlayer + direct file** | **Impossible.** AVFoundation cannot open Matroska at all, and the library is overwhelmingly MKV with ASS subtitles, FLAC/Opus audio and multiple tracks. |
| **Mac transcodes/remuxes to HLS, phone uses AVPlayer** | Works, but it is an entire subsystem — a packager, a segment cache, a session lifecycle, and a CPU-hungry Mac. ASS subtitles have to be burned in or converted to WebVTT, losing typesetting. Wrong first move. |
| **VLCKit (MobileVLCKit)** | Plays everything, but it is a *second* player engine with a second set of quirks, while the project already has deep, hard-won knowledge of libmpv's behaviour. |
| **libmpv via MPVKit** ✅ | Same engine, same options, same HDR lessons. mpv issues its own HTTP Range requests, so seeking works over the network with no server-side session state. MKV, ASS, soft subs, multi-track audio: all native. |

Consequences:

- The Mac's media endpoint is **a plain Range-capable byte server**. That is
  the whole "streaming" implementation. No session, no manifest, no state.
- `hwdec=videotoolbox` gives hardware HEVC Main10 and H.264 decode on every
  supported iPhone, so 1080p 10-bit costs almost nothing. 4K HEVC decodes too;
  whether the *network* can carry it is the real limit.
- **Auth for mpv:** the bearer token must not go in the URL (it would land in
  logs and history). mpv takes `http-header-fields`, so set
  `Authorization: Bearer …` there. Verify this early — it is the one place
  where "mpv fetches its own bytes" collides with the auth design.
- **HDR on iPhone is deliberately out of scope for v1.** The Mac's EDR
  pipeline took a full plan and a genuinely nasty bug (`docs/HDR_DOLBY_PLAYBACK_PLAN.md`)
  to get right, and iOS's display handling is different again. Ship SDR
  tone-mapped output first and say so.

---

## 5. Data on the phone: a cache of answers, not a second database

> **Revised 2026-09-29, after Phase 1 shipped.** This section originally
> called for the phone to run `LibraryDatabase` with the same migrations and
> be populated from the Mac. That was reasoned about before the DTOs existed,
> and writing them changed the answer: **the phone is not sent rows, it is
> sent answers.** The server has already run `library()`, resolved the display
> title, averaged the scores and joined the progress. Feeding that back
> through DTO → domain model → SQLite → the same query → domain model → view
> would be a mapping layer in both directions whose only payoff is reusing SQL
> whose result is already in hand. The phone caches the responses instead.
>
> The original reasoning for a mirror — instant launch, browsing offline — is
> still right, and a JSON snapshot on disk delivers both. What is given up is
> running queries the server does not offer, and there are none.

The phone keeps the last good response to each read route on disk and renders
from it:

- **Reads** come from the cache first and are refreshed in the background, so
  the app opens instantly and still works with the Mac asleep.
- **Writes** never touch the cache directly. Progress and watched flags go
  into an **outbox**, are sent to the Mac, and the cache is updated only from
  what comes back. The Mac's database is the single source of truth, always —
  two writers to one logical library is a conflict-resolution problem nobody
  needs, and it is why `PUT /progress` goes through the same call the Mac
  player's autosave uses rather than writing the row directly.
- **Sync** is a full `GET /library` for now; `?since=` and the SSE stream are
  the optimisation, not the design.

The cache stores **no media files** — only responses and posters.

One thing the server must send that is not in the schema: **the displayed
title**. The Mac sorts the grid in `LibraryView` over the title the metadata
gave the work, not `anime.sortTitle` (which is the folder's romaji name); that
was a deliberate fix. If the phone sorts on `sortTitle` the two grids come out
in different orders, which directly violates "所有条目都是一样的". So
`/library` carries a resolved `displayTitle` and `sortKey` per row and the
phone sorts on those.

---

## 6. The HTTP surface

Bound to `0.0.0.0:47380` (configurable). **Every request requires the bearer
token, including from localhost.**

### Pairing

| | |
|---|---|
| `POST /pair` | Body `{code, deviceName, publicKey}`. The Mac shows a 6-digit code in Settings for 5 minutes. Returns a 32-byte device token. Rate-limited to 5 attempts, then the code is burned. |
| `GET /health` | The only unauthenticated route. Returns `{name, version, schemaVersion, transports}` and nothing else — it exists to let the resolver race endpoints, so it must leak nothing. |

Tokens live in the iOS **Keychain** on the phone and in
`…/Application Support/AnimeGod/credentials.json` on the Mac, alongside the
other keys — consistent with the decision to move credentials out of the
macOS Keychain, which was made because ad-hoc builds re-prompt for every item
after each reinstall.

### Library

| | |
|---|---|
| `GET /library?since=` | `LibraryAnime` rows + `displayTitle`, `sortKey`, poster URL, `watchedCount`, `lastWatchedAt`, `lastPlayedAt` |
| `GET /anime/{id}` | Metadata from every matched source, external refs, community posts, the personal profile |
| `GET /anime/{id}/episodes` | `EpisodeMedia` incl. progress and every version |
| `GET /continue-watching` | The Mac's own `continueWatching()` |
| `GET /poster/{animeID}` | **Proxied** through the Mac, from `PosterImageCache`. The phone never talks to Bangumi's or AniList's CDN — one less thing to be blocked or slow, and it reuses artwork the Mac already decoded. |

### Playback

| | |
|---|---|
| `GET /media/{mediaFileID}` | The bytes. `Accept-Ranges: bytes`, `206` with `Content-Range`, `ETag` from `(fileSize, modifiedAt)`. Opens the file through `ScopedLibraryAccess` — a bare path silently lands in the container instead, which is a mistake this codebase has already made once with download folders. |
| `PUT /progress/{episodeID}` | `{position, duration, isWatched?, overridesWatched}` → `AppModel.saveProgress`, so the `MAX(old, new)` rule and the tail rule apply identically to phone writes |
| `POST /episodes/{id}/watched` | The explicit mark, `overridesWatched: true` |
| `POST /handoff/claim`, `POST /handoff/release` | §3 |
| `GET /events` | SSE: `progress`, `handoff`, `libraryChanged`, `scanFinished`, `downloadProgress` |

### Danmaku and subtitles — the quiet win

| | |
|---|---|
| `GET /danmaku/{mediaFileID}` | The **already-merged, already-shifted** comment pool the Mac built |
| `GET /subtitles/{mediaFileID}` | Downloaded sidecar files for that video |

This deserves emphasis. The Mac has already done the work that is hard on a
phone: dandanplay's 16 MB MD5 file hash, Bilibili's `buvid3` bootstrap and
daily WBI key signing, the per-part `cid` resolution, the cross-source merge
with provider shifts baked in, and the local cache. **The phone asks for a
pool of comments and gets one.** It needs no credentials, no WBI
implementation, no matching logic, and it cannot disagree with the Mac about
which pool belongs to which file. The iOS renderer is then a port of
`DanmakuCanvas` — Core Animation, `CALayer`, `CADisplayLink`; all of that
exists on iOS, and the engine itself is already in `AnimeGodCore`.

The one thing to carry over deliberately: `DanmakuCanvas`'s host layer is
**not** geometry-flipped, and engine lanes are top-origin, converted in
`syncLayers`. On iOS, `UIView`'s layer is *already* top-left origin, so the
conversion is the thing to delete, not to keep. Getting this backwards makes
lanes grow up from the bottom, which is exactly the bug the macOS version hit.

---

## 7. Security

An HTTP server holding someone's whole library, reachable over a VPN, is worth
thinking about for ten minutes.

- **Bearer token on every request, no exceptions**, `/health` excepted and
  deliberately empty.
- **Constant-time token comparison.** A naive `==` on a secret is a timing
  oracle; it costs one line to avoid.
- **No public exposure, ever.** No UPnP, no port mapping, no "share to the
  internet" toggle. Reachability off-LAN is Tailscale's job, and Tailscale
  authenticates and encrypts the whole path in WireGuard. This is a deliberate
  boundary: the moment the server is internet-reachable it needs a threat
  model it does not have.
- **Transport encryption**, honestly stated:
  - Over Tailscale — already WireGuard-encrypted and peer-authenticated.
    Plain HTTP inside the tunnel is fine.
  - Over LAN — plain HTTP plus the bearer token. On Glide's per-account VLAN
    or a home router that is your own devices only. On a shared network a
    passive attacker on the same segment could read the token and the video.
  - **Phase 6 adds optional TLS** with a self-signed cert generated at first
    launch and **pinned at pairing** (mpv takes `--tls-ca-file`; `URLSession`
    pins in its delegate). Not day one, but the design should not have to
    change to accept it — so version the protocol from the first commit.
- **Sandbox honesty:** serving a library file must go through
  `ScopedLibraryAccess`, and a security-scoped bookmark **freezes the
  entitlement it was created under**. A bookmark made while the app was
  read-only still resolves and still refuses writes. Reads are what the server
  needs, so this is fine — but `AnimeGod -smokeFolderAccess <path>` is the
  tool if a file mysteriously will not open.

---

## 8. Keeping the Mac awake

The server is useless if the Mac is asleep, and **nothing the phone can send
will wake a sleeping Mac into running an app** — Wake-on-LAN gets the hardware
up, not a suspended process with its network sockets gone.

What is achievable, and the project already has the pattern:
`App/Player/PlaybackActivity.swift` holds
`ProcessInfo.beginActivity(.idleSystemSleepDisabled)` while playback runs and
releases it on pause. `LinkServer` does the same thing, narrower: hold an
activity **only while a paired device is actually streaming**, release it
within a minute of the last byte. Verify with `pmset -g assertions`.

Anything beyond that is the user's Energy Saver settings, and the app should
say so plainly in Settings rather than pretending.

---

## 9. The screens

The Mac sidebar has twelve sections. A phone with twelve tabs is a bad phone
app, so they map rather than clone — but nothing is dropped, and the framing
that makes "所有条目都是一样的" true is this: **some sections are the phone's
own, and some are the phone acting as a remote control for the Mac.** Both are
the same data.

| Mac section | iPhone | Phase |
|---|---|---|
| Library | Tab 1 — grid, same sort orders incl. watch status | 2 |
| Continue Watching | Tab 2 — the handoff lives at the top | 2 |
| *(player)* | Full-screen, portrait + landscape | 3 |
| Bangumi Charts | Tab 3 § | 5 |
| Rankings | Tab 3 § | 5 |
| Diary | Tab 3 § | 5 |
| Statistics | Tab 3 § | 5 |
| Find Releases | Tab 3 § — search on the phone, **download on the Mac** | 6 |
| Downloads | Tab 3 § — live progress over SSE, pause/resume remotely | 6 |
| Subscriptions | Tab 3 § — follow/unfollow, confirm candidates | 6 |
| Library Folders | Settings — read-only; adding a folder is a Mac action | 5 |
| Episode Cache | Settings — plus the phone's **own** offline downloads | 5 |
| Settings | Tab 4 — pairing, transport status, playback prefs | 1 |

Tab 3 is a "More" list. The four tabs are Library / Continue / More /
Settings.

**Offline on the phone** (Phase 5) is the one genuinely new feature: pull an
episode's bytes down over the link into the app's own container and play it
locally. It is the same `EpisodeCacheStore` idea pointed at a different source,
and it is what makes the app useful on the Tube — which is, in the end, the
actual use case behind all of this.

---

## 10. Phases

Each phase builds and is verifiable on its own. Ship order matters: the
handoff is the point, but it is worthless before there is something to hand
off to.

### Phase 0 — make the core build for iOS — **verified 2026-09-29**

This phase was actually run, and it is a one-line change. On 2026-09-29, with
`platforms` temporarily set to `[.macOS(.v14), .iOS(.v17)]`:

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
swift build --product AnimeGodCore \
  -Xswiftc -sdk -Xswiftc "$SDK" -Xswiftc -target -Xswiftc arm64-apple-ios17.0 \
  -Xcc -isysroot -Xcc "$SDK" -Xcc -target -Xcc arm64-apple-ios17.0
```

> `Build of product 'AnimeGodCore' complete! (72.53s)` — **250/250 files, no
> errors**, against the iOS 26.5 SDK.

Everything compiled, including GRDB, the 105 KB `LibraryDatabase`, the whole
Bilibili/dandanplay danmaku stack, the torrent search core, and — unexpectedly
— `ArchiveExtractor`: the hand-written `CLibArchive` module map and header are
platform-neutral, so `import CLibArchive` resolves on iOS too. Only *linking*
`-larchive` into an iOS executable is untested, and the phone has no reason to
extract archives.

**The change was reverted** so the tree was left as found; `Package.swift` and
`Package.resolved` are byte-identical to `994ca14`. To actually take this
phase:

- `Package.swift`: `platforms: [.macOS(.v14), .iOS(.v17)]`.
- Optionally make the `CLibArchive` dependency
  `.when(platforms: [.macOS])` and wrap `ArchiveExtractor.swift` in
  `#if canImport(CLibArchive)`. Not required to build, only to avoid
  shipping dead code to the phone.
- Remember `git checkout -- Package.resolved` after any `swift test`: it
  rewrites the file and drops the MPVKit pin the Xcode project shares.

**Done when** the above builds and `swift test` still reports its full 395
tests in 65 suites on macOS.

### Phase 1 — the link, Mac side — **done 2026-09-29**
- `AnimeGodLink`: DTOs, `LinkTransport`, `LinkResolver`, the protocol version.
- `LinkServer` on the Mac (`Network.framework` `NWListener`; no third-party
  HTTP server — the surface is ~15 routes).
- Pairing UI in Settings: enable, 6-digit code, paired-device list, revoke.
- Bonjour advertisement.
- **Verify headlessly**: `AnimeGod -smokeLink` starts the server, prints the
  endpoints it is reachable on, pairs a fake device and exercises every route
  including a Range read of a real media file. The app target has no tests, so
  this *is* the test, the way the other smoke flags are.

### Phase 2 — the phone, read-only — **done 2026-09-29**
- New `AnimeGodMobile` target in `project.yml`.
- Pair, mirror, library grid, detail, episode list, continue-watching.
- Posters via `/poster`. No playback yet.
- **Done when** the phone shows the same grid in the same order as the Mac.

### Phase 3 — playback — **done 2026-09-29**

Driven end to end in the simulator against the real library: a 1080p 10-bit
HEVC MKV decodes through VideoToolbox, the embedded Chinese subtitles render,
playback resumes at the saved second, and closing the player writes the new
position into the Mac's database. What it cost:

- **`ytdl` does not exist on iOS.** MPVKit builds LuaJIT for macOS only, so
  there is no `ytdl_hook` and setting the option is rejected outright — which
  the strict option assertion turned into a launch crash. The assertion was
  right; the option is gone.
- **`loadfile` is `<url> [<flags> [<index> [<options>]]]`.** The options are
  the *fourth* argument and the third is an integer. `start=` in the index
  slot is rejected, and it presents as a spinner that never stops, because mpv
  reports that class of failure only through its own log. `MPV_EVENT_LOG_MESSAGE`
  is forwarded under `AG_MPV_LOG` now for exactly this reason.
- **MoltenVK works in the simulator**, with benign
  `VK_ERROR_FEATURE_NOT_PRESENT: Metal does not support disabling primitive
  restart` warnings.
- **Not yet verified: landscape.** The layout is written for it — the surface
  is landscape-oriented so a rotation is a layout pass, not a renderer rebuild
  — but rotating the simulator was not driven from here.

### Phase 3 — playback (original)
- `MPVPlayerController` for iOS over MPVKit, `hwdec=videotoolbox`, SDR only.
- Playback from `/media/{id}` with the bearer header.
- Progress write-back via the outbox.
- Landscape, gestures, AirPlay-audio, lock-screen controls.
- **Done when** an episode plays end to end over the LAN and the Mac's library
  shows the new position.

### Phase 4 — the handoff ⭐
- Claim/release, leases, the `409` takeover.
- Mac side: pause → flush → `endSession()` → close window, in that order.
- SSE so both screens agree live.
- **Done when** the sentence at the top of this document is literally true,
  in both directions, and `WatchEvent` rows are still written for sessions
  that ended in a handoff.

### Phase 5 — parity
- Danmaku over `/danmaku` + the iOS `DanmakuCanvas` port.
- Subtitles, the More tab, offline download-to-phone.

### Phase 6 — reach
- Tailscale endpoint configuration and a transport indicator in the UI.
- Peer-to-peer Wi-Fi transport.
- Optional TLS with a pinned self-signed cert.
- Optional server-side transcode for relayed/cellular sessions — **only**
  when measurements show it is needed. `VideoToolbox` on the Mac, one
  ladder rung (720p ~2.5 Mbps), and it stays off by default.

---

## 11. `project.yml`

The iOS target joins the same generated project. Sketch:

```yaml
options:
  deploymentTarget:
    macOS: "14.0"
    iOS: "17.0"

targets:
  AnimeGodMobile:
    type: application
    platform: iOS
    sources: [path: Mobile]
    dependencies:
      - package: AnimeGodCore
      - package: MPVKit
        product: MPVKit          # LGPL. Never MPVKit-GPL, on either platform.
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.uhmmu.AnimeGod
        PRODUCT_NAME: AnimeGod
        SWIFT_STRICT_CONCURRENCY: complete
        INFOPLIST_KEY_NSLocalNetworkUsageDescription: >
          AnimeGod finds your Mac on the same Wi-Fi network to stream your library.
        INFOPLIST_KEY_NSBonjourServices: _animegod._tcp
        INFOPLIST_KEY_UIBackgroundModes: audio
```

The bundle id can be shared across platforms (it is a different platform, so
it is a different app record) which keeps iCloud and Handoff options open
later. `UIBackgroundModes: audio` is what lets playback survive a screen lock.

---

## 12. Things that will go wrong

Collected in advance so they are recognised rather than rediscovered.

1. ~~**mpv and the bearer token.**~~ **Settled 2026-09-29.** `-smokeLink`
   drives a headless libmpv at the real media route and checks both
   directions: it loads the stream when `http-header-fields` carries
   `Authorization: Bearer …`, and is refused without it. The token stays out
   of the URL, and out of logs and history with it. No signed URLs needed.
2. **`livePosition` vs `position`.** Using the throttled one in the handoff
   costs up to 200 ms — small, but it is exactly the kind of thing that gets
   copied into three more places once it is wrong.
3. **Losing `WatchEvent` on handoff.** See §3 step 4. Silent, and only
   noticed weeks later when the statistics look thin.
4. **The mirror drifting.** Any write path that touches the phone's mirror
   without going through the Mac will eventually produce two libraries that
   disagree. The outbox is not optional.
5. **Sorting.** `sortTitle` is the folder name; the grid shows the metadata
   title. Ship `displayTitle` from the server or the two grids differ.
6. **NFD titles.** macOS folder names are decomposed; the parser precomposes
   and `v13_precomposed_titles` rewrote the stored rows. The phone must never
   re-introduce a decomposed string into the mirror — Swift compares the two
   spellings equal, so nothing will notice until something hashes or sends
   them.
7. **Danmaku lane origin.** Flipped on iOS relative to macOS. §6.
8. **Sandbox file access.** `ScopedLibraryAccess`, not a bare path.
9. **App Transport Security.** Plain HTTP to a local address needs an ATS
   exception on iOS. Scope it to the minimum (`NSAllowsLocalNetworking`),
   not a blanket `NSAllowsArbitraryLoads`.
10. **Two apps, one string catalog problem.** New user-facing text on the
    phone needs the same treatment as the Mac's: literals in SwiftUI views
    are extracted automatically, computed `String`s are not.
    `scripts/check-localizations.py` must still report 0 missing across
    en / zh-Hans / ja.

---

## 13. Open questions for the user

1. **Glide Home Network** — is it offered at this building? If yes, turn it
   on; transports 1 and 2 then work and Tailscale becomes the off-site path
   rather than the only path.
2. **Deployment target.** iOS 17 keeps the SwiftUI API modern and matches the
   macOS 14 line. Which iPhone is this running on?
3. **Signing.** A free Apple ID gives 7-day provisioning, which means
   reinstalling weekly. A paid account (£79/yr) gives a year and makes
   TestFlight possible. This decision gates Phase 2 actually being usable
   day to day, not just buildable.
4. **Scope of the "More" tab.** Charts, rankings, diary and statistics are
   real work for screens that may rarely be opened on a phone. Worth
   confirming before Phase 5 rather than building all four on spec.
