# AnimeGod 0.1.0 — Milestones 1–8

The complete vertical slice of the product plan: a local-first anime library
and player, metadata aggregation, personal tracking, and yearly statistics —
all native SwiftUI on macOS.

## Highlights

**Player (M5)**
- Chapters, playback speed, volume, subtitle/audio delay controls
- External subtitle auto-discovery + manual loading
- Full keyboard shortcuts (Space, ←/→, F, N/P) and double-click fullscreen
- In-player episode navigation with category labels (Episodes / SP / Music / …)
- Alternative encodes (DoVi + SDR) merge into one episode with a version menu
- Auto-hiding controls in a standalone player window

**Smarter matching (M6)**
- Best-effort auto-matching: every title links to its most likely Bangumi/AniList
  entry; dubious candidates queue in "Review Matches"
- Auto-guessed links display confidence; a wrong link is fixed with Change Match
- Provider-reported anime types (TV / movie / OVA / ONA) classify local entries
- Extended filename corpus: fractional episodes, release versions, Chinese
  numeral chapters, disc menus

**Translation (M7)**
- Independent translation service with a DeepL-compatible provider
- One batched request per batch of posts; results cached in the local database
- Original text always preserved beside the translation
- API key stored in the macOS Keychain

**Statistics (M8)**
- Yearly report: watch time, sessions, episodes finished, monthly/weekday/hour
  habits, most-watched anime, most-watched studios, personal highest-rated
- Studio credits from AniList and Bangumi infoboxes
- All computed locally from watch history

**Library intelligence**
- One folder, two works: 前篇/後篇 compilation films and bundled movies split
  into separate entries
- Bonus folders (SPs/特典) stay attached to their work as specials
- Pirate-site ad labels and technical tails stripped from titles
- Adult-video catalogue codes excluded from the library
- Rescans preserve bindings, personal entries, and history across renames

## Known limitations

- HDR10/HLG tone-maps to SDR; the EDR pipeline and native Dolby Vision are
  planned ([roadmap](docs/HDR_DOLBY_PLAYBACK_PLAN.md)).
- Direct MyAnimeList integration needs an official client ID (not bundled).
- First launch of an unsigned build may require right-click → Open.
