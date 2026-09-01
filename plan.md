# GoPro Timelapse: Analysis and Automatic Exposure Correction Plan

This plan covers the first two priorities for moving GoPro Timelapse toward an LRTimelapse-style workflow:

1. Cached per-frame luminance and exposure analysis
2. Holy Grail exposure compensation and robust visual deflicker

The plan deliberately starts with reusable, testable core components and CLI workflows. A visual timeline editor can consume the same project data later without requiring the analysis and correction engines to be rewritten.

## Goals

- Analyze a sequence once and reuse the results across previews and renders.
- Distinguish intentional long-term brightness changes from camera exposure steps and frame-to-frame flicker.
- Generate non-destructive exposure correction curves that can be inspected, adjusted, disabled, and regenerated.
- Keep source GPR, DNG, and rendered image files read-only.
- Make all automatic decisions reproducible and record their parameters in a versioned project file.
- Support both GPR RAW sequences and rendered photo sequences where practical.

## Non-goals for this phase

- A full SwiftUI timeline editor
- Lightroom/XMP round-tripping
- Local masks or subject-aware grading
- Optical-flow motion blur or stabilization
- Exact matching of Adobe Camera Raw rendering
- Real-time full-resolution playback

---

# 1. Cached Per-frame Luminance and Exposure Analysis

## 1.1 Refactor the package around a reusable core

Move sequence discovery, metadata, analysis, curves, and correction logic out of `main.swift` into a library target.

Proposed package structure:

```text
Sources/
  GoProTimelapseCore/
    Project/
      Project.swift
      ProjectStore.swift
      ProjectMigration.swift
    Sequence/
      SequenceScanner.swift
      SourceFrame.swift
      FrameMetadata.swift
    Analysis/
      AnalysisEngine.swift
      AnalysisMetrics.swift
      AnalysisRegion.swift
      ProxyGenerator.swift
      LuminanceAnalyzer.swift
    Curves/
      Curve.swift
      CurvePoint.swift
      CurveInterpolation.swift
    Correction/
      ExposureTransitionDetector.swift
      HolyGrailCorrector.swift
      DeflickerEngine.swift
    RAW/
      RAWRenderer.swift
    Rendering/
      RenderPipeline.swift
      FFmpegEncoder.swift
  GoProTimelapseCLI/
    main.swift
Tests/
  GoProTimelapseCoreTests/
```

Initial refactoring should preserve the current `gopro-timelapse` command and behavior. The executable target should depend on `GoProTimelapseCore`.

## 1.2 Introduce a versioned project format

Use a project directory so large generated data does not need to live in one JSON document.

Suggested layout:

```text
my-sequence.gptl/
  project.json
  analysis.json
  thumbnails/
  proxies/
  cache/
```

SQLite can replace `analysis.json` if sequences become large or query performance becomes important. JSON is acceptable for the first implementation because a typical GoPro sequence contains a manageable number of records and JSON is easy to inspect while the schema evolves.

`project.json` should contain:

```json
{
  "schemaVersion": 1,
  "sourceDirectory": "/absolute/path/to/sequence",
  "sourceMode": "gpr",
  "createdAt": "2026-09-01T12:00:00Z",
  "updatedAt": "2026-09-01T12:00:00Z",
  "analysisSettings": {
    "proxyLongEdge": 640,
    "region": { "kind": "center", "width": 0.7, "height": 0.7 },
    "ignoreClippedPixels": true
  },
  "curves": {
    "creativeExposure": [],
    "cameraStepCorrection": [],
    "deflickerExposure": []
  }
}
```

Requirements:

- Include a `schemaVersion` in every persisted top-level format.
- Write files atomically using a temporary file followed by rename.
- Preserve analysis and generated corrections until their inputs or settings change.
- Store paths relative to the project when possible; retain a source directory reference separately.
- Add migration hooks before the second schema version is needed.

## 1.3 Define sequence and frame identities

