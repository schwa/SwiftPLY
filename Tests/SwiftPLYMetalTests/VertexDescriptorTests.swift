#if canImport(Metal) && canImport(ModelIO)
import Foundation
import Metal
import ModelIO
import SwiftPLY
@testable import SwiftPLYMetal
import Testing

private let realWorldURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("SwiftPLYTests/Fixtures/RealWorld")

// position float3 at 0, normal float3 at 12, color uchar4 normalized at 24, texture coordinate float2 at 28.
private func modelIODescriptor() -> MDLVertexDescriptor {
    let descriptor = MDLVertexDescriptor()
    descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
    descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
    descriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeColor, format: .uChar4Normalized, offset: 24, bufferIndex: 0)
    descriptor.attributes[3] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 28, bufferIndex: 0)
    descriptor.attributes[4] = MDLVertexAttribute(name: "other", format: .float, offset: 0, bufferIndex: 1)
    descriptor.layouts[0] = MDLVertexBufferLayout(stride: 36)
    descriptor.layouts[1] = MDLVertexBufferLayout(stride: 4)
    return descriptor
}

private func metalDescriptor() -> MTLVertexDescriptor {
    let descriptor = MTLVertexDescriptor()
    let formats: [(MTLVertexFormat, Int)] = [(.float3, 0), (.float3, 12), (.uchar4Normalized, 24), (.float2, 28)]
    for (index, (format, offset)) in formats.enumerated() {
        descriptor.attributes[index].format = format
        descriptor.attributes[index].offset = offset
        descriptor.attributes[index].bufferIndex = 0
    }
    descriptor.layouts[0].stride = 36
    return descriptor
}

private let blenderNames = [
    MDLVertexAttributePosition: ["x", "y", "z"],
    MDLVertexAttributeNormal: ["nx", "ny", "nz"],
    MDLVertexAttributeColor: ["red", "green", "blue", "alpha"],
    MDLVertexAttributeTextureCoordinate: ["s", "t"]
]

private func readBlenderCube(_ definition: PLYStructureDefinition) throws -> [UInt8] {
    let reader = try PLYReader(data: Data(contentsOf: realWorldURL.appendingPathComponent("blender_cube_binary.ply")))
    var bytes = [UInt8](repeating: 0, count: reader.elements[0].count * definition.stride)
    let count = try bytes.withUnsafeMutableBytes { try reader.read(element: reader.elements[0], into: $0, definition: definition) }
    #expect(count == 14)
    return bytes
}

@Suite("Structure definitions from vertex descriptors")
internal struct VertexDescriptorTests {
    @Test("Model I/O descriptor")
    func modelIO() throws {
        let definition = try PLYStructureDefinition(modelIODescriptor(), names: blenderNames)
        #expect(definition.stride == 36)
        #expect(definition.fields.map(\.propertyName) == ["x", "y", "z", "nx", "ny", "nz", "red", "green", "blue", "alpha", "s", "t"])
        #expect(definition.fields.map(\.offset) == [0, 4, 8, 12, 16, 20, 24, 25, 26, 27, 28, 32])

        let bytes = try readBlenderCube(definition)
        bytes.withUnsafeBytes { raw in
            #expect(raw.loadUnaligned(fromByteOffset: 0, as: SIMD3<Float>.self) == [-1, -1, -1])
            #expect(raw.loadUnaligned(fromByteOffset: 28, as: SIMD2<Float>.self) == [0.375, 0])
        }
        #expect(Array(bytes[24..<28]) == [0, 0, 0, 255])
    }

    @Test("Metal descriptor gives the same layout as the Model I/O descriptor")
    func metal() throws {
        let names = [0: MDLVertexAttributePosition, 1: MDLVertexAttributeNormal, 2: MDLVertexAttributeColor, 3: MDLVertexAttributeTextureCoordinate]
        let definition = try PLYStructureDefinition(metalDescriptor(), attributeNames: names, names: blenderNames)
        #expect(try definition == PLYStructureDefinition(modelIODescriptor(), names: blenderNames))
        #expect(try readBlenderCube(definition) == readBlenderCube(PLYStructureDefinition(modelIODescriptor(), names: blenderNames)))
    }

    @Test("Other buffer indices use their own layout")
    func otherBuffer() throws {
        let definition = try PLYStructureDefinition(modelIODescriptor(), bufferIndex: 1)
        #expect(definition == PLYStructureDefinition(stride: 4, fields: [PLYStructureDefinition.Field(propertyName: "other", type: .float, offset: 0)]))
    }

    @Test("Format mapping", arguments: [
        (MDLVertexFormat.char3, PLYReader.PropertyType.char, 3), (.char2Normalized, .char, 2),
        (.uChar, .uchar, 1), (.uChar4Normalized, .uchar, 4),
        (.short2, .short, 2), (.short4Normalized, .short, 4),
        (.uShort3, .ushort, 3), (.uShortNormalized, .ushort, 1),
        (.int4, .int, 4), (.uInt2, .uint, 2), (.float4, .float, 4)
    ])
    func formats(format: MDLVertexFormat, type: PLYReader.PropertyType, count: Int) {
        #expect(PLYStructureDefinition.propertyType(for: format).map { $0 == (type, count) } == true)
    }

    @Test("Formats with no PLY type", arguments: [MDLVertexFormat.half3, .int1010102Normalized, .uInt1010102Normalized, .invalid])
    func unsupportedFormats(format: MDLVertexFormat) {
        #expect(PLYStructureDefinition.propertyType(for: format) == nil)
    }

    @Test("Descriptors that cannot map throw")
    func errors() {
        let half = MDLVertexDescriptor()
        half.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .half3, offset: 0, bufferIndex: 0)
        half.layouts[0] = MDLVertexBufferLayout(stride: 8)
        #expect(throws: PLYError.invalidValue(MDLVertexAttributePosition)) { try PLYStructureDefinition(half) }

        let unnamed = MDLVertexDescriptor()
        unnamed.attributes[0] = MDLVertexAttribute(name: "", format: .float, offset: 0, bufferIndex: 0)
        unnamed.layouts[0] = MDLVertexBufferLayout(stride: 4)
        #expect(throws: PLYError.invalidValue("")) { try PLYStructureDefinition(unnamed) }

        #expect(throws: PLYError.invalidValue("layout 99")) { try PLYStructureDefinition(modelIODescriptor(), bufferIndex: 99) }
        #expect(throws: PLYError.invalidValue("x")) { try PLYStructureDefinition(metalDescriptor(), attributeNames: [99: "x"]) }
    }
}
#endif
