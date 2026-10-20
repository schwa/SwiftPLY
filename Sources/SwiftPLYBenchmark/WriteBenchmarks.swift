import Foundation
import SwiftPLY
import SwiftPLYStructs

// Writing benchmarks: Swift values to PLY `Data`, including PLYWriter.init and finish(). The source values are made
// before timing. After timing, each file is read back and compared with the source, so a fast but wrong writer fails.

private let triangles = PLYStructureDefinition(stride: 12, fields: [
    .init(propertyName: "vertex_indices", type: .int, offset: 0, list: .init(countType: .uchar, length: 3))
])

// Compares the bytes of every field. Padding between fields is not compared.
private func checkSame<T>(_ written: [T], _ source: [T], _ definition: PLYStructureDefinition, _ name: String) throws {
    try check(written.count == source.count, "\(name) count \(written.count) vs \(source.count)")
    try written.withUnsafeBytes { writtenBytes in
        try source.withUnsafeBytes { sourceBytes in
            for record in 0..<source.count {
                for field in definition.fields {
                    let offset = record * definition.stride + field.offset
                    let size = field.type.size * (field.list?.length ?? 1)
                    try check(memcmp(writtenBytes.baseAddress.unsafelyUnwrapped + offset, sourceBytes.baseAddress.unsafelyUnwrapped + offset, size) == 0, "\(name) record \(record) \(field.propertyName)")
                }
            }
        }
    }
}

private func readBack<T: BitwiseCopyable>(_ data: Data, _: T.Type, element: Int, names: [String: [String]]) throws -> [T] {
    let reader = try PLYReader(data: data)
    return try reader.read(T.self, element: reader.elements[element], names: names)
}

// Three indices for each face, with no padding, as `triangles` describes.
private func readTriangles(_ data: Data, element: Int) throws -> [Int32] {
    let reader = try PLYReader(data: data)
    var indices = [Int32](repeating: 0, count: reader.maximumRecordCount(of: reader.elements[element]) * 3)
    let count = try indices.withUnsafeMutableBytes { try reader.read(element: reader.elements[element], into: $0, definition: triangles) }
    return Array(indices.prefix(count * 3))
}

private struct WriteWorkload {
    var name: String
    // Makes the source values, and returns the timed write and the check of its result.
    var prepare: () throws -> (write: () throws -> Data, check: (Data) throws -> Void)
}

private func makeWriteWorkloads(scale: Int) -> [WriteWorkload] {
    let splatCount = 100_000 * scale
    let vertexCount = 100_000 * scale
    let faceCount = 200_000 * scale
    let asciiVertexCount = 25_000 * scale
    let asciiFaceCount = 50_000 * scale

    func fullSplats(_ format: PLYReader.Format) -> WriteWorkload {
        WriteWorkload(name: "write_splat_full_\(format == .binaryLittleEndian ? "le" : "be")") {
            let splats = (0..<splatCount).map { record in
                InriaSplat(
                    position: [value(record, 0), value(record, 1), value(record, 2)],
                    normal: [value(record, 3), value(record, 4), value(record, 5)],
                    f_dc: [value(record, 6), value(record, 7), value(record, 8)],
                    f_rest: InlineArray { value(record, 9 + $0) },
                    opacity: value(record, 54),
                    scale: [value(record, 55), value(record, 56), value(record, 57)],
                    rot: [value(record, 58), value(record, 59), value(record, 60), value(record, 61)]
                )
            }
            let definition = try PLYStructureDefinition(for: InriaSplat.self, names: splatNames)
            let write = {
                let element = PLYReader.Element(name: "vertex", count: splats.count, definition: definition)
                var writer = PLYWriter(header: PLYHeader(format: format, elements: [element]))
                try writer.write(splats, names: splatNames)
                return try writer.finish()
            }
            return (write, { data in try checkSame(try readBack(data, InriaSplat.self, element: 0, names: splatNames), splats, definition, "splat") })
        }
    }

    let renderSplats = WriteWorkload(name: "write_splat_render_le") {
        let splats = (0..<splatCount).map { record in
            RenderSplat(
                position: [value(record, 0), value(record, 1), value(record, 2)],
                f_dc: [value(record, 6), value(record, 7), value(record, 8)],
                opacity: value(record, 54),
                scale: [value(record, 55), value(record, 56), value(record, 57)],
                rot: [value(record, 58), value(record, 59), value(record, 60), value(record, 61)]
            )
        }
        let definition = try PLYStructureDefinition(for: RenderSplat.self, names: positionNames)
        let write = {
            let element = PLYReader.Element(name: "vertex", count: splats.count, definition: definition)
            var writer = PLYWriter(header: PLYHeader(format: .binaryLittleEndian, elements: [element]))
            try writer.write(splats, names: positionNames)
            return try writer.finish()
        }
        return (write, { data in try checkSame(try readBack(data, RenderSplat.self, element: 0, names: positionNames), splats, definition, "render splat") })
    }

    func mesh(_ format: PLYReader.Format, vertexCount: Int, faceCount: Int, name: String) -> WriteWorkload {
        WriteWorkload(name: name) {
            let vertices = (0..<vertexCount).map { record in
                MeshVertex(
                    position: [value(record, 0), value(record, 1), value(record, 2)],
                    color: SIMD4((0..<4).map { UInt8(truncatingIfNeeded: record &+ $0) })
                )
            }
            let faces = (0..<faceCount).flatMap { face in
                (0..<3).map { Int32((face + $0) % vertexCount) }
            }
            let definition = try PLYStructureDefinition(for: MeshVertex.self, names: meshNames)
            let write = {
                var writer = PLYWriter(header: PLYHeader(format: format, elements: [
                    PLYReader.Element(name: "vertex", count: vertices.count, definition: definition),
                    PLYReader.Element(name: "face", count: faceCount, definition: triangles)
                ]))
                try writer.write(vertices, names: meshNames)
                try faces.withUnsafeBytes { try writer.write($0, definition: triangles) }
                return try writer.finish()
            }
            let checkResult = { (data: Data) in
                try checkSame(try readBack(data, MeshVertex.self, element: 0, names: meshNames), vertices, definition, "\(name) vertex")
                try check(try readTriangles(data, element: 1) == faces, "\(name) faces")
            }
            return (write, checkResult)
        }
    }

    return [
        fullSplats(.binaryLittleEndian),
        fullSplats(.binaryBigEndian),
        renderSplats,
        mesh(.binaryLittleEndian, vertexCount: vertexCount, faceCount: faceCount, name: "write_mesh_le"),
        mesh(.ascii, vertexCount: asciiVertexCount, faceCount: asciiFaceCount, name: "write_mesh_ascii")
    ]
}

func runWriteBenchmarks(repeats: Int, scale: Int) throws {
    let clock = ContinuousClock()
    var total = 0.0
    for workload in makeWriteWorkloads(scale: scale) {
        let (write, checkResult) = try workload.prepare()
        var times: [Double] = []
        var result = Data()
        for _ in 0..<repeats {
            let duration = try clock.measure { result = try write() }
            times.append(Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1_000)
        }
        try checkResult(result)
        let median = times.sorted()[times.count / 2]
        total += median
        print("METRIC \(workload.name)_ms=\(String(format: "%.3f", median))")
        print("DIAGNOSTIC \(workload.name)_mb=\(String(format: "%.1f", Double(result.count) / 1_048_576))")
    }
    print("METRIC write_total_ms=\(String(format: "%.3f", total))")
}