Each source frame needs a stable identity so cached analysis can be reused safely.

```swift
struct SourceFingerprint: Codable, Equatable, Sendable {
  var relativePath: String
  var byteCount: Int64
  var modificationTime: Date
  var contentSampleHash: String
}

struct SourceFrame: Codable, Identifiable, Sendable {
  var id: String
  var index: Int
  var source: SourceFingerprint
  var metadata: FrameMetadata
}
```

Use a fast content sample hash over the beginning and end of the file in addition to file size and modification time. A full cryptographic hash of every large RAW file is unnecessary during normal scans, but can be made available as a strict verification option.

On every project open:

1. Scan supported source files using natural filename ordering.
2. Compare fingerprints with the stored sequence.
3. Preserve cached records for unchanged frames.
4. Reanalyze changed or added frames.
5. Flag missing or reordered frames.
6. Invalidate generated correction curves if the sequence layout changed.

## 1.4 Extract capture metadata

Capture metadata should be collected before pixel analysis. Prefer metadata embedded in the GPR/DNG source; use ImageIO or an EXIF library for rendered photos.

Store at least:

```swift
struct FrameMetadata: Codable, Equatable, Sendable {
  var captureDate: Date?
  var intervalFromPreviousSeconds: Double?
  var shutterSeconds: Double?
  var aperture: Double?
  var iso: Double?
  var exposureBiasEV: Double?
  var focalLengthMM: Double?
  var orientation: Int?
  var width: Int?
  var height: Int?
  var cameraMake: String?
  var cameraModel: String?
  var exposureValue: Double?
}
```

Calculate a consistent camera exposure value when the required fields exist:

```text
cameraEV = log2(aperture² / shutterSeconds) - log2(ISO / 100)
```

The sign convention must be documented. In this plan, a lower camera EV means the camera captured more light. Correction code should use named conversion functions rather than duplicating sign inversions.

Also calculate and report:

- Missing or duplicate capture timestamps
- Unexpected capture intervals
- Changes in image dimensions or orientation
- Missing frames inferred from filename or timestamp gaps
- Abrupt shutter, ISO, aperture, or exposure-bias changes

Metadata absence must not prevent luminance analysis. It should reduce the confidence of camera-step detection later.

## 1.5 Generate analysis proxies

Analyze small proxies rather than full-resolution images.

Default proxy policy:

- 640 pixels on the long edge
- Preserve aspect ratio and orientation
- Use linear-light RGB where the decoder permits it
- Use fixed development settings across the entire sequence
- Disable per-image auto-brightness, automatic white balance, and other adaptive processing
- Store a versioned proxy-generation signature with every result

For GPR sources:

1. Reuse a cached DNG if available, otherwise convert GPR to DNG.
2. Develop a low-resolution RGB proxy with LibRaw.
3. Ensure LibRaw automatic brightness is disabled.
4. Keep development settings identical for every frame.

For JPEG, TIFF, and PNG sources:

1. Decode with ImageIO/Core Graphics.
2. Normalize orientation.
3. Convert into the defined analysis color space.
4. Convert transfer-encoded values to linear light before luminance calculations.

The proxy cache key must include:

- Source fingerprint
- Proxy dimensions
- Decoder/developer version
- Analysis color-space version
- RAW development settings
- Orientation handling version

Changing only video codec, output dimensions, or ffmpeg settings must not invalidate analysis proxies.

## 1.6 Calculate luminance metrics

Calculate luminance from linear RGB using documented coefficients, initially Rec.709/sRGB primaries:

```text
Y = 0.2126 R + 0.7152 G + 0.0722 B
logY = log2(max(Y, epsilon))
```

Record robust metrics rather than relying on one average:

