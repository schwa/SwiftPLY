import Foundation
@testable import SwiftPLY
import Testing

private struct BinaryWriter {
    var data = Data()
    let littleEndian: Bool

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        let ordered = littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: ordered) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Float) { append(value.bitPattern) }
    mutating func append(_ value: Double) { append(value.bitPattern) }
}

private func makePLY(_ header: String, body: Data = Data()) -> Data {
    var data = Data(header.utf8)
    data.append(body)
    return data
}

private func allTypesHeader(_ format: String) -> String {
    """
    ply
    format \(format) 1.0
    element v 1
    property int8 a
    property uint8 b
    property int16 c
    property uint16 d
    property int32 e
    property uint32 f
    property float32 g
    property float64 h
    end_header

    """
}

private func allTypesBody(littleEndian: Bool) -> Data {
    var writer = BinaryWriter(littleEndian: littleEndian)
    writer.append(Int8(-1))
    writer.append(UInt8(2))
    writer.append(Int16(-3))
    writer.append(UInt16(4))
    writer.append(Int32(-5))
    writer.append(UInt32(6))
    writer.append(Float(7.5))
    writer.append(Double(8.25))
    return writer.data
}

private let expectedAllTypes: [PLYReader.PropertyValue] = [
    .char(-1), .uchar(2), .short(-3), .ushort(4), .int(-5), .uint(6), .float(7.5), .double(8.25)
]

@Suite("PLY coverage")
internal struct PLYCoverageTests {
    @Test("Binary values of all types", arguments: [true, false])
    func binaryAllTypes(littleEndian: Bool) throws {
        let format = littleEndian ? "binary_little_endian" : "binary_big_endian"
        let reader = try PLYReader(data: makePLY(allTypesHeader(format), body: allTypesBody(littleEndian: littleEndian)))
        let element = try #require(reader.primaryElement)

        var values: [[PLYReader.PropertyValue?]] = []
        try reader.readValues(element: element) { values.append($0) }
        #expect(values == [expectedAllTypes])

        var floats: [[Float?]] = []
        try reader.readFloatValues(element: element) { floats.append($0) }
        #expect(floats == [[-1, 2, -3, 4, -5, 6, 7.5, 8.25]])
    }

    @Test("ASCII values of all types")
    func asciiAllTypes() throws {
        let reader = try PLYReader(data: makePLY(allTypesHeader("ascii") + "-1 2 -3 4 -5 6 7.5 8.25\n"))
        let element = try #require(reader.primaryElement)

        var values: [[PLYReader.PropertyValue?]] = []
        try reader.readValues(element: element) { values.append($0) }
        #expect(values == [expectedAllTypes])

        var floats: [[Float?]] = []
        try reader.readFloatValues(element: element) { floats.append($0) }
        #expect(floats == [[-1, 2, -3, 4, -5, 6, 7.5, 8.25]])
    }

    @Test("ASCII unparsable scalars become nil")
    func asciiUnparsable() throws {
        let reader = try PLYReader(data: makePLY(allTypesHeader("ascii") + "x x x x x x x x\n"))
        var values: [[PLYReader.PropertyValue?]] = []
        try reader.readValues(element: reader.elements[0]) { values.append($0) }
        #expect(values == [Array(repeating: nil, count: 8)])
    }

    @Test("Binary lists with each count type", arguments: [true, false], ["char", "uchar", "short", "ushort", "int", "uint"])
    func binaryLists(littleEndian: Bool, countType: String) throws {
        let format = littleEndian ? "binary_little_endian" : "binary_big_endian"
        let header = """
        ply
        format \(format) 1.0
        element face 1
        property float x
        property list \(countType) int indices
        end_header

        """
        var writer = BinaryWriter(littleEndian: littleEndian)
        writer.append(Float(1.5))
        switch countType {
        case "char": writer.append(Int8(2))
        case "uchar": writer.append(UInt8(2))
        case "short": writer.append(Int16(2))
        case "ushort": writer.append(UInt16(2))
        case "int": writer.append(Int32(2))
        default: writer.append(UInt32(2))
        }
        writer.append(Int32(10))
        writer.append(Int32(20))

        let reader = try PLYReader(data: makePLY(header, body: writer.data))
        let element = try #require(reader.primaryElement)

        var records: [PLYReader.Record] = []
        try reader.read { records.append($0) }
        #expect(records == [["x": .float(1.5), "indices": .list([.int(10), .int(20)])]])

        var floats: [[Float?]] = []
        try reader.readFloatValues(element: element) { floats.append($0) }
        #expect(floats == [[1.5, nil]])
    }

