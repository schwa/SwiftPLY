import Foundation
@testable import SwiftPLY
import Testing

// Every count type, conversion, and kind of line, through the fast readers and writers. Each case compares with
// the reference implementations or with values read one at a time.

private let integerTypes: [PLYReader.PropertyType] = [.char, .uchar, .short, .ushort, .int, .uint]
private let allTypes = integerTypes + [.float, .double]

private func value(_ number: Int, as type: PLYReader.PropertyType) -> PLYReader.PropertyValue {
    switch type {
    case .char:
        .char(Int8(number % 100))
    case .uchar:
        .uchar(UInt8(number % 200))
    case .short:
        .short(Int16(number % 30_000))
    case .ushort:
        .ushort(UInt16(number % 60_000))
    case .int:
        .int(Int32(number))
    case .uint:
        .uint(UInt32(number))
    case .float:
        .float(Float(number) * 0.5)
    case .double:
        .double(Double(number) * 0.25)
    }
}

// A file with `count` records of a list of three `itemType` items counted by `countType`, and one scalar.
private func listFile(format: PLYReader.Format, countType: PLYReader.PropertyType, itemType: PLYReader.PropertyType, count: Int) throws -> Data {
    let element = PLYReader.Element(name: "face", count: count, properties: [
        .init(name: "i", kind: .list(count: countType, item: itemType)),
        .init(name: "s", kind: .scalar(.ushort))
    ])
    var writer = PLYWriter(header: PLYHeader(format: format, elements: [element]))
    var reference = ReferenceWriter(header: writer.header)
    for record in 0..<count {
        let values: [PLYReader.PropertyValue] = [.list((0..<3).map { value(record + $0, as: itemType) }), value(record, as: .ushort)]
        try writer.write(values)
        try reference.write(values)
    }
    let data = try writer.finish()
    #expect(try data == reference.finish())
    return data
}

private func rows(_ reader: PLYReader, _ element: PLYReader.Element) throws -> [String] {
    var result: [String] = []
    try reader.readValues(element: element) { result.append("\($0)") }
    return result
}

@Suite("Types and count types")
internal struct TypeCoverageTests {
    @Test("Lists with every count type, read and written, value and definition", arguments: [PLYReader.Format.ascii, .binaryLittleEndian, .binaryBigEndian], integerTypes)
    func countTypes(format: PLYReader.Format, countType: PLYReader.PropertyType) throws {
        // More than one checkpoint. "Large binary elements with lists" covers reading in parts.
        let count = PLYReader.checkpointInterval + 100
        let data = try listFile(format: format, countType: countType, itemType: .int, count: count)
        let reader = try PLYReader(data: data)
        let element = reader.elements[0]

        var floats = 0
        try reader.readFloatValues(element: element) { _ in floats += 1 }
        #expect(floats == count)
        #expect(try rows(reader, element).count == count)

        // List items converted to Double, and the scalar converted to Float.
        let definition = PLYStructureDefinition(stride: 32, fields: [
            .init(propertyName: "i", type: .double, offset: 0, list: .init(countType: countType, length: 3)),
            .init(propertyName: "s", type: .float, offset: 24)
        ])
        var bytes = [UInt8](repeating: 0, count: count * 32)
        #expect(try bytes.withUnsafeMutableBytes { try reader.read(element: element, into: $0, definition: definition) } == count)
        bytes.withUnsafeBytes { raw in
            #expect(raw.loadUnaligned(fromByteOffset: 32 * 7 + 16, as: Double.self) == 9)
            #expect(raw.loadUnaligned(fromByteOffset: 32 * 7 + 24, as: Float.self) == 7)
        }

        // The same records written from memory with each count type.
        let intDefinition = PLYStructureDefinition(stride: 16, fields: [
            .init(propertyName: "i", type: .int, offset: 0, list: .init(countType: countType, length: 3)),
            .init(propertyName: "s", type: .ushort, offset: 12)
        ])
        var source = [UInt8](repeating: 0, count: count * 16)
        _ = try source.withUnsafeMutableBytes { try reader.read(element: element, into: $0, definition: intDefinition) }
        var writer = PLYWriter(header: reader.header)
        var reference = ReferenceWriter(header: reader.header)
        try source.withUnsafeBytes { try writer.write($0, definition: intDefinition) }
        try source.withUnsafeBytes { try reference.write($0, definition: intDefinition) }
        #expect(try writer.finish() == reference.finish())
    }

