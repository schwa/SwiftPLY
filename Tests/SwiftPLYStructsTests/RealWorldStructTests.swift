import Foundation
import SwiftPLY
import SwiftPLYStructs
import Testing

private let realWorldURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("SwiftPLYTests/Fixtures/RealWorld")

private let positionNames = ["position": ["x", "y", "z"]]
private let meshNames = [
    "position": ["x", "y", "z"],
    "normal": ["nx", "ny", "nz"],
    "color": ["red", "green", "blue", "alpha"],
    "uv": ["s", "t"]
]

private func load(_ name: String) throws -> PLYReader {
    try PLYReader(data: Data(contentsOf: realWorldURL.appendingPathComponent("\(name).ply")))
}

// swiftlint:disable identifier_name
private struct InriaSplat: Equatable {
    var position: SIMD3<Float>
    var f_dc: SIMD3<Float>
    var opacity: Float
    var scale: SIMD3<Float>
    var rot: SIMD4<Float>
}
// swiftlint:enable identifier_name

// swiftlint:disable identifier_name
private struct FullSplat {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var f_dc: SIMD3<Float>
    var f_rest: InlineArray<45, Float>
    var opacity: Float
    var scale: SIMD3<Float>
    var rot: SIMD4<Float>
}
// swiftlint:enable identifier_name

private struct WithSIMDArray {
    var values: InlineArray<2, SIMD2<Float>>
}

private struct ColoredVertex {
    var position: SIMD3<Float>
    var color: SIMD4<UInt8>
}

private struct BlenderVertex: Equatable {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<UInt8>
    var uv: SIMD2<Float>
}

@Suite("Real-world PLY files as structs")
internal struct RealWorldStructTests {
    @Test("Gaussian splat fields map with numbered names", arguments: ["splat_inria_3", "splat_cluster_fly_16", "splat_sh1", "splat_normals_no_sh", "sharp_extra_elements"])
    func splats(name: String) throws {
        let reader = try load(name)
        let splats = try reader.read(InriaSplat.self, names: positionNames)
        #expect(splats.count == reader.elements[0].count)

        var floats: [[Float?]] = []
        try reader.readFloatValues(element: reader.elements[0]) { floats.append($0) }
        let names = reader.elements[0].properties.map(\.name)
        func column(_ property: String) -> [Float] {
            floats.map { $0[names.firstIndex(of: property) ?? -1] ?? .nan }
        }
        #expect(splats.map(\.position.x) == column("x"))
        #expect(splats.map(\.f_dc.z) == column("f_dc_2"))
        #expect(splats.map(\.opacity) == column("opacity"))
        #expect(splats.map(\.scale.y) == column("scale_1"))
        #expect(splats.map(\.rot.w) == column("rot_3"))
    }

    @Test("InlineArray fields map to numbered properties")
    func inlineArray() throws {
        let reader = try load("splat_inria_3")
        let definition = try PLYStructureDefinition(for: FullSplat.self, names: meshNames)
        #expect(definition.fields.map(\.propertyName) == reader.elements[0].properties.map(\.name))

        let splats = try reader.read(FullSplat.self, names: meshNames)
        var floats: [[Float?]] = []
        try reader.readFloatValues(element: reader.elements[0]) { floats.append($0) }
        let restIndex = try #require(reader.elements[0].properties.firstIndex { $0.name == "f_rest_0" })
        for (splat, row) in zip(splats, floats) {
            #expect((0..<45).map { splat.f_rest[$0] } == row[restIndex..<restIndex + 45].map { $0 ?? .nan })
        }

        let element = PLYReader.Element(name: "vertex", count: splats.count, definition: definition)
        var writer = PLYWriter(header: PLYHeader(format: .binaryLittleEndian, elements: [element]))
        try writer.write(splats, names: meshNames)
        let original = try Data(contentsOf: realWorldURL.appendingPathComponent("splat_inria_3.ply"))
        let written = try writer.finish()
        #expect(written.dropFirst(writer.header.serialized.utf8.count) == original.dropFirst(reader.bodyOffset))
        #expect(throws: PLYError.invalidValue("values")) { try PLYStructureDefinition(for: WithSIMDArray.self) }
    }

    @Test("RGBA mesh vertices")
    func coloredMesh() throws {
        let vertices = try load("mesh_rgba_garden").read(ColoredVertex.self, names: meshNames)
        #expect(vertices.count == 26)
        #expect(vertices[0].position == [Float(4.905365943908691), Float(3.639979124069214), Float(-0.8202934265136719)])
        #expect([vertices[0].color.x, vertices[0].color.y, vertices[0].color.z] == [90, 114, 94])
    }

    @Test("Blender export", arguments: ["blender_cube_ascii", "blender_cube_binary"])
    func blender(name: String) throws {
        let vertices = try load(name).read(BlenderVertex.self, names: meshNames)
        #expect(vertices.count == 14)
        #expect(vertices[0].position == [-1, -1, -1])
        #expect(vertices[0].normal == [-0.5773503, -0.5773503, -0.5773503])
        #expect(vertices[0].color == [0, 0, 0, 255])
        #expect(vertices[0].uv == [0.375, 0])
    }
}