    @Test("Binary float list count is a non-integer type")
    func binaryListFloatCount() throws {
        let header = """
        ply
        format binary_little_endian 1.0
        element face 1
        property list float int indices
        end_header

        """
        #expect(throws: PLYError.invalidHeader) { try PLYReader(data: makePLY(header)) }
    }

    @Test("Binary list overruns data in float path")
    func binaryListOverrun() throws {
        let header = """
        ply
        format binary_little_endian 1.0
        element face 1
        property list uchar int indices
        end_header

        """
        let reader = try PLYReader(data: makePLY(header, body: Data([5, 0, 0])))
        #expect(throws: PLYError.invalidData) {
            try reader.readFloatValues(element: reader.elements[0]) { _ in }
        }
    }

    @Test("Truncated binary data throws", arguments: [true, false])
    func truncatedBinary(useFloats: Bool) throws {
        let reader = try PLYReader(data: makePLY(allTypesHeader("binary_little_endian"), body: Data([1, 2])))
        let element = reader.elements[0]
        #expect(throws: PLYError.invalidData) {
            if useFloats {
                try reader.readFloatValues(element: element) { _ in }
            } else {
                try reader.readValues(element: element) { _ in }
            }
        }
    }

    @Test("Second element offset", arguments: ["ascii", "binary_little_endian"])
    func secondElement(format: String) throws {
        let header = """
        ply
        format \(format) 1.0
        element a 2
        property uchar v
        element b 1
        property short w
        end_header

        """
        let body: Data
        if format == "ascii" {
            body = Data("1\n2\n300\n".utf8)
        } else {
            var writer = BinaryWriter(littleEndian: true)
            writer.append(UInt8(1))
            writer.append(UInt8(2))
            writer.append(Int16(300))
            body = writer.data
        }
        let reader = try PLYReader(data: makePLY(header, body: body))
        #expect(reader.recordCount == 2)
        var records: [PLYReader.Record] = []
        try reader.read(element: reader.elements[1]) { records.append($0) }
        #expect(records == [["w": .short(300)]])
        var floats: [[Float?]] = []
        try reader.readFloatValues(element: reader.elements[1]) { floats.append($0) }
        #expect(floats == [[300]])
    }

    @Test("Binary offset skips empty element with list property")
    func binaryOffsetAfterListElement() throws {
        let header = """
        ply
        format binary_little_endian 1.0
        element face 0
        property list uchar int i
        element v 1
        property uchar x
        end_header

        """
        let reader = try PLYReader(data: makePLY(header, body: Data([7])))
        var values: [[PLYReader.PropertyValue?]] = []
        try reader.readValues(element: reader.elements[1]) { values.append($0) }
        #expect(values == [[.uchar(7)]])
        var floats: [[Float?]] = []
        try reader.readFloatValues(element: reader.elements[1]) { floats.append($0) }
        #expect(floats == [[7]])
    }

    @Test("Binary element after element with list data", arguments: [true, false])
    func binaryOffsetAfterListData(littleEndian: Bool) throws {
        let format = littleEndian ? "binary_little_endian" : "binary_big_endian"
        let header = """
        ply
        format \(format) 1.0
        element face 2
        property list uchar int i
        property uchar flag
        element v 1
        property float x
        end_header

        """
        var writer = BinaryWriter(littleEndian: littleEndian)
        writer.append(UInt8(2))
        writer.append(Int32(1))
        writer.append(Int32(2))
        writer.append(UInt8(7))
        writer.append(UInt8(1))
        writer.append(Int32(3))
        writer.append(UInt8(8))
        writer.append(Float(4.5))
        let reader = try PLYReader(data: makePLY(header, body: writer.data))
        var values: [[PLYReader.PropertyValue?]] = []
        try reader.readValues(element: reader.elements[1]) { values.append($0) }
        #expect(values == [[.float(4.5)]])
        var floats: [[Float?]] = []
        try reader.readFloatValues(element: reader.elements[1]) { floats.append($0) }
        #expect(floats == [[4.5]])
    }

    @Test("Read every element of a file with lists", arguments: ["ascii", "binary_little_endian", "binary_big_endian"])
    func readEveryElement(format: String) throws {
        let header = """
        ply
        format \(format) 1.0
        element vertex 2
        property float x
        element face 2
        property list uchar int i
        element edge 1
        property short a
        end_header

        """
        let body: Data
        if format == "ascii" {
            body = Data("1.5\r\n2.5\n3 0 1 2\n1 7\n-4\n".utf8)
        } else {
            var writer = BinaryWriter(littleEndian: format == "binary_little_endian")
            writer.append(Float(1.5))
            writer.append(Float(2.5))
            writer.append(UInt8(3))
            writer.append(Int32(0))
            writer.append(Int32(1))
            writer.append(Int32(2))
            writer.append(UInt8(1))
            writer.append(Int32(7))
            writer.append(Int16(-4))
            body = writer.data
        }
        let reader = try PLYReader(data: makePLY(header, body: body))
        var records: [[PLYReader.Record]] = []
        for element in reader.elements {
            var elementRecords: [PLYReader.Record] = []
            try reader.read(element: element) { elementRecords.append($0) }
            records.append(elementRecords)
        }
        #expect(records == [
            [["x": .float(1.5)], ["x": .float(2.5)]],
            [["i": .list([.int(0), .int(1), .int(2)])], ["i": .list([.int(7)])]],
            [["a": .short(-4)]]
        ])
    }

    @Test("Binary offset throws when earlier list data is truncated")
    func binaryOffsetTruncated() throws {
        let header = """
        ply
        format binary_little_endian 1.0
        element face 1
        property list uchar int i
        element v 1
        property float x
        end_header

        """
        let reader = try PLYReader(data: makePLY(header, body: Data([9, 0])))
        #expect(throws: PLYError.invalidData) {
            try reader.readValues(element: reader.elements[1]) { _ in }
        }
    }

    @Test("Binary offset throws on negative list count")
    func binaryOffsetNegativeCount() throws {
        let header = """
        ply
        format binary_little_endian 1.0
        element face 1
        property list char int i
        element v 1
        property uchar x
        end_header

        """
        let reader = try PLYReader(data: makePLY(header, body: Data([0xFF, 1])))
        #expect(throws: PLYError.invalidData) {
            try reader.readValues(element: reader.elements[1]) { _ in }
        }
    }

    @Test("List with a floating-point count type throws", arguments: [true, false])
    func listWithFloatCountType(useFloats: Bool) throws {
        let reader = try PLYReader(data: makePLY("ply\nformat binary_little_endian 1.0\nend_header\n", body: Data([0, 0, 128, 63])))
        let property = PLYReader.Property(name: "i", kind: .list(count: .float, item: .int))
        let element = PLYReader.Element(name: "f", count: 1, properties: [property])
        #expect(throws: PLYError.invalidData) {
            if useFloats {
                try reader.readFloatValues(element: element) { _ in }
            } else {
                try reader.readValues(element: element) { _ in }
            }
        }
    }

    @Test("Huge element counts do not hang or overflow", .timeLimit(.minutes(1)), arguments: ["ascii", "binary_little_endian"], ["property float x", "property list uchar int i"])
    func hugeCounts(format: String, property: String) throws {
        let header = "ply\nformat \(format) 1.0\nelement v \(Int.max)\n\(property)\nelement w 1\nproperty uchar y\nend_header\n"
        let reader = try PLYReader(data: makePLY(header, body: Data("1 2\n".utf8)))
        #expect(reader.maximumRecordCount(of: reader.elements[0]) <= 5)
        if format == "ascii" {
            #expect(reader.maximumRecordCount(of: reader.elements[1]) == 1)
        } else {
            #expect(reader.maximumRecordCount(of: reader.elements[1]) == 0)
            #expect(throws: PLYError.invalidData) { try reader.read(element: reader.elements[1]) { _ in } }
        }
    }

    @Test("maximumRecordCount is limited by the data")
    func maximumRecordCount() throws {
        let binary = try PLYReader(data: makePLY("ply\nformat binary_little_endian 1.0\nelement v 100\nproperty float x\nproperty list uchar int i\nend_header\n", body: Data(count: 50)))
        #expect(binary.maximumRecordCount(of: binary.elements[0]) == 10)
        let ascii = try PLYReader(data: makePLY("ply\nformat ascii 1.0\nelement v 100\nproperty float x\nend_header\n", body: Data("1\n2\n".utf8)))
        #expect(ascii.maximumRecordCount(of: ascii.elements[0]) == 5)
        let small = try PLYReader(data: makePLY("ply\nformat binary_little_endian 1.0\nelement v 2\nproperty float x\nend_header\n", body: Data(count: 400)))
        #expect(small.maximumRecordCount(of: small.elements[0]) == 2)
        let empty = PLYReader.Element(name: "none", count: 3, properties: [])
        #expect(small.maximumRecordCount(of: empty) == 3)
    }

    @Test("ASCII skips blank lines and stops at end of data")
    func asciiShortBody() throws {
        let header = """
        ply
        format ascii 1.0
        element v 3
        property int x
        end_header

        """
        let reader = try PLYReader(data: makePLY(header + "\n1"))
        var records: [PLYReader.Record] = []
        try reader.read { records.append($0) }
        #expect(records == [["x": .int(1)]])
    }

    @Test("ASCII malformed rows throw", arguments: ["", "2 1", "x", "0", "1 2 3 4"])
    func asciiMalformed(row: String) throws {
        let header = """
        ply
        format ascii 1.0
        element v 1
        property list uchar int i
        property int x
        end_header

        """
        let reader = try PLYReader(data: makePLY(header + (row.isEmpty ? " 9\n" : row + "\n")))
        if row == "1 2 3 4" {
            var records: [PLYReader.Record] = []
            try reader.read { records.append($0) }
            #expect(records == [["i": .list([.int(2)]), "x": .int(3)]])
        } else {
            #expect(throws: PLYError.invalidData) { try reader.read { _ in } }
        }
    }

    @Test("Header errors", arguments: [
        ("ply\nformat\nend_header\n", PLYError.invalidHeader),
        ("ply\nformat weird 1.0\nend_header\n", PLYError.unsupportedFormat("weird")),
        ("ply\nformat ascii 1.0\nelement v\nend_header\n", PLYError.invalidHeader),
        ("ply\nformat ascii 1.0\nproperty int x\nend_header\n", PLYError.invalidHeader),
        ("ply\nformat ascii 1.0\nelement v 1\nproperty list uchar\nend_header\n", PLYError.invalidHeader),
        ("ply\nformat ascii 1.0\nelement v 1\nproperty bogus x\nend_header\n", PLYError.invalidHeader),
        ("ply\nformat ascii 1.0\nelement v 1\nproperty list float int i\nend_header\n", PLYError.invalidHeader),
        ("ply\nformat ascii 1.0\nelement v 1\nproperty list uchar bogus i\nend_header\n", PLYError.invalidHeader),
        ("ply\nformat ascii 1.0\nelement v -1\nend_header\n", PLYError.invalidHeader),
        ("ply\nformat ascii 1.0\nelement v 1\nproperty int x\nelement v 2\nproperty int y\nend_header\n", PLYError.invalidHeader),
        ("ply\nelement v 0\nend_header\n", PLYError.formatNotSet),
        ("ply\nformat ascii 1.0\n", PLYError.missingEndHeader)
    ])
    func headerErrors(header: String, error: PLYError) {
        #expect(throws: error) { try PLYReader(data: Data(header.utf8)) }
    }

    @Test("Non-ASCII header throws invalidEncoding")
    func invalidHeaderEncoding() {
        var data = Data("ply\ncomment ".utf8)
        data.append(0xFF)
        data.append(contentsOf: Data("\nend_header\n".utf8))
        #expect(throws: PLYError.invalidEncoding) { try PLYReader(data: data) }
    }

    @Test("Non-UTF8 ASCII body throws invalidEncoding")
    func invalidBodyEncoding() throws {
        var data = Data("ply\nformat ascii 1.0\nelement v 1\nproperty uchar x\nend_header\n".utf8)
        data.append(0xFF)
        let reader = try PLYReader(data: data)
        #expect(throws: PLYError.invalidEncoding) { try reader.read { _ in } }
    }

    @Test("Header skips comments, unknown keywords, and multiple elements")
    func headerMisc() throws {
        let reader = try PLYReader(data: Data("""
        ply
        format ascii 1.0
        comment hello
        obj_info whatever
        element a 0
        element b 0
        property int x
        end_header

        """.utf8))
        #expect(reader.format == .ascii)
        #expect(reader.elements.map(\.name) == ["a", "b"])
        #expect(reader.elements[1].properties == [
            PLYReader.Property(name: "x", kind: .scalar(.int))
        ])
    }

    @Test("Header serializes and parses back to the same value")
    func headerRoundTrip() throws {
        for format in [PLYReader.Format.ascii, .binaryLittleEndian, .binaryBigEndian] {
            let types: [PLYReader.PropertyType] = [.char, .uchar, .short, .ushort, .int, .uint, .float, .double]
            let header = PLYHeader(format: format, elements: [
                PLYReader.Element(name: "vertex", count: 3, properties: types.map { PLYReader.Property(name: "p\($0.name)", kind: .scalar($0)) }),
                PLYReader.Element(name: "face", count: 1, properties: [PLYReader.Property(name: "i", kind: .list(count: .uchar, item: .int))]),
                PLYReader.Element(name: "empty", count: 0, properties: [])
            ])
            let text = header.serialized
            let parsed = try PLYHeader.parse(Data(text.utf8))
            #expect(parsed.header == header)
            #expect(parsed.bodyOffset == text.utf8.count)
            #expect(PLYReader.Format(name: format.name) == format)
        }
        #expect(PLYReader.Format(name: "nope") == nil)
    }

    @Test("Reader exposes the parsed header")
    func readerHeader() throws {
        let text = "ply\nformat ascii 1.0\nelement v 1\nproperty float x\nend_header\n"
        let reader = try PLYReader(data: Data(text.utf8))
        #expect(reader.header == PLYHeader(format: .ascii, elements: [
            PLYReader.Element(name: "v", count: 1, properties: [PLYReader.Property(name: "x", kind: .scalar(.float))])
        ]))
        #expect(reader.header.serialized == text)
    }

    @Test("No elements throws noElements")
    func noElements() throws {
        let reader = try PLYReader(data: Data("ply\nformat ascii 1.0\nend_header\n".utf8))
        #expect(reader.primaryElement == nil)
        #expect(reader.recordCount == 0)
        #expect(throws: PLYError.noElements) { try reader.read { _ in } }
    }

    @Test("PropertyType parsing and sizes")
    func propertyTypes() {
        let pairs: [(String, String, PLYReader.PropertyType, Int)] = [
            ("char", "int8", .char, 1), ("uchar", "uint8", .uchar, 1),
            ("short", "int16", .short, 2), ("ushort", "uint16", .ushort, 2),
            ("int", "int32", .int, 4), ("uint", "uint32", .uint, 4),
            ("float", "float32", .float, 4), ("double", "float64", .double, 8)
        ]
        for (name, alias, type, size) in pairs {
            #expect(PLYReader.PropertyType(string: name) == type)
            #expect(PLYReader.PropertyType(string: alias) == type)
            #expect(type.size == size)
        }
        #expect(PLYReader.PropertyType(string: "nope") == nil)
    }

    @Test("PropertyValue floatValue of list is nil")
    func listFloatValue() {
        #expect(PLYReader.PropertyValue.list([]).floatValue == nil)
    }

    @Test("Error descriptions", arguments: [
        PLYError.invalidEncoding, .invalidHeader, .unsupportedFormat("x"), .missingEndHeader,
        .noElements, .formatNotSet, .invalidData, .invalidValue("x"), .recordCountMismatch
    ])
    func errorDescriptions(error: PLYError) {
        #expect(error.errorDescription?.isEmpty == false)
    }
}
