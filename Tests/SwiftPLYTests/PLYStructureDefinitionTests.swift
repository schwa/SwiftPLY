import Foundation
@testable import SwiftPLY
import Testing

private let realWorldURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/RealWorld")

// position float3 at 0, color uchar4 at 12, 16 bytes per record.
private func meshDefinition() throws -> PLYStructureDefinition {
    var definition = PLYStructureDefinition(stride: 16)
    try definition.append("position", type: .float, offset: 0, count: 3, propertyNames: ["x", "y", "z"])
    try definition.append("color", type: .uchar, offset: 12, count: 4, propertyNames: ["red", "green", "blue", "alpha"])
    return definition
}

@Suite("PLY structure definitions")
internal struct PLYStructureDefinitionTests {
    @Test("Default property names")
    func defaultNames() {
        let names = PLYStructureDefinition.defaultPropertyNames
        #expect(names("x", 1) == ["x"])
        #expect(names("position", 3) == ["position_0", "position_1", "position_2"])
        #expect(names("uv", 2) == ["uv_0", "uv_1"])
        #expect(names("scale", 3) == ["scale_0", "scale_1", "scale_2"])
    }

    @Test("append makes one field per lane")
    func append() throws {
        let definition = try meshDefinition()
        #expect(definition.fields.map(\.propertyName) == ["x", "y", "z", "red", "green", "blue", "alpha"])
        #expect(definition.fields.map(\.offset) == [0, 4, 8, 12, 13, 14, 15])
        var custom = PLYStructureDefinition(stride: 8)
        try custom.append("uv", type: .float, offset: 0, count: 2, propertyNames: ["s", "t"])
        #expect(custom.fields == [
            PLYStructureDefinition.Field(propertyName: "s", type: .float, offset: 0),
            PLYStructureDefinition.Field(propertyName: "t", type: .float, offset: 4)
        ])
        #expect(throws: PLYError.invalidValue("uv")) { try custom.append("uv", type: .float, offset: 0, count: 2, propertyNames: ["s"]) }
    }

    @Test("Hand-built definition reads a real file into raw memory and writes it back", arguments: [PLYReader.Format.ascii, .binaryLittleEndian, .binaryBigEndian])
    func readAndWrite(format: PLYReader.Format) throws {
        let reader = try PLYReader(data: Data(contentsOf: realWorldURL.appendingPathComponent("mesh_rgba_garden.ply")))
        let definition = try meshDefinition()
        let count = reader.elements[0].count
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: count * definition.stride, alignment: 4)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        #expect(try reader.read(element: reader.elements[0], into: buffer, definition: definition) == count)
        #expect(buffer.load(fromByteOffset: 0, as: Float.self) == Float(4.905365943908691))
        #expect(Array(buffer[12..<16]) == [90, 114, 94, 255])

        let element = PLYReader.Element(name: "vertex", count: count, definition: definition)
        var writer = PLYWriter(header: PLYHeader(format: format, elements: [element]))
        try writer.write(UnsafeRawBufferPointer(buffer), definition: definition)
        let copy = UnsafeMutableRawBufferPointer.allocate(byteCount: buffer.count, alignment: 4)
        defer { copy.deallocate() }
        copy.initializeMemory(as: UInt8.self, repeating: 0)
        let rewritten = try PLYReader(data: writer.finish())
        #expect(try rewritten.read(element: rewritten.elements[0], into: copy, definition: definition) == count)
        #expect(Array(copy) == Array(buffer))
    }

    @Test("Binary reads give the same bytes with and without the direct copy", arguments: [PLYReader.Format.binaryLittleEndian, .binaryBigEndian])
    func directCopyMatchesConversion(format: PLYReader.Format) throws {
        // `x` is a double in the file but a float in the definition, so only `red` can be copied directly.
        let properties = [
            PLYReader.Property(name: "x", kind: .scalar(.double)),
            PLYReader.Property(name: "pad", kind: .scalar(.short)),
            PLYReader.Property(name: "red", kind: .scalar(.uchar))
        ]
        let header = PLYHeader(format: format, elements: [PLYReader.Element(name: "v", count: 2, properties: properties)])
        var writer = PLYWriter(header: header)
        try writer.write([.double(1.5), .short(-1), .uchar(7)])
        try writer.write([.double(-2), .short(-1), .uchar(9)])
        let reader = try PLYReader(data: writer.finish())

        let converted = PLYStructureDefinition(stride: 8, fields: [
            PLYStructureDefinition.Field(propertyName: "x", type: .float, offset: 0),
            PLYStructureDefinition.Field(propertyName: "red", type: .uchar, offset: 4)
        ])
        let copied = PLYStructureDefinition(stride: 16, fields: [
            PLYStructureDefinition.Field(propertyName: "x", type: .double, offset: 0),
            PLYStructureDefinition.Field(propertyName: "red", type: .uchar, offset: 8)
        ])
        var convertedBytes = [UInt8](repeating: 0, count: 16)
        var copiedBytes = [UInt8](repeating: 0, count: 32)
        _ = try convertedBytes.withUnsafeMutableBytes { try reader.read(element: reader.elements[0], into: $0, definition: converted) }
        _ = try copiedBytes.withUnsafeMutableBytes { try reader.read(element: reader.elements[0], into: $0, definition: copied) }
        convertedBytes.withUnsafeBytes { raw in
            #expect(raw.loadUnaligned(fromByteOffset: 0, as: Float.self) == 1.5)
            #expect(raw.loadUnaligned(fromByteOffset: 8, as: Float.self) == -2)
        }
        copiedBytes.withUnsafeBytes { raw in
            #expect(raw.loadUnaligned(fromByteOffset: 0, as: Double.self) == 1.5)
            #expect(raw.loadUnaligned(fromByteOffset: 16, as: Double.self) == -2)
        }
        #expect([convertedBytes[4], convertedBytes[12], copiedBytes[8], copiedBytes[24]] == [7, 9, 7, 9])
    }

    @Test("Direct copy throws when the data is shorter than the header count")
    func directCopyTruncated() throws {
        var data = Data("ply\nformat binary_little_endian 1.0\nelement v 3\nproperty uchar red\nelement w 0\nend_header\n".utf8)
        data.append(contentsOf: [1, 2])
        let reader = try PLYReader(data: data)
        let definition = PLYStructureDefinition(stride: 1, fields: [PLYStructureDefinition.Field(propertyName: "red", type: .uchar, offset: 0)])
        var bytes = [UInt8](repeating: 0, count: 3)
        #expect(throws: PLYError.invalidData) {
            try bytes.withUnsafeMutableBytes { try reader.read(element: reader.elements[0], into: $0, definition: definition) }
        }
    }

    @Test("Fixed-length list fields read faces and write them back", arguments: [
        ("blender_cube_binary", PLYReader.PropertyType.uchar, PLYReader.PropertyType.uint, 4),
        ("blender_cube_ascii", .uchar, .uint, 4),
        ("bunny", .uchar, .int, 3),
        ("mesh_rgba_garden", .uchar, .int, 3)
    ])
    func faces(name: String, countType: PLYReader.PropertyType, itemType: PLYReader.PropertyType, length: Int) throws {
        let reader = try PLYReader(data: Data(contentsOf: realWorldURL.appendingPathComponent("\(name).ply")))
        let faceElement = try #require(reader.elements.first { $0.name == "face" })
        let field = PLYStructureDefinition.Field(propertyName: "vertex_indices", type: itemType, offset: 0, list: .init(countType: countType, length: length))
        let definition = PLYStructureDefinition(stride: 4 * length, fields: [field])

        var indices = [UInt32](repeating: 0, count: faceElement.count * length)
        let count = try indices.withUnsafeMutableBytes { try reader.read(element: faceElement, into: $0, definition: definition) }
        #expect(count == faceElement.count)
        var expected: [UInt32] = []
        try reader.read(element: faceElement) { record in
            if case .list(let items)? = record["vertex_indices"] {
                expected += items.compactMap { $0.doubleValue.map { UInt32($0) } }
            }
        }
        #expect(indices == expected)

        let element = PLYReader.Element(name: "face", count: count, definition: definition)
        #expect(element.properties == [PLYReader.Property(name: "vertex_indices", kind: .list(count: countType, item: itemType))])
        var writer = PLYWriter(header: PLYHeader(format: .binaryBigEndian, elements: [element]))
        try indices.withUnsafeBytes { try writer.write($0, definition: definition) }
        let rewritten = try PLYReader(data: writer.finish())
        var copy = [UInt32](repeating: 0, count: indices.count)
        _ = try copy.withUnsafeMutableBytes { try rewritten.read(element: rewritten.elements[0], into: $0, definition: definition) }
        #expect(copy == indices)
    }

    @Test("A list field and scalar fields in one record")
    func mixedFaces() throws {
        let reader = try PLYReader(data: Data(contentsOf: realWorldURL.appendingPathComponent("beetle_binary.ply")))
        var definition = PLYStructureDefinition(stride: 16, fields: [
            PLYStructureDefinition.Field(propertyName: "vertex_indices", type: .int, offset: 0, list: .init(countType: .uchar, length: 3))
        ])
        try definition.append("color", type: .uchar, offset: 12, count: 4, propertyNames: ["red", "green", "blue", "alpha"])
        var bytes = [UInt8](repeating: 0, count: 16 * reader.elements[1].count)
        _ = try bytes.withUnsafeMutableBytes { try reader.read(element: reader.elements[1], into: $0, definition: definition) }
        bytes.withUnsafeBytes { raw in
            #expect(raw.loadUnaligned(as: SIMD3<Int32>.self) == [0, 1, 2])
        }
        #expect(Array(bytes[12..<16]) == [191, 191, 191, 255])
    }

    @Test("A list with a different length throws")
    func wrongLength() throws {
        let reader = try PLYReader(data: Data(contentsOf: realWorldURL.appendingPathComponent("blender_cube_binary.ply")))
        let field = PLYStructureDefinition.Field(propertyName: "vertex_indices", type: .uint, offset: 0, list: .init(countType: .uchar, length: 3))
        let definition = PLYStructureDefinition(stride: 12, fields: [field])
        var indices = [UInt32](repeating: 0, count: 6 * 3)
        #expect(throws: PLYError.invalidValue("vertex_indices")) {
            try indices.withUnsafeMutableBytes { try reader.read(element: reader.elements[1], into: $0, definition: definition) }
        }
        let scalarField = PLYStructureDefinition(stride: 4, fields: [PLYStructureDefinition.Field(propertyName: "vertex_indices", type: .uint, offset: 0)])
        #expect(throws: PLYError.invalidValue("vertex_indices")) {
            try indices.withUnsafeMutableBytes { try reader.read(element: reader.elements[1], into: $0, definition: scalarField) }
        }
    }

    @Test("Bytes that no field covers are not changed")
    func padding() throws {
        let reader = try PLYReader(data: Data("ply\nformat ascii 1.0\nelement v 1\nproperty uchar red\nend_header\n7\n".utf8))
        var bytes: [UInt8] = [1, 2, 3, 4]
        let definition = PLYStructureDefinition(stride: 4, fields: [PLYStructureDefinition.Field(propertyName: "red", type: .uchar, offset: 2)])
        _ = try bytes.withUnsafeMutableBytes { try reader.read(element: reader.elements[0], into: $0, definition: definition) }
        #expect(bytes == [1, 2, 7, 4])
    }

    @Test("Definitions that are not valid throw", arguments: [
        (PLYStructureDefinition(stride: 0, fields: [PLYStructureDefinition.Field(propertyName: "x", type: .float, offset: 0)]), "stride"),
        (PLYStructureDefinition(stride: 4), "stride"),
        (PLYStructureDefinition(stride: 4, fields: [PLYStructureDefinition.Field(propertyName: "x", type: .float, offset: 1)]), "x"),
        (PLYStructureDefinition(stride: 4, fields: [PLYStructureDefinition.Field(propertyName: "x", type: .float, offset: -1)]), "x"),
        (PLYStructureDefinition(stride: 8, fields: [PLYStructureDefinition.Field(propertyName: "x", type: .int, offset: 0, list: .init(countType: .float, length: 1))]), "x"),
        (PLYStructureDefinition(stride: 8, fields: [PLYStructureDefinition.Field(propertyName: "x", type: .int, offset: 0, list: .init(countType: .uchar, length: 0))]), "x"),
        (PLYStructureDefinition(stride: 8, fields: [PLYStructureDefinition.Field(propertyName: "x", type: .int, offset: 0, list: .init(countType: .uchar, length: 3))]), "x"),
        (PLYStructureDefinition(stride: 8, fields: [
            PLYStructureDefinition.Field(propertyName: "x", type: .float, offset: 0),
            PLYStructureDefinition.Field(propertyName: "x", type: .float, offset: 4)
        ]), "x")
    ])
    func invalid(definition: PLYStructureDefinition, name: String) throws {
        let reader = try PLYReader(data: Data("ply\nformat ascii 1.0\nelement v 0\nproperty float x\nend_header\n".utf8))
        #expect(throws: PLYError.invalidValue(name)) {
            try reader.read(element: reader.elements[0], into: UnsafeMutableRawBufferPointer(start: nil, count: 0), definition: definition)
        }
        var writer = PLYWriter(header: reader.header)
        #expect(throws: PLYError.invalidValue(name)) { try writer.write(UnsafeRawBufferPointer(start: nil, count: 0), definition: definition) }
    }

    @Test("Writing needs a whole number of records")
    func partialRecord() throws {
        let definition = PLYStructureDefinition(stride: 4, fields: [PLYStructureDefinition.Field(propertyName: "x", type: .float, offset: 0)])
        var writer = PLYWriter(header: PLYHeader(format: .ascii, elements: [PLYReader.Element(name: "v", count: 1, definition: definition)]))
        let bytes: [UInt8] = [0, 0, 0]
        #expect(throws: PLYError.invalidValue("stride")) {
            try bytes.withUnsafeBytes { try writer.write($0, definition: definition) }
        }
    }

    @Test("A list value cannot be stored in a field")
    func storeList() throws {
        let field = PLYStructureDefinition.Field(propertyName: "x", type: .float, offset: 0)
        var value: Float = 0
        #expect(throws: PLYError.invalidValue("x")) {
            try withUnsafeMutableBytes(of: &value) { bytes in
                let base = try #require(bytes.baseAddress)
                try field.store(.list([]), in: base)
            }
        }
    }
}