```swift
struct AnalysisMetrics: Codable, Equatable, Sendable {
  var logAverageLuminance: Double
  var medianLogLuminance: Double
  var percentile01: Double
  var percentile05: Double
  var percentile25: Double
  var percentile50: Double
  var percentile75: Double
  var percentile95: Double
  var percentile99: Double
  var clippedShadowFraction: Double
  var clippedHighlightFraction: Double
  var meanRed: Double
  var meanGreen: Double
  var meanBlue: Double
  var adjacentDifference: Double?
  var analysisConfidence: Double
}
```

Use median or a trimmed mean of log luminance as the default exposure signal. Log-space values are preferable because exposure corrections are measured in stops.

The analyzer should support these regions:

- Entire frame
- Center-weighted rectangle
- User-defined normalized rectangle
- Optional bitmap mask in a later iteration

Default to a centered region covering approximately 70% of width and height. This reduces the influence of dark borders, lens artifacts, and subjects entering at the edges.

Outlier handling:

- Optionally exclude nearly black and clipped pixels.
- Record the excluded fraction.
- Reduce confidence when too few valid pixels remain.
- Detect frames whose histogram or adjacent-frame difference suggests a scene cut, obstruction, or corrupt image.

## 1.7 Cache analysis records

Each frame's analysis record should include all inputs needed to decide whether it remains valid:

```swift
struct FrameAnalysisRecord: Codable, Identifiable, Sendable {
  var id: String
  var frameIndex: Int
  var sourceFingerprint: SourceFingerprint
  var metadata: FrameMetadata
  var metrics: AnalysisMetrics
  var analysisSignature: String
  var analyzedAt: Date
  var warnings: [String]
}
```

Caching behavior:

- Skip unchanged frames with a matching analysis signature.
- Reanalyze only invalid records.
- Show cache hit/miss counts.
- Permit `--force` to rebuild all records.
- Permit `--clear-cache` to remove generated data without touching project settings.
- Keep proxy cache cleanup separate from analysis result cleanup.

## 1.8 Add analysis CLI commands

Proposed commands:

```sh
# Create or update a project and analyze the sequence
gopro-timelapse analyze /path/to/photos \
  --project /path/to/sequence.gptl \
  --source gpr

# Reanalyze with a center region
gopro-timelapse analyze sequence.gptl \
  --region center:0.7x0.7

# Force regeneration
gopro-timelapse analyze sequence.gptl --force

# Print project and sequence diagnostics
gopro-timelapse inspect sequence.gptl

# Export data for plotting or external inspection
gopro-timelapse export-analysis sequence.gptl \
  --format csv \
  --output analysis.csv
```

The current one-shot render syntax should remain supported. Rendering a folder without a project can create a temporary in-memory project, while automatic correction features should require or strongly recommend a persistent project.

Analysis progress should include:

- Metadata scan progress
- Proxy generation progress
- Luminance analysis progress
- Cache hit count
- Warnings and confidence summary
- Total elapsed time

## 1.9 Analysis acceptance criteria

Analysis milestone is complete when:

- A GPR sequence can be analyzed without modifying source files.
- Every frame has a stable index, fingerprint, metadata record, and luminance metrics.
- A second identical analysis run uses cached results and is substantially faster.
- Changing one source file invalidates only that frame and dependent adjacent metrics.
- Changing the analysis region invalidates all luminance metrics but not unrelated source metadata.
- CSV export includes frame index, filename, timestamp, ISO, shutter, aperture, camera EV, median log luminance, clipping fractions, and confidence.
- Synthetic exposure changes produce measured luminance differences within a documented tolerance.
- Missing metadata and corrupt frames produce actionable warnings rather than crashes.

---

# 2. Holy Grail Compensation and Robust Visual Deflicker

## 2.1 Keep correction components separate

Do not bake all corrections into the existing `Grade.exposure` value. Store separate additive curves in stops:

```text
finalExposure(frame) =
    creativeExposure(frame)
  + cameraStepCorrection(frame)
  + deflickerExposure(frame)
```

Definitions:

