import Foundation
import SwiftPLY
import Testing

// Truncated copies of real files: Gaussian splats (INRIA, cluster fly, SH demo, Sharp), the Stanford bunny,
// a beetle mesh with face colors, a mesh with RGBA vertex colors, and a Blender 5.2 cube export.
private let realWorldURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/RealWorld")

private let fixtureNames = [
    "beetle_ascii", "beetle_binary", "blender_cube_ascii", "blender_cube_binary", "bunny", "mesh_rgba_garden",
    "sharp_extra_elements", "splat_cluster_fly_16", "splat_inria_3", "splat_normals_no_sh", "splat_sh1"
]

private func load(_ name: String) throws -> PLYReader {
    try PLYReader(data: Data(contentsOf: realWorldURL.appendingPathComponent("\(name).ply")))
}

private func allValues(_ reader: PLYReader) throws -> [[[PLYReader.PropertyValue?]]] {
    try reader.elements.map { element in
        var records: [[PLYReader.PropertyValue?]] = []
        try reader.readValues(element: element) { records.append($0) }
        return records
    }
}

@Suite("Real-world PLY files")
internal struct RealWorldTests {
    @Test("Every element reads completely", arguments: fixtureNames)
    func readsCompletely(name: String) throws {
        let reader = try load(name)
        for (element, records) in try zip(reader.elements, allValues(reader)) {
            #expect(records.count == element.count, "\(element.name)")
            #expect(records.allSatisfy { !$0.contains(nil) }, "\(element.name)")
            var floatCount = 0
            try reader.readFloatValues(element: element) { _ in floatCount += 1 }
            #expect(floatCount == element.count)
        }
    }

    @Test("Writing every record back gives the same values", arguments: fixtureNames, [PLYReader.Format.ascii, .binaryBigEndian])
    func rewrite(name: String, format: PLYReader.Format) throws {
        let reader = try load(name)
        var writer = PLYWriter(header: PLYHeader(format: format, elements: reader.elements))
        let original = try allValues(reader)
        for records in original {
            for record in records {
                try writer.write(record.compactMap(\.self))
            }
        }
        #expect(try allValues(PLYReader(data: writer.finish())) == original)
    }

    @Test("Binary files written back are byte-identical after the header", arguments: fixtureNames)
    func binaryBodyIdentical(name: String) throws {
        let data = try Data(contentsOf: realWorldURL.appendingPathComponent("\(name).ply"))
        let reader = try PLYReader(data: data)
        guard reader.format != .ascii else {
            return
        }
        var writer = PLYWriter(header: reader.header)
        for records in try allValues(reader) {
            for record in records {
                try writer.write(record.compactMap(\.self))
            }
        }
        let written = try writer.finish()
        #expect(written.dropFirst(reader.header.serialized.utf8.count) == data.dropFirst(reader.bodyOffset))
    }

    @Test("Spot values match an independent Python decoder")
    func spotValues() throws {
        let beetle = try load("beetle_binary")
        var face: [PLYReader.PropertyValue?] = []
        try beetle.readValues(element: beetle.elements[1]) { if face.isEmpty { face = $0 } }
        #expect(face.prefix(6) == [.list([.int(0), .int(1), .int(2)]), .int(0), .uchar(191), .uchar(191), .uchar(191), .uchar(255)])
        #expect(beetle.elements[1].properties.last?.name == "materialIndex")

        let garden = try load("mesh_rgba_garden")
        var vertex: [Float?] = []
        try garden.readFloatValues(element: garden.elements[0]) { if vertex.isEmpty { vertex = $0 } }
        #expect(vertex == [Float(4.905365943908691), Float(3.639979124069214), Float(-0.8202934265136719), 90, 114, 94, 255])

        let sharp = try load("sharp_extra_elements")
        #expect(sharp.elements.map(\.name) == ["vertex", "extrinsic", "intrinsic", "image_size", "frame", "disparity", "color_space", "version"])
        var imageSize: [PLYReader.Record] = []
        try sharp.read(element: sharp.elements[3]) { imageSize.append($0) }
        #expect(imageSize.first == ["image_size": .uint(8_064)])

        let blender = try load("blender_cube_ascii")
        #expect(blender.elements[1].properties == [PLYReader.Property(name: "vertex_indices", kind: .list(count: .uchar, item: .uint))])
    }
}
