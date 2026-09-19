# Localization Plan: Chinese and Japanese

Status: **L1–L4 implemented**

Goal: AnimeGod ships in English, Simplified Chinese and Japanese, and
Settings has a language picker (System / English / 简体中文 / 日本語).

Order: **L1 → L2 → L3 → L4**. Each phase is its own commit (or a few),
verified by building, installing and taking snapshots before the next
starts.

## Current state

- The app has no localization at all: no string catalog, no `.lproj`, and
  no `defaultLocalization` in `Package.swift`. Only 4 places use
  `String(localized:)`, `LocalizedStringKey` or `Text(verbatim:)`.
- **Scale:**
  - About 465 string literals passed straight to `Text` / `Label` /
    `Button` / `Section` / `Toggle` / `.help` / … across 22 files.
    SwiftUI treats these as `LocalizedStringKey`, so they are picked up
    automatically once a catalog exists.
  - About 180 `case …: "Text"` computed labels (status lines, episode kind
    names, danmaku and subtitle phases, download states…). These are
    plain `String`s, so they are **not** localized until converted.
  - About 60 display names and status strings in `AnimeGodCore`, e.g.
    `EpisodeCategory.displayName` ("Specials (SP)") and provider error
    messages.
  - Interpolated sentences and counts ("\(n) episodes", "Episode \(n)").
    These need plural and format variants.
- Dates and numbers mostly go through formatters (17 sites), so they
  follow the locale on their own. Hand-built formats need checking.

## Decisions

- **String Catalogs** (`.xcstrings`) with English as the source language.
  Xcode 26 extracts SwiftUI literals and `String(localized:)` into them on
  every build, and plural and format variants live in the same file.
- **Language choice requires a relaunch.** The picker writes the app's own
  `AppleLanguages` default (removed for "System") and offers **Relaunch
  Now**. Switching live would only partly work: SwiftUI `Text` could
  follow an environment locale, but `String(localized:)`, AppKit panels,
  menus and formatters resolve the language at launch. A relaunch is how
  macOS apps usually do this. Quitting already saves torrent resume data
  (`applicationWillTerminate`).
- **Chinese means Simplified (`zh-Hans`).** Traditional (`zh-Hant`) can be
  added later with the same catalog.
- **Not translated:**
  - Anime titles, episode titles, file and release names, fansub groups,
    and user data.
  - Provider and brand names: Bangumi, AniList, dandanplay, Bilibili,
    Nyaa, 动漫花园, Jimaku, SubDL, OpenSubtitles, assrt, DeepL.
  - Smoke-test and log output.
  - Code that passes such values into `Text` uses `Text(verbatim:)`, so a
    title that happens to match a key is never "translated".
- **Out of scope:** which language the *metadata* is shown in (Bangumi
  Chinese titles vs. Japanese originals). That is a separate setting and
  can follow later.

---

## L1 — Infrastructure and the language setting

1. `App/Localizable.xcstrings`, with source language `en`.
2. `project.yml`:
   - `options.developmentLanguage: en` and
     `LOCALIZATION_PREFERS_STRING_CATALOGS: YES`.
   - `SWIFT_EMIT_LOC_STRINGS: YES`, so literals are extracted.
   - `CFBundleLocalizations` = `en`, `zh-Hans`, `ja` in the generated
     Info.plist.
   - Also localize the Info.plist strings. The copyright line and the
     category stay as they are.
3. **Core package:**
   - `defaultLocalization: "en"` and
     `resources: [.process("Resources")]` with
     `Sources/AnimeGodCore/Resources/Localizable.xcstrings`.
   - Core strings use `String(localized: …, bundle: .module)`.
   - **To verify first:** both `xcodebuild` and command-line `swift test`
     must compile the catalog. If the SwiftPM CLI can't, fall back to
     keeping core strings as English keys and mapping them to localized
     text in the App layer, which is fewer moving parts. Record the
     result here.
