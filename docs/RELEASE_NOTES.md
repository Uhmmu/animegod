# AnimeGod 0.7.0

**The episode you want is not always on your disk.**

This release adds a whole section for watching straight from a streaming site —
and it does it the way [Kazumi](https://github.com/Predidit/Kazumi) does, with
rules people write and share rather than code nobody can fix. A site that
renames its buttons is a rule update, not an app update.

Rules use Kazumi's own format unchanged, so **a rule written for that app works
here as it is**.

---

## 🌐 A streaming site becomes a source by writing five selectors

That is the whole of it: a search URL and at most five XPath selectors saying
how one site lists its shows.

| | |
|---|---|
| 🔍 **One search, every source** | Every installed rule answers at once, results grouped per site — which source has this week's episode is not knowable in advance |
| 🧩 **Rules, not code** | Install from the shared catalog, or paste one in as JSON, a list, or the base64 blob they get shared as |
| 🛣 **Every playback line** | A site's second and third upload are right there when the first is down |
| 🎞 **The same player** | libmpv, with danmaku and subtitles as usual |
| 📔 **The same watch record** | Resume, mark seen, the diary, the statistics |

**Each source says what it did.** "Nothing found" is its own answer and not a
failure — a site that has never carried a show is not a site you need to go and
fix. A rule whose selectors have gone stale says *that* instead, which is the
one case where there is something to do.

Settings → **Online Sources** lists what is installed, installs from the shared
catalog, and updates the rules the catalog is ahead of. The catalog is a file on
GitHub, which not every network can reach, so it offers a **mirror** when it
cannot.

## 🎬 The page's own player says where the video is

A streaming site does not put its video URL in the page. It assembles it in its
own JavaScript, usually two iframes deep, so the only honest way to find it is
to load the episode and watch what the player does. That takes a few seconds and
the episode says so while it happens.

**A parser that skips the browser looks like it works and does not play.** This
is not a design preference — it was measured on a real episode page:

| what offered it | when | the URL | what it serves |
|---|---|---|---|
| an iframe's query string | **2.21 s** | `play.xfvod.pro:8088/…/01.mp4` | ❌ `401`, with or without a referer |
| the `<video>` element | **9.96 s** | the same path, **no port** | ✅ `206 video/mp4` |

First-past-the-post gives you a resolution that is instant, plausible and dead.
So candidates are **ranked, not raced**: a `<video>` element's source or a
playlist the page actually fetched beats a URL merely handed to a player, and the
quick guess is kept only as the fallback if nothing better arrives.

Two more things that had to be true:

- **Scripts go into every frame.** The player on one real site is
  `player.moedot.net/player/index.php` → `ec.php` — two iframes down.
- **Ad frames are blocked.** An ad's `<video>` element is indistinguishable from
  the episode's to anything watching the page, and whichever showed up first
  would be what played.

Hotlink-protected streams are fetched with the referer the site expects, and the
player is given the same headers — the stream is handed to mpv directly, with
nothing in between opening it first.

## 📔 An episode watched from a site is in the diary like any other

Watching from a site writes **the rows watching a file writes** — the work, its
episodes, their progress, a watch event — because that is what the diary, the
statistics and the resume point are read out of. No parallel history, no second
kind of "watched".

The map onto them is keyed on **the rule's name and the episode's page URL**,
never the resolved stream: a stream comes back signed or cache-busted every
time it is resolved, and a page URL does not change.

| | |
|---|---|
| ▶️ **Resume** | Where you left it, on whichever line you were watching |
| ✅ **Mark seen** | By hand, as everywhere else |
| 🧾 **Several lines, one episode** | A site offering the same episode on three lines has three URLs — finishing it on whichever one was up is finishing it |
| 🚫 **Out of the grid** | An online work has no files, so it stays out of the library grid and the Continue Watching shelf |

**Following a playback line puts the work in the library section**, so a show
you are watching from a site is somewhere you can get back to rather than a
search you have to repeat.

## 🔧 Three things that were wrong on a stream

| | |
|---|---|
| ▶️ **The player said nothing at all** | Every local file is probed before it is played — a disc image probe and a Dolby Vision probe, both of which open a file handle a remote URL simply does not have. A resolved `.mp4` sat in that inspection and **mpv was never handed the file**. A stream now goes straight to mpv. Nothing is lost: Dolby Vision arrives on a disc, and the path that probe selects cannot send a referer anyway |
| 💬 **Danmaku stopped guessing** | dandanplay identifies a file by the MD5 of its first 16 MB, which a stream has none of — so every automatic pass fell back to guessing from a title and bound whatever it guessed. Loading danmaku for an online episode is now your own move: the menu's **Refresh**, or picking the episode yourself |
| 🈳 **Subtitles stopped asking** | Same reason, same answer — an online episode is no longer nagged about a match that cannot be made automatically |

---

## Under the hood, for the curious

- **libxml2, not `XMLDocument`.** `XMLDocument` is this library underneath, and
  it **does not exist on the iOS SDK** — so the rule engine would have had to
  live behind a platform check, in a core that builds for both. libxml2 ships
  headers *and* library in every SDK.
- **A rule's inner selectors start with `//` and mean "inside this row".** XPath
  anchors that at the document, so taken literally every row returns row 0's
  answer. Measured on a real page: `//div[3]/div[2]/a[1]` inside a result row
  matched **2 unscoped vs 1 scoped**, and `//li/a` inside one playback line
  matched **62 vs 24** — collapsing two lines into one wrong list.
- **JSONPath is a deliberate subset.** Every expression in the live catalog was
  collected — **eleven**, all `$` plus dot keys plus `[*]`. Filters, slices and
  recursive descent are used by no rule, and return nothing rather than
  something wrong. **7 of 17 rules** need API mode, so it is not optional.
- **Not every site resolves.** One of the seventeen chains its player URL
  through *another site's* play page, which nothing here follows yet. It is the
  site, not the configuration — a bare probe fails on it too.

**774 tests in 120 suites**, 1045 + 129 + 173 strings with nothing missing in
简体中文 or 日本語.
