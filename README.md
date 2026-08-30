# GoPro Timelapse

A Swift CLI that converts GoPro `.GPR` RAW frames, develops them with LibRaw,
applies an interpolated grading ramp, and encodes an MP4 with ffmpeg. Source
photos are read-only and are never modified.

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
- `--jobs N` — limit parallel RAW workers
- `--keep-frames` — retain developed PNG frames
- `--encoder auto|software|videotoolbox|nvenc` — choose the video encoder
- `--bitrate N` — VideoToolbox bitrate in Mbps
- `--crf N` — software/NVENC quality
- `--overwrite` — replace existing output (and an `--init-ramp` file)
- `--dry-run` — validate and print the plan without rendering

Run `swift run gopro-timelapse --help` for the complete CLI reference.

## Current scope

Implemented: GPR-to-DNG conversion, LibRaw development, exposure and color
controls, keyframe interpolation, parallel RAW processing, and ffmpeg encoding.
Automatic luminance analysis, deflickering, previews, and a visual ramp editor
are not yet implemented.
