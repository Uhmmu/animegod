# Video Quality and Fullscreen Scaling Plan

Status: **Planning only — not implemented**

This document defines future work for improving AnimeGod's perceived and
measurable playback quality. It is a read-only specification: none of the
changes below are implemented by this plan.

The source encode is explicitly outside scope. The goal is to preserve as much
of the source as possible through decode, scaling, color conversion, display
composition, and motion presentation.

## 1. Current conclusion

Entering fullscreen should not introduce an additional permanent low-resolution
stretch in the current mpv path. `MPVPlayerController.updateSurface()` sets the
Metal drawable size to the view bounds multiplied by the destination screen's
backing scale, and the renderer is rebuilt after the fullscreen transition.

Fullscreen can still look softer than a window because a lower-resolution
source is enlarged over more physical pixels and a larger visual angle. It can
also expose weaknesses elsewhere in the pipeline:

- the selected spatial scaler and chroma reconstruction;
- stale drawable dimensions after moving between screens with different scale
  factors;
- HDR tone mapping that targets theoretical rather than currently available
  display headroom;
- disagreement between mpv's target color space and the Metal layer's declared
  color space;
- cached danmaku bitmaps surviving a viewport or backing-scale change;
- frame cadence mismatch between the video and the display.

These cases must be distinguished before any visual difference is described as
"fullscreen quality loss."

## 2. Scope

### In scope

- Windowed, resized, fullscreen, and cross-display drawable resolution.
- mpv/libplacebo luma scaling, chroma scaling, downscaling, anti-ringing,
  debanding, and dithering policy.
- SDR, HDR10, HLG, Dolby Vision fallback, and Apple-native Dolby Vision output.
- Current and potential EDR headroom handling.
- Display cadence, frame drops, and motion clarity.
- Subtitle, danmaku, and artwork raster quality where application code controls
  it.
- Diagnostics and repeatable visual/performance validation.

### Out of scope

- Re-encoding, replacing, or downloading better video sources.
- Claiming support for Dolby Vision Profile 7 FEL/MEL enhancement layers.
- Making Anime4K, AI super-resolution, sharpening, or frame generation the
  default presentation.
- Changing the media library, metadata, matching, watch history, or translation
  systems.
- Replacing mpv/MPVKit unless measurements prove the existing renderer cannot
  satisfy a required acceptance criterion.

## 3. Non-negotiable renderer constraints

Future implementation must preserve the constraints already established by the
HDR/Dolby Vision work:

1. Do not change `CAMetalLayer.pixelFormat`, `colorspace`, or `edrMetadata`
   while mpv is rendering into the active MoltenVK swapchain.
2. Do not reintroduce the runtime `wid = 0 -> layer` cycle.
3. Configure `target-colorspace-hint` before `mpv_initialize`.
4. Continue passing a `CAMetalLayer` pointer as `wid` for MPVKit 1.0.0.
5. Preserve the Apple-native `AVPlayer` + `AVPlayerLayer` path for eligible
   Dolby Vision Profile 8.4 MP4/MOV assets.
6. Prefer correct color reproduction over filters that merely appear sharper.
7. Every quality setting must have an explicit performance and artifact budget.

## 4. Risks found in the current code

### R1 — Cross-display backing scale can become stale

`updateSurface()` reacts to layout/frame changes and fullscreen completion. The
display observers currently re-evaluate HDR capability but do not explicitly
refresh the Metal surface when only the window's backing scale changes.

Possible result: moving an unchanged-size window from a 1x display to a 2x
display can temporarily retain a lower-resolution drawable until another resize
or fullscreen transition occurs.

### R2 — Resolved: one system-owned display mapping

The player reads both
`maximumExtendedDynamicRangeColorComponentValue` and
`maximumPotentialExtendedDynamicRangeColorComponentValue`. Potential headroom
decides EDR eligibility only. mpv maps HDR into a 1000-nit linear mastering
range, while `CAEDRMetadata` performs the single final adaptation to the
display's current headroom. The diagnostics panel reports the mpv target.

