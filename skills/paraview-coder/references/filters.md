# Filters

Filters transform the output of a reader or another filter. Chain each filter's
`Input=` to the _previous_ stage in the pipeline (e.g. a contour after a slice
takes `Input=slice1`), not always back to the original reader. Replace `'var0'`
with the real scalar array name from the request.

## Contents

- [Slice](#slice)
- [Contour / isosurface](#contour--isosurface)
- [IsoVolume](#isovolume)
- [Threshold](#threshold)
- [Clip](#clip)
- [Table To Points](#table-to-points)
- [Delaunay 3D](#delaunay-3d)
- [Stream tracer](#stream-tracer)
- [Tube](#tube)
- [Glyph](#glyph)
- [Warp By Vector](#warp-by-vector)
- [Transform](#transform)
- [Gradient](#gradient)
- [Connectivity](#connectivity)
- [Extract Surface / Triangulate](#extract-surface--triangulate)
- [Integrate Variables](#integrate-variables)
- [Histogram](#histogram)
- [Calculator](#calculator)
- [Cell Data to Point Data](#cell-data-to-point-data)
- [Plot Over Line](#plot-over-line)
- [Temporal Interpolator](#temporal-interpolator)
- [Shrink / Extract Edges](#shrink--extract-edges)
- [Time-series statistics](#time-series-statistics)

## Slice

Use to cut a planar cross-section. Output is polydata.

```python
slice1 = Slice(registrationName='Slice1', Input=ml100vtk)
slice1.SliceType = 'Plane'
slice1.HyperTreeGridSlicer = 'Plane'
slice1.SliceOffsetValues = [0.0]
slice1.PointMergeMethod = 'Uniform Binning'
```

## Contour / isosurface

Use to compute isolines/isosurfaces from a point-centered scalar. Use the
isosurface value from the request verbatim; if none is given, derive it from
`(min + max) / 2` (see data inspection in `readers.md`). **Replace `'var0'`** with
the real array name — a leftover `'var0'` logs `Contour array is null` and renders
nothing. When the contour follows another filter, set `Input=` to that filter.

```python
contour1 = Contour(registrationName='Contour1', Input=ml100vtk)
contour1.ContourBy = ['POINTS', 'var0']
contour1.Isosurfaces = [0.5]
contour1.PointMergeMethod = 'Uniform Binning'
```

If the user named no array, inspect first and use the real name:

```python
ml100vtk.UpdatePipeline()
array_name = ml100vtk.PointData.GetArray(0).GetName()
contour1.ContourBy = ['POINTS', array_name]
```

For "several contours across the range", sample N isovalues between `min` and
`max` (see data inspection in `readers.md`) rather than hand-listing them. Use
`np.logspace` instead only when the data spans orders of magnitude and `min > 0`.

```python
import numpy as np

contour_values = np.linspace(min, max, 8).tolist()
# contour_values = np.logspace(np.log10(min), np.log10(max), 8).tolist()  # min > 0
contour1.Isosurfaces = contour_values
```

## IsoVolume

Use to extract the region where a scalar falls within a threshold range
(a "filled" isosurface rather than a shell).

```python
isoVolume1 = IsoVolume(registrationName='IsoVolume1', Input=predictionvtr)
isoVolume1.InputScalars = ['POINTS', 'Intensity']
isoVolume1.ThresholdRange = [0.2, 1.0]
```

## Threshold

Use to keep only cells whose scalar falls in a value range. On ParaView 5.10+
the range is set with the separate `LowerThreshold` / `UpperThreshold`
properties (not a single `ThresholdRange` pair). Use `float('-inf')` /
`float('inf')` for an open-ended bound.

```python
threshold1 = Threshold(registrationName='Threshold1', Input=ml100vtk)
threshold1.Scalars = ['POINTS', 'var0']
threshold1.LowerThreshold = 0.2
threshold1.UpperThreshold = 1.0
threshold1.Invert = 0          # 1 keeps values outside the range
```

`AllPoints` / `AllScalars` is **not** a valid Threshold property in recent
ParaView — do not set it.

## Clip

Use to cut away part of the dataset with an implicit plane. Output is an
unstructured grid. Configure `Origin`/`Normal` to choose the kept side — **do not
rely on `InsideOut`**.

```python
clip = Clip(registrationName='Clip', Input=delaunay3D)
clip.ClipType = 'Plane'
clip.ClipType.Origin = [0.0, 0.0, 0.0]
clip.ClipType.Normal = [1.0, 0.0, 0.0]
```

## Table To Points

Use to turn a CSV/table (see `CSVReader` in `readers.md`) into a point cloud by
naming the columns that hold the x/y/z coordinates. The result is geometry you
can display, triangulate (Delaunay 3D), or clip.

```python
tableToPoints1 = TableToPoints(registrationName='TableToPoints1', Input=csv)
tableToPoints1.XColumn = 'x'
tableToPoints1.YColumn = 'y'
tableToPoints1.ZColumn = 'z'
```

## Delaunay 3D

Use to build a 3D Delaunay triangulation (unstructured grid) from a point set —
e.g. to give a points-only dataset a surface to clip or display.

```python
delaunay3D = Delaunay3D(registrationName='Delaunay3D', Input=points)
```

## Stream tracer

Use to trace streamlines through a vector field from a seed. Set `Vectors` to
the vector array on the input; tune seed `Center`/`Radius` from the dataset
bounds (see `readers.md`).

```python
streamTracer = StreamTracer(
    registrationName='StreamTracer1',
    Input=velocity,
    SeedType='Point Cloud',
)
streamTracer.Vectors = ['POINTS', 'V']
streamTracer.MaximumStreamlineLength = 20.0
streamTracer.SeedType.Center = [0.0, 0.0, 0.0]
streamTracer.SeedType.Radius = 2.0
```

Optional integration / seeding tuning:

```python
streamTracer.IntegrationDirection = 'BOTH'        # 'FORWARD', 'BACKWARD', 'BOTH'
streamTracer.IntegratorType = 'Runge-Kutta 4-5'
streamTracer.InitialStepLength = 0.1
streamTracer.SeedType.NumberOfPoints = 100        # denser seed cloud
```

## Tube

Use to thicken streamlines (or any polylines) into renderable tubes.

```python
tube = Tube(registrationName='Tube1', Input=streamTracer)
tube.Scalars = ['POINTS', 'AngularVelocity']
tube.Vectors = ['POINTS', 'Normals']
tube.Radius = 0.075
```

Optional shape tuning — `NumberOfSides` smooths the cross-section; `VaryRadius`
makes the tube thickness follow a scalar/vector:

```python
tube.NumberOfSides = 6
tube.VaryRadius = 'By Scalar'   # 'Off', 'By Scalar', 'By Vector', 'By Absolute Scalar'
```

## Glyph

Use to place oriented/scaled glyphs (cones, arrows, etc.) at points — e.g. to
show flow direction along streamlines. Orient and scale by a vector array.

```python
glyph = Glyph(registrationName='Glyph1', Input=streamTracer, GlyphType='Cone')
glyph.OrientationArray = ['POINTS', 'V']
glyph.ScaleArray = ['POINTS', 'V']
glyph.ScaleFactor = 0.05
glyph.GlyphTransform = 'Transform2'
```

Tuning the cone shape (optional):

```python
glyph.GlyphType.Resolution = 10
glyph.GlyphType.Radius = 0.15
glyph.GlyphType.Height = 0.5
```

Cap glyph density on large datasets and scale by vector magnitude:

```python
glyph.MaximumNumberOfSamplePoints = 5000
glyph.VectorScaleMode = 'Scale by Magnitude'
```

Alternatively, thin glyphs deterministically by taking every Nth point instead of
random sampling:

```python
glyph.GlyphMode = 'Every Nth Point'
glyph.Stride = 10
```

A good auto `ScaleFactor` is ~1% of the bounding-box diagonal (compute the
diagonal from `bounds` — see `readers.md`).

## Warp By Vector

Use to displace points along a vector field (e.g. exaggerate a deformation).

```python
warpByVector1 = WarpByVector(registrationName='WarpByVector1', Input=reader)
warpByVector1.Vectors = ['POINTS', 'V']
warpByVector1.ScaleFactor = 1.0
```

## Transform

Use to translate, rotate, or scale a dataset geometrically. The sub-proxy is
also named `Transform`; set its `Translate` / `Rotate` (degrees) / `Scale`.

```python
transform1 = Transform(registrationName='Transform1', Input=reader)
transform1.Transform = 'Transform'
transform1.Transform.Translate = [1.0, 0.0, 0.0]
transform1.Transform.Rotate = [0.0, 0.0, 90.0]   # degrees, per axis
transform1.Transform.Scale = [2.0, 2.0, 2.0]
```

## Gradient

Use to compute the gradient of a scalar/vector field, and optionally vorticity,
divergence, or Q-criterion from a vector field. Call `UpdatePipeline()` before
showing so the new arrays exist.

```python
gradient1 = Gradient(registrationName='Gradient1', Input=reader)
gradient1.ScalarArray = ['POINTS', 'V']
gradient1.ComputeVorticity = 1
gradient1.ComputeDivergence = 1
gradient1.ComputeQCriterion = 1
gradient1.UpdatePipeline()
```

## Connectivity

Use to label connected regions (each gets a `RegionId`), e.g. to color or
threshold disjoint components separately.

```python
connectivity1 = Connectivity(registrationName='Connectivity1', Input=contour1)
```

## Extract Surface / Triangulate

Use to turn a volumetric dataset (image data, structured/unstructured grid) into
a triangulated surface — required before exporting to STL/PLY/OBJ
(see `output.md`). Polydata only needs `Triangulate`.

```python
extractSurface1 = ExtractSurface(registrationName='ExtractSurface1', Input=reader)
triangulate1 = Triangulate(registrationName='Triangulate1', Input=extractSurface1)
```

## Integrate Variables

Use to integrate quantities over the dataset — e.g. surface `Area` of a contour,
or `Volume` of a solid. The result is a one-row table; fetch it from the server
and read the cell array. Run on a _surface_ for `Area`.

```python
import paraview.servermanager as sm

integrateVariables1 = IntegrateVariables(registrationName='IntegrateVariables1', Input=contour1)
integrateVariables1.UpdatePipeline()
integrated = sm.Fetch(integrateVariables1)
area = integrated.GetCellData().GetArray('Area').GetValue(0)
print('Surface area:', area)
```

## Histogram

Use to bin a scalar into a frequency distribution. Two quirks: the input array is
chosen with `SelectInputArray = [location, name]`, and the bin count must be set
through the proxy property (`NumberOfBins`, or `BinCount` on some versions) —
direct attribute assignment is rejected.

```python
import paraview.servermanager as sm

histogram1 = Histogram(registrationName='Histogram1', Input=reader)
histogram1.SelectInputArray = ['POINTS', 'var0']
nbins = histogram1.GetProperty('NumberOfBins') or histogram1.GetProperty('BinCount')
nbins.SetElement(0, 256)
histogram1.UpdatePipeline()

table = sm.Fetch(histogram1)
centers = table.GetColumnByName('bin_centers') or table.GetColumn(0)
freqs = table.GetColumnByName('bin_frequencies') or table.GetColumn(1)
for i in range(table.GetNumberOfRows()):
    print(centers.GetValue(i), freqs.GetValue(i))
```

To show a histogram in a chart view instead of printing it, see
`layout-and-views.md`.

## Calculator

Use to compute a derived field from existing arrays via an expression. Reference
components as `velocity_X`, coordinates as `coordsX`, and build vectors with
`iHat`/`jHat`/`kHat`.

```python
calculator1 = Calculator(registrationName='Calculator1', Input=mpasvtp)
calculator1.Function = '(-velocity_X*sin(coordsX*0.0174533) + velocity_Y*cos(coordsX*0.0174533)) * iHat + 0*jHat + 0*kHat'
```

## Cell Data to Point Data

Use when a filter needs point-centered data but the arrays are cell-centered
(e.g. before contouring cell data). Averages surrounding cell values onto points.

```python
cellToPoint = CellDatatoPointData(registrationName='CellDatatoPointData1', Input=reader)
cellToPoint.CellDataArraytoprocess = ['Intensity', 'Phase']
```

## Plot Over Line

Use to sample point-centered variables along a line for an XY plot or CSV export.

```python
plotOverLine1 = PlotOverLine(registrationName='PlotOverLine1', Input=wavelet1)
plotOverLine1.Point1 = [0, 0, 0]
plotOverLine1.Point2 = [0, 0, 10]
```

Display it in a chart view (see `layout-and-views.md`) or write it to CSV:

```python
writer = CreateWriter('<output_path>', plotOverLine1)  # e.g. line-plot.csv
writer.UpdatePipeline()
```

## Temporal Interpolator

Use to interpolate a time-varying dataset between timesteps (e.g. for smoother
animations or side-by-side comparison with the raw data).

```python
temporalInterpolator = TemporalInterpolator(Input=data)
```

## Shrink / Extract Edges

`Shrink` pulls each cell toward its centroid (factor in `[0, 1]`); `ExtractEdges`
produces a wireframe of the input.

```python
shrink = Shrink(Input=sphere)
shrink.ShrinkFactor = 0.5
wireframe = ExtractEdges(Input=sphere)
```

## Time-series statistics

Use to compute statistics across timesteps. Iterate timesteps by calling
`UpdatePipeline(t)` and fetching the data; `print()` the results so they appear
in stdout.

```python
import numpy as np
from vtkmodules.numpy_interface import dataset_adapter as dsa

timesteps = data.TimestepValues
sum_all = 0.0
num_all = 0
for t in timesteps:
    data.UpdatePipeline(t)
    mb = dsa.WrapDataObject(FetchData(data)[0])
    eqps = mb.CellData['EQPS'].GetArrays()[0]
    sum_all += np.sum(eqps)
    num_all += eqps.GetNumberOfTuples()
mean_all = sum_all / num_all
print('Average EQPS over all time steps:', mean_all)
```
