# Skills

> Agent skills to progressively disclose visualization pipeline templates

## About

Skills are on-demand OpenCode context injections. The skill tool loads a
`SKILL.md` file — plus any reference files it points to — into the active
agent context at the moment they are needed. Only the files relevant to the
current request are opened, keeping context lean. Skills encode specialized
instructions, working code snippets, and hard-won failure modes that would
be too costly to carry in the base system prompt.

## ParaView

**Skill name:** `paraview-coder`

Generates a single, complete `pvpython` script from a natural-language
visualization request and saves a screenshot to disk. Scripts target
ParaView 5.12+ running headless (no interactive window).

**Triggers:** user mentions ParaView, pvpython, `paraview.simple`, VTK, or
a scientific file format (`.vtk`, `.vtu`, `.vtp`, `.vtr`, `.ex2`, Exodus,
IOSS); or requests a visualization operation — isosurfaces/contours, slices,
clips, glyphs, streamlines, tubes, volume rendering, color maps/transfer
functions, scalar bars, camera framing, animations, or plot-over-line views.

**Workflow:**

0. **Format request** — invoke the `paraview-prompt-formatter` subagent to
   normalize the raw request into a structured flat-prose prompt with concrete
   values and explicit paths. No code is written until this returns.
1. **Reader** — select the reader matching the input file extension.
2. **Data inspection** (only if needed) — fetch scalar range or spatial bounds
   before transfer functions or explicit camera math.
3. **Filters** — slice, contour, clip, glyph, stream tracer, tube, calculator,
   threshold, histogram. Each filter chains `Input=` to the previous filter.
4. **Render view** — create the view and set its pixel dimensions.
5. **Display & color** — show each source, set representation, color by array.
6. **Layout / extra views** — multi-view layouts, chart/histogram views,
   text annotations.
7. **Camera framing** — frame the camera after all `Show(...)` calls.
8. **Output** — save screenshot, data export, or animation.

**Reference files** (`skills/paraview/references/`):

| File                      | Covers                                                                 |
| ------------------------- | ---------------------------------------------------------------------- |
| `readers.md`              | Reader selection by file extension; data inspection snippets           |
| `filters.md`              | Slice, contour, clip, glyph, stream tracer, tube, threshold, histogram |
| `rendering-and-camera.md` | Render view setup; camera framing and reset calls                      |
| `displays-and-color.md`   | Representations; color arrays; color/opacity transfer functions        |
| `layout-and-views.md`     | Multi-view layouts; chart and histogram views; text annotations        |
| `output.md`               | `SaveScreenshot`; data export; animation                               |
