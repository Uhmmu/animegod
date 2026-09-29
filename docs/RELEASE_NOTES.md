# AnimeGod 0.5.0

**Your library, in your pocket. Put the Mac down mid-episode and pick the phone up at the same second.**

AnimeGod is now two apps. The Mac still holds everything — the files, the
database, the metadata, the danmaku matches — and an iPhone app of the same
name mirrors it over your own network. Nothing is uploaded, nothing is
duplicated, and nothing new is exposed to the internet.

This release also fixes the watch-state bugs that could replay episode one
forever or quietly un-finish something you had finished.

## 📱 AnimeGod on iPhone

The phone is not a second library. It is the same library, seen from
somewhere else.

| | |
|---|---|
| **Same shelves** | Every work, episode, poster, score and diary entry the Mac has |
| **Continue watching** | The Mac's position, to the second — not to the last autosave |
| **Handoff** | Tap an episode and the Mac pauses, records the session and closes its window |
| **Send it back** | One tap reopens the Mac's player exactly where the phone stopped |
| **Danmaku** | Already matched and merged by the Mac; the phone only draws them |
| **Subtitles** | Embedded tracks and the sidecars the Mac downloaded, in one menu |
| **Offline** | Download an episode and play it with the Mac asleep, or a continent away |
| **The rest** | Diary, statistics, rankings, charts, downloads and subscriptions |

### Handing an episode over

The phone asks the Mac for the episode rather than reading a cached row, and
the difference is the point: in the run that proved it out, the Mac was at
**380.672 s** while the cached row still said **365 s**. The phone started at
380.672 s. The Mac paused, wrote a 77.3-second session into the diary, and
closed its window. Sending it back reopened the Mac's player where the phone
had left it.

A claim is leased, so a phone that dies on the bus cannot strand an episode,
and two devices cannot drive the same one at once.

### Getting to the Mac

Every route produces the same thing — an address that reaches your Mac — and
they are **all raced at once**, with the first to answer winning.

| | |
|---|---|
| 📶 **Bonjour / same Wi-Fi** | Found by name; nothing to type |
| 🔒 **Tailscale** | Anywhere in the world, over WireGuard |
| ⌨️ **Typed address** | For networks that block discovery — student halls especially |

Every address is remembered **per kind**, so pairing at home and then leaving
no longer erases the one that works from outside.

Access is a bearer token on every request, and the Mac only serves once you
turn it on in **Settings → iPhone** — after which it remembers, so a paired
phone keeps working across launches.

> **Building it yourself:** the iPhone app is not on the App Store. The `.ipa`
> attached here is signed with a personal development team, which means it
> expires seven days after it was built. To keep it alive, open `project.yml`,
> put your own `DEVELOPMENT_TEAM` in, and build the `AnimeGodMobile` scheme.

## 🎯 Watch state that tells the truth

- **"Resume Watching" used to always play episode one.** Only its *title*
  reacted to progress. It now opens the first unseen main episode, at its own
  breakpoint, and offers **Play Again** from the top once everything is seen.
- **Finished episodes could un-finish themselves.** The player autosaves every
  ten seconds and the save recomputed `isWatched` from scratch, so opening a
  finished episode and dragging the scrubber undid it. Only your own mark can
  lower the flag now.
- **A new sort order**: Finished / Still Watching / Not Started, newest first.
- A series counts as watched five minutes from the end and a film ten, with the
  tail capped at a quarter of the runtime — so a four-minute creditless opening
  is not "watched" the moment it opens.

## 💬 Danmaku, measured rather than guessed at

Three faults that were invisible to the compiler and to the tests, all found by
instrumenting the renderer instead of theorising about it. **The Mac gets the
first two as well.**

| Symptom | Actually |
|---|---|
| "The overlapping strokes look darker" | The outline was drawn **over** the fill and centred on the glyph, so half of that black sat inside letterforms. At 16pt a CJK stroke is about a pixel wide, so it was swallowed whole. The outline now goes underneath. |
| "The comments stutter" | The clock was hard-anchored on every sample, and mpv reports a position quantised to the video's frame period after a variable hop. It now tracks gradually, and reads the frame's display time rather than the callback's arrival time. |
| "They appear out of nowhere" | Any layout pass that moved the view a fraction of a point threw away every bitmap and cleared the engine. Metrics are rounded now. |

Comments also **cross the whole screen** rather than stopping at a seam inside
the picture, while their size and stacking still come from the picture — two
rectangles, two different jobs.

New on the phone: a **Style** panel for coverage (top ¼ through full), size,
opacity, spacing, speed and density, with **subtitle delay and size** beside it.

## 🈳 Subtitles that are all there

Simplified-only characters used to come out as boxes — 还, 请, 伤 — while 你
rendered fine. mpv's default subtitle font resolves to Helvetica on iOS, which
has no CJK at all, and the fallback iOS offers lives inside a private framework
a sandboxed app **cannot open**. What survived was whatever the Japanese system
font happened to cover.

AnimeGod now carries Noto Sans CJK SC, which covers simplified, traditional,
Japanese and Korean in one file.

## ✋ Two gestures worth having

- **Press and hold** to run at double speed, with a knock from the haptic
  engine. **Tap first, then hold**, for triple.
- **Rotation lock stays on.** When the phone is held one way and pinned
  another — which can only happen while rotation is locked — a button appears
  and takes the hint, then times out. With the lock off it is never drawn.

## 🌏 简体中文 / 日本語

The iPhone app is fully localized in Simplified Chinese and Japanese, like the
Mac. 173 new strings, 0 missing.

---

**Requirements:** macOS 14+ · iOS 17+ · Universal (Apple silicon + Intel)
