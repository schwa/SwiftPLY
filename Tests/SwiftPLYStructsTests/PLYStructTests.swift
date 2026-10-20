import Foundation
import SwiftPLY
import SwiftPLYStructs
import Testing

private struct Vertex: Equatable {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<UInt8>
    var uv: SIMD2<Float>
    var id: Int32
    var weight: Double
}

private struct Small: Equatable {
    var x: Float
    var red: UInt8
}

private struct Signed: Equatable {
    var value: Int8
}

private struct AllScalars: Equatable {
    var a: Int8
    var b: UInt8
    var c: Int16
    var d: UInt16
    var e: Int32
    var f: UInt32
    var g: Float
    var h: Double
}

private struct RGBA: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
}

private struct Point: Equatable {
    var x: Float
    var y: Float
    var z: Float
}

private struct NestedVertex: Equatable {
    var point: Point
    var id: Int16
    var color: RGBA
}

private struct DeepVertex: Equatable {
    var vertex: NestedVertex
    var weight: Double
}

private struct TwoColors {
    var front: RGBA
    var back: RGBA
}

private struct NestedBool {
    var point: Point
    var flags: WithBool
}

private enum Kind {
    case a, b
}

private struct WithEnum {
    var x: Float
    var kind: Kind
}

private struct WithBool {
    var flag: Bool
}

private struct Empty {}

private let vertices = [
    Vertex(position: [1, 2, 3], normal: [0, 0, 1], color: [255, 128, 0, 255], uv: [0.25, 0.75], id: -1, weight: 0.1),
    Vertex(position: [-4, 5.5, 6], normal: [1, 0, 0], color: [1, 2, 3, 4], uv: [1, 0], id: 7, weight: 1e300)
]

private func makeData(_ text: String) -> Data {
    Data(text.utf8)
}

@Suite("PLY struct reading and writing")
internal struct PLYStructTests {
    @Test("Structs round-trip through every format", arguments: [PLYReader.Format.ascii, .binaryLittleEndian, .binaryBigEndian])
    func roundTrip(format: PLYReader.Format) throws {
        let element = try PLYReader.Element(name: "vertex", count: vertices.count, fieldsOf: Vertex.self)
        var writer = PLYWriter(header: PLYHeader(format: format, elements: [element]))
        try writer.write(vertices)
        let reader = try PLYReader(data: writer.finish())
        #expect(try reader.read(Vertex.self) == vertices)
    }

    @Test("Every scalar field type round-trips", arguments: [PLYReader.Format.ascii, .binaryBigEndian])
    func allScalars(format: PLYReader.Format) throws {
        let records = [
            AllScalars(a: -128, b: 255, c: -32_768, d: 65_535, e: .min, f: .max, g: 0.5, h: -0.25),
            AllScalars(a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8)
        ]
        let element = try PLYReader.Element(name: "v", count: records.count, fieldsOf: AllScalars.self)
        var writer = PLYWriter(header: PLYHeader(format: format, elements: [element]))
        try writer.write(records)
        let reader = try PLYReader(data: writer.finish())
        #expect(try reader.read(AllScalars.self) == records)
    }

    @Test("Tuples use their labels, or .0 and .1 when unlabeled")
    func tuples() throws {
        let element = try PLYReader.Element(name: "v", count: 0, fieldsOf: (Float, y: Float).self)
        #expect(element.properties.map(\.name) == [".0", "y"])
    }

