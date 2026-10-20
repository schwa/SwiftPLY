import Foundation
import SwiftPLY
import SwiftPLYStructs

// Loading benchmarks: Data to Swift values, including PLYReader.init. Files are generated in memory.
// Every workload checks its results, so a fast but wrong loader fails.
// Usage: SwiftPLYBenchmark [repeats] [scale]. Prints `METRIC name=milliseconds` lines (median of the repeats).

// swiftlint:disable identifier_name
struct InriaSplat {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var f_dc: SIMD3<Float>
    var f_rest: InlineArray<45, Float>
    var opacity: Float
    var scale: SIMD3<Float>
    var rot: SIMD4<Float>
}

struct RenderSplat {
    var position: SIMD3<Float>
    var f_dc: SIMD3<Float>
    var opacity: Float
    var scale: SIMD3<Float>
    var rot: SIMD4<Float>
}
// swiftlint:enable identifier_name

struct MeshVertex {
    var position: SIMD3<Float>
    var color: SIMD4<UInt8>
}

struct ScanVertex {
    var position: SIMD3<Float>
    var confidence: Float
}

struct BenchmarkFailure: Error, CustomStringConvertible {
    var description: String
}

func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition {
        throw BenchmarkFailure(description: message())
    }
}

// Deterministic values that are different for every record and property, and exact in Float and Double.
func value(_ record: Int, _ property: Int) -> Float {
    Float((record &* 31 &+ property &* 7) % 2_048) * 0.25 - 256
}

let positionNames = ["position": ["x", "y", "z"]]
let splatNames = [
    "position": ["x", "y", "z"],
    "normal": ["nx", "ny", "nz"]
]
let meshNames = [
    "position": ["x", "y", "z"],
    "color": ["red", "green", "blue", "alpha"]
]

struct BinaryBuilder {
    var data = Data()
    let littleEndian: Bool

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: littleEndian ? value.littleEndian : value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Float) {
        append(value.bitPattern)
    }

    mutating func append(_ value: Double) {
        append(value.bitPattern)
    }
}