4. **Language picker:** in Settings → Appearance (renamed **General**), a
   Language menu showing each language in its own name. It sets or
   removes `AppleLanguages` in the app's defaults and shows a banner with
   **Relaunch Now** (open a new instance, then terminate).
5. **Verification tools:**
   - `-smokeAppearanceSnapshots` and `-smokePlayerTest` already work per
     language when launched with `-AppleLanguages "(zh-Hans)"` or
     `"(ja)"`. Every screen can be captured in all three languages
     without new code.
   - `scripts/check-localizations.py` reads the catalogs and lists
     entries per language that are missing, stale, or still equal to the
     English source. It exits non-zero so it can gate a release.

**Done when:** the picker switches the app to a pseudo-locale after a
relaunch, the catalogs exist, and English looks unchanged.

---

## L2 — Make every user-facing string localizable

Goal: nothing the user reads bypasses the catalog. Still English only.

Go through the code file by file:

- **Computed labels returning `String`** (`episodeLabel`, `statusText`,
  danmaku `statusLine`, download and subscription states, release tags,
  OSD messages, panel notes…): convert to
  `String(localized:)`, or return `LocalizedStringResource` where the
  value flows into `Text`.
- **Enums with display names:** `EpisodeCategory`, `EpisodeKind`,
  `DanmakuSourceSelection`, subtitle phases, translation providers,
  appearance and language modes.
- **Counts and sentences:** "\(n) episodes", "SP \(n)", "\(count)
  subtitles found — click to choose". These become catalog entries with
  plural variants. Word order must be free to change: Japanese puts the
  number in a different place.
- **User-visible errors:** `LocalizedError.errorDescription` in providers
  and the scanner, alert text, and failure reasons in badges.
- **AppKit surfaces:** `NSOpenPanel` titles and prompts, menu commands
  (`CommandGroup`), window titles.
- **Things to mark verbatim:** titles, file names, provider names and
  numbers-only labels (`12`, `SP3`) → `Text(verbatim:)` or keep them out
  of the catalog.
- **Hand-built date and number formats:** check the Diary's "Sep 19 at
  17:39" and the Statistics labels, and move them to `.formatted()` or
  `Date.FormatStyle` so they follow the locale.

**Done when:** `scripts/check-localizations.py` shows every string
extracted, English output is unchanged (snapshot comparison against the
G1 captures), and searching for `"…"` literals in `String`-returning UI
code finds only deliberate verbatim cases.

---

## L3 — Simplified Chinese

1. **Glossary first** (in this file), so the same thing is always called
   the same, using terms from Bangumi and fansub communities. Examples:
   - All Anime → 全部番剧
   - Episode → 第 N 话 / 集
   - Specials → 特别篇 (SP)
   - Creditless OP/ED → 无字幕 OP/ED
   - Danmaku → 弹幕
   - Release → 资源
   - Fansub → 字幕组
   - Seeding → 做种
   - Subscriptions → 订阅
   - Episode Cache → 剧集缓存
   - Continue Watching → 继续观看
2. Translate every entry, including plural and format variants. Chinese
   has one plural form.
3. **Verify:**
   - Library snapshots and player captures (bubbles, OSD, episode picker,
     sheets) with `-AppleLanguages "(zh-Hans)"`.
   - Look for truncation in fixed widths: bubble widths, episode tiles,
     toolbar labels, and the Settings form.

**Done when:** the check script reports 0 missing for `zh-Hans`, and every
snapshot reads naturally with nothing clipped.

---

## L4 — Japanese

1. **Glossary**, again from what Japanese anime apps and niconico use.
   Examples:
   - Episode → 第N話
   - Specials → 特典 / SP
   - Creditless → ノンクレジット
   - Danmaku → コメント（弾幕）
   - Subtitles → 字幕
   - Seeding → シード
   - Continue Watching → 続きを見る
2. Translate everything, then run the same snapshot pass. Japanese
   strings run longer than Chinese, so bubble and panel widths need the
   most care.

**Done when:** the check script reports 0 missing for `ja`, and the
snapshots are clean.

---

## Afterwards

