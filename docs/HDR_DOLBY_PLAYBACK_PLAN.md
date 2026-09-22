# HDR / Dolby Vision Playback Plan

Status: **Complete (Phases 0–4)** — implemented 2026-09-11.
Owner: AnimeGod.

## Current state (as of this plan)

Rendering architecture: **libmpv embedded via `wid` = CAMetalLayer pointer**,
`vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=moltenkv` (MPVKit 1.0.0, mpv ≈0.41).

Already implemented:

- HDR detection from **decoded signal metadata** (mpv `video-params`) and real
  `dvvC`/`dvcC` configuration records, never from filenames:
  `VideoColorProfile.swift` and `DolbyVisionContainerProbe.swift`.
- Diagnostics overlay in the player (**⌘⇧D**): codec, pixel format, bit depth,
  primaries/transfer/matrix, HDR format, signal peak, hardware decoder,
  display name / EDR headroom / potential headroom, pipeline mode.
  **⌘⇧H** forces/unforces SDR without changing the live layer format.
- Version policy: alternative encodes merge into one episode; EDR displays
  prefer a detected DV Profile 8 version with a compatible base layer, while
  SDR displays retain the SDR-first default. The version menu remains available.
- HDR content on SDR displays tone maps via mpv/libplacebo.

Known current limitations (why the plan exists):

1. **MoltenVK swapchains do not resize in place.** Cycling `wid` through
   `0 → layer pointer` was removed because it could interrupt playback after
   the first frame. After a fullscreen transition completes, the player now
   rebuilds the mpv renderer against the final drawable size and restores the
   playback position, pause state, speed, volume, delays, and track selection.
   Validate windowed and fullscreen playback with the headless smoke test
   (`AnimeGod -smokePlayerTest`, which prints window/view/drawable sizes and
   captures screenshots).
2. The renderer starts with a constant 16-bit-float linear BT.2020 EDR layer.
   HDR10/HLG use EDR on capable displays; SDR displays and Forced SDR use
   explicit BT.709/BT.1886/100-nit targets. Initialization failure retries once
   with the BGRA8 SDR pipeline and reports that fallback.
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

Completion: **done**. Metal EDR is configured before mpv initialization;
HLG/HDR10 metadata changes rebuild between renderer sessions; headroom refreshes
live; diagnostics expose layer format, tone mapping, pipeline, and Forced SDR.

Goal: HDR10 and HLG play with EDR brightness and correct colors on HDR-capable
displays; correct HDR→SDR tone mapping on SDR displays. Priority: correct color
reproduction > hardware decoding > performance > feature completeness.

1. **EDR pipeline at renderer creation, not at runtime.**
   - Configure the Metal layer **before** `mpv_initialize`: `pixelFormat =
     .rgba16Float`, `colorspace = extendedLinearITUR_2020`,
     `wantsExtendedDynamicRangeContent = true`, `CAEDRMetadata` per format
     (HDR10: `CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: 1000,
     opticalOutputScale: 203)` — matching libplacebo's linear reference white; HLG:
     `CAEDRMetadata.hlg`).
   - The layer configuration must be **constant for the whole session**; for
     SDR content, drive mpv's `target-prim=bt.709 + target-trc=bt.1886 +
     target-peak=100` so libplacebo renders into the same linear BT.2020
     target. mpv target options are runtime-safe; layer options are not.
   - **The layer colorspace, `target-trc` and `target-colorspace-hint` must
     name the same transfer function.** Shipped as `extendedLinearITUR_2020`
     + `target-trc=linear` while the hint signalled PQ; linear light read as
     PQ code values is a fraction of a nit, so HDR played nearly black.
     Corrected 2026-09-22 to `itur_2100_PQ` + `target-trc=pq`.
   - **`CAMetalLayer.pixelFormat` is not ours to set.** MoltenVK replaces it
     when libplacebo creates the swapchain (`bgr10a2`), so the `rgba16Float`
     assignment described a surface that never existed. The diagnostics line
     prints the real format.
   - **HDR output cannot be judged from a window capture.**
     `CGWindowListCreateImage` does not represent an EDR layer faithfully.
     Use `AG_SMOKE_FORCE_SDR=1` to capture the same frame through the SDR
     path as a reference, and confirm on the display.
   - **`target-peak` is an integer option.** `String(1000.0)` is `"1000.0"`,
     which mpv rejects (`MPV_ERROR_OPTION_ERROR`) while carrying on with
     `auto` — and `auto` under `target-trc=linear` resolves to 203 nits, so
     every HDR file was tone mapped down by a factor of five before
     `CAEDRMetadata` mapped it back up. Fixed 2026-09-22 by writing an
     integer; `setOption`/`setString` now print and assert on any rejected
     value, because this failure is otherwise completely silent. The
     `-smokePlayerTest` color line prints `mpv.target-peak` — compare it
     against the source's `max-luma` when touching this path.
   - Fallback validation: if MoltenVK cannot negotiate an rgba16Float
     swapchain, fall back to the current SDR path automatically and report
     it in the diagnostics panel.
2. **Replace the fullscreen-only renderer rebuild with in-place resizing** if
   a future MPVKit/MoltenVK release reliably honors
   `VK_ERROR_OUT_OF_DATE_KHR`; do not reintroduce a runtime `wid` cycle.
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
metalLayer.edrMetadata = CAEDRMetadata(minLuminance: 0.005,
                                       maxLuminance: 1000,
                                       opticalOutputScale: 203)
```