    @Test("Default property names")
    func defaultNames() throws {
        let element = try PLYReader.Element(name: "vertex", count: 0, fieldsOf: Vertex.self)
        #expect(element.properties.map(\.name) == [
            "position_0", "position_1", "position_2", "normal_0", "normal_1", "normal_2",
            "color_0", "color_1", "color_2", "color_3", "uv_0", "uv_1", "id", "weight"
        ])
        #expect(element.properties[6].kind == .scalar(.uchar))
        #expect(try PLYStructureDefinition(for: Vertex.self).stride == MemoryLayout<Vertex>.stride)
    }

    @Test("Names override the default names")
    func namesOverride() throws {
        let names = ["position": ["px", "py", "pz"]]
        let element = try PLYReader.Element(name: "vertex", count: 1, fieldsOf: Vertex.self, names: names)
        #expect(element.properties.prefix(3).map(\.name) == ["px", "py", "pz"])
        var writer = PLYWriter(header: PLYHeader(format: .ascii, elements: [element]))
        try writer.write([vertices[0]], names: names)
        let reader = try PLYReader(data: writer.finish())
        #expect(try reader.read(Vertex.self, names: names) == [vertices[0]])
        #expect(throws: PLYError.invalidValue("position")) {
            try PLYStructureDefinition(for: Vertex.self, names: ["position": ["a"]])
        }
    }

    @Test("Values convert to the field type, and extra properties are ignored")
    func conversion() throws {
        let reader = try PLYReader(data: makeData("""
        ply
        format ascii 1.0
        element v 2
        property double x
        property int extra
        property float red
        end_header
        1.5 9 200
        -2 9 3

        """))
        #expect(try reader.read(Small.self) == [Small(x: 1.5, red: 200), Small(x: -2, red: 3)])
    }

    @Test("Value out of range for the field throws", arguments: ["200", "1.5", "x"])
    func outOfRange(value: String) throws {
        let reader = try PLYReader(data: makeData("ply\nformat ascii 1.0\nelement v 1\nproperty float value\nend_header\n\(value)\n"))
        #expect(throws: PLYError.invalidValue("value")) { try reader.read(Signed.self) }
    }

    @Test("Nested struct fields use their own names")
    func nested() throws {
        let definition = try PLYStructureDefinition(for: DeepVertex.self)
        #expect(definition.fields.map(\.propertyName) == ["x", "y", "z", "id", "red", "green", "blue", "alpha", "weight"])
        #expect(definition.fields.map(\.offset) == [
            MemoryLayout<DeepVertex>.offset(of: \.vertex.point.x), MemoryLayout<DeepVertex>.offset(of: \.vertex.point.y),
            MemoryLayout<DeepVertex>.offset(of: \.vertex.point.z), MemoryLayout<DeepVertex>.offset(of: \.vertex.id),
            MemoryLayout<DeepVertex>.offset(of: \.vertex.color.red), MemoryLayout<DeepVertex>.offset(of: \.vertex.color.green),
            MemoryLayout<DeepVertex>.offset(of: \.vertex.color.blue), MemoryLayout<DeepVertex>.offset(of: \.vertex.color.alpha),
            MemoryLayout<DeepVertex>.offset(of: \.weight)
        ])

        let records = [
            DeepVertex(vertex: NestedVertex(point: Point(x: 1, y: 2, z: 3), id: -4, color: RGBA(red: 5, green: 6, blue: 7, alpha: 8)), weight: 0.5),
            DeepVertex(vertex: NestedVertex(point: Point(x: -1, y: 0, z: 9), id: 10, color: RGBA(red: 255, green: 0, blue: 1, alpha: 2)), weight: -2)
        ]
        let element = try PLYReader.Element(name: "vertex", count: records.count, fieldsOf: DeepVertex.self)
        var writer = PLYWriter(header: PLYHeader(format: .binaryBigEndian, elements: [element]))
        try writer.write(records)
        #expect(try PLYReader(data: writer.finish()).read(DeepVertex.self) == records)
    }

    @Test("Dotted paths override nested names, and duplicate names throw")
    func nestedNames() throws {
        #expect(throws: PLYError.invalidValue("red")) {
            let element = try PLYReader.Element(name: "v", count: 0, fieldsOf: TwoColors.self)
            let reader = try PLYReader(data: Data(PLYHeader(format: .ascii, elements: [element]).serialized.utf8))
            _ = try reader.read(TwoColors.self)
        }
        let names = ["front.red": ["r"], "back.red": ["back_red"], "back.green": ["back_green"], "back.blue": ["back_blue"], "back.alpha": ["back_alpha"]]
        let definition = try PLYStructureDefinition(for: TwoColors.self, names: names)
        #expect(definition.fields.map(\.propertyName) == ["r", "green", "blue", "alpha", "back_red", "back_green", "back_blue", "back_alpha"])
    }

    @Test("Struct field types that are not supported throw")
    func unsupportedFields() {
        #expect(throws: PLYError.invalidValue("flag")) { try PLYStructureDefinition(for: WithBool.self) }
        #expect(throws: PLYError.invalidValue("flags.flag")) { try PLYStructureDefinition(for: NestedBool.self) }
        #expect(throws: PLYError.invalidValue("kind")) { try PLYStructureDefinition(for: WithEnum.self) }
        #expect(throws: PLYError.invalidValue("Empty")) { try PLYStructureDefinition(for: Empty.self) }
    }

    @Test("Missing or list properties throw", arguments: ["property float y\nproperty uchar red", "property list uchar float x\nproperty uchar red"])
    func missingProperty(properties: String) throws {
        let reader = try PLYReader(data: makeData("ply\nformat ascii 1.0\nelement v 0\n\(properties)\nend_header\n"))
        #expect(throws: PLYError.invalidValue("x")) { try reader.read(Small.self) }
    }

    @Test("A huge element count does not allocate before reading", .timeLimit(.minutes(1)))
    func hugeCount() throws {
        let header = "ply\nformat binary_little_endian 1.0\nelement v \(Int.max / 2)\nproperty float x\nproperty uchar red\nend_header\n"
        var data = Data(header.utf8)
        data.append(contentsOf: [0, 0, 128, 63, 7])
        let reader = try PLYReader(data: data)
        #expect(throws: PLYError.invalidData) { try reader.read(Small.self) }
    }

    @Test("Buffer edge cases")
    func bufferEdgeCases() throws {
        let reader = try PLYReader(data: makeData("ply\nformat ascii 1.0\nelement v 2\nproperty float x\nproperty uchar red\nend_header\n1 2\n3 4\n"))
        var small = [Small(x: 0, red: 0)]
        #expect(throws: PLYError.recordCountMismatch) {
            try small.withUnsafeMutableBufferPointer { try reader.read(element: reader.elements[0], into: $0) }
        }
        let empty = PLYReader.Element(name: "none", count: 0, properties: reader.elements[0].properties)
        #expect(try reader.read(element: empty, into: UnsafeMutableBufferPointer<Small>(start: nil, count: 0)) == 0)

        let noElements = try PLYReader(data: makeData("ply\nformat ascii 1.0\nend_header\n"))
        #expect(throws: PLYError.noElements) { try noElements.read(Small.self) }
    }

    @Test("Writing continues into the next element")
    func writeAcrossElements() throws {
        let first = try PLYReader.Element(name: "a", count: 2, fieldsOf: Small.self)
        let second = try PLYReader.Element(name: "b", count: 1, fieldsOf: Small.self)
        var writer = PLYWriter(header: PLYHeader(format: .binaryLittleEndian, elements: [first, second]))
        let records = [Small(x: 1, red: 1), Small(x: 2, red: 2), Small(x: 3, red: 3)]
        try writer.write(records)
        try writer.write(UnsafeBufferPointer<Small>(start: nil, count: 0))
        #expect(throws: PLYError.recordCountMismatch) { try writer.write(records) }
        let reader = try PLYReader(data: writer.finish())
        #expect(try reader.read(Small.self, element: reader.elements[1]) == [records[2]])
    }

    @Test("Writing throws when a property has no matching field", arguments: ["property float x\nproperty uchar green", "property double x\nproperty uchar red"])
    func writeMismatch(properties: String) throws {
        let header = try PLYHeader.parse(makeData("ply\nformat ascii 1.0\nelement v 1\n\(properties)\nend_header\n")).header
        var writer = PLYWriter(header: header)
        #expect(throws: PLYError.self) { try writer.write([Small(x: 1, red: 1)]) }
    }
}
