# AnimeGod 0.4.0

**Follow an airing season once. Let AnimeGod take it from there.**

This release turns subscriptions into a single decision instead of a form to
maintain. It also makes metadata self-filling, brings AniList results back for
almost the whole library, and fixes the title-identity mistakes that could turn
one season into many cards.

## 🔔 One-click subscriptions

- Open an unfinished season in **Episode Sets** and press **Subscribe**.
  AnimeGod reads the fansub, encode, folder and episode range from the set you
  chose; there is no rule form to fill in.
- New episodes follow that same release pattern and land in the season's shared
  folder automatically.
- The schedule is learned from when episodes actually appeared. AnimeGod shows
  the likely next release time and recognises a finished season from the
  fansub's finale tag, a full-season pack, provider episode counts, or a long
  enough silence after the usual cadence.
- Long-running series published under two numbering schemes are kept on the
  current run instead of suddenly jumping back to a short alternate sequence.
- Download and upload speed limits can be set for the session, with a separate
  limit available for an individual task.

## 🔗 Metadata that fills itself in

- Metadata enrichment now runs quietly after launch and every library scan.
  When AnimeGod genuinely needs help, it opens **Review Matches** instead of
  leaving a badge easy to miss.
- AniList matching now understands romaji, English and native titles, retries a
  work under names learned from other providers, and removes only safe format
  words such as “movie” or “part one” when needed.
- Japanese titles copied from macOS folders are normalised before searching, so
  visually identical spellings with different Unicode bytes no longer miss.
- AniList rate limits and temporary failures are waited out rather than
  disabling the provider for the rest of a run.
- A title that a provider does not know can be searched directly from the
  review sheet, and **Skip** is remembered.

## 📚 A library that stays one work

- All-bracket release names, index titles containing several aliases, and bare
  CRC checksums in folder names are read as titles instead of creating a new
  work for every episode.
- Downloads group by the anime or their shared season folder, so twelve
  incoming episodes remain one card even before metadata arrives.
- The anime row created when a download starts now uses the same title rule as
  the scanner. This removes the empty matched page beside a second page that
  actually contains the files.
- Existing decomposed macOS titles are migrated safely; metadata, history and
  bindings stay attached when duplicate identities merge.

## ↕️ Sort the library you see

- Order the grid by **Name**, **Recently Added**, or **Rating**.
- Name sorting uses the title shown on each card, not a hidden folder title.
  Latin titles stay together while Chinese titles still sort naturally by
  pinyin.

## Compatibility

- Requires macOS 14 or later. The supplied DMG contains a Universal app for
  Apple silicon and Intel Macs.
- The app is ad-hoc signed but not Developer ID notarized. Depending on macOS
  security settings, the first launch may require right-clicking the app and
  choosing **Open**.
- Database migrations are additive. Existing libraries, downloads, metadata,
  personal records and watch history are preserved.
