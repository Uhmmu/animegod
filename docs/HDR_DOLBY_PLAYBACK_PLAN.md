# HDR / Dolby Vision Playback Plan (Deferred Work)

Status: Phase 0 complete. Phases 1–4 pending.
Owner: TBD (handoff-ready for Codex or a future session).

## Current state (as of this plan)

Rendering architecture: **libmpv embedded via `wid` = CAMetalLayer pointer**,
`vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=moltenkv` (MPVKit 1.0.0, mpv ≈0.41).

Already implemented:

- HDR detection from **decoded signal metadata** (mpv `video-params`), never from
  filenames: `Sources/AnimeGodCore/Player/VideoColorProfile.swift` — SDR/HDR10/HLG/
  DolbyVision classification requires BT.2020 **and** PQ/HLG together; a "DoVi"
  release label only upgrades a wide-gamut PQ signal.
- Diagnostics overlay in the player (**⌘⇧D**): codec, pixel format, bit depth,
  primaries/transfer/matrix, HDR format, signal peak, hardware decoder,
  display name / EDR headroom / potential headroom, pipeline mode.
  **⌘H⇧** toggles the experimental EDR pipeline (see Phase 1 gate).
- Version policy: alternative encodes of one episode merge into a single
  episode; **SDR version preferred by default** (macOS players cannot render
  Dolby Vision metadata); switchable via the version menu in the player.
- HDR content on SDR displays tone maps via mpv/libplacebo.

Known current limitations (why the plan exists):

1. **Runtime resizes do not reconfigure the MoltenVK swapchain.** The mpv
   `wid`+MoltenVK path freezes the rendered output at the size the VO was
   created with. Current workaround: after a resize settles (300 ms debounce)
   the player cycles `wid` through 0 → layer pointer, forcing mpv to rebuild
   the whole VO. This produces a ~0.3 s black flash on every resize/fullscreen
   transition. Verified by the headless smoke test
   (`AnimeGod -smokePlayerTest`, prints window/view/drawable sizes and
   auto-screenshots via `screencapture`).
2. **HDR plays through HDR→SDR tone mapping** (mpv default target). No EDR
   output yet — HDR looks washed out ("发灰") on the XDR display.
3. `dwidth/dheight` report the source-derived display size, **not** the VO
   output size — do not use them to verify swapchain size again.

## Hard-won constraints (do not re-learn these the hard way)

- **Never flip `CAMetalLayer.pixelFormat` / `colorspace` / `edrMetadata` while
  mpv is rendering.** MoltenVK created its swapchain against the initial
  format; flipping mid-flight produces black screens or garbage colors.
  (Verified: DoVi → black screen, SDR → noise.)
- **`target-colorspace-hint` must be set before `mpv_initialize`** (MPVKit demo
  comment: changing it at runtime "can cause player slow and hangs").
- **MPVKit 1.0.0 specifics**: `wid` on this build only accepts a CAMetalLayer
  pointer (passing an NSView aborts in `MVKSurface::initLayer` with
  `doesNotRecognizeSelector`); the OpenGL/mac context is **not** compiled in
  (upstream splits it into the `0.40.0-opengl` tag); 1.0.0 is the newest
  release, so no MPVKit bump is available to fix the resize hole.
- mpv ignores property writes that set the **same value** (the wid cycle must
  go through a different value, e.g. 0).
- The mpv wakeup callback must be typed as an explicit `@convention(c)`
  function pointer; otherwise Swift 6 infers MainActor isolation for the
  literal and `dispatch_assert_queue` traps on mpv's core thread (app crash).

## Phase 1 — Correct HDR10 / HLG end-to-end (first priority)

Goal: HDR10 and HLG play with EDR brightness and correct colors on HDR-capable
displays; correct HDR→SDR tone mapping on SDR displays. Priority: correct color
reproduction > hardware decoding > performance > feature completeness.

