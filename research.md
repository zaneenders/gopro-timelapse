# Deflicker research and architecture notes

## Findings from the current implementation

1. The UI's original baseline was a moving median followed by triangular smoothing. It generated a dense correction independently for every frame. That is useful for removing isolated flicker, but its fixed 15–121-frame window behaves very differently for short and long sequences.
2. The original implementation lived under `GoProTimelapseUI`, while the CLI had a separate ramp and renderer. This made the UI a second application rather than a frontend for the same engine.
3. Frame zero was present in analysis, but endpoint fitting could effectively ignore an anomalous first frame: a local fit has no samples to its left, and an endpoint outlier can obtain excessive leverage. A regression test now requires frame zero to receive a correction.
4. The green/magenta flashes have a concrete renderer-level cause. `LibrawGrade.exposure` is documented and used as EV stops, but the `swift-libraw` bridge assigns it directly to LibRaw's `exp_shift`. LibRaw documents `exp_shift` as a **linear multiplier** from 0.25 through 8.0. It must receive `pow(2, EV)`. Negative automatic EV values were therefore invalid, and positive values below 1 darkened rather than brightened. This can produce clipping and unstable color, so smoothing alone cannot fix it.
5. Analysis currently prefers paired camera JPEGs while final rendering develops GPR RAW. A JPEG can include per-frame GoPro white balance, tone mapping, sharpening, and noise reduction. Measuring JPEGs and correcting a different RAW rendering pipeline introduces model mismatch.
6. The UI's automatic correction adjusts exposure only; it does not intentionally animate tint. Therefore alternating hue is not evidence that the luminance estimator should generate a color ramp. The exposure-unit renderer bug and per-frame camera white balance are the first places to fix.

## Recommended algorithm

Use two time scales instead of correcting one adjacent-frame difference at a time:

1. Decode every analysis frame with fixed development settings. For production-quality RAW correction, analyze fixed-WB RAW proxies; paired JPEGs should be an explicitly labelled fast approximation.
2. Measure robust log luminance in a stable region and retain clipping/confidence information.
3. Hampel-filter the measured signal to replace isolated outliers for **baseline fitting only**. Keep the original measurement for residual calculation.
4. Fit the intended long-term trend with robust LOESS. Express its span as a percentage of total frames (default 10%) or capture time when timestamps become available. This matches the proposed percentage approach while preserving smooth sunrise/sunset movement.
5. Calculate dense residuals as `baseline - measured`. Dense residuals are still needed to remove true frame-level flicker; do not replace them with a sparse creative ramp.
6. Do not smooth the residual by default: alternating frame flicker requires an alternating correction. Cap it to ±0.5 EV, constrain extreme adjacent changes to 0.25 EV, and prevent positive correction on clipped frames.
7. Keep generated deflicker, camera exposure-step compensation, and creative grading as separate additive curves.

Percentage ramping belongs in the **baseline and correction smoothing spans**, not in dropping most measurements or interpolating corrections from arbitrary percentage keyframes. Sampling only every N% risks missing one-frame flicker—the defect the pass is intended to remove.

## Architecture direction

The package should have one reusable engine:

```text
GoProTimelapseCore
  sequence scanning
  fixed analysis proxy decoding
  luminance analysis
  robust baseline/deflicker curves
  grade/ramp composition
  RAW/photo rendering
  ffmpeg encoding
  progress/events

GoProTimelapse (CLI)
  argument parsing and text progress only

GoProTimelapseUI
  state and Chroma widgets only; calls Core operations
```

The first refactor in this branch moves grading and automatic correction into `GoProTimelapseCore`, which both CLI and UI targets depend upon. Rendering and sequence discovery remain duplicated and should be migrated next without changing output behavior.

## Validation required before tuning defaults

Create fixtures for:

- Constant scene with random ±0.1 EV flicker.
- Smooth multi-stop sunset/sunrise plus flicker.
- First-frame and last-frame outliers.
- ISO/shutter steps with metadata.
- Clipped headlights, moon, or sun.
- Dark high-ISO GoPro frames prone to green/magenta channel clipping.

For each fixture compare residual energy, preservation of the long-term slope, endpoint behavior, clipping, and channel chromaticity—not only the visual brightness curve.