- `creativeExposure`: user-authored long-term grading intent.
- `cameraStepCorrection`: generated compensation for ISO, shutter, aperture, or exposure-bias transitions.
- `deflickerExposure`: generated residual correction based on visual luminance measurements.

Each generated curve should store:

- Generator type and version
- Generation timestamp
- Frame range
- Algorithm parameters
- Input analysis signature
- Confidence summary
- Whether the curve is enabled

This separation lets users regenerate deflicker without losing a creative ramp and inspect which stage contributed a correction.

## 2.2 Create a general curve model

Replace or adapt the current ramp model so correction curves can contain dense or sparse points.

```swift
enum CurveInterpolation: String, Codable, Sendable {
  case hold
  case linear
  case smoothstep
  case monotonicCubic
}

struct CurvePoint: Codable, Identifiable, Sendable {
  var id: UUID
  var frame: Int
  var value: Double
  var confidence: Double?
}

struct ExposureCurve: Codable, Sendable {
  var interpolation: CurveInterpolation
  var points: [CurvePoint]
  var enabled: Bool
}
```

Requirements:

- Reject duplicate frame positions unless explicitly merged.
- Reject non-finite values.
- Clamp or warn about points outside the sequence.
- Use monotonic interpolation for long transitions where overshoot would be harmful.
- Support dense per-frame corrections without forcing thousands of editable keyframes into the creative curve.
- Provide curve composition, sampling, simplification, and range-limiting utilities.

## 2.3 Normalize the measured luminance signal

Before detecting exposure steps or flicker, construct a reliable measured signal:

1. Start with median or trimmed mean log luminance.
2. Mark low-confidence, corrupt, or heavily clipped frames as invalid.
3. Fill short invalid gaps by interpolation only for algorithm input; retain warning flags.
4. Optionally compensate for known camera exposure changes to estimate scene brightness.
5. Apply robust outlier rejection using a Hampel filter or median absolute deviation.
6. Preserve both raw and cleaned signals for inspection.

All brightness-domain calculations should be in stops/log2 units so correction values map directly to exposure adjustments.

## 2.4 Detect camera exposure transitions

Identify changes in shutter speed, ISO, aperture, and exposure bias from metadata.

For each frame transition, calculate expected captured-light change. With aperture `N`, shutter `t`, and ISO `S`, define a light-gathering signal using one consistent convention, for example:

```text
captureExposureStops = log2(t) + log2(S / 100) - 2 * log2(N)
```

Then:

```text
metadataStep[i] = captureExposureStops[i] - captureExposureStops[i - 1]
```

A positive value indicates a nominally brighter capture. Test this sign convention explicitly.

Classify transitions:

- No metadata change
- Expected small step
- Large camera mode change
- Metadata unavailable
- Metadata change not confirmed visually
- Visual step not explained by metadata

Compare each predicted metadata step with local measured luminance on both sides. Use a short robust window rather than adjacent frames alone. Produce a confidence score based on:

- Completeness of metadata
- Agreement between expected and observed direction
- Agreement between expected and observed magnitude
- Local scene stability
- Clipping level
- Adjacent-frame image difference

Do not automatically apply low-confidence large corrections. Report them for review or cap them according to configured limits.

## 2.5 Generate Holy Grail camera-step compensation

The Holy Grail corrector should remove discrete camera setting jumps while preserving the scene's long-term brightness transition.

Initial algorithm:

1. Select a frame range, defaulting to the full sequence.
2. Build `captureExposureStops` from metadata.
3. Detect discrete setting changes and group rapid multi-setting changes into one transition event.
4. Estimate the visual step around each event using robust pre/post windows.
5. Blend metadata prediction and visual estimate according to confidence.
6. Accumulate the inverse of accepted steps into `cameraStepCorrection`.
7. Anchor the curve at zero at the first selected frame, unless the user chooses another anchor.
8. Optionally taper correction outside the selected range.
9. Limit maximum single-step and total correction according to explicit parameters.

