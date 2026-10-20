import Foundation
import SwiftPLY

// Benchmarks for the callback and value APIs: `readValues`, `readFloatValues`, `read(element:callback:)`, and
// `write(_: [PropertyValue])`. The files and values are made before timing. Every workload checks its results.

private struct ValueWorkload {
    var name: String
    // Makes the input, and returns the timed work.
    var prepare: () throws -> () throws -> Void
}

private func makeValueWorkloads(scale: Int) -> [ValueWorkload] {
    let splatCount = 100_000 * scale
    let vertexCount = 100_000 * scale
    let faceCount = 200_000 * scale
    let asciiVertexCount = 25_000 * scale
    let asciiFaceCount = 50_000 * scale
    let samples = [0, splatCount / 2, splatCount - 1]

    let readValues = ValueWorkload(name: "values_read_splat_readValues") {
        let data = makeSplatFile(count: splatCount, littleEndian: true)
        return {
            let reader = try PLYReader(data: data)
            var record = 0
            try reader.readValues(element: reader.elements[0]) { values in
                if samples.contains(record) {
                    try check(values[53] == .float(value(record, 53)), "readValues record \(record)")
                }
                record += 1
            }
            try check(record == splatCount, "readValues count")
        }
    }

    let readFloatValues = ValueWorkload(name: "values_read_splat_readFloatValues") {
        let data = makeSplatFile(count: splatCount, littleEndian: false)
        return {
            let reader = try PLYReader(data: data)
            var record = 0
            try reader.readFloatValues(element: reader.elements[0]) { values in
                if samples.contains(record) {
                    try check(values[61] == value(record, 61), "readFloatValues record \(record)")
                }
                record += 1
            }
            try check(record == splatCount, "readFloatValues count")
        }
    }

    let readRecords = ValueWorkload(name: "values_read_splat_records") {
        let data = makeSplatFile(count: splatCount, littleEndian: true)
        return {
            let reader = try PLYReader(data: data)
            var record = 0
            try reader.read(element: reader.elements[0]) { values in
                if samples.contains(record) {
                    try check(values["opacity"] == .float(value(record, 54)), "records record \(record)")
                }
                record += 1
            }
            try check(record == splatCount, "records count")
        }
    }

    let readMesh = ValueWorkload(name: "values_read_mesh_readValues") {
        let data = makeMeshFile(vertexCount: vertexCount, faceCount: faceCount)
        return {
            let reader = try PLYReader(data: data)
            var vertices = 0
            try reader.readValues(element: reader.elements[0]) { _ in vertices += 1 }
            var face = 0
            try reader.readValues(element: reader.elements[1]) { values in
                if face == faceCount - 1 {
                    try check(values[0] == .list([.int(Int32(face % vertexCount)), .int(Int32((face + 1) % vertexCount)), .int(Int32((face + 2) % vertexCount))]), "mesh face")
                }
                face += 1
            }
            try check(vertices == vertexCount && face == faceCount, "mesh counts")
        }
    }

    let readASCII = ValueWorkload(name: "values_read_ascii_readValues") {
        let data = makeASCIIScanFile(vertexCount: asciiVertexCount, faceCount: asciiFaceCount)
        return {
            let reader = try PLYReader(data: data)
            var vertex = 0
            try reader.readValues(element: reader.elements[0]) { values in
                if vertex == asciiVertexCount - 1 {
                    try check(values[2] == .float(value(vertex, 2)), "ascii vertex")
                }
                vertex += 1
            }
            var faces = 0
            try reader.readValues(element: reader.elements[1]) { _ in faces += 1 }
            try check(vertex == asciiVertexCount && faces == asciiFaceCount, "ascii counts")
        }
    }

    func writeSplats(_ format: PLYReader.Format, name: String) -> ValueWorkload {
        ValueWorkload(name: name) {
            let properties = splatPropertyNames.map { PLYReader.Property(name: $0, kind: .scalar(.float)) }
            let header = PLYHeader(format: format, elements: [PLYReader.Element(name: "vertex", count: splatCount, properties: properties)])
            let records = (0..<splatCount).map { record in
                (0..<properties.count).map { PLYReader.PropertyValue.float(value(record, $0)) }
            }
            let expected = format == .ascii ? nil : makeSplatFile(count: splatCount, littleEndian: format == .binaryLittleEndian)
            return {
                var writer = PLYWriter(header: header)
                for record in records {
                    try writer.write(record)
                }
                let data = try writer.finish()
                if let expected {
                    try check(data.dropFirst(header.serialized.utf8.count) == expected.dropFirst(try PLYReader(data: expected).bodyOffset), "\(name) bytes")
                }
            }
        }
    }

    func writeMesh(name: String, ascii: Bool = false) -> ValueWorkload {
        ValueWorkload(name: name) {
            let data = ascii ? makeASCIIScanFile(vertexCount: asciiVertexCount, faceCount: asciiFaceCount) : makeMeshFile(vertexCount: vertexCount, faceCount: faceCount)
            let reader = try PLYReader(data: data)
            var records: [[PLYReader.PropertyValue]] = []
            for element in reader.elements {
                try reader.readValues(element: element) { values in records.append(values.map { $0 ?? .float(0) }) }
            }
            return {
                var writer = PLYWriter(header: reader.header)
                for record in records {
                    try writer.write(record)
                }
                let written = try writer.finish()
                try check(written.dropFirst(reader.header.serialized.utf8.count) == data.dropFirst(reader.bodyOffset), "\(name) bytes")
            }
        }
    }

    return [
        readValues,
        readFloatValues,
        readRecords,
        readMesh,
        readASCII,
        writeSplats(.binaryLittleEndian, name: "values_write_splat_le"),
        writeSplats(.ascii, name: "values_write_splat_ascii"),
        writeMesh(name: "values_write_mesh_le"),
        writeMesh(name: "values_write_mesh_ascii", ascii: true)
    ]
}

// `filter` runs only the workloads whose names contain it, and names the total after it.
func runValueBenchmarks(repeats: Int, scale: Int, filter: String) throws {
    let clock = ContinuousClock()
    var total = 0.0
    for workload in makeValueWorkloads(scale: scale) where filter.isEmpty || workload.name.contains(filter) {
        let run = try workload.prepare()
        var times: [Double] = []
        for _ in 0..<repeats {
            let duration = try clock.measure { try run() }
            times.append(Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1_000)
        }
        let median = times.sorted()[times.count / 2]
        total += median
        print("METRIC \(workload.name)_ms=\(String(format: "%.3f", median))")
    }
    print("METRIC values\(filter.isEmpty ? "" : "_\(filter)")_total_ms=\(String(format: "%.3f", total))")
}
