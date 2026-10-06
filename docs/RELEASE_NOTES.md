# AnimeGod 0.6.1

**Four things that were quietly wrong.**

0.6.0 gave concerts their own section. This release is what a week of actually
using it turned up: a live Blu-ray that no catalogue would vouch for, a 37 GB
disc image that reported itself empty, a work filed under a date, and a
question that would not stop asking itself.

---

## 🎤 A disc only Discogs holds is still a concert

A concert moves itself into the section when a source says `Live` — and only
**two** sources ever say it: MusicBrainz's `Live` secondary type and Bangumi's
演出 subject. Discogs says nothing of the sort. Measured across four catalogue
numbers, not one carries a `Live` descriptor:

| catalogue number | Discogs says | MusicBrainz has it |
|---|---|---|
| `UPXH-29056` | Blu-ray × 2, 46 songs | ❌ not at all |
| `ANZX-10294` | Blu-ray, Limited Edition | ✅ |
| `BRMM-10876` | CD + Blu-ray Audio | ✅ |
| `BRMM-10679` | CD + Blu-ray | ✅ |

So a Japanese live Blu-ray that **only** Discogs holds could never move itself
in, however exactly its number answered. One was already identified, sitting in
the database with all 46 of its songs, while the work itself stayed in the anime
grid.

What Discogs does say, without meaning to, is that the release is something you
**watch** — and a music catalogue indexes music, so a video medium in one is a
concert or a music video, never an episode of a series. That now moves a disc
in, with one guard: only when no anime provider has matched the work. A
catalogue number alone still moves nothing — `ANZX` is Aniplex's anime label
as well.

Three things had to follow:

| | |
|---|---|
| 💿 **Which disc of a box is the video** | `formats` lists the media in box order with a count each (`2 × CD`, then `1 × Blu-ray`) and the track list numbers its discs the same way — so a 2CD+BD album's **third** disc is recognised as the live, and its 26 songs are the setlist instead of the album's 13 |
| 🔢 **A barcode from the release's own text file** | No cue sheet, no catalogue number in any name, and a saved shop page carrying `EAN ‏ : ‎ 4988031567562` — the only exact key in the folder, and both catalogues answer it with one release |
| ✅ **A finished record over a work still in the grid** | Decided from the record already on disk, rather than by asking every service again |

## 💽 A Blu-ray image that names its folders in UTF-16

A UDF file identifier is OSTA compressed Unicode, and its first byte says which
of two encodings follows. AnimeGod only ever looked for one of them.

| image | `BDMV` written as | result |
|---|---|---|
| `SENNEN_JYOYU.iso` | `42 44 4D 56` | ✅ played |
| `ROAD GAME『テクノプア』…iso` | `00 42 00 44 00 4D 00 56` | ❌ "no playable Blu-ray video" |

Neither image carries an ISO 9660 side to fall back on, so the identifier as the
disc spells it is all there is to go on. Both spellings are read now — and the
second image plays: 1920×1080, 2:22:15, 33 chapters, seeking fine. libbluray
never had a problem with it; only the probe did.

## 🏷 A work's name is what is outside the brackets

The title is not only what the card shows — it is what every metadata provider
is asked for. Two works in a real library were filed under something that is
not a title at all:

| folder | before | after |
|---|---|---|
| `[BDMV][220824] ずっと真夜中でいいのに。 - 鷹は飢えても踊り忘れず` | `220824` | the name |
| `[Sakurato][20190112] Domestic na Kanojo [TV01-12+SP Fin]…` | `TV01-12+SP Fin` | `Domestic na Kanojo` |

The second is why that work had no metadata: it was searching for a description
of the folder's contents. A folder that is *nothing but* brackets still reads a
bracket — that part was right and is unchanged.

## 🔁 A metadata question is asked once

Closing the match review answers nothing — **Done is not Skip** — so every entry
was still pending when the next automatic pass ran, and the sheet opened again.
At every launch. In the library this was found in, the only unanswerable
questions were two concert discs no anime index lists, and the stored skip-list
had exactly **one** entry in it after months.

The queue itself is right. Opening a window over whatever you are doing, a
second and a third time, to ask the same thing, is not. A question now offers
itself once; after that it waits in the toolbar, where asking is your move.

---

## 📦 Install

Download `AnimeGod-0.6.1.dmg`, drag it to Applications. Universal (Apple
Silicon + Intel), macOS 14+. Ad-hoc signed and **not notarized** — on first
launch, right-click the app and choose **Open**.

Upgrading from 0.6.0 needs nothing: the library, the concert records and every
setlist you pasted are kept. Works whose names were wrong are renamed on the
next scan, and what was bound to them comes along.
