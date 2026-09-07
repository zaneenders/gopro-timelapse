# Keyframe Grading Editor Plan

## Goal

Keep the existing rendering pipeline and improve output through a small Lightroom-style editor: choose a few representative photos, develop each to taste, and interpolate their settings across the sequence.

This is a proposed next milestone, not a description of a completed editor. Controls should feel familiar, but are not expected to reproduce Lightroom's processing exactly.

## Existing foundation

- The CLI's `Sources/GoProTimelapse/Ramp.swift` defines exposure, temperature, tint, contrast, saturation, vibrance, shadows, and highlights, with linear or smooth interpolation.
- The UI already has basic exposure and temperature keyframes.
- The UI's shared `UIGrade` model in `Sources/GoProTimelapseCore/ExposureWorkflow.swift` only carries exposure and temperature. UI preview and movie export currently pass those two controls to LibRaw.
- Automatic exposure correction exists separately; the UI adds it to the creative exposure ramp.
- RAW previews and final output already use GPR → DNG → LibRaw development.

The primary work is unifying the models and exposing a consistent editing workflow, rather than replacing the rendering pipeline.

## 1. Basic Develop panel

Start with controls already supported by the CLI renderer:

| Group | Controls |
| --- | --- |
| Light | Exposure, contrast, highlights, shadows |
| White balance | Temperature, tint |
| Color | Vibrance, saturation |

Each control should provide:

- A slider and editable numeric value.
- An individual reset action.
- Clear units and meaningful bounds.

Also provide before/after comparison, a histogram, and highlight/shadow clipping warnings.

Validate highlights and shadows behavior on real RAW frames before selecting UI ranges. Lowering developed highlights is not necessarily equivalent to recovering clipped RAW detail. Decide how camera/as-shot white balance and explicit temperature/tint settings interact before exposing those modes.

## 2. Anchor-photo workflow

1. Select a representative frame.
2. Add a keyframe and adjust its look.
3. Move to another point where lighting changes.
4. Add and grade that anchor.
5. Scrub through the interpolated result.

Timeline requirements:

- Visible keyframe markers.
- Next/previous keyframe navigation.
- Add and delete keyframe actions.
- Clear distinction between an anchor and an interpolated frame.
- New keyframes initialize from the current interpolated grade, so inserting an anchor does not change the result.

Make the behavior of editing a non-keyframe explicit: either require adding an anchor or clearly indicate automatic keyframe creation.

## 3. Predictable ramping

Interpolate settings, not images.

- **Exposure:** interpolate in stops.
- **Temperature:** consider reciprocal-Kelvin (mired) interpolation for more even-looking white-balance transitions; validate visually.
- **Other controls:** begin with bounded linear interpolation.
- **Modes:** offer Linear and Smooth, without overshooting anchor values.
- **Default:** start with Linear. Easing into and out of every anchor can create visible pauses during otherwise continuous lighting changes.
- **Outside the anchors:** hold the nearest endpoint grade.

Define and test behavior for empty ramps, a single anchor, duplicate frame indices, and optional white-balance values. Preserve existing saved-ramp behavior or explicitly version any changes to interpolation semantics.

## 4. Keep deflicker separate from creative grading

Use the existing conceptual composition:

```text
frame exposure = creative keyframe exposure
               + automatic correction × correction strength
```

Provide independent toggles for the creative grade and automatic correction, and show their curves separately where practical.

Automatic correction should remove unwanted flicker without flattening intentional sunset or nightfall. Changing the creative grade should not silently regenerate the analysis or overwrite the saved correction.

## 5. Shared architecture

Unify the CLI and UI grade/ramp models in `GoProTimelapseCore` before expanding the panel.

Today the CLI has the fuller `Grade`/`RampFile` implementation while the UI uses a separate two-control `UIGrade`. One shared model and interpolation implementation should drive:

- Selected-frame previews.
- Per-frame grade evaluation.
- UI movie export.
- CLI rendering.
- Saved ramp JSON.

Keep source photos read-only and preserve compatibility with existing ramp files where possible. Save and reload creative grading separately from automatic correction.

Ensure all controls reach both preview and final rendering, including preview cache identity/invalidation. Avoid a slider that changes the preview but is omitted from export.

## 6. Responsive, trustworthy previews

Investigate caching developed image data rather than repeating RAW development for every slider adjustment.

- Determine which adjustments can safely run on cached data and which require RAW redevelopment.
- Debounce expensive updates and discard stale preview results.
- Keep any fast preview path consistent with the final rendering path.
- Check preview/export agreement with representative day, dusk, and night frames.

Do not trade away color or tonal consistency solely for interactive speed.

## First milestone

**Open a sequence → grade three anchor frames with all eight controls → scrub the ramp → save/reload it → render using exactly those settings.**

Suggested implementation order:

1. Consolidate grade, keyframe, serialization, and interpolation in Core.
2. Wire the complete grade through UI preview and export.
3. Add the Develop panel and clear keyframe editing interactions.
4. Add ramp save/load and timeline markers/navigation.
5. Add before/after, histogram, and clipping warnings.
6. Validate preview responsiveness and rendered temporal consistency.

### Acceptance checks

- Adding an unchanged keyframe does not change the evaluated ramp.
- Anchor frames reproduce their exact settings.
- Interpolated settings remain within intended bounds.
- Saving and loading preserves settings and interpolation mode.
- Existing ramp files remain usable, or migration is explicit.
- CLI and UI evaluate the same ramp consistently.
- Every visible grading control affects both preview and export.
- Creative exposure and automatic correction can be inspected independently.
- Representative rendered transitions show no unintended discontinuities at anchors.

## Deferred scope

Leave masks, local adjustments, clarity/dehaze, elaborate tone curves, and other advanced editing tools for later.

The immediate priority is direct control over exposure, white balance, and tonal balance across the sequence, with a preview that can be trusted.
