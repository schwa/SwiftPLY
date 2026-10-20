import Foundation
@testable import SwiftPLY

// Simple, slow versions of the reader and writer. Parity tests compare the fast library code with them.

// The text of a value, as Swift's `description` gives it.
private func referenceText(_ value: PLYReader.PropertyValue) -> String {
    switch value {
    case .char(let number):
        number.description
    case .uchar(let number):
        number.description
    case .short(let number):
        number.description
    case .ushort(let number):
        number.description
    case .int(let number):
        number.description
    case .uint(let number):
        number.description
    case .float(let number):
        number.description
    case .double(let number):
        number.description
    case .list(let items):
        items.map(referenceText).joined(separator: " ")
    }
}

private func referenceBytes(_ value: PLYReader.PropertyValue, littleEndian: Bool) -> [UInt8] {
    func bytes<I: FixedWidthInteger>(_ number: I) -> [UInt8] {
        withUnsafeBytes(of: littleEndian ? number.littleEndian : number.bigEndian) { Array($0) }
    }
    switch value {
    case .char(let number):
        return bytes(number)
    case .uchar(let number):
        return bytes(number)
    case .short(let number):
        return bytes(number)
    case .ushort(let number):
        return bytes(number)
    case .int(let number):
        return bytes(number)
    case .uint(let number):
        return bytes(number)
    case .float(let number):
        return bytes(number.bitPattern)
    case .double(let number):
        return bytes(number.bitPattern)
    case .list(let items):
        return items.flatMap { referenceBytes($0, littleEndian: littleEndian) }
    }
}

private func referenceCount(_ count: Int, type: PLYReader.PropertyType) -> PLYReader.PropertyValue? {
    switch type {
    case .char:
        Int8(exactly: count).map { .char($0) }
    case .uchar:
        UInt8(exactly: count).map { .uchar($0) }
    case .short:
        Int16(exactly: count).map { .short($0) }
    case .ushort:
        UInt16(exactly: count).map { .ushort($0) }
    case .int:
        Int32(exactly: count).map { .int($0) }
    case .uint:
        UInt32(exactly: count).map { .uint($0) }
    case .float, .double:
        nil
    }
}

// Writes records one value at a time, with Strings for ASCII.
internal struct ReferenceWriter {
    let header: PLYHeader
    private var data: Data
    private var elementIndex = 0
    private var recordIndex = 0

    init(header: PLYHeader) {
        self.header = header
        data = Data(header.serialized.utf8)
        skipEmptyElements()
    }

    func currentElement() throws -> PLYReader.Element {
        guard elementIndex < header.elements.count else {
            throw PLYError.recordCountMismatch
        }
        return header.elements[elementIndex]
    }

    mutating func write(_ values: [PLYReader.PropertyValue]) throws {
        let element = try currentElement()
        guard values.count == element.properties.count else {
            throw PLYError.invalidValue(element.name)
        }
        var fields: [String] = []
        var bytes: [UInt8] = []
        let littleEndian = header.format == .binaryLittleEndian
        for (property, value) in zip(element.properties, values) {
            switch (property.kind, value) {
            case (.scalar(let type), _) where value.scalarType == type:
                fields.append(referenceText(value))
                bytes += referenceBytes(value, littleEndian: littleEndian)

            case let (.list(countType, itemType), .list(items)) where items.allSatisfy { $0.scalarType == itemType }:
                guard let count = referenceCount(items.count, type: countType) else {
                    throw PLYError.invalidValue(property.name)
                }
                fields.append(referenceText(count))
                if !items.isEmpty {
                    fields.append(referenceText(value))
                }
                bytes += referenceBytes(count, littleEndian: littleEndian) + referenceBytes(value, littleEndian: littleEndian)

            default:
                throw PLYError.invalidValue(property.name)
            }
        }
        if header.format == .ascii {
            data.append(contentsOf: (fields.joined(separator: " ") + "\n").utf8)
        } else {
            data.append(contentsOf: bytes)
        }
        recordIndex += 1
        if recordIndex == header.elements[elementIndex].count {
            elementIndex += 1
            recordIndex = 0
            skipEmptyElements()
        }
    }

    // Records from memory, one `write(_:)` for each record.
    mutating func write(_ records: UnsafeRawBufferPointer, definition: PLYStructureDefinition) throws {
        try definition.validate()
        guard records.count.isMultiple(of: definition.stride) else {
            throw PLYError.invalidValue("stride")
        }
        guard let base = records.baseAddress else {
            return
        }
        for index in 0..<(records.count / definition.stride) {
            let element = try currentElement()
            let fields = try element.properties.map { property in
                guard let field = definition.fields.first(where: { $0.propertyName == property.name }), property.kind == field.kind else {
                    throw PLYError.invalidValue(property.name)
                }
                return field
            }
            try write(fields.map { $0.load(from: base + index * definition.stride) })
        }
    }

    func finish() throws -> Data {
        guard elementIndex == header.elements.count else {
            throw PLYError.recordCountMismatch
        }
        return data
    }

    private mutating func skipEmptyElements() {
        while elementIndex < header.elements.count, header.elements[elementIndex].count < 1 {
            elementIndex += 1
        }
    }
}

internal extension PLYReader {
    // ASCII rows from Strings for each line and token.
    func referenceASCIIRows(element: Element, callback: ([PropertyValue?]) throws -> Void) throws {
        var offset = try startOffset(of: element)
        for _ in 0..<element.count {
            guard offset < data.count else {
                break
            }
            let end = data[offset...].firstIndex(of: 0x0A) ?? data.count
            let lineData = data[offset..<end]
            offset = end + 1
            guard let rawLine = String(bytes: lineData, encoding: .utf8) else {
                throw PLYError.invalidEncoding
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }
            let values = line.split(separator: " ").map(String.init)
            var valueIndex = 0
            var row: [PropertyValue?] = []
            for property in element.properties {
                switch property.kind {
                case .list(_, let itemType):
                    guard valueIndex < values.count, let listCount = Int(values[valueIndex]), listCount >= 0 else {
                        throw PLYError.invalidData
                    }
                    valueIndex += 1
                    var items: [PropertyValue] = []
                    for _ in 0..<listCount {
                        guard valueIndex < values.count else {
                            throw PLYError.invalidData
                        }
                        if let value = PropertyValue(string: values[valueIndex], type: itemType) {
                            items.append(value)
                        }
                        valueIndex += 1
                    }
                    row.append(.list(items))

                case .scalar(let type):
                    guard valueIndex < values.count else {
                        throw PLYError.invalidData
                    }
                    row.append(PropertyValue(string: values[valueIndex], type: type))
                    valueIndex += 1
                }
            }
            try callback(row)
        }
    }
}