The linear buffer and `CAEDRMetadata` share a 203-nit optical reference white,
matching libplacebo's linear-light convention. This avoids first compressing
Dolby/HDR to 100 nits and then asking Core Animation to tone map it again.

### R3 — Output color contracts need end-to-end verification

The normal Metal surface is declared as 16-bit-float extended-linear BT.2020.
HDR output requests linear BT.2020 from mpv, which is conceptually aligned. SDR
output currently requests BT.709/BT.1886 while retaining that linear BT.2020
layer. The 8-bit fallback layer is declared sRGB while mpv is also asked for a
BT.1886 target.

MoltenVK and `target-colorspace-hint` negotiation may alter the effective
result, so this plan does not label the current behavior a confirmed color bug.
Implementation must inspect the actual negotiated output and make the mpv
target primaries/transfer agree with the layer/swapchain contract.

### R4 — EDR metadata peak is fixed

HDR10 `CAEDRMetadata` currently uses a fixed 1000-nit maximum while mpv's
`target-peak` is derived separately. On a display or operating condition whose
available range differs from 1000 nits, the two descriptions can diverge.

### R5 — Spatial quality is mostly implicit

The app selects `vo=gpu-next` but does not define an application-owned quality
profile. The bundled mpv defaults are reasonable, but changes in dependency
defaults could silently change AnimeGod's output, and the current settings do
not deliberately optimize animation line art and gradients.

### R6 — Active danmaku bitmaps can be stretched after fullscreen

The danmaku rasterizer invalidates its bitmap cache when font metrics or backing
scale changes. Existing comment layers are reused without replacing their
`contents`, so comments already on screen may retain the old bitmap and be
scaled to the new fullscreen geometry. Newly created comments use the new
resolution.

### R7 — Motion quality is not observable enough

The current diagnostics expose codec, pixel format, HDR information, layer
format, and pipeline name, but not source dimensions, scale ratio, active
scalers, display refresh rate, video frame rate, or dropped/repeated frames.
Spatial softness and cadence judder therefore cannot be separated quickly.

## 5. Phased implementation

Each phase must remain a separate scoped change. Do not begin a later phase
until the earlier phase's acceptance gate passes.

### Phase 0 — Establish measurable baselines

Goal: make every later comparison attributable to one pipeline change.

Work:

- Extend diagnostics with:
  - source coded and display dimensions;
  - view size in points;
  - backing scale factor;
  - Metal drawable size in pixels;
  - source-to-output scale ratio;
  - active `scale`, `cscale`, `dscale`, deband, and dither values;
  - source and target primaries/transfer functions;
  - current and potential EDR headroom;
  - source FPS, display FPS, dropped frames, and repeated frames.
- Extend the smoke output so windowed/fullscreen comparisons record the same
  values.
- Create a small, legally redistributable validation set or local-only manifest
  covering:
  - SDR BT.709 8-bit and 10-bit;
  - 720p, 1080p, and 2160p animation line art;
  - fine texture and high-frequency patterns;
  - dark gradients prone to banding;
  - HDR10 PQ and HLG;
  - eligible Dolby Vision Profile 8.4;
  - 23.976, 24, 25, 30, and 60 fps cadence.
- Capture matched frames without controls or danmaku at identical timestamps.
  Screen captures are supporting evidence, not a replacement for on-device
  visual inspection.

Acceptance gate:

- Diagnostics distinguish source size from drawable size.
- Repeated baseline runs report stable dimensions and active renderer settings.
- No quality option is changed in this phase.

### Phase 1 — Make fullscreen and cross-display resolution exact

Goal: ensure every steady-state drawable matches the destination display's
physical pixel grid.

Work:

- Handle backing-property changes in addition to frame and screen changes.
- Recompute `contentsScale` and `drawableSize` after a cross-display move even
  when the view's point dimensions do not change.
- Rebuild the MoltenVK renderer only when required by a final, stable surface;
  coalesce fullscreen/backing notifications to prevent duplicate rebuilds.
