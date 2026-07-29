---
name: paraview-coder
description: >-
    Writes complete, headless pvpython (ParaView) scripts from a natural-language
    visualization request and saves a screenshot of the result. Use this whenever
    the user wants to visualize a scientific dataset, mentions ParaView, pvpython,
    paraview.simple, VTK, or asks to render/screenshot a .vtk, .vtu, .vtp, .vtr,
    .ex2/Exodus, or IOSS file. Triggers on requests for isosurfaces/contours,
    slices, clips, glyphs, streamlines/stream tracers, tubes, volume rendering,
    wireframes, calculators, plot-over-line / chart views, multi-view comparisons,
    color maps / transfer functions, scalar bars, camera framing, or animations
    even when the user does not say the words "ParaView" or "script". Reach for it
    any time the deliverable is Python code that drives ParaView to produce an
    image of data.
license: Proprietary. Part of the ChatVis research artifact.
compatibility: >-
    Produces Python scripts intended to run under pvpython (ParaView's batch
    interpreter, headless/offscreen). Snippets target ParaView 5.12+; the
    paraview.simple API drifts between versions, so adapt if the local pvpython
    rejects a call.
metadata:
    author: chatvis
    version: "1.0"
---

# ParaView script generation (pvpython)

Your job is to turn a visualization request into a single, complete Python
script that runs under `pvpython` and writes a screenshot to disk. `pvpython`
is headless: there is no interactive window, so the script must build the whole
pipeline, frame the camera explicitly, and save an image — nothing is implicit.

Before writing any code, the raw request is normalized into a structured,
flat-prose ParaView prompt by the `paraview-prompt-formatter` subagent (see
Step 0). Every step after that consumes the formatted prompt, not the raw
request.

## Output contract

Return the script as **one** fenced `python ... ` block containing the
complete script. Any prose explanation goes _after_ that block, never before it,
and is never itself wrapped in a python fence. Downstream tooling extracts the
first python block, so a stray earlier fence will be picked up instead of the
real script.

Every script begins with `from paraview.simple import *`.

The script is complete only when it contains, at minimum: a reader for the
input file, a render view with an explicit size, a `Show(...)` for the source
being imaged, a camera-framing call after the last `Show(...)`, and a
`SaveScreenshot(...)` to the output path. A script missing any of these
produces a blank or absent image.

## Placeholders you must substitute

Snippets in the reference files use angle-bracket sentinels and one placeholder
array name. Replace them with values taken from the user's request — do not
leave them in the final script:

- `<input_path>` — the dataset file the user named.
- `<output_path>` — the screenshot path the user named (or a sensible default
  like `screenshot.png`).
- `'var0'` — a **placeholder scalar array name**. Replace it with the array the
  user named (e.g. `'marschner_lobb'`, `'Temp'`, `'Pres'`). If the user names no
  array, inspect the data and use the first PointData array (see
  `references/readers.md`). A leftover `'var0'` on a dataset that has no such
  array is the single most common cause of a blank or failed render.

## Step 0: Format the request (always first)

Before generating any code, call the Task tool with
`subagent_type: paraview-prompt-formatter`, passing the user's raw
natural-language request verbatim as the prompt. Do this for every request,
including requests that already look well-structured.

The subagent returns a structured, flat-prose ParaView prompt: ordered
pipeline operations with concrete values preserved verbatim, the input/output
paths, and a 1920 x 1080 screenshot convention baked in.

The subagent is **blocking on paths**: if the input data path or output
screenshot path is missing, it will ask the user for them and will not emit a
formatted prompt until both are provided. Do not write any code until the
subagent returns a formatted prompt. Relay its question to the user, wait for
the answer, and re-invoke it if needed.

Every step below consumes the **formatted prompt** produced here, not the raw
user request.

## Workflow

Read the **formatted prompt** line by line and build the pipeline in this order.
Skip steps that the prompt does not call for.

1. **Reader** — pick the reader that matches the input file extension.
   See `references/readers.md`.
2. **Data inspection (only if needed)** — fetch scalar range or spatial bounds.
   Needed _only_ before transfer functions or explicit camera placement; not for
   plain slices, contours, clips, or wireframes. See `references/readers.md`.