    @Test("List items that change type", arguments: [PLYReader.Format.binaryLittleEndian, .binaryBigEndian, .ascii], [(PLYReader.PropertyType.double, PLYReader.PropertyType.float), (.float, .double), (.int, .short)])
    func listConversions(format: PLYReader.Format, types: (file: PLYReader.PropertyType, memory: PLYReader.PropertyType)) throws {
        let data = try listFile(format: format, countType: .uchar, itemType: types.file, count: 50)
        let reader = try PLYReader(data: data)
        let definition = PLYStructureDefinition(stride: 3 * types.memory.size, fields: [
            .init(propertyName: "i", type: types.memory, offset: 0, list: .init(countType: .uchar, length: 3))
        ])
        var bytes = [UInt8](repeating: 0, count: 50 * definition.stride)
        #expect(try bytes.withUnsafeMutableBytes { try reader.read(element: reader.elements[0], into: $0, definition: definition) } == 50)
        let expected = value(49 + 2, as: types.file)
        let last = bytes.withUnsafeBytes { raw in
            definition.fields[0].load(from: raw.baseAddress.unsafelyUnwrapped + 49 * definition.stride)
        }
        guard case .list(let items) = last else {
            Issue.record("not a list")
            return
        }
        #expect(items[2].doubleValue == expected.doubleValue)
    }

    @Test("Scalars of every type into every type", arguments: [PLYReader.Format.binaryLittleEndian, .binaryBigEndian, .ascii])
    func scalarConversions(format: PLYReader.Format) throws {
        let element = PLYReader.Element(name: "v", count: 3, properties: allTypes.map { .init(name: "\($0)", kind: .scalar($0)) })
        var writer = PLYWriter(header: PLYHeader(format: format, elements: [element]))
        // Multiples of 4, so that every value is a whole number that fits every type.
        for record in 0..<3 {
            try writer.write(allTypes.map { value((record + 1) * 4, as: $0) })
        }
        let reader = try PLYReader(data: writer.finish())
        for target in allTypes {
            let definition = PLYStructureDefinition(stride: 8 * allTypes.count, fields: allTypes.enumerated().map { index, type in
                .init(propertyName: "\(type)", type: target, offset: 8 * index)
            })
            var bytes = [UInt8](repeating: 0, count: 3 * definition.stride)
            #expect(try bytes.withUnsafeMutableBytes { try reader.read(element: reader.elements[0], into: $0, definition: definition) } == 3)
            let last = bytes.withUnsafeBytes { raw in
                definition.fields.map { $0.load(from: raw.baseAddress.unsafelyUnwrapped + 2 * definition.stride).doubleValue }
            }
            #expect(last == allTypes.map { value(12, as: $0).doubleValue })
        }
    }

