# GoPro Timelapse

A Swift CLI that converts GoPro `.GPR` RAW frames, develops them with LibRaw,
applies an interpolated grading ramp, writes a 10-bit ProRes 422 HQ master, and
transcodes that master to an MP4 with ffmpeg. Source photos are read-only and
are never modified.

## Requirements

- Swift 6.3+
- ffmpeg on `PATH`

The GoPro GPR SDK and LibRaw are built through Swift Package Manager via
[swift-gpr_tools](https://github.com/zaneenders/swift-gpr_tools) and
[swift-libraw](https://github.com/zaneenders/swift-libraw).

## Render the imported 2026-08-29 sequence

This single command creates a starter ramp and then renders with it:

```sh
cd ~/Developer/gopro-timelapse
swift run -c release gopro-timelapse \
  --input /home/zane/Media/2026-08-29-tl \
  --source gpr \
  --init-ramp /home/zane/Media/2026-08-29-tl/moon-night-linear-ramp.json \
  --fps 30 \
  --width 3840 \
  --codec hevc \
  --encoder auto \
  --crf 20 \
  --overwrite \
  --output /home/zane/Media/2026-08-29-tl/moon-night-raw-linear-hevc.mp4
```

`--init-ramp` does **not** stop after writing the ramp. It creates the JSON,
loads it, and continues rendering in the same invocation. Because
`--overwrite` also permits replacing the ramp, use `--ramp` for later renders
so that your ramp edits are preserved:

```sh
cd ~/Developer/gopro-timelapse
swift run -c release gopro-timelapse \
  --input /home/zane/Media/2026-08-29-tl \
  --source gpr \
  --ramp /home/zane/Media/2026-08-29-tl/moon-night-linear-ramp.json \
  --fps 30 \
  --width 3840 \
  --codec hevc \
  --encoder auto \
  --crf 20 \
  --overwrite \
  --output /home/zane/Media/2026-08-29-tl/moon-night-raw-linear-hevc.mp4
```

Add `--dry-run` to inspect the render plan without creating a video.

## Analyze and render on a server

The graphical **Analyze** action writes `automatic-correction.json` into the
source folder. The CLI can also perform accurate parallel analysis directly
from GPR files instead of using the camera JPEG proxies. On the server, run:

```sh
cd /path/to/gopro-timelapse
swift run -c release gopro-timelapse \
  --input /path/to/sequence \
  --source gpr \
  --jobs 16 \
  --analyze /path/to/sequence/automatic-correction.json
```

`--analyze` writes the correction file and exits without rendering a movie.
Adjust `--jobs` for the number of concurrent RAW analysis workers appropriate
for the server.

Then render using that correction file:

```sh
cd /path/to/gopro-timelapse
swift run -c release gopro-timelapse \
  --input /path/to/sequence \
  --source gpr \
  --ramp /path/to/ramp.json \
  --automatic-correction /path/to/sequence/automatic-correction.json \
  --automatic-strength 1 \
  --jobs 16 \
  --fps 30 \
  --width 3840 \
  --codec hevc \
  --encoder nvenc \
  --crf 20 \
  --overwrite \
  --output /path/to/timelapse.mp4
```

Use `--encoder software` if the server does not have an NVIDIA GPU or its
ffmpeg build does not provide NVENC. `--encoder auto` selects an available
backend automatically.

Use `--automatic-strength 2` only for an exaggerated diagnostic render to
confirm that the correction is visible. It scales the saved correction and
does not rerun analysis.

## Ramp format

Frames are zero-based. `interpolation` can be `smooth` (default) or `linear`.
Exposure is measured in stops, temperature in Kelvin, highlights in `0...1`,
and shadows and vibrance conventionally in `-1...1`.

```json
{
  "interpolation": "linear",
  "keyframes": [
    {
      "frame": 0,
      "exposure": 0,
      "temperature": 5200,
      "tint": 10,
      "contrast": 1,
      "saturation": 1,
      "vibrance": 0,
      "shadows": 0,
      "highlights": 0
    },
    {
      "frame": 675,
      "exposure": 2.1,
      "temperature": 3800,
      "tint": 0,
      "contrast": 1.08,
      "saturation": 1,
      "vibrance": 0.2,
      "shadows": 0.3,
      "highlights": 0.7
    }
  ]
}
```

## Useful options

- `--source gpr|jpg|auto` — choose RAW, rendered photos, or automatic selection
- `--denoise 0...1` — RAW chroma denoising; default `0.7`, `0` disables it
- `--width N` — maximum render width; default `0` preserves source dimensions
- `--jobs N` — limit parallel RAW analysis/render workers
- `--analyze FILE` — analyze GPR frames in parallel, write correction JSON, and exit
- `--automatic-correction FILE` — apply a saved dense per-frame correction
- `--automatic-strength 0...2` — scale the saved correction; default `1`
- `--keep-frames` — retain developed PNG frames
- GPR conversions persist under `<source>/.gopro-timelapse/dng`; delete that folder to rebuild the DNG cache
- Final renders retain a same-basename `.prores.mov` 10-bit ProRes 422 HQ master
- `--encoder auto|software|videotoolbox|nvenc` — choose the HEVC/H.264 delivery encoder
- `--bitrate N` — VideoToolbox bitrate in Mbps
- `--crf N` — software/NVENC quality
- `--overwrite` — replace existing output (and an `--init-ramp` file)
- `--dry-run` — validate and print the plan without rendering

Run `swift run gopro-timelapse --help` for the complete CLI reference.

## Graphical UI (early preview)

The Chroma UI builds and runs directly with Swift Package Manager; no Xcode
project is required. SwiftPM resolves the remote Chroma `display-images` branch.

On macOS:

```sh
swift run gopro-timelapse-mac
```

On Linux with a Wayland session:

```sh
swift run gopro-timelapse-wayland
```

Enter a source directory and press **Load**. The UI currently accepts GPR
sequences only. Every selected-frame preview and every luminance measurement
uses the same GPR → temporary DNG → LibRaw development domain as final output;
paired camera JPEGs are deliberately ignored. Converted DNGs are retained in
`.gopro-timelapse/dng` inside the source folder and reused by previews, analysis,
and subsequent renders when the source GPR has not changed. Analysis therefore
resumes conversion after an app restart, including recovery of a completed DNG
whose metadata sidecar had not yet been written. Dedicated headless GPR worker
processes scale to the system's active CPU count while populating the cache in
parallel, avoiding both UI relaunches and the SDK's process-global XMP
concurrency limitation. Use `j`/`k` to move
to the next/previous frame; Command-Up/Down on macOS or Super-Up/Down on Linux
jumps to the first/last frame. Analyze develops 16-bit RAW proxies for all
frames and writes `automatic-correction.json`. Final export applies that
correction while creating a source-size 10-bit ProRes 422 HQ master followed by
HEVC Main 10.

## Current scope

Implemented in the shared Core and CLI: GPR-to-DNG conversion, 16-bit LibRaw
development, exposure and color controls, keyframe interpolation, parallel RAW
analysis and processing, robust luminance-based correction files, 10-bit ProRes
master generation, and HEVC/H.264 delivery encoding with ffmpeg. The early UI
is intentionally GPR/RAW-only: it provides GPR sequence scanning, RAW previews,
16-bit RAW luminance analysis, correction graphing, and ProRes-first movie
export. JPEG/rendered-photo ingestion is disabled for now. A complete visual ramp
editor and metadata-aware camera-step correction are not yet implemented.