3. **Filters** — slice, contour/isosurface, clip, glyph, stream tracer, tube,
   calculator, etc. Chain each filter's `Input=` to the _previous_ filter, not
   always back to the reader. See `references/filters.md`.
4. **Render view** — create the view and set its size.
   See `references/rendering-and-camera.md`.
5. **Display & color** — show each source, choose a representation (surface,
   wireframe, volume), and color by an array if asked.
   See `references/displays-and-color.md`.
6. **Layout / extra views** — layouts, side-by-side comparisons, chart and
   histogram views, text annotations. See `references/layout-and-views.md`.
7. **Camera framing** — frame the camera _after_ all `Show(...)` calls (see
   gotcha below). See `references/rendering-and-camera.md`.
8. **Output** — save the screenshot (or data / animation / exported scene).
   See `references/output.md`.

Each reference file is a categorized catalog of working snippets with a one-line
"use when". Open only the files the current request needs — they are detailed
and not worth loading wholesale.

## Gotchas

These are the mistakes a script will make without being told otherwise. They are
ParaView-/pvpython-specific and defy reasonable assumptions, so they matter more
than any single snippet.

- **Blank screenshot — unframed camera.** `Show()` alone does not frame the
  camera under `pvpython`; the default camera sits inside or far from the data
  and the saved image comes out empty. After all `Show(...)` calls, always emit
  a render-view-direction call (`ResetCamera()`, `ResetActiveCameraToPositiveX()`,
  `ApplyIsometricView()`, etc.). "Rotate the view to look in +X" means call the
  +X reset, not hand-invent `CameraPosition = [1, 0, 0]`.

- **Blank screenshot — hand-rolled camera.** Do not set `CameraPosition`,
  `CameraFocalPoint`, or `CameraViewUp` directly unless you are deliberately
  placing the camera, and even then call `ResetCamera()` first. Hand-rolled
  coordinates without a reset are the second most common cause of an empty image.

- **`Contour array is null` — leftover `'var0'`.** The contour/slice array name
  must be a real array on the dataset. Substitute the user's array name; if none
  is given, read the first PointData array name explicitly. Leaving `'var0'` on a
  dataset without that array logs `Contour array is null` and renders nothing.

- **Solid-black volume render — incomplete transfer functions.** Volume
  rendering is atomic: you must emit the scalar range, the color transfer
  function, and the opacity transfer function, then set both `LookupTable` and
  `ScalarOpacityFunction` on the display. Omit any one and every ray sample hits
  opaque black. "Default transfer function" means "use these ramps", not "omit
  them". Keep the array name identical across the whole chain (range → color TF →
  opacity TF → `ColorArrayName`) or it also renders black. See
  `references/displays-and-color.md`.

- **Inspect data only when you need it.** Emit the scalar-range / bounds
  snippets only before transfer functions or explicit camera math. Plain
  isosurfaces, slices, clips, and wireframes use literal values from the request
  and need no inspection. Call `UpdatePipeline()` before reading range/bounds, and
  reference the reader variable explicitly rather than relying on
  `GetActiveSource()`, which is unreliable under `pvpython`.

- **Suppress the first-render camera reset for multi-step pipelines** when you
  are managing the camera yourself: `paraview.simple._DisableFirstRenderCameraReset()`.

- **Do not use `clip1.InsideOut`** — it is unreliable here; configure the clip
  plane (`Origin`/`Normal`) to select the side you want instead.

- **Opacity transfer-function points are quartets, not pairs.**
  `pwf.Points` is a flat list of `[value, alpha, midpoint, sharpness]` per control
  point (`midpoint`/`sharpness` default to `0.5`/`0.0`). Emitting bare
  `[value, alpha]` pairs silently corrupts the ramp. Likewise `lut.RGBPoints` is
  `[value, r, g, b]` quadruples. See `references/displays-and-color.md`.

- **Threshold uses `LowerThreshold`/`UpperThreshold` on ParaView 5.10+**, not a
  single `ThresholdRange`, and has no `AllPoints` property. The `Histogram`
  filter's bin count must be set via `GetProperty('NumberOfBins')` /
  `'BinCount'` + `SetElement(0, n)`, not by direct attribute assignment. See
  `references/filters.md`.
