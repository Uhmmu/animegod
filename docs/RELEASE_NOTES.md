# AnimeGod 0.3.2

**A downloaded season is one show again.**

0.3.1 could assemble a whole season and start it in one click. What arrived
afterwards was twelve folders, twelve cards, twelve unreadable release names
and no cover — and nothing matched to an anime until long after the last
episode had landed. This release is about the gap between "the download
works" and "the season is in my library".

| Before | Now |
|---|---|
| Twelve folders side by side in the library root | One folder, named after the anime |
| Twelve cards on the home screen | One card, with the real cover and one progress ring |
| Matched by hand once everything had finished | Asked once, before the first episode finishes |
| Finished releases drifting into "Queued" | Finished releases keep seeding |
| A moved file quietly downloaded again | The task stops and says so |

## 📁 One folder for the season

- A set started from **Find Releases** now lands in a single folder named after
  the anime, instead of spreading twelve folders through your library root.
- Choosing several releases at once, or downloading from an anime's own page,
  shares a folder the same way.
- Episodes already downloaded one at a time can be **collected into one folder**
  from the Downloads list. The engine moves the files, so seeding is never
  interrupted, and the folders it empties are removed.
- Release titles that list every alias of a work at once —
  `尼古喵喵 / ヤニねこ / Yani Neko / Chainsmoker Cat` — are now read alias by
  alias, so the folder is named after the one the files themselves use.

## 🖼 One card, matched before it finishes

- Starting a download of something your library does not know now **asks which
  anime it is** — once for the whole season, not once per episode — with
  ranked candidates, covers and a search box for correcting the title.
- Answering links the work immediately: the card gets the real title and cover
  while the episodes are still arriving, and it **opens the anime's page**, so
  the synopsis, ratings and comments are there before the files are.
- The scan that runs when the download finishes finds the anime **already
  matched**. Nothing is left to link by hand afterwards.
- The home screen groups downloads by the work they belong to, so a twelve-part
  season is one card rather than twelve.

## 🌱 Seeding that keeps going

- A finished release held back by the seed queue was being reported as
  **Queued**, which made a completed season look as though it had fallen all
  the way back to waiting for a slot. It now reports as finished.
- Seeding is no longer metered against the download limit. It costs upload only,
  and downloads are always given their slots first — whereas the old limit
  paused a finished season one episode at a time until almost nothing was still
  sharing.

## 🛟 Fixes

- **A completed download whose files have moved is paused, not fetched again.**
  Moving a finished episode in the Finder is an ordinary thing to do;
  re-downloading it was not a reasonable answer. The task stops and explains
  what it cannot find.
- Archive extraction only opens a task's **own** files, so finishing one episode
  of a set no longer reaches into the half-written archive of the episode
  beside it.
- Renaming a task into a shared folder now removes the folder it leaves behind,
  and a rename that fails is reported instead of failing silently.
- The Japanese README, which the other two link to, is no longer a version
  behind.

## Compatibility

- Requires macOS 14 or later. The supplied DMG contains a Universal app for
  Apple silicon and Intel Macs.
- The app is ad-hoc signed but not Developer ID notarized. Depending on macOS
  security settings, the first launch may require right-clicking the app and
  choosing **Open**.
- Existing downloads are untouched by the new folder rules: nothing already on
  disk is moved unless you ask for it from the Downloads list.
