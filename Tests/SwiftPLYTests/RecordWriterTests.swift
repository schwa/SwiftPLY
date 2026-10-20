import Foundation
@testable import SwiftPLY
import Testing

// The record writer must give the same bytes and errors as the path through `write(_: [PropertyValue])`.

private enum WriteOutcome: Equatable {
    case data(Data)
    case error(String)
}

private func writeOutcome(_ header: PLYHeader, _ body: (inout PLYWriter) throws -> Void) -> WriteOutcome {
    var writer = PLYWriter(header: header)
    do {
        try body(&writer)
        return try .data(writer.finish())
    } catch {
        return .error(String(describing: error))
    }
}

private func referenceOutcome(_ header: PLYHeader, _ body: (inout ReferenceWriter) throws -> Void) -> WriteOutcome {
    var writer = ReferenceWriter(header: header)
    do {
        try body(&writer)
        return try .data(writer.finish())
    } catch {
        return .error(String(describing: error))
    }
}

// Records with every scalar type, a list, and padding between fields.
private func makeRecords(count: Int, seed: Int) -> (definition: PLYStructureDefinition, bytes: [UInt8]) {
    let types: [PLYReader.PropertyType] = [.char, .uchar, .short, .ushort, .int, .uint, .float, .double]
    var fields: [PLYStructureDefinition.Field] = []
    var offset = 0
    for (index, type) in types.enumerated() {
        offset = (offset + type.size - 1) / type.size * type.size + (index.isMultiple(of: 3) ? type.size : 0)
        fields.append(.init(propertyName: "p\(index)", type: type, offset: offset))
        offset += type.size
    }
    fields.append(.init(propertyName: "list", type: .int, offset: offset, list: .init(countType: .uchar, length: 3)))
    offset += 12
    let stride = (offset + 7) / 8 * 8
    var generator = SplitMix(seed: UInt64(seed))
    let bytes = (0..<(count * stride)).map { _ in UInt8.random(in: 0...255, using: &generator) }
    return (PLYStructureDefinition(stride: stride, fields: fields), bytes)
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private func compare(header: PLYHeader, definition: PLYStructureDefinition, bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) {
    let new = writeOutcome(header) { writer in try bytes.withUnsafeBytes { try writer.write($0, definition: definition) } }
    let old = referenceOutcome(header) { writer in try bytes.withUnsafeBytes { try writer.write($0, definition: definition) } }
    #expect(new == old, sourceLocation: sourceLocation)
}

// Random values of the right type for each property, and sometimes a wrong one.
private func randomRecord(_ properties: [PLYReader.Property], wrong: Bool, using generator: inout SplitMix) -> [PLYReader.PropertyValue] {
    func scalar(_ type: PLYReader.PropertyType) -> PLYReader.PropertyValue {
        switch type {
        case .char:
            .char(.random(in: .min ... .max, using: &generator))
        case .uchar:
            .uchar(.random(in: .min ... .max, using: &generator))
        case .short:
            .short(.random(in: .min ... .max, using: &generator))
        case .ushort:
            .ushort(.random(in: .min ... .max, using: &generator))
        case .int:
            .int(.random(in: .min ... .max, using: &generator))
        case .uint:
            .uint(.random(in: .min ... .max, using: &generator))
        case .float:
            .float(Float(bitPattern: .random(in: .min ... .max, using: &generator)))
        case .double:
            .double(Double(bitPattern: .random(in: .min ... .max, using: &generator)))
        }
    }
    var values = properties.map { property -> PLYReader.PropertyValue in
        switch property.kind {
        case .scalar(let type):
            return scalar(type)
        case let .list(countType, itemType):
            // Lengths that fit the count type. Wrong records test lengths that do not fit.
            let longest = countType == .char ? 127 : 255
            return .list((0..<Int.random(in: 0...longest, using: &generator)).map { _ in scalar(itemType) })
        }
    }
    if wrong, !values.isEmpty {
        let index = Int.random(in: values.indices, using: &generator)
        values[index] = [.list([.float(1)]), .int(1), .double(1), .list(Array(repeating: .int(1), count: 300))][Int.random(in: 0...3, using: &generator)]
        if Bool.random(using: &generator) {
            values.removeLast()
        }
    }
    return values
}

@Suite("Record writer matches the value path")
internal struct RecordWriterTests {
    @Test("Every type, lists, and padding", arguments: [PLYReader.Format.ascii, .binaryLittleEndian, .binaryBigEndian], [1, 7, 140_000])
    func records(format: PLYReader.Format, count: Int) {
        let (definition, bytes) = makeRecords(count: count, seed: count)
        let element = PLYReader.Element(name: "v", count: count, definition: definition)
        compare(header: PLYHeader(format: format, elements: [element]), definition: definition, bytes: bytes)
    }

    @Test("Records continue into the next element, with a field order unlike the property order", arguments: [PLYReader.Format.ascii, .binaryBigEndian])
    func twoElements(format: PLYReader.Format) {
        let (definition, bytes) = makeRecords(count: 10, seed: 3)
        var properties = PLYReader.Element(name: "a", count: 4, definition: definition).properties
        properties.reverse()
        let header = PLYHeader(format: format, elements: [
            PLYReader.Element(name: "a", count: 4, properties: properties),
            PLYReader.Element(name: "empty", count: 0, properties: properties),
            PLYReader.Element(name: "b", count: 6, definition: definition)
        ])
        compare(header: header, definition: definition, bytes: bytes)
    }

    @Test("write(_: [PropertyValue]) matches the String-based writer", arguments: [PLYReader.Format.ascii, .binaryLittleEndian, .binaryBigEndian])
    func valueWrites(format: PLYReader.Format) {
        let types: [PLYReader.PropertyType] = [.char, .uchar, .short, .ushort, .int, .uint, .float, .double]
        var properties = types.map { PLYReader.Property(name: "\($0)", kind: .scalar($0)) }
        properties.append(.init(name: "faces", kind: .list(count: .uchar, item: .int)))
        properties.append(.init(name: "weights", kind: .list(count: .char, item: .double)))
        var generator = SplitMix(seed: 42)
        var written = 0
        for trial in 0..<200 {
            let count = Int.random(in: 0...20, using: &generator)
            let records = (0..<count).map { _ in randomRecord(properties, wrong: trial.isMultiple(of: 5) && Int.random(in: 0..<10, using: &generator) == 0, using: &generator) }
            let header = PLYHeader(format: format, elements: [
                PLYReader.Element(name: "v", count: max(0, count - (trial.isMultiple(of: 7) ? 1 : 0)), properties: properties),
                PLYReader.Element(name: "empty", count: 0, properties: []),
                PLYReader.Element(name: "none", count: trial.isMultiple(of: 3) ? 1 : 0, properties: [])
            ])
            let new = writeOutcome(header) { writer in
                for record in records {
                    try writer.write(record)
                }
                if trial.isMultiple(of: 3) {
                    try writer.write([])
                }
            }
            let old = referenceOutcome(header) { writer in
                for record in records {
                    try writer.write(record)
                }
                if trial.isMultiple(of: 3) {
                    try writer.write([])
                }
            }
            #expect(new == old, "trial \(trial)")
            if case .data = new {
                written += 1
            }
        }
        // Most trials have only valid records and the right count, so they must give data.
        #expect(written > 100)
    }

    @Test("Many ASCII records, several batches and elements, mixed with records from memory")
    func manyASCIIRecords() {
        let properties: [PLYReader.Property] = [.init(name: "x", kind: .scalar(.float)), .init(name: "i", kind: .list(count: .uchar, item: .int))]
        let (definition, bytes) = makeRecords(count: 1_000, seed: 5)
        let header = PLYHeader(format: .ascii, elements: [
            PLYReader.Element(name: "a", count: 70_000, properties: properties),
            PLYReader.Element(name: "b", count: 1_000, definition: definition),
            PLYReader.Element(name: "c", count: 2_000, properties: properties)
        ])
        // Short lists, so that the test is fast. Other tests cover long lists.
        var generator = SplitMix(seed: 8)
        func makeRecord() -> [PLYReader.PropertyValue] {
            [.float(Float(bitPattern: .random(in: .min ... .max, using: &generator))), .list((0..<Int.random(in: 0...3, using: &generator)).map { _ in .int(.random(in: .min ... .max, using: &generator)) })]
        }
        let first = (0..<70_000).map { _ in makeRecord() }
        let last = (0..<2_000).map { _ in makeRecord() }
        let new = writeOutcome(header) { writer in
            for record in first {
                try writer.write(record)
            }
            try bytes.withUnsafeBytes { try writer.write($0, definition: definition) }
            for record in last {
                try writer.write(record)
            }
        }
        let old = referenceOutcome(header) { writer in
            for record in first {
                try writer.write(record)
            }
            try bytes.withUnsafeBytes { try writer.write($0, definition: definition) }
            for record in last {
                try writer.write(record)
            }
        }
        #expect(new == old)
        guard case .data(let data) = new else {
            Issue.record("writing failed: \(new)")
            return
        }
        #expect(data.count > 500_000)
    }

    @Test("Errors", arguments: [PLYReader.Format.ascii, .binaryLittleEndian])
    func errors(format: PLYReader.Format) {
        let (definition, bytes) = makeRecords(count: 5, seed: 9)
        let element = PLYReader.Element(name: "v", count: 5, definition: definition)
        // Too many records.
        compare(header: PLYHeader(format: format, elements: [PLYReader.Element(name: "v", count: 3, definition: definition)]), definition: definition, bytes: bytes)
        // A property with no field, and a property whose type differs from its field.
        var missing = element
        missing.properties.append(.init(name: "other", kind: .scalar(.float)))
        compare(header: PLYHeader(format: format, elements: [missing]), definition: definition, bytes: bytes)
        var otherType = element
        otherType.properties[0].kind = .scalar(.int)
        compare(header: PLYHeader(format: format, elements: [otherType]), definition: definition, bytes: bytes)
        // A list length that does not fit its count type.
        var longList = definition
        longList.fields[8].list = .init(countType: .char, length: 200)
        longList.stride = longList.fields[8].offset + 800
        let longBytes = [UInt8](repeating: 1, count: longList.stride * 2)
        compare(header: PLYHeader(format: format, elements: [PLYReader.Element(name: "v", count: 2, definition: longList)]), definition: longList, bytes: longBytes)
    }
}
