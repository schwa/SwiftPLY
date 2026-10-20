# SwiftPLY

SwiftPLY reads [PLY](https://paulbourke.net/dataformats/ply/) files in Swift. It supports ASCII, binary little-endian, and binary big-endian files.

```swift
import SwiftPLY

let reader = try PLYReader(data: Data(contentsOf: url))
try reader.read { record in
    print(record["x"]?.floatValue ?? 0)
}
```

For large files, use the struct or structure definition APIs below. They are up to 50 times faster than reading or writing one `PropertyValue` at a time (see [Benchmarks](#benchmarks)).

To write a file, give `PLYWriter` a header. Then write the records of each element in header order.

```swift
let header = PLYHeader(format: .binaryLittleEndian, elements: [
    PLYReader.Element(name: "vertex", count: 1, properties: [
        PLYReader.Property(name: "x", kind: .scalar(.float))
    ])
])
var writer = PLYWriter(header: header)
try writer.write([.float(1.5)])
let data = try writer.finish()
```

## Records in memory

This is the fastest way to read and write large files. SwiftPLY copies the values straight into or out of your memory and uses all cores.

A `PLYStructureDefinition` gives the stride of a record and the offset and type of each property. With a definition, SwiftPLY reads records into raw memory, for example the contents of an `MTLBuffer`, and writes records from raw memory.

```swift
var definition = PLYStructureDefinition(stride: 16)
try definition.append("position", type: .float, offset: 0, count: 3, propertyNames: ["x", "y", "z"])
try definition.append("color", type: .uchar, offset: 12, count: 4, propertyNames: ["red", "green", "blue", "alpha"])

let buffer = UnsafeMutableRawBufferPointer(start: metalBuffer.contents(), count: metalBuffer.length)
let count = try reader.read(element: reader.elements[0], into: buffer, definition: definition)
```

A field can also be a list with the same length in every record, for example triangle faces:

```swift
let triangles = PLYStructureDefinition(stride: 12, fields: [
    .init(propertyName: "vertex_indices", type: .uint, offset: 0, list: .init(countType: .uchar, length: 3))
])
```

The opt-in `SwiftPLYMetal` library makes a definition from an `MDLVertexDescriptor` or an `MTLVertexDescriptor`.

```swift
import SwiftPLYMetal

let definition = try PLYStructureDefinition(vertexDescriptor, attributeNames: [0: "position"], names: ["position": ["x", "y", "z"]])
```

You can also read and write structs with the opt-in `SwiftPLYStructs` library. Each field must be a PLY scalar type or a SIMD vector of one. `SwiftPLYStructs` finds the fields through Swift runtime functions that are not public API. The `SwiftPLY` library does not use them.

```swift
import SwiftPLYStructs

struct Splat {
    var position: SIMD3<Float>
    var scale: SIMD3<Float>     // scale_0 scale_1 scale_2
    var opacity: Float          // opacity
}

// A field with more than one lane maps to numbered names. Pass names to use others.
let names = ["position": ["x", "y", "z"]]
let splats = try reader.read(Splat.self, names: names)

let element = try PLYReader.Element(name: "vertex", count: splats.count, fieldsOf: Splat.self, names: names)
var writer = PLYWriter(header: PLYHeader(format: .binaryLittleEndian, elements: [element]))
try writer.write(splats, names: names)
```

`PLYStructureDefinition(for: Splat.self, names: names)` gives the definition for a struct.

## Benchmarks

`SwiftPLYBenchmark` reads and writes large files that it makes in memory, then checks the results. Build it in Release:

```sh
swift build -c release --product SwiftPLYBenchmark
.build/release/SwiftPLYBenchmark 5 10          # reading
.build/release/SwiftPLYBenchmark write 5 10    # writing
.build/release/SwiftPLYBenchmark values 5 10   # one value at a time
```

Results on an Apple M5 Max (18 cores), macOS 27.0.1, Release build. Reading starts from `Data` in memory and includes `PLYReader.init`. Writing ends with the file `Data` in memory.

"Struct" is the struct and structure definition APIs. "Value" is `readValues` and `write(_: [PropertyValue])`, which read or write one value at a time. Each time is the median of 5 runs.

| Workload | Struct read | Value read | Struct write | Value write |
|---|---|---|---|---|
| 1M Gaussian splats, 62 float properties, binary (237 MB) | 3.8 ms | 58 ms | 3.6 ms | 125 ms |
| Mesh: 1M vertices (float xyz, uchar rgba) and 2M triangles, binary | 1.7 ms | 84 ms | 3.0 ms | 94 ms |
| Mesh: 250k vertices and 500k triangles, ASCII | 8.6 ms | 49 ms | 12.5 ms | 30 ms |

Reading the splats as dictionary records with `read(element:callback:)` takes 248 ms. The benchmark also measures big-endian files, ASCII splats, subsets of properties, and conversion from `double` to `Float`.

## Fuzzing

The fuzzer reads each input through all read APIs. If a binary file reads, it writes the file and reads it again to check the values.

The Swift in Xcode cannot build the fuzzer. Install the open-source toolchain with [swiftly](https://www.swift.org/install/macos/swiftly/):

```sh
swiftly install latest
```

Then run the fuzzer for 5 minutes, or give the number of minutes:

```sh
just fuzz
just fuzz 30
```