- READMEs gain a line about languages. A `README.ja.md` is optional.
- The release notes for the next version mention the language setting.

---

## Outcome

### Infrastructure

- **Catalogs:**
  - `App/Localizable.xcstrings` (667 strings) and
    `Sources/AnimeGodCore/Resources/Localizable.xcstrings` (84 strings,
    `bundle: .module`). All are translated into `zh-Hans` and `ja`.
  - English plural forms exist for the counted strings ("1 episode" /
    "3 episodes").
  - Keys with no letters (`%lld`, `%@ / %@`) are marked
    `shouldTranslate: false`.
- **Command-line workflow:** `xcodebuild` writes `.stringsdata` but does not
  update the catalogs, so run `scripts/sync-localizations.sh
  DerivedData/<task>`. Stale keys are then removed by hand (or by
  deleting entries whose `extractionState` is `stale`).
- **Core catalog under SwiftPM:** command-line SwiftPM copies the core
  catalog without compiling it. `swift test` therefore sees the English
  keys, and the 304 tests pass unchanged. Xcode compiles it into
  `AnimeGodCore_AnimeGodCore.bundle/Contents/Resources/<lang>.lproj`.
- **Stale bundle after incremental builds:** the core bundle embedded in
  the app was left over from a build made while the catalog was still
  empty; deleting the built `.app` fixed it. Release builds use fresh
  DerivedData, so they are not affected. If core strings show English in
  a localized build, check that bundle first.
- **Relaunch:** `AppLanguage.relaunch()` starts
  `/bin/sh -c 'while kill -0 <pid>; do sleep 0.2; done; open <app>'` and
  terminates. The new instance starts only after this one exited and
  saved torrent resume data. This works inside the sandbox; verified with
  `-smokeRelaunch`.

### Rules that came out of L2

- **UI components** (the player bubble rows) take a
  `LocalizedStringResource` for literals, so they are extracted, and a
  `verbatim:` initializer for data (track names, titles).
- **Stored English labels:** watch history and cache entries store
  canonical English episode labels (`Episode.displayLabel`). Views show
  them through `Episode.localizedLabel`, so records made under one
  language read correctly in another.
- **Identifiers are not numbers to format:** interpolated `Int`s in
  localized strings get locale digit grouping ("#157,220,001"). Pass IDs,
  ports and codes as `String(x)`, or use `Text(verbatim:)`.
- **English grammar in code:** hand-built plurals
  (`"episode\(n == 1 ? "" : "s")"`) are replaced by catalog plural
  variants. So are sentences that embed a lowercased English noun.
- **Not translated, on purpose:** the ⌘⇧D developer diagnostics,
  provider and brand names, fansub notation (内嵌/内封/外挂, 简/繁/日),
  the native-language names in language pickers, and `EP` tags.

### Glossary

| English | 简体中文 | 日本語 |
|---|---|---|
| Anime (library) | 番剧 | アニメ |
| Episode N | 第 N 集 | 第N話 |
| Episodes (category) | 正片 | 本編 |
| Specials (SP) | 特别篇 (SP) | 特別編 (SP) |
| Creditless Opening / Ending | 无字幕片头 / 片尾 | ノンクレジットOP / ED |
| Trailer / Extra | 预告 / 特典 | 予告編 / 特典 |
| Movie | 剧场版 | 劇場版 |
| Danmaku | 弹幕 | 弾幕 |
| Release / Find Releases | 资源 / 查找资源 | リリース / リリース検索 |
| Fansub | 字幕组 | 字幕グループ |
| Batch / Raw | 合集 / 生肉 | まとめ / RAW |
| Seeding · peers | 做种 · 用户 | シード · ピア |
| Subscriptions | 订阅 | 購読 |
| Episode Cache | 剧集缓存 | エピソードキャッシュ |
| Continue Watching | 继续观看 | 続きを見る |
| Anime Diary | 观看日记 | 視聴日記 |
| Shoutbox / Reviews / Discussions (Bangumi) | 吐槽 / 日志 / 讨论 | ひとこと / レビュー / ディスカッション |

