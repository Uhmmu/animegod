# AnimeGod 0.6.0

**A concert Blu-ray is not an anime, and AnimeGod has stopped pretending it is.**

A live disc has no episodes, no synopsis, and no provider that rates it as a
work. What it has is **what was played** — so the setlist is the page, and
everything else follows from where that information lives. This release adds a
Concerts section built around that, four music sources behind it, five general
torrent indexes in front of it, and the switch that stops every finished
download from seeding behind your back.

---

## 🎤 Concerts

Its own section in the sidebar. Deliberately **not** on the home screen: a
concert is not something you are partway through a season of.

| | |
|---|---|
| 🏷 **Files itself** | `6th LIVE`, `演唱会`, `合同ライブ`, `12th☆LIVE` — a live recognises itself when the download starts and never raises the "which anime is this?" sheet |
| 🎚 **The setlist is the page** | Songs, lengths, the encore, the hall, the night it happened |
| 💿 **Two nights are one work** | `DAY1` + `DAY2`, however they arrived — one folder, two folders, or the night in the filename |
| 🚫 **No "watched"** | There is no finishing a concert. Your position is still kept; it is a position, not a verdict |
| 🎸 **Grouped by band** | Each act in the order it played, the act you are collecting now at the top |
| 🖼 **Choose a cover** | Plenty of concerts have none anywhere. Pick one and it stays |

### Where the information comes from

No single catalogue knows a concert. Four do, between them, and each is asked
only what it is actually good at — measured, not assumed.

| | |
|---|---|
| **Discogs** | The catalogue number, the label, the barcode, the shape of the box |
| **MusicBrainz** | The setlist, the song lengths, and the name of each night |
| **Bangumi** | The hall, the date, and a score somebody voted on |
| **setlist.fm** | What was *actually* played, night by night, with the encore marked |
| **The release's own folder** | The catalogue number in a cue sheet, the jacket scans, what else was in the box |

The folder is often the best of the five. One release here is named
`[DBD-Raws][MyGO!!!!! 6th LIVE…][1080P][BDRip]` and carries no catalogue number
at all — but two levels down sits `OST/BRMM-10876.cue`, and that number answers
with the release and **both nights' setlists, sixteen songs each**.

**Every field says who answered it.** A concert page is four services and a
folder, and no two of them answer the same question, so the page stops implying
one source:

```
这些信息来自哪里
MusicBrainz   曲目 · 艺人 · 标题 · 番号 · 条码 · 厂牌
Bangumi       演出日期 · 评分 · 简介
setlist.fm    场馆
This release  封面 · 盒内附属
```

### Where a song starts

Nothing publishes this. Three answers, in this order:

1. **The video's own chapters**, read straight off the file. If the encode kept
   them and named them, that is the disc telling you what is on it and where —
   better than any catalogue, and it no longer takes playing the file to find
   out.
2. **The disc's marks**, aligned to the setlist while it plays.
3. **Paste one in.** People post these lists; paste one and it becomes the
   setlist, including the parts no catalogue lists. A disc that already has
   times but no names takes a **bare list of song names** instead, with the
   times shown beside them as you type — the counts are expected to disagree, so
   the mismatch is shown rather than silently resolved.

### In the player

A concert plays as a concert: the scrubber **cuts itself into songs**, the scrub
bubble names the one under the pointer, and there is a song picker bottom right.
No subtitle search, no danmaku — nobody writes either for a live Blu-ray, and
being asked twice at the start of every concert is not a feature.

---

## 🧲 Five more places to look

Every index AnimeGod searched was an *anime* index, and a concert Blu-ray is not
filed as anime. **Knaben, torrents-csv, BitSearch, TheRARBG and The Pirate Bay**
join them, grouped separately in Settings.

Measured, with this library's own queries:

| | nyaa | knaben | torrents-csv | TheRARBG |
|---|---|---|---|---|
| `MyGO 9th LIVE` | 0 | 1 | 1 | **18** |
| `Ave Mujica 4th LIVE` | 0 | 30 | 2 | **30** |

And **Nyaa was only ever asked about its Anime category** — while a live Blu-ray
is filed under Live Action or Music. It is asked about the whole site now.

---

## 🌱 Sharing is a choice now, and it starts off

Everything that finished used to seed for as long as the app was open, with no
way to say otherwise. One switch — Settings → Downloads — and it **starts off**.
Off is not "stop the next one": the seed queue shuts *and* every finished task
stops on the spot.

A **Seeding** section shows what is actually being shared: upload rate, how much
has gone out, the peers being served, the ratio given back.

---

## 📦 A work is one work

**"I downloaded episode one on its own and episode two became a second show."**
A season in its first week cannot be downloaded as a set, and a lone download was
the one path that never named a folder — so it landed in one named after the
release while the set a week later named it after the work. Two folders, two
cards, two library entries.

Every new download now joins the work already being downloaded under a matching
name, folder and anime alike, whichever way it was started: by hand,
multi-select, a set, a subscription, or an accepted subscription candidate.

**A release search opens on Episode Sets**, because what you want from a search
is almost always "get me this show" — unless the show is one episode old, in
which case it opens on the results that exist.

---

## 🩹 Fixes

| | |
|---|---|
| **Watch state on screen** | A finished episode now says so without reopening the page — macOS stops drawing a window the player covered, so the count was right in the model and stale on screen |
| **A tap on the phone** | Tapping the picture no longer fast-forwards it; `onPressingChanged` reports the press, not the long press |
| **Covers** | A local jacket scan never loaded at all — the cache insisted on an HTTP response, and a file URL has none |

---

## Install

Download `AnimeGod-0.6.0.dmg` and drag AnimeGod to Applications. Universal
(Apple Silicon + Intel), ad-hoc signed, not notarized — on first launch,
right-click and choose **Open**.

The iPhone companion is unchanged in this release and is not packaged with it;
0.5.0's `.ipa` still pairs with this build.