The generated result should be piecewise constant or use short transition ramps. A configurable transition width of 0–3 frames can avoid abrupt correction boundaries when RAW development or camera metadata applies changes gradually.

Suggested options:

```sh
gopro-timelapse holy-grail sequence.gptl \
  --range 0...1800 \
  --anchor first \
  --transition-width 1 \
  --max-step 1.5 \
  --min-confidence 0.65
```

The command should print an event table:

```text
Frame  Setting change       Predicted  Observed  Applied  Confidence
421    ISO 100 -> 200        +1.00 EV   +0.93 EV  -0.96 EV 0.94
817    1/30s -> 1/15s        +1.00 EV   +0.72 EV  -0.84 EV 0.73
```

Sign conventions in user-facing output must clearly state whether a value describes the capture change or the correction being applied.

## 2.6 Estimate the intended luminance baseline

After camera-step compensation, estimate the smooth long-term scene brightness curve. This baseline must preserve sunrise/sunset transitions rather than flattening the entire sequence.

Start with a robust local regression implementation:

- LOESS with robust reweighting, or
- A smoothing spline with outlier-resistant weights

A Savitzky–Golay filter can be offered as a fast alternative, but robust LOESS is a better default for uneven or contaminated data.

Inputs:

```text
correctedMeasured[i] = measuredLogLuminance[i] + cameraStepCorrection[i]
```

Baseline parameters:

- Smoothing window in frames or seconds
- Robust iteration count
- Maximum residual accepted as normal flicker
- Scene-change boundaries
- Optional user anchors
- Optional preservation of specified keyframe brightness

The smoothing window should be expressed in seconds internally when timestamps are reliable, with a frame-based fallback. This keeps behavior consistent across capture intervals.

Avoid smoothing across:

- Large timestamp gaps
- Explicit user boundaries
- Detected scene cuts
- Camera restarts or major framing changes
- Long runs of invalid analysis

## 2.7 Generate residual visual deflicker

Calculate the initial residual correction:

```text
deflickerRaw[i] = baseline[i] - correctedMeasured[i]
```

Then constrain it:

1. Set low-confidence frames from interpolated neighboring corrections where safe.
2. Apply a small temporal smoothing pass to prevent correction noise.
3. Clamp absolute correction to `maxCorrection`.
4. Clamp change per frame to `maxDeltaPerFrame`.
5. Reduce positive correction when highlight clipping would become excessive.
6. Optionally reduce negative correction when shadows are already heavily clipped.
7. Anchor the average correction over the selected range to zero unless another policy is selected.

Suggested defaults:

- Baseline window: approximately 2–5 minutes of capture time, adjusted to sequence length
- Maximum residual correction: 0.5 EV
- Maximum correction change per frame: 0.15 EV
- Robust iterations: 2–3
- Highlight protection: enabled

These are starting values and should be validated against real GoPro sunrise and sunset sequences.

Proposed command:

```sh
gopro-timelapse deflicker sequence.gptl \
  --range 0...1800 \
  --window 120s \
  --strength 1.0 \
  --max-correction 0.5 \
  --max-delta 0.15 \
  --protect-highlights
```

`--strength` should blend between no correction and the generated curve rather than changing the baseline fit:

```text
appliedDeflicker = generatedDeflicker * strength
```

This makes strength predictable and permits values from `0...1` initially.

## 2.8 Handle difficult scenes conservatively

The algorithm should detect and report cases where a global luminance correction is unreliable:

- Headlights or flash entering the scene
- Large moving foreground objects
- Fast clouds exposing and hiding the sun
- Camera movement or reframing
- Water reflections
- Lightning
- Partial lens obstruction
- Extreme highlight or shadow clipping
- Scene cuts

Mitigations:

- Use a center or user-defined analysis region.
- Prefer robust luminance percentiles over arithmetic mean.
- Use histogram distance or proxy difference to down-weight unstable frames.
- Segment the sequence at detected discontinuities.
- Never generate unbounded corrections through low-confidence regions.
- Surface warnings with frame ranges and recommended action.