1. **EDR pipeline at renderer creation, not at runtime.**
   - Configure the Metal layer **before** `mpv_initialize`: `pixelFormat =
     .rgba16Float`, `colorspace = extendedLinearITUR_2020`,
     `wantsExtendedDynamicRangeContent = true`, `CAEDRMetadata` per format
     (HDR10: `CAEDRMetadata.hdr10(minLuminance: 0.5, maxLuminance: displayPeak,
     opticalOutputScale: 100)` — shader output 1.0 == 100 nit; HLG:
     `CAEDRMetadata.hlg`).
   - The layer configuration must be **constant for the whole session**; for
     SDR content, drive mpv's `target-prim=bt.709 + target-trc=bt.1886 +
     target-peak=100` so libplacebo renders into the same linear BT.2020
     target. mpv target options are runtime-safe; layer options are not.
   - Fallback validation: if MoltenVK cannot negotiate an rgba16Float
     swapchain, fall back to the current SDR path automatically and report
     it in the diagnostics panel.
2. **Eliminate (or keep behind a flag) the wid-cycle resize hack** once the
   constant-format layer is in place — verify whether MoltenVK now honors
   `VK_ERROR_OUT_OF_DATE_KHR` on resize; if not, keep the cycle as the
   fallback.
3. **HDR output decision logic** (already drafted in
   `PlayerState.reconfigureColorOutput`): signal is HDR ∧ display has EDR
   headroom ∧ not user-forced-SDR. Re-evaluate on screen change and
   `NSApplication.didChangeScreenParametersNotification`.
4. **Diagnostics panel additions**: live EDR headroom refresh, actual swapchain
   format, tone-mapping mode name, "Forced SDR" indicator.
5. **Validation matrix** (from the original spec): SDR Rec.709 8-bit, SDR 709
   10-bit, HDR10 HEVC Main10 BT.2020 PQ, HLG Main10, HDR-on-SDR-display,
   HDR-on-XDR-display. Manual pass + ⌘⇧D screenshots per case.

Reference for the Metal EDR contract (Apple sample):

```swift
metalLayer.wantsExtendedDynamicRangeContent = true
metalLayer.pixelFormat = .rgba16Float
metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
metalLayer.edrMetadata = CAEDRMetadata(minLuminance: 0.5,
                                       maxLuminance: 1000,
                                       opticalOutputScale: 100)
```

## Phase 2 — Apple-native Dolby Vision

Goal: when macOS can play a Dolby Vision file natively, let it.

1. Detect DV properly (not from filenames): inspect the container — MKV/MP4
   `dvvC`/`dvcC` box parsing (side-data) or, for MP4, AVFoundation's
   format descriptions. Store the detected profile in
   `VideoColorProfile.releaseHint` → `hdrFormat == .dolbyVision`.
2. Native-eligibility check (Apple's DV 8.4 conditions): `hvc1`, Main10,
   single video track, `dvvC`, BT.2020/HLG color metadata. If eligible →
   route through the native pipeline (Phase 1 EDR path or AVFoundation
   fallback player) and report mode `Dolby Vision native`.
3. Non-eligible DV with HDR10-compatible base layer → play base layer,
   report mode `Dolby Vision → HDR10 fallback`.
4. Never claim full support for Profile 7 / FEL (see Phase 4).

## Phase 3 — MKV Dolby Vision Profile 8 with fallback policy

1. Parse DV RPU availability from MPV (libplacebo processes P8 RPUs when the
   build supports it; verify at runtime, report honestly in diagnostics).
2. Update the version-default policy: when the display is EDR-capable and a
   file is DV-P8 with HDR10 base, prefer the DV file over the SDR file;
   otherwise keep the current SDR-first rule.
3. Diagnostics: report `Dolby Vision native` / `Dolby Vision → HDR10 fallback`
   / `HDR10` / `HLG` / `SDR` exactly — never generic "HDR".

## Phase 4 — Profile 7 / MEL / FEL (explicitly last, likely never)

- Blu-ray Profile 7 FEL requires reference-decoder-grade handling. Decision:
  **not supported**; fall back to the HDR10 base layer and say so in the
  diagnostics panel. Revisit only with a concrete user need.

## Regression gates (run after every phase)

- `swift test` — includes `VideoColorProfileTests` (classification rules,
  bit-depth mapping) and the rest of the 61-test suite.
- Headless smoke: `AnimeGod.app/Contents/MacOS/AnimeGod -smokePlayerTest`
  prints window/view/drawable sizes and captures windowed/fullscreen
  screenshots to `/tmp/ag_windowed.png` and `/tmp/ag_fullscreen.png`.
- `xcodegen generate` after adding files; `xcodebuild … build` must pass with
  Swift 6 strict concurrency.
- Deploy target: copy the built app to `/Applications` — **the user launches
  that copy**; stale duplicate installs have burned us before.
