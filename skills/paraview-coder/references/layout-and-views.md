# Layout & views

A layout holds one or more views in the saved image. Every script that saves a
screenshot of a render view should create a layout and assign the view to it.

## Contents

- [Single view layout](#single-view-layout)
- [Side-by-side comparison](#side-by-side-comparison)
- [Chart & histogram views](#chart--histogram-views)
- [Text annotations](#text-annotations)
- [Background palette & layout size](#background-palette--layout-size)

## Single view layout

Include this in scripts that render to a screenshot.

```python
layout = CreateLayout(name='Layout')
layout.AssignView(0, renderView)
```

## Side-by-side comparison

Two render views split horizontally — e.g. prediction vs. ground truth. Size
each view, split the layout, and assign each view to a cell.

```python
renderView1 = CreateView('RenderView')
renderView1.ViewSize = [900, 1400]
renderView2 = CreateView('RenderView')
renderView2.ViewSize = [900, 1400]

layout1 = CreateLayout(name='Layout #1')
layout1.SplitHorizontal(0, 0.5)
layout1.AssignView(1, renderView1)
layout1.AssignView(2, renderView2)
layout1.SetSize(1800, 1400)
```

Frame each view independently (and optionally link cameras — see
`rendering-and-camera.md`):

```python
SetActiveView(renderView1)
renderView1.ResetCamera(True, 0.9)
SetActiveView(renderView2)
renderView2.ResetCamera(True, 0.9)
```

## Chart & histogram views

For Plot Over Line (see `filters.md`) display the result in an XY chart view and
assign it to a layout cell so it appears in the saved image.

```python
lineChartView1 = CreateView('XYChartView')
plotDisplay = Show(plotOverLine1, lineChartView1, 'XYChartRepresentation')

layout1 = GetLayoutByName('Layout #1')
AssignViewToLayout(view=lineChartView1, layout=layout1, hint=0)
```

Histogram of a scalar:

```python
histogramView1 = CreateView('XYHistogramChartView')
histogramView1.ViewSize = [500, 780]
viewLayout1 = GetLayout()
viewLayout1.SplitHorizontal(0, 0.5)
viewLayout1.AssignView(2, histogramView1)
SetActiveSource(wavelet1)
histogram = Show(wavelet1, histogramView1)
histogram.SelectInputArray = ['POINTS', 'RTData']
histogram.UseColorMapping = True
```

## Text annotations

Label a view with a text source. Position is in normalized `[0,1]` viewport
coordinates.

```python
text1 = Text(registrationName='Text1')
text1.Text = 'NN Prediction'
text1Display = Show(text1, renderView1, 'TextSourceRepresentation')
text1Display.FontFamily = 'Times'
text1Display.FontSize = 12
text1Display.WindowLocation = 'Any Location'
text1Display.Position = [0.1, 0.0]
```

## Background palette & layout size

```python
LoadPalette('WhiteBackground')   # or 'BlueGrayBackground'
layout = GetLayout()
layout.SetSize(1280, 800)
```
