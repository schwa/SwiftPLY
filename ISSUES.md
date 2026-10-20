# ISSUES.md

---

## 1: Add PLY write support

+++
status: closed
priority: medium
kind: feature
labels: effort:m, area:writer
created: 2026-10-20T11:37:52Z
updated: 2026-10-20T12:02:21Z
closed: 2026-10-20T12:02:21Z
+++

Add a PLYWriter that can write PLY files. It should support the same formats and property types as PLYReader. Add round-trip tests (write, then read back).

- `2026-10-20T11:46:58Z`: Related: #7 proposes a shared header type for reading and writing.

---

## 2: Decode PLY elements into caller-provided structs

+++
status: closed
priority: medium
kind: feature
labels: effort:l, area:reader
created: 2026-10-20T11:43:48Z
updated: 2026-10-20T12:08:46Z
closed: 2026-10-20T12:08:46Z
+++

Let a caller pass a struct type and get PLY element records filled into storage of that type.

The destination may be a Swift array or an MTLBuffer, so the API should write into caller-owned memory (UnsafeMutableBufferPointer, MutableSpan, or OutputSpan) rather than only returning [T].

Open questions:
- How properties map to struct fields: key paths, a mapping/layout description, or byte offsets.
- Whether to require layout-compatible (POD/BitwiseCopyable) types for fast binary copies.
- Type conversion when PLY types differ from field types (e.g. uchar color to Float).
- How to handle list properties.

Done when a caller can fill an [T] and an MTLBuffer with vertex structs from a binary and an ASCII PLY, with tests.

\- `2026-10-20T11:46:58Z`: Related: #6 (generic scalar decoder) prepares the ground for this.
\- `2026-10-20T11:55:36Z`: Punted by auto-issue-fixer. Read the issue and the reader code after #5 and #6. Punting: the open design questions are API decisions that the code cannot answer.

Proposal to approve or change:
- Mapping: key paths. 'PLYFieldMap<T>' with entries like '.float("x", \Vertex.position.x)' and '.uchar("red", \Vertex.color.r)'.
- Destination: 'reader.read(element:into: UnsafeMutableBufferPointer<T>, map:) throws -> Int' (records written). Convenience '[T]' overload. MTLBuffer callers use 'contents().bindMemory(to:capacity:)'.
- Conversion: the PLY value converts to the field type (uchar 255 to Float 255.0, no normalization).
- Lists: not supported in v1. Mapping a list property throws.
- Missing property in the file: throw.

Questions:
1. Is key-path mapping OK, or do you want byte offsets (MemoryLayout.offset) for a faster copy?
2. Must color uchar to Float normalize to 0...1?
3. Is v1 without list support OK?

- `2026-10-20T12:03:30Z`: Scope update: also support writing. A caller passes structs (from an array or an MTLBuffer, so UnsafeBufferPointer or Span) plus the same field map, and PLYWriter writes one record per struct. Use the same mapping for reading and writing. Done when structs round-trip (write, then read back) through all three formats.

---

## 3: Add performance benchmarks

+++
status: closed
priority: medium
kind: task
labels: effort:s, area:performance
created: 2026-10-20T11:44:05Z
updated: 2026-10-20T14:22:59Z
closed: 2026-10-20T14:22:59Z
+++

Add benchmarks for PLYReader so we can measure and track parse speed.

Cover:
- ASCII, binary little endian, and binary big endian.
- Large vertex-only files (e.g. 1M+ vertices) and files with face lists.
- readValues, read (Record dictionaries), and readFloatValues.

Report throughput (MB/s and records/s). Generate test files in code; do not commit large fixtures. Consider package-benchmark or a simple Swift Testing/XCTest measure harness.

\- `2026-10-20T13:06:47Z`: Related: #10 and #11 need these benchmarks.
\- `2026-10-20T14:22:37Z`: Benchmark run, commit cd43324, Release, 'SwiftPLYBenchmark 5 10' (median of 5), Apple M5 Max, 18 cores, 128 GB, macOS 27.0.1.

| Workload | ms | Before (baseline) |
|---|---|---|
| splat_full_le (1M INRIA splats, 248 MB) | 3.6 | 118 |
| splat_subset_le (17 of 62 properties) | 1.9 | 24 |
| splat_subset_be | 2.1 | 34 |
| splat_double_to_float | 4.0 | 315 |
| mesh_le (1M vertices + 2M faces) | 1.8 | 134 |
| scan_ascii (250k vertices + 500k faces) | 7.1 | 487 |
| total | 20.5 | 1112 |

---

## 4: Binary element offset ignores list properties

+++
status: closed
priority: high
kind: bug
labels: effort:s, area:reader
created: 2026-10-20T11:45:58Z
updated: 2026-10-20T11:50:11Z
closed: 2026-10-20T11:50:11Z
+++