## Phase 2 — Apple-native Dolby Vision

Completion: **done**. MP4/MOV uses AVFoundation only when a real `dvvC` record,
Profile 8.4, `hvc1`, Main10, a single video track, and BT.2020/HLG compatibility
agree. Other DV assets stay on mpv with an explicit HDR10-fallback mode.

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

Completion: **done**. mpv's decoded `dolby-vision-profile` and level properties
are runtime RPU evidence. MKV P8 remains on libplacebo/mpv; EDR displays prefer
a container-detected P8 compatible-base version; mode labels are exact.

1. Parse DV RPU availability from MPV (libplacebo processes P8 RPUs when the
   build supports it; verify at runtime, report honestly in diagnostics).
2. Update the version-default policy: when the display is EDR-capable and a
   file is DV-P8 with HDR10 base, prefer the DV file over the SDR file;
   otherwise keep the current SDR-first rule.
3. Diagnostics: report `Dolby Vision native` / `Dolby Vision → HDR10 fallback`
   / `HDR10` / `HLG` / `SDR` exactly — never generic "HDR".

## Phase 4 — Profile 7 / MEL / FEL (explicitly last, likely never)

Completion: **done by explicit non-support policy**.

- Blu-ray Profile 7 FEL requires reference-decoder-grade handling. Decision:
  **not supported**; fall back to the HDR10 base layer and say so in the
  diagnostics panel. Revisit only with a concrete user need.

## Regression gates (run after every phase)

- `swift test` — includes `VideoColorProfileTests` (classification rules,
  bit-depth mapping, dvcC/dvvC parsing, native eligibility) and the rest of the
  64-test suite.
- Headless smoke: `AnimeGod.app/Contents/MacOS/AnimeGod -smokePlayerTest`
  prints window/view/drawable sizes and captures windowed/fullscreen
  screenshots to `/tmp/ag_windowed.png` and `/tmp/ag_fullscreen.png`.
- `xcodegen generate` after adding files; `xcodebuild … build` must pass with
  Swift 6 strict concurrency.
- Deploy target: copy the built app to `/Applications` — **the user launches
  that copy**; stale duplicate installs have burned us before.

## Completion evidence (2026-09-11)

- `swift test`: 64 tests passed.
- `xcodegen generate`: succeeded.
- Swift 6 arm64 Debug build with MPVKit 1.0.0: succeeded.
- The headless windowed/fullscreen smoke writes `/tmp/ag_windowed.png` and
  `/tmp/ag_fullscreen.png`; it uses the drawable size, not `dwidth`/`dheight`,
  as host-surface evidence. Latest run preserved live playback at 1092/5649 s
  while resizing 2460×1628 → 3024×1898 pixels.
- Deterministic tests cover classification, box parsing, eligibility, and
  fallback policy. Final visual color judgment still requires the six mastered
  validation clips on the target SDR/XDR displays.
