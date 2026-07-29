# Readers & data inspection

Pick the reader by file extension. Every script starts with
`from paraview.simple import *`.

## Contents

- [Version check](#version-check)
- [Readers by extension](#readers-by-extension)
- [RAW volume files](#raw-volume-files)
- [Data inspection](#data-inspection)

## Version check

The `paraview.simple` API drifts between versions, so when a call is rejected (or
you are unsure a property exists locally) emit a version probe rather than
guessing. This is diagnostic — not boilerplate for every script.

```python
from paraview.simple import GetParaViewVersion
print(GetParaViewVersion())   # e.g. (5, 13); APIs below differ across versions
```

## Readers by extension

### `.vtk` (legacy VTK)

Use when the input is a legacy VTK file. Type may be structured/rectilinear
grid, image/volume, unstructured grid, or polydata; also supports file series.

```python
ml100vtk = LegacyVTKReader(registrationName='input', FileNames=['<input_path>'])
```

### `.ex2` / Exodus / IOSS

Preferred reader for Exodus II / IOSS data (distributed reader).

```python
reader = IOSSReader(registrationName='input', FileName=['<input_path>'])
```

Alternative Exodus reader (older API; use IOSSReader unless something requires
this one):

```python
reader = ExodusIIReader(FileName='<input_path>')
reader.UpdatePipeline()
```

### `.vtp` (XML PolyData)

Use when the input is XML polygonal data. Declare the point arrays to load.

```python
mpasvtp = XMLPolyDataReader(registrationName='input', FileName=['<input_path>'])
mpasvtp.PointArrayStatus = ['velocity', 'temperature', 'salinity']  # adapt to the file
```

### `.vtr` (XML RectilinearGrid)

Use for rectilinear grids; declare the cell (or point) arrays to load.

```python
predictionvtr = XMLRectilinearGridReader(registrationName='input', FileName=['<input_path>'])
predictionvtr.CellArrayStatus = ['Intensity', 'Phase']  # adapt to the file
```

### `.vtm` (XML MultiBlock)

Use when reading a multi-block dataset or a saved file series.

```python
canslices = XMLMultiBlockDataReader(FileName=['<input_path>'])
```

### `.csv` (CSVReader)

Use for tabular data. A CSV is a table, not geometry — to plot it in 3D, feed it
through `TableToPoints` to turn named columns into a point cloud (see
`filters.md`).

```python
csv = CSVReader(FileName=['<input_path>'])
```

### `.nc` (NetCDFReader)

Use for NetCDF datasets (often climate/ocean grids).

```python
reader = NetCDFReader(FileName=['<input_path>'])
```

### Generic open / sources

`OpenDataFile` auto-selects a reader by extension when you do not want to commit
to a specific reader class:

```python
reader = OpenDataFile('<input_path>')
```

Procedural sources (no file): `Wavelet()` builds a synthetic uniform grid with
an `RTData` scalar; `Sphere()` builds a sphere. Useful for demos/tests.

```python
wavelet1 = Wavelet(registrationName='Wavelet1')
```

## RAW volume files

Use for headerless `.raw` binary volumes. The reader cannot infer geometry, so
you must set the extent, scalar type, byte order, and component count explicitly.
Dimensions/type are often encoded in the filename (e.g. `foot_256x256x256_uint8.raw`).

```python
reader = OpenDataFile('<input_path>')
reader.DataExtent = [0, 255, 0, 255, 0, 255]   # [0, dim_x-1, 0, dim_y-1, 0, dim_z-1]
reader.FileDimensionality = 3
reader.DataScalarType = 'unsigned char'         # see the type map below
reader.DataByteOrder = 'LittleEndian'           # or 'BigEndian'
reader.NumberOfScalarComponents = 1
reader.DataSpacing = [1.0, 1.0, 1.0]            # only set if non-uniform
```

`ImageReader` is the explicit reader class for the same job — use it when you
want to name the reader rather than rely on `OpenDataFile`'s extension guess. The
configuration properties are identical:

```python
reader = ImageReader(FileNames=['<input_path>'])
reader.DataScalarType = 'unsigned char'         # see the type map below
reader.DataByteOrder = 'LittleEndian'           # or 'BigEndian'
reader.DataExtent = [0, 255, 0, 255, 0, 255]    # [0, dim_x-1, 0, dim_y-1, 0, dim_z-1]
reader.FileDimensionality = 3
reader.NumberOfScalarComponents = 1
```

Map the on-disk data type to ParaView's `DataScalarType`:

| RAW type  | `DataScalarType` |
| --------- | ---------------- |
| `uint8`   | `unsigned char`  |
| `uint16`  | `unsigned short` |
| `int8`    | `char`           |
| `int16`   | `short`          |
| `float32` | `float`          |
| `float64` | `double`         |

A 3D RAW volume cannot use the default image-slice representation — show it as
`'Outline'` (cheap) or `'Volume'` (see volume rendering in
`displays-and-color.md`):

```python
display = Show(reader, renderView)
display.SetRepresentationType('Outline')
```

## Data inspection

Emit these **only** when the script genuinely needs them — before transfer
functions (which reference `min`/`max`) or before explicit camera math (which
references `bounds`). Plain slices, contours, clips, and wireframes do not need
them. Always `UpdatePipeline()` first so the data information is populated, and
reference the reader variable explicitly (`GetActiveSource()` is unreliable
under `pvpython`).

### Scalar min/max of the first PointData array

Use before configuring transfer functions, or to discover the array name when
the user named none.

```python
ml100vtk.UpdatePipeline()
pd = ml100vtk.PointData
array_name = pd.GetArray(0).GetName()   # the real name of the first array
min, max = pd.GetArray(0).GetRange()
```

### Spatial bounds (for explicit camera placement)

Use before deriving a camera position from the dataset extent.

```python
reader.UpdatePipeline()
bounds = reader.GetDataInformation().GetBounds()
length = [bounds[1] - bounds[0], bounds[3] - bounds[2], bounds[5] - bounds[4]]
```

### Print all PointData arrays and their ranges

Use to discover available arrays and component ranges. Anything `print()`ed is
visible in stdout, which helps when the user did not name an array.

```python
reader = OpenDataFile('<input_path>')
pd = reader.PointData
for ai in pd.values():
    print(ai.GetName(), ai.GetNumberOfComponents(), end=' ')
    for i in range(ai.GetNumberOfComponents()):
        print(ai.GetRange(i), end=' ')
    print()
```
