# Rendering & camera

Under `pvpython` the camera is never framed implicitly. Create a render view,
show your data, then **always** end with a camera-framing call — otherwise the
default camera sits inside or far from the data and the screenshot is blank.

## Contents

- [Create a render view](#create-a-render-view)
- [Camera framing (preferred)](#camera-framing-preferred)
- [Dolly, rotate & padded framing](#dolly-rotate--padded-framing)
- [Explicit camera placement](#explicit-camera-placement)
- [Background color](#background-color)
- [First-render reset](#first-render-reset)

## Create a render view

```python
renderView = CreateView('RenderView')
renderView.ViewSize = [1920, 1080]
```

`GetActiveViewOrCreate('RenderView')` is a convenient alternative when you do not
need to set the size explicitly:

```python
renderView = GetActiveViewOrCreate('RenderView')
```

## Camera framing (preferred)

Emit exactly one of these _after_ all `Show(...)` calls. This is the reliable way
to frame the view; prefer it over hand-set camera coordinates.

```python
# default framing — fit data to the view
renderView.ResetCamera()
```

```python
# look down +X (also: PositiveY/Z, NegativeX/Y/Z variants)
renderView.ResetActiveCameraToPositiveX()
renderView.ResetCamera()
```

```python
# isometric (3/4) view
renderView.ApplyIsometricView()
renderView.ResetCamera()
```

`ResetCamera` accepts a zoom-to-fit factor; values < 1 leave a margin:

```python
renderView.ResetCamera(True, 0.9)
```

A user phrase like "rotate the view to look in the +X direction" maps to
`ResetActiveCameraToPositiveX()` — do not invent `CameraPosition = [1, 0, 0]`.

To aim at an arbitrary direction:

```python
direction = [0.5, 1, 0.5]
ResetCameraToDirection(renderView.CameraFocalPoint, direction)
```

## Dolly, rotate & padded framing

Operate on the live camera object for incremental moves _after_ a `ResetCamera()`.
`Dolly` zooms (a factor `< 1` pulls back, leaving margin around the data — handy
so a screenshot is not cropped tight); `Azimuth` / `Elevation` rotate the camera
by degrees.

```python
renderView.ResetCamera()
camera = renderView.GetActiveCamera()
camera.Dolly(0.7)          # zoom out ~30% for padding
camera.Azimuth(30.0)       # rotate around the view-up axis (degrees)
camera.Elevation(15.0)     # rotate around the horizontal axis (degrees)
```

To add padding by distance instead of dolly, push the camera along its view
direction away from the focal point:

```python
renderView.ResetCamera()
camera = renderView.GetActiveCamera()
pos, focal = camera.GetPosition(), camera.GetFocalPoint()
pad = 1.5                   # 1.0 = tight, 1.5 = 50% margin
camera.SetPosition([focal[i] + (pos[i] - focal[i]) * pad for i in range(3)])
```

## Explicit camera placement

Use only when the framing calls above are not enough (e.g. the user gives exact
coordinates, or you must derive the position from `bounds`/`length`). Call
`ResetCamera()` first, then set the coordinates — setting them without a prior
reset is a common cause of a blank image.

```python
renderView.ResetCamera()
renderView.CameraPosition = [3.86, 3.86, 3.86]
renderView.CameraFocalPoint = [0.0, 0.0, 0.0]
renderView.CameraViewUp = [-0.408, 0.816, -0.408]
```

To copy one view's camera onto another (linked side-by-side views):

```python
renderView2.CameraPosition = renderView1.CameraPosition
renderView2.CameraFocalPoint = renderView1.CameraFocalPoint
renderView2.CameraViewUp = renderView1.CameraViewUp
```

## Background color

ParaView draws a **gradient** background by default (`Background` →
`Background2`). For a flat, solid color set both to the same RGB and disable the
palette/gradient. On 5.10+ use `BackgroundColorMode`; older versions use
`UseGradientBackground`.

```python
renderView.Background = [0.32, 0.34, 0.43]    # RGB in [0, 1]
renderView.Background2 = [0.32, 0.34, 0.43]   # same color = no gradient
renderView.UseColorPaletteForBackground = 0
renderView.BackgroundColorMode = 'Single Color'
```

To force a named palette (e.g. a white background for a figure) instead, see
`LoadPalette` in `layout-and-views.md` or `OverrideColorPalette` on
`SaveScreenshot` in `output.md`.

## First-render reset

For multi-step pipelines where you manage the camera yourself, suppress
ParaView's automatic first-render reset so it does not fight your settings:

```python
paraview.simple._DisableFirstRenderCameraReset()
```
