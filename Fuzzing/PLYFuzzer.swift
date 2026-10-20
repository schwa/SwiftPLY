import Foundation

// libFuzzer entry point, built with `just fuzz` (needs the open-source toolchain from swiftly; Xcode's Swift has no
// libFuzzer). The SwiftPLY sources are compiled into the same module, so no import is needed.
//
// Every input must either throw a PLYError or read without a crash. Files that read are written back out in their
// own format, and the result must read back to the same values.

private let maximumInputSize = 1 << 20

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzPLY(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    guard let bytes, count <= maximumInputSize else {
        return 0
    }
    let data = Data(bytes: bytes, count: count)
    guard let reader = try? PLYReader(data: data) else {
        return 0
    }
    // Headers that declare huge elements are skipped: memory for them is limited by the data, but reading them one
    // value at a time takes too long for a fuzzer.
    guard reader.elements.allSatisfy({ reader.maximumRecordCount(of: $0) <= 100_000 }) else {
        return 0
    }
    var allValues: [[[PLYReader.PropertyValue]]] = []
    for element in reader.elements {
        var values: [[PLYReader.PropertyValue]] = []
        let read = Result {
            try reader.readValues(element: element) { row in values.append(row.map { $0 ?? .uchar(0) }) }
        }
        _ = try? reader.readFloatValues(element: element) { _ in }
        _ = try? reader.read(element: element) { _ in }
        readWithDefinition(reader, element)
        // A record of an ASCII element can be blank, and nil values are replaced above, so only fully read binary
        // elements are written back.
        if case .success = read, reader.format != .ascii, values.count == element.count {
            allValues.append(values)
        } else {
            return 0
        }
    }
    checkRoundTrip(reader, allValues)
    return 0
}

// Reads the element into memory, with every scalar property as a Float and every list as three Ints.
private func readWithDefinition(_ reader: PLYReader, _ element: PLYReader.Element) {
    var definition = PLYStructureDefinition(stride: 1)
    var offset = 0
    var names = Set<String>()
    for property in element.properties where names.insert(property.name).inserted {
        switch property.kind {
        case .scalar:
            definition.fields.append(.init(propertyName: property.name, type: .float, offset: offset))
            offset += 4

        case .list(let countType, _):
            guard countType != .float, countType != .double else {
                continue
            }
            definition.fields.append(.init(propertyName: property.name, type: .int, offset: offset, list: .init(countType: countType, length: 3)))
            offset += 12
        }
    }
    guard !definition.fields.isEmpty else {
        return
    }
    definition.stride = offset
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, reader.maximumRecordCount(of: element) * offset), alignment: 8)
    defer { buffer.deallocate() }
    _ = try? reader.read(element: element, into: buffer, definition: definition)
}

private func checkRoundTrip(_ reader: PLYReader, _ allValues: [[[PLYReader.PropertyValue]]]) {
    var writer = PLYWriter(header: reader.header)
    do {
        for values in allValues {
            for record in values {
                try writer.write(record)
            }
        }
        let rewritten = try PLYReader(data: writer.finish())
        for (element, values) in zip(rewritten.elements, allValues) {
            var index = 0
            try rewritten.readValues(element: element) { row in
                // Compare as text, so that NaN values are equal.
                precondition("\(row.map { $0 ?? .uchar(0) })" == "\(values[index])", "round trip changed element \(element.name) record \(index)")
                index += 1
            }
        }
    } catch {
        preconditionFailure("round trip failed: \(error)")
    }
}