The first version does not need semantic computer vision. Robust statistics, regional analysis, boundaries, and clear confidence reporting should come first.

## 2.9 Integrate corrections into rendering

At render time, compose exposure values per frame:

```swift
let finalExposure =
  creativeExposure.value(at: frame)
  + cameraStepCorrection.value(at: frame)
  + deflickerExposure.value(at: frame)
```

Then add the result to the existing grade exposure before passing it to LibRaw.

Requirements:

- Rendering must print which curves are enabled.
- Add flags to disable individual generated curves without editing project data:

```sh
gopro-timelapse render sequence.gptl --no-deflicker
gopro-timelapse render sequence.gptl --no-camera-step-correction
```

- A project render must fail or warn when correction curves reference an outdated analysis signature.
- Correction changes should invalidate developed preview/final-frame caches, but not source proxies or metadata analysis.
- The rendered-photo path must either apply the same exposure correction in a defined color pipeline or explicitly reject corrected project rendering until it does.

## 2.10 Add diagnostics and review outputs

Until a visual editor exists, make algorithm behavior inspectable through generated files.

Add CSV columns for:

- Raw measured luminance
- Cleaned measured luminance
- Camera exposure stops
- Detected metadata step
- Camera-step correction
- Estimated baseline
- Deflicker residual
- Creative exposure
- Final composed exposure
- Confidence and warning flags

Also generate an SVG or HTML report containing:

- Measured luminance curve
- Camera exposure curve
- Baseline curve
- Camera-step correction
- Deflicker correction
- Final predicted luminance
- Markers for setting changes and low-confidence frames

Proposed command:

```sh
gopro-timelapse report sequence.gptl --output report.html
```

This report will provide essential feedback before the SwiftUI timeline is implemented and can later become the specification for the visual graph.

## 2.11 Correction acceptance criteria

The automatic correction milestone is complete when:

- Metadata exposure steps are detected and reported with confidence scores.
- The generated camera-step curve compensates known synthetic ISO/shutter/aperture jumps with the correct sign.
- Smooth sunrise or sunset trends remain present after correction.
- Residual frame-to-frame luminance variation is measurably lower after deflicker.
- The algorithm does not flatten a deliberately smooth multi-stop transition.
- Corrections are stored independently from creative grading and can be enabled or disabled.
- Re-running an algorithm with identical settings produces identical curves.
- Outdated analysis invalidates generated curves or produces a clear warning.
- Low-confidence and clipped frames do not produce extreme corrections.
- A report allows every applied correction to be traced to source measurements and algorithm settings.

---

# Testing Strategy

## Unit tests

### Metadata and exposure math

- Verify EV calculations for known aperture, shutter, and ISO values.
- Verify all sign conventions.
- Verify one-stop changes for ISO doubling, shutter doubling, and aperture changes.
- Verify behavior with missing and invalid metadata.

### Luminance analysis

- Analyze constant linear RGB images with known luminance.
- Verify transfer-function decoding for rendered images.
- Verify percentiles, clipping fractions, and log-luminance calculations.
- Verify region selection and orientation handling.
- Verify that outlier pixels do not dominate robust metrics.

### Curves

- Test hold, linear, smoothstep, and monotonic interpolation.
- Test curve composition and range sampling.
- Reject duplicate frames and non-finite values.
- Verify curve simplification remains within a requested error tolerance.

### Cache invalidation

- Unchanged source and settings produce cache hits.
- Source modification invalidates only the affected frame.
- Analysis region changes invalidate luminance metrics.
- Render codec changes do not invalidate analysis.
- Algorithm version changes invalidate generated correction curves.

## Synthetic sequence tests

Generate proxy-sized image sequences with known behavior:

1. Constant scene plus random ±0.1 EV flicker.
2. Smooth three-stop sunset plus random flicker.
3. Smooth sunset with exact one-stop ISO transitions.
4. Camera steps whose visual magnitude differs slightly from metadata prediction.
5. Moving bright object crossing the analysis region.
6. Clipped highlights during part of the sequence.
7. Missing and corrupt frames.
8. A timestamp gap that must split the smoothing baseline.

For each sequence, assert:

- Recovered correction sign and approximate magnitude
- Reduced residual variance
- Preserved long-term trend
- Bounded correction values
- Appropriate warning and confidence behavior

## Real-world fixtures

Keep a small, redistributable fixture sequence or derived proxies in the test repository. Maintain larger private/manual test sequences for:

- Sunset
- Sunrise
- Day-to-night Holy Grail transition
- Clouds
- City traffic/headlights
- High-ISO night footage

Record before/after metrics and inspect preview videos for visible pumping or brightness jumps.

---

# Implementation Milestones

## Milestone A: Core refactor and project model

- Add `GoProTimelapseCore` target.
- Move ramp, RAW renderer, source scanning, and ffmpeg orchestration into focused files.
- Preserve current CLI behavior.
- Add project creation, loading, atomic saving, and schema versioning.
- Add project model tests.

Deliverable: current renders work through the new core, and `.gptl` projects can be created and reopened.

## Milestone B: Metadata and proxy analysis

- Add stable source fingerprints.
- Extract capture metadata.
- Generate low-resolution fixed-development proxies.
- Calculate robust luminance metrics.
- Cache records and proxies.
- Add `analyze`, `inspect`, and CSV export commands.

Deliverable: a sequence can be analyzed twice, with the second run mostly using cache hits.

## Milestone C: Curves and camera-step correction

- Add the general exposure curve model.
- Implement exposure math and setting-change events.
- Compare metadata and visual steps.
- Generate camera-step correction with confidence and limits.
- Add `holy-grail` and diagnostic export commands.

Deliverable: synthetic and real camera exposure jumps are removed without flattening the sequence trend.

## Milestone D: Robust visual deflicker

- Implement cleaned luminance signals and boundaries.
- Add robust baseline estimation.
- Generate bounded residual correction.
- Add clipping protection and confidence weighting.
- Add `deflicker` command.

Deliverable: synthetic flicker variance is significantly reduced while long-term luminance movement is preserved.

## Milestone E: Rendering integration and reports

- Compose creative, camera-step, and deflicker curves during rendering.
- Add cache invalidation for developed frames.
- Add per-curve render overrides.
- Generate SVG/HTML diagnostic reports.
- Render before/after proxy videos for review.

Deliverable: a complete CLI workflow from import and analysis through automatic correction and final render.

---

# Proposed End-to-end Workflow

```sh
# 1. Create the project and analyze all frames
gopro-timelapse analyze /path/to/gopro-sequence \
  --source gpr \
  --project /path/to/sunset.gptl

# 2. Inspect sequence integrity and exposure events
gopro-timelapse inspect /path/to/sunset.gptl

# 3. Correct discrete camera exposure transitions
gopro-timelapse holy-grail /path/to/sunset.gptl \
  --range 0...1800

# 4. Remove residual visual flicker
gopro-timelapse deflicker /path/to/sunset.gptl \
  --window 120s \
  --strength 1.0

# 5. Review measurements and generated corrections
gopro-timelapse report /path/to/sunset.gptl \
  --output /path/to/sunset-report.html

# 6. Render using all enabled curves
gopro-timelapse render /path/to/sunset.gptl \
  --fps 30 \
  --width 3840 \
  --codec hevc \
  --encoder auto \
  --output /path/to/sunset.mp4
```

# Definition of Done

The combined work is done when a user can point the CLI at a GoPro sequence, persistently analyze it, inspect camera and visual luminance curves, automatically compensate stepped exposure changes, remove residual flicker, and render a corrected video without modifying the source images. Reopening and rerendering the project must reuse cached work, and all generated corrections must remain explainable, reversible, and independently controllable.