- Keep the AVPlayerLayer path sized by bounds and managed by AVFoundation.
- Preserve position, pause, speed, volume, delays, and selected tracks across
  every required mpv rebuild.
- Add regression coverage for 1x -> 2x, 2x -> 1x, windowed -> fullscreen,
  fullscreen -> windowed, and fullscreen on a secondary display.

Acceptance gate:

- In every steady state, `drawableSize == bounds * backingScaleFactor`.
- The renderer's actual output surface equals the recorded drawable size.
- No second scaling pass is visible or reported after a transition completes.
- Playback does not freeze, restart from the wrong position, or rebuild twice.

### Phase 2 — Align SDR/HDR color output and live EDR headroom

Goal: make the declared surface, rendered pixels, and display mapping describe
the same color space and luminance range.

Work:

- Separate display capability from live rendering capacity:
  - potential headroom decides HDR eligibility;
  - Core Animation adapts the mastering range to current display headroom.
- Clamp and smooth noisy headroom updates so minor changes do not cause visible
  pumping or repeated renderer rebuilds.
- Define an explicit output contract for each path:
  - mpv EDR HDR10/HLG;
  - mpv SDR content on the float EDR surface;
  - mpv forced-SDR output;
  - BGRA8 SDR fallback;
  - Apple-native Dolby Vision.
- Align mpv target primaries/TRC, swapchain signaling, `CAMetalLayer.colorspace`,
  and EDR metadata for each contract.
- Derive HDR10 metadata peak from the chosen output contract rather than a
  universal 1000-nit constant. Change layer metadata only between renderer
  sessions.
- Record actual output parameters in diagnostics instead of reporting only the
  intended mode.

Acceptance gate:

- Neutral SDR gray ramps show no unexpected gamma shift between the float and
  BGRA8 fallback paths.
- SDR color appearance is stable between windowed and fullscreen modes.
- HDR highlights roll off without obvious clipping when current headroom falls.
- HDR10, HLG, forced SDR, and Dolby Vision diagnostics match the visible path.
- Tests cover headroom clamping and the output-decision matrix.

### Phase 3 — Introduce conservative quality presets

Goal: improve fullscreen scaling and gradients while preserving source intent
and predictable performance.

Work:

- Add application-owned presets rather than depending entirely on mpv defaults:
  - **Balanced**: dependable default for all supported Macs;
  - **High Quality**: stronger scaling/anti-ringing for Apple Silicon;
  - **Source-faithful**: minimal enhancement for comparison and diagnosis.
- Start High Quality evaluation with mpv's maintained high-quality profile or
  its explicit equivalent, including `ewa_lanczossharp` and conservative
  anti-ringing.
- Evaluate chroma scaling independently using saturated animation edges and
  subtitle-like colored line art.
- Evaluate debanding on dark gradients. Keep it reversible because excessive
  thresholds can remove real fine detail.
- Preserve correct downscaling and sigmoid upscaling unless measurements show a
  regression.
- Keep dithering appropriate to the actual output bit depth; do not hard-code
  8-bit dithering into a float EDR path.
- Do not enable global unsharp masking.

Acceptance gate:

- 720p/1080p fullscreen line art is visibly cleaner than Balanced without
  objectionable halos or ringing.
- Gradient banding improves without erasing intentional grain or texture.
- 4K playback remains within the frame-time budget on the minimum supported
  Apple Silicon tier.
- A preset can be changed without corrupting the active color pipeline.

### Phase 4 — Improve motion presentation separately from sharpness

Goal: reduce cadence judder and dropped frames without inventing motion.

Work:

- Measure default audio-synced playback before changing synchronization.
- Evaluate display-resample behavior for common anime frame rates on 60 Hz and
  ProMotion displays.
- Keep temporal interpolation off by default unless a dedicated opt-in mode is
  justified. Frame blending can reduce judder but can also soften motion and
  create ghosting.
- Detect interlaced content and provide an automatic or explicit deinterlace
  path; do not deinterlace progressive sources.
- Report dropped/repeated frames and renderer frame time in diagnostics.

Acceptance gate:

- 23.976/24 fps playback has stable cadence for the selected policy.
- No sustained frame dropping occurs in Balanced or High Quality modes.
- Progressive anime is never accidentally deinterlaced.
- Motion enhancement, if retained, is clearly optional and reversible.

### Phase 5 — Fix overlay and artwork raster quality

Goal: keep non-video visuals crisp without altering video pixels.

Work:

- Re-rasterize and reassign the contents of every active danmaku layer when
  line height or backing scale changes.
- Preserve bitmap caching, but include all raster-affecting parameters in the
  cache key.
- Verify fractional-position filtering for moving comments; prefer smooth
  motion over forced integer snapping that causes jitter.
- Record danmaku raster scale in diagnostics.
- For posters, preserve original cached bytes and add decode/downsample policy
  based on the final rendered pixel size. Never upscale a thumbnail and label it
  as a higher-quality asset.

Acceptance gate:

- A comment visible during fullscreen entry becomes as sharp as a newly emitted
  comment at the same size.
- Moving between 1x and 2x displays refreshes all active comment bitmaps.
- Overlay layers do not disable or flatten EDR video beneath them.
- Poster decoding reduces memory without producing a lower-resolution render
  than the destination view requires.

### Phase 6 — Optional advanced enhancement experiments

Goal: test enhancements that deliberately depart from strict source fidelity
without making them the default.

Candidates:

- Anime-oriented shader upscaling for low-resolution sources.
- Mild, resolution-aware sharpening after scaling.
- Core ML or platform super-resolution only if it can be integrated without
  breaking HDR metadata, playback latency, or LGPL boundaries.

Rules:

- These modes must be labeled as enhancement, not restoration.
- Side-by-side and pixel-peep testing must cover halos, ringing, stair-stepping,
  texture invention, subtitle damage, and GPU cost.
- Disable automatically when the renderer cannot maintain frame rate.
- Never process the Apple-native Dolby Vision path unless Apple explicitly
  supports the required pixel transformation while preserving metadata.

Acceptance gate:

- Enhancement is opt-in and can be disabled instantly.
- It never changes the baseline Balanced or Source-faithful output.
- Diagnostics disclose the active shader/model and render cost.

## 6. Validation matrix

Every implementation phase that changes rendering must test at least:

| Dimension | Cases |
| --- | --- |
| Window state | windowed, live resize, fullscreen, exit fullscreen |
| Display | built-in Retina, external 1x/2x where available, SDR, EDR/XDR |
| Resolution | 720p, 1080p, 2160p, exact 1:1 mapping |
| Color | SDR 8-bit, SDR 10-bit, HDR10, HLG, forced SDR, DV 8.4 |
| Cadence | 23.976, 24, 25, 30, 60 fps |
| Overlay | no overlay, controls visible, active danmaku |
| Performance | paused, normal playback, seek, episode switch |

For each case record:

- source and drawable dimensions;
- backing scale and scale ratio;
- source/output color metadata;
- current/potential EDR headroom;
- active quality preset and filters;
- renderer FPS, dropped/repeated frames, and GPU/frame-time observations;
- matched screenshots plus a short on-device visual judgment.

## 7. Definition of done

The full plan is complete only when:

1. Fullscreen and cross-display steady states always render at the correct
   drawable pixel size.
2. SDR and HDR color contracts are explicit, observable, and validated on their
   target displays.
3. Live HDR tone mapping respects current display headroom without brightness
   pumping.
4. High Quality improves scaling and gradients without unacceptable artifacts
   or dropped frames.
5. Existing danmaku remains sharp through fullscreen and scale transitions.
6. Motion quality is measured independently from spatial sharpness.
7. All unit tests, the macOS build, the fullscreen smoke test, and the complete
   visual matrix pass.
8. Documentation and release notes state exactly which enhancements are
   faithful rendering and which are optional reconstruction.

## 8. Recommended implementation order

Implement Phases 0 through 5 in order. Phase 6 is optional and should be
considered only after the faithful playback pipeline is demonstrably correct.