readBinary and readBinaryFloats compute an element's start offset by summing fixed property sizes of earlier elements. List properties count as 0 bytes. Reading any element after one with non-empty list data starts at the wrong offset and returns garbage or throws invalidData.

Repro: binary PLY with 'element face 1 / property list uchar int i' followed by 'element vertex 1 / property float x'. Reading vertex returns wrong values.

Fix: walk earlier elements record by record to find the real offset (see the element-locating refactor issue).

- `2026-10-20T11:46:58Z`: Related: #5 fixes this as part of the element locator refactor.

---

## 5: Refactor: single internal element locator for PLYReader

+++
status: closed
priority: medium
kind: task
labels: effort:m, area:reader
created: 2026-10-20T11:45:58Z
updated: 2026-10-20T11:51:36Z
closed: 2026-10-20T11:51:36Z
+++

Internal only. Do not change public API.

Today readASCII, readBinary, and readBinaryFloats each compute where an element's data starts:
- ASCII assumes one line per record and decodes the whole file to a String on every call.
- Binary sums fixed sizes and ignores lists (see the binary offset bug).

Add one internal component that finds each element's start (ASCII line index or binary byte offset), computed once and cached on the reader. All read paths use it.

Done when: all three paths use the locator, the offset bug is fixed, and tests read every element of a mixed ASCII and binary file with lists.

- `2026-10-20T11:46:58Z`: Related: fixes #4.

---

## 6: Refactor: one generic scalar decoder for PLYReader

+++
status: closed
priority: medium
kind: task
labels: effort:m, area:reader
created: 2026-10-20T11:45:58Z
updated: 2026-10-20T11:54:35Z
closed: 2026-10-20T11:54:35Z
+++

Internal only. Do not change public API.

readBinaryValue and readBinaryFloat repeat the same type and endianness switch. readBinary and readBinaryFloats repeat the row loop. ASCII parsing is a third copy. Issue #2 (decode into caller structs) adds a fourth unless decoding is shared.