    @Test("List items that do not fit the field type throw", arguments: [PLYReader.Format.ascii, .binaryLittleEndian])
    func listItemOutOfRange(format: PLYReader.Format) throws {
        let data = try listFile(format: format, countType: .uchar, itemType: .int, count: 300)
        let reader = try PLYReader(data: data)
        let definition = PLYStructureDefinition(stride: 3, fields: [
            .init(propertyName: "i", type: .char, offset: 0, list: .init(countType: .uchar, length: 3))
        ])
        var bytes = [UInt8](repeating: 0, count: 300 * 3)
        #expect(throws: PLYError.invalidValue("i")) {
            try bytes.withUnsafeMutableBytes { try reader.read(element: reader.elements[0], into: $0, definition: definition) }
        }
    }

    @Test("A list count type that is not an integer type throws when writing values")
    func floatCountType() throws {
        let element = PLYReader.Element(name: "v", count: 1, properties: [.init(name: "i", kind: .list(count: .float, item: .int))])
        var writer = PLYWriter(header: PLYHeader(format: .binaryLittleEndian, elements: [element]))
        #expect(throws: PLYError.invalidValue("i")) { try writer.write([.list([.int(1)])]) }
    }

    @Test("Lines with characters that are not ASCII")
    func nonASCIILines() throws {
        // U+2003 is whitespace to Foundation, so it is trimmed. A line of only U+2003 is blank.
        let text = "ply\nformat ascii 1.0\nelement v 4\nproperty int a\nproperty list uchar int b\nend_header\n1 1 2\u{2003}\n\u{2003}\n3 1 4\n5 1 6\n"
        let reader = try PLYReader(data: Data(text.utf8))
        var reference: [String] = []
        try reader.referenceASCIIRows(element: reader.elements[0]) { reference.append("\($0)") }
        #expect(try rows(reader, reader.elements[0]) == reference)
        let definition = PLYStructureDefinition(stride: 8, fields: [
            .init(propertyName: "a", type: .int, offset: 0), .init(propertyName: "b", type: .int, offset: 4, list: .init(countType: .uchar, length: 1))
        ])
        var bytes = [Int32](repeating: 0, count: 8)
        #expect(try bytes.withUnsafeMutableBytes { try reader.read(element: reader.elements[0], into: $0, definition: definition) } == 3)
        #expect(Array(bytes.prefix(6)) == [1, 2, 3, 4, 5, 6])
    }

    @Test("Lines with many tokens")
    func manyTokens() throws {
        let items = (0..<200).map(String.init).joined(separator: " ")
        let text = "ply\nformat ascii 1.0\nelement v 2\nproperty list uchar int b\nend_header\n200 \(items)\n200 \(items)\n"
        let reader = try PLYReader(data: Data(text.utf8))
        var reference: [String] = []
        try reader.referenceASCIIRows(element: reader.elements[0]) { reference.append("\($0)") }
        #expect(try rows(reader, reader.elements[0]) == reference)
    }

    @Test("Elements that are not in the header", arguments: [PLYReader.Format.ascii, .binaryLittleEndian])
    func elementsNotInHeader(format: PLYReader.Format) throws {
        let data = try listFile(format: format, countType: .uchar, itemType: .int, count: 3)
        let reader = try PLYReader(data: data)
        // An element that is not in the header starts after the last element, where there is no data.
        let other = PLYReader.Element(name: "other", count: 2, properties: [.init(name: "s", kind: .scalar(.ushort))])
        let definition = PLYStructureDefinition(stride: 2, fields: [.init(propertyName: "s", type: .ushort, offset: 0)])
        var bytes = [UInt8](repeating: 0, count: 4)
        let result = Result { try bytes.withUnsafeMutableBytes { try reader.read(element: other, into: $0, definition: definition) } }
        #expect(String(describing: result) == (format == .ascii ? "success(0)" : "failure(SwiftPLY.PLYError.invalidData)"))

        // An element with no records fits after the last element.
        let empty = PLYReader.Element(name: "empty", count: 0, properties: other.properties)
        #expect(try bytes.withUnsafeMutableBytes { try reader.read(element: empty, into: $0, definition: definition) } == 0)
        let emptyList = PLYReader.Element(name: "empty", count: 0, properties: [.init(name: "i", kind: .list(count: .uchar, item: .int))])
        let listDefinition = PLYStructureDefinition(stride: 4, fields: [.init(propertyName: "i", type: .int, offset: 0, list: .init(countType: .uchar, length: 1))])
        #expect(try bytes.withUnsafeMutableBytes { try reader.read(element: emptyList, into: $0, definition: listDefinition) } == 0)
    }

    @Test("Values from strings that do not parse", arguments: allTypes)
    func stringValues(type: PLYReader.PropertyType) {
        #expect(PLYReader.PropertyValue(string: "x", type: type) == nil)
        #expect(PLYReader.PropertyValue(string: "1", type: type)?.doubleValue == 1)
    }
}