let splatPropertyNames = ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2"]
    + (0..<45).map { "f_rest_\($0)" }
    + ["opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]

func makeSplatFile(count: Int, littleEndian: Bool, double: Bool = false) -> Data {
    let type = double ? "double" : "float"
    var header = "ply\nformat \(littleEndian ? "binary_little_endian" : "binary_big_endian") 1.0\nelement vertex \(count)\n"
    for name in splatPropertyNames {
        header += "property \(type) \(name)\n"
    }
    header += "end_header\n"
    var builder = BinaryBuilder(data: Data(header.utf8), littleEndian: littleEndian)
    builder.data.reserveCapacity(header.utf8.count + count * splatPropertyNames.count * (double ? 8 : 4))
    for record in 0..<count {
        for property in splatPropertyNames.indices {
            if double {
                builder.append(Double(value(record, property)))
            } else {
                builder.append(value(record, property))
            }
        }
    }
    return builder.data
}

func makeMeshFile(vertexCount: Int, faceCount: Int) -> Data {
    let header = """
    ply
    format binary_little_endian 1.0
    element vertex \(vertexCount)
    property float x
    property float y
    property float z
    property uchar red
    property uchar green
    property uchar blue
    property uchar alpha
    element face \(faceCount)
    property list uchar int vertex_indices
    end_header

    """
    var builder = BinaryBuilder(data: Data(header.utf8), littleEndian: true)
    for record in 0..<vertexCount {
        for property in 0..<3 {
            builder.append(value(record, property))
        }
        for property in 0..<4 {
            builder.append(UInt8(truncatingIfNeeded: record &+ property))
        }
    }
    for face in 0..<faceCount {
        builder.append(UInt8(3))
        for corner in 0..<3 {
            builder.append(Int32((face &+ corner) % vertexCount))
        }
    }
    return builder.data
}

func makeASCIIScanFile(vertexCount: Int, faceCount: Int) -> Data {
    var text = """
    ply
    format ascii 1.0
    comment Like the Stanford scans
    element vertex \(vertexCount)
    property float x
    property float y
    property float z
    property float confidence
    property float intensity
    element face \(faceCount)
    property list uchar int vertex_indices
    end_header

    """
    for record in 0..<vertexCount {
        text += "\(value(record, 0)) \(value(record, 1)) \(value(record, 2)) \(value(record, 3)) 0.5\n"
    }
    for face in 0..<faceCount {
        text += "3 \(face % vertexCount) \((face + 1) % vertexCount) \((face + 2) % vertexCount)\n"
    }
    return Data(text.utf8)
}

struct Workload {
    var name: String
    var makeData: () -> Data
    var run: (Data) throws -> Void
}

func makeWorkloads(scale: Int) -> [Workload] {
    let splatCount = 100_000 * scale
    let vertexCount = 100_000 * scale
    let faceCount = 200_000 * scale
    let asciiVertexCount = 25_000 * scale
    let asciiFaceCount = 50_000 * scale

    let fullSplat = Workload(name: "splat_full_le", makeData: { makeSplatFile(count: splatCount, littleEndian: true) }) { data in
        let splats = try PLYReader(data: data).read(InriaSplat.self, names: splatNames)
        try check(splats.count == splatCount, "splat count")
        for record in [0, splatCount / 2, splatCount - 1] {
            let splat = splats[record]
            try check(splat.position == [value(record, 0), value(record, 1), value(record, 2)], "splat position \(record)")
            try check(splat.f_rest[44] == value(record, 53), "splat f_rest \(record)")
            try check(splat.rot.w == value(record, 61), "splat rot \(record)")
        }
    }

    func renderSplat(name: String, littleEndian: Bool, double: Bool) -> Workload {
        Workload(name: name, makeData: { makeSplatFile(count: splatCount, littleEndian: littleEndian, double: double) }) { data in
            let splats = try PLYReader(data: data).read(RenderSplat.self, names: positionNames)
            try check(splats.count == splatCount, "\(name) count")
            for record in [0, splatCount / 3, splatCount - 1] {
                let splat = splats[record]
                try check(splat.position == [value(record, 0), value(record, 1), value(record, 2)], "\(name) position \(record)")
                try check(splat.f_dc == [value(record, 6), value(record, 7), value(record, 8)], "\(name) f_dc \(record)")
                try check(splat.opacity == value(record, 54), "\(name) opacity \(record)")
                try check(splat.scale.z == value(record, 57), "\(name) scale \(record)")
                try check(splat.rot == [value(record, 58), value(record, 59), value(record, 60), value(record, 61)], "\(name) rot \(record)")
            }
        }
    }

    let mesh = Workload(name: "mesh_le", makeData: { makeMeshFile(vertexCount: vertexCount, faceCount: faceCount) }) { data in
        let reader = try PLYReader(data: data)
        let vertices = try reader.read(MeshVertex.self, element: reader.elements[0], names: meshNames)
        let triangles = PLYStructureDefinition(stride: 12, fields: [
            .init(propertyName: "vertex_indices", type: .int, offset: 0, list: .init(countType: .uchar, length: 3))
        ])
        var indices = [Int32](repeating: 0, count: reader.maximumRecordCount(of: reader.elements[1]) * 3)
        let faces = try indices.withUnsafeMutableBytes { try reader.read(element: reader.elements[1], into: $0, definition: triangles) }
        try check(vertices.count == vertexCount && faces == faceCount, "mesh counts")
        for record in [0, vertexCount - 1] {
            try check(vertices[record].position.y == value(record, 1), "mesh position \(record)")
            try check(vertices[record].color.w == UInt8(truncatingIfNeeded: record &+ 3), "mesh color \(record)")
        }
        for face in [0, faceCount - 1] {
            try check(indices[face * 3 + 2] == Int32((face + 2) % vertexCount), "mesh face \(face)")
        }
    }

    let ascii = Workload(name: "scan_ascii", makeData: { makeASCIIScanFile(vertexCount: asciiVertexCount, faceCount: asciiFaceCount) }) { data in
        let reader = try PLYReader(data: data)
        let vertices = try reader.read(ScanVertex.self, element: reader.elements[0], names: positionNames)
        let triangles = PLYStructureDefinition(stride: 12, fields: [
            .init(propertyName: "vertex_indices", type: .int, offset: 0, list: .init(countType: .uchar, length: 3))
        ])
        var indices = [Int32](repeating: 0, count: reader.maximumRecordCount(of: reader.elements[1]) * 3)
        let faces = try indices.withUnsafeMutableBytes { try reader.read(element: reader.elements[1], into: $0, definition: triangles) }
        try check(vertices.count == asciiVertexCount && faces == asciiFaceCount, "scan counts")
        for record in [0, asciiVertexCount - 1] {
            try check(vertices[record].position.z == value(record, 2) && vertices[record].confidence == value(record, 3), "scan vertex \(record)")
        }
        try check(indices[asciiFaceCount * 3 - 1] == Int32((asciiFaceCount + 1) % asciiVertexCount), "scan face")
    }

    return [
        fullSplat,
        renderSplat(name: "splat_subset_le", littleEndian: true, double: false),
        renderSplat(name: "splat_subset_be", littleEndian: false, double: false),
        renderSplat(name: "splat_double_to_float", littleEndian: true, double: true),
        mesh,
        ascii
    ]
}

// `SwiftPLYBenchmark write [repeats] [scale]` runs the writing benchmarks instead, and
// `SwiftPLYBenchmark values [repeats] [scale] [filter]` runs the callback and value API benchmarks.
let mode = CommandLine.arguments.count > 1 && ["write", "values"].contains(CommandLine.arguments[1]) ? CommandLine.arguments[1] : "read"
let arguments = mode == "read" ? CommandLine.arguments : Array(CommandLine.arguments.dropFirst())
let repeats = arguments.count > 1 ? Int(arguments[1]) ?? 5 : 5
let scale = arguments.count > 2 ? Int(arguments[2]) ?? 1 : 1

if mode != "read" {
    do {
        if mode == "write" {
            try runWriteBenchmarks(repeats: repeats, scale: scale)
        } else {
            try runValueBenchmarks(repeats: repeats, scale: scale, filter: arguments.count > 3 ? arguments[3] : "")
        }
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }
    exit(0)
}

do {
    let workloads = makeWorkloads(scale: scale)
    let clock = ContinuousClock()
    var total = 0.0
    for workload in workloads {
        let data = workload.makeData()
        var times: [Double] = []
        for _ in 0..<repeats {
            let duration = try clock.measure { try workload.run(data) }
            times.append(Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1_000)
        }
        let median = times.sorted()[times.count / 2]
        total += median
        print("METRIC \(workload.name)_ms=\(String(format: "%.3f", median))")
        // Diagnostic: the part of the load that is PLYReader.init. Not part of total_ms.
        var initTimes: [Double] = []
        for _ in 0..<repeats {
            let duration = try clock.measure { _ = try PLYReader(data: data) }
            initTimes.append(Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1_000)
        }
        print("DIAGNOSTIC \(workload.name)_init_ms=\(String(format: "%.3f", initTimes.sorted()[initTimes.count / 2]))")
    }
    print("METRIC total_ms=\(String(format: "%.3f", total))")
} catch {
    print("FAILED: \(error)")
    exit(1)
}