Add one internal decoder generic over the output (PropertyValue, Float, later caller fields), and one row loop shared by readValues and readFloatValues. Keep the readFloatValues fast path at least as fast (measure; see benchmarks issue #3).

Done when: the duplicate switches and loops are gone, coverage stays at 100%, and existing tests pass unchanged.

- `2026-10-20T11:46:58Z`: Related: prepares the ground for #2.

---

## 7: Model PLY properties so invalid states cannot exist

+++
status: closed
priority: low
kind: enhancement
labels: effort:m, area:reader
created: 2026-10-20T11:46:33Z
updated: 2026-10-20T11:59:45Z
closed: 2026-10-20T11:59:45Z
+++

WARNING: PUBLIC API CHANGE. This breaks source compatibility for PLYReader.Property and the header types. Do not start without approval.

PLYReader.Property has type, isList, listCountType, and listItemType. This allows invalid values, for example a list with no count type. Every read path has to guard against this, and tests have to build broken properties by hand to cover those guards.

Proposal:
- Replace the fields with an enum, for example 'case scalar(PropertyType)' and 'case list(count: PropertyType, item: PropertyType)'.
- Move the header (format, elements) into its own public value type that can be parsed and serialized. Writer support (#1) can then share it.

Done when: invalid properties cannot be built, the guards are removed, and header parse and serialize round-trip in tests.

- `2026-10-20T11:46:58Z`: Related: #1 (writer) can share the header type.

---

## 8: Fuzz PLYReader, PLYHeader, and PLYWriter

+++
status: closed
priority: medium
kind: task
labels: effort:m, area:testing
created: 2026-10-20T12:15:05Z
updated: 2026-10-20T17:11:38Z
closed: 2026-10-20T17:11:38Z
+++

Fuzz the parsers so malformed input throws a PLYError and never crashes, hangs, or reads out of bounds.

Targets:
- PLYHeader.parse and PLYReader.init with random and mutated headers.
- readValues, readFloatValues, and read(element:) on all formats with mutated bodies (truncated data, huge counts, negative list counts, NaN/inf, bad UTF-8).
- SwiftPLYStructs read(element:into:) with mutated files.
- Round trip: random headers and records through PLYWriter, then PLYReader, give the same values.

Seed corpus: Tests/SwiftPLYTests/Fixtures (including RealWorld).

Options: libFuzzer via 'swiftc -sanitize=fuzzer,address' (needs a toolchain with libFuzzer; Xcode's may not ship it), or a seeded random mutation test in Swift Testing that runs in CI with a fixed time budget.

Known risk to check: huge element counts in the header (for example 'element vertex 9999999999') with ASCII bodies, and Array(unsafeUninitializedCapacity:) with a huge count in SwiftPLYStructs.

- `2026-10-20T13:06:47Z`: Related: #15 (huge header counts).
- `2026-10-20T17:11:38Z`: Added libFuzzer fuzzing: Fuzzing/PLYFuzzer.swift, Fuzzing/PLY.dict, Fuzzing/Corpus (seeded from the Splats PLY corpus, merged to 1125 files), and 'just fuzz [minutes]' (needs 'swiftly install latest'; Xcode's Swift has no libFuzzer). The fuzzer reads every element through readValues, readFloatValues, dictionary records, and a definition read, and checks that binary files round-trip through PLYWriter. First run found duplicate element names reading the wrong data (now invalidHeader). 5-minute run after the fix: 1.37M inputs, no crashes.

---

## 9: Read and write with a structure definition instead of a Swift struct

+++
status: closed
priority: medium
kind: feature
created: 2026-10-20T12:15:23Z
updated: 2026-10-20T12:20:02Z
closed: 2026-10-20T12:20:02Z
+++

Replace the struct-based API with one that takes a structure definition: a description of a record's memory layout. Callers that do not have a Swift struct can use it directly.

Sketch (names to decide):
  struct PLYStructureDefinition { var stride: Int; var fields: [Field] }
  struct Field { var propertyName: String; var type: PLYReader.PropertyType; var offset: Int }

- Core read/write takes a definition plus raw memory (UnsafeMutableRawBufferPointer / UnsafeRawBufferPointer), for example reader.read(element:into:definition:) and writer.write(_:definition:). This lives in SwiftPLY and does not need runtime reflection.
- Callers can build a definition by hand.
- SwiftPLYStructs builds a definition from a Swift struct with the runtime reflection hack (PLYStructLayout today), keeping the current naming rules and names: overrides. The current typed read/write APIs become thin wrappers.
- PLYReader.Element(fieldsOf:) becomes an Element built from a definition.

Bonus: build a definition from MTLVertexDescriptor, MDLVertexDescriptor, and MTKModelIOVertexDescriptorFromMetal output.
- MDLVertexDescriptor has attribute names (position, normal, color, textureCoordinate) that map to PLY names (x y z, nx ny nz, red green blue alpha, s t or u v).
- MTLVertexDescriptor has no names, so it needs an attribute index to names mapping.
- Map vertex formats to PLY types (float3 to 3 x float, uchar4 to 4 x uchar). Decide what to do with normalized formats (uchar4Normalized) and half floats, which PLY has no type for.
- One buffer layout at a time (bufferIndex / layouts[n].stride). Interleaved only, unless we also support multiple buffers.
- Probably a separate opt-in target (for example SwiftPLYMetal) so SwiftPLY does not import Metal or ModelIO.

Done when: read and write work with a hand-built definition, a struct-derived definition, and a vertex-descriptor definition, with round-trip tests using the RealWorld fixtures.

---

## 10: Copy bytes directly in definition reads when types match

+++
status: closed
priority: medium
kind: enhancement
labels: effort:m, area:performance
created: 2026-10-20T12:21:26Z
updated: 2026-10-20T13:10:47Z
closed: 2026-10-20T13:10:47Z
+++

PLYReader.read(element:into:definition:) goes through readValues, which makes a PropertyValue for every scalar. For binary files where each field's type equals its property type, copy bytes directly (with byte swap for big endian). Measure with the benchmarks from #3.

- `2026-10-20T13:06:47Z`: Related: #3 (benchmarks to measure this).

---

## 11: Debug builds of readFloatValues are about 20% slower since #6

+++
status: closed
priority: low
kind: task
labels: effort:s, area:performance
created: 2026-10-20T12:21:26Z
updated: 2026-10-20T13:25:35Z
closed: 2026-10-20T13:25:35Z
+++

The generic readScalar from #6 is not specialized at -Onone. Release is unchanged; Debug went from 173 to 215 ms for 300k vertices x 4 properties. Decide if this matters. Options: @_specialize, or non-generic fast paths for Float.

- `2026-10-20T13:06:47Z`: Related: #3.
- `2026-10-20T13:25:35Z`: Closed: Debug build performance is not a goal. Release is unchanged.

---

## 12: Decide default property names for UV fields (u v or s t)

+++
status: closed
priority: low
kind: task
labels: effort:xs, area:structs
created: 2026-10-20T12:21:26Z
updated: 2026-10-20T13:19:59Z
closed: 2026-10-20T13:19:59Z
+++

defaultPropertyNames maps uv, texcoord, and textureCoordinate to u v. Blender 5.2 exports s t (see Fixtures/RealWorld/blender_cube_*.ply), so callers need names: ["textureCoordinate": ["s", "t"]]. Decide the default, or try both when reading.

\- `2026-10-20T13:14:00Z`: Punted by auto-issue-fixer: no decision recorded.

Recommendation: when reading, try the names in order: s t, then u v, then texture_u texture_v (MeshLab). When writing (Element(definition:)), use s t, which Blender writes. This needs one change: a field can have more than one candidate name set, used only by read.

Simpler option: change the default to s t and keep names: for files that use u v.

Question: fallback names when reading, or just switch the default to s t?

- `2026-10-20T13:19:59Z`: Resolved: no semantic names. A field with one lane keeps its name; more lanes map to f_0 f_1 ... Callers pass names for x y z, s t, and so on.

---

## 13: Map fixed-size array fields (InlineArray) to numbered properties

+++
status: closed
priority: low
kind: feature
labels: effort:m, area:structs
created: 2026-10-20T12:21:26Z
updated: 2026-10-20T13:12:05Z
closed: 2026-10-20T13:12:05Z
+++

Splat files have f_rest_0 ... f_rest_44. A struct field like InlineArray<45, Float> could map to f_rest_0 ... f_rest_44 with the default naming rule. InlineArray needs the macOS 26 runtime; the package targets macOS 15, so this needs availability checks.

- `2026-10-20T13:06:47Z`: The package now targets macOS 26, so InlineArray needs no availability check on macOS. iOS 18 and visionOS 2 still need one.

---

## 14: Support nested struct fields in SwiftPLYStructs

+++
status: closed
priority: low
kind: enhancement
labels: effort:m, area:structs
created: 2026-10-20T12:21:26Z
updated: 2026-10-20T13:24:51Z
closed: 2026-10-20T13:24:51Z
+++

A field whose type is another struct (for example var color: RGB) throws invalidValue. The reflection code could recurse into it and add the nested offset. Decide how nested names map (for example color.r to red, or the nested field names as is).

\- `2026-10-20T13:11:03Z`: Punted by auto-issue-fixer: the naming of nested fields needs a decision. The code change is small (recurse into a struct field with the reflection functions and add its offset).

Proposal: flatten. Nested fields use their own names and rules as if they were top-level fields. For example 'var color: RGBA' where RGBA has red/green/blue/alpha: UInt8 maps to red green blue alpha. Two nested structs with the same field names give duplicate property names, which throws (as validate() does today). 'names' overrides use the dotted path, for example names: ["color.red": ["r"]].

Alternatives: prefix with the outer field (color_red), or dotted names (color.red), which no PLY file I found uses.

Question: is flattening with dotted-path overrides OK?

- `2026-10-20T13:24:51Z`: Decided: nested fields use their own names (red green blue alpha). names: takes dotted paths for nested fields ("color.red"). Duplicate property names throw when the definition is used.

---

## 15: Check header element counts against the data size before allocating

+++
status: closed
priority: medium
kind: bug
labels: effort:s, area:reader
created: 2026-10-20T12:21:26Z
updated: 2026-10-20T13:08:40Z
closed: 2026-10-20T13:08:40Z
+++

A header like 'element vertex 9999999999' makes SwiftPLYStructs read(_:) allocate that many records with Array(unsafeUninitializedCapacity:) before any data is read. Reject counts that cannot fit in the remaining data (binary: count x minimum record size; ASCII: count x 1 line). Related: #8.

- `2026-10-20T13:06:47Z`: Related: #8 (fuzzing).

---

## 16: Support list properties in PLYStructureDefinition

+++
status: closed
priority: low
kind: feature
labels: effort:m, area:structs
created: 2026-10-20T12:21:26Z
updated: 2026-10-20T13:13:46Z
closed: 2026-10-20T13:13:46Z
+++

Definitions only map scalar properties, so faces (property list uchar int vertex_indices) cannot be read into or written from raw memory. Option: a fixed-length list field (for example 3 x int for triangles) that throws if a record has a different length.

---

## 17: Build and test on iOS and visionOS

+++
status: closed
priority: medium
kind: task
created: 2026-10-20T12:21:26Z
updated: 2026-10-20T13:05:46Z
closed: 2026-10-20T13:05:46Z
+++

CI only runs macOS. SwiftPLYMetal (ModelIO, MetalKit) and the SwiftPLYStructs runtime functions are not built or run on iOS or visionOS. Add simulator builds and tests to CI (xcb ci generate --spm-platform ios --spm-platform visionos).

---

## 18: Write API documentation for release

+++
status: new
priority: medium
kind: documentation
created: 2026-10-20T15:35:37Z
+++

Add doc comments (and possibly a DocC catalog) for the public API of SwiftPLY, SwiftPLYStructs, and SwiftPLYMetal before release: PLYReader, PLYWriter, PLYHeader, PLYStructureDefinition, the struct and vertex-descriptor helpers, and PLYError. Explain when to use the struct/definition APIs (fast, bulk) versus the value and callback APIs.

---
