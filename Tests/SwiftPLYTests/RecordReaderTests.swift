import Foundation
@testable import SwiftPLY
import Testing

// The record readers must give the same bytes, counts, and errors as the path through `readValues`.

private let fixturesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

private enum Outcome: Equatable {
    case records(Int, [UInt8])
    case error(String)
}

private func outcome(_ body: (UnsafeMutableRawBufferPointer) throws -> Int, byteCount: Int) -> Outcome {
    var bytes = [UInt8](repeating: 0xAB, count: byteCount)
    do {
        let count = try bytes.withUnsafeMutableBytes(body)
        return .records(count, bytes)
    } catch {
        return .error(String(describing: error))
    }
}

// A definition that maps every property of `element`, converting some of them to other types.
private func definition(for element: PLYReader.Element, convert: Bool) -> PLYStructureDefinition {
    var result = PLYStructureDefinition(stride: 1)
    var offset = 0
    for (index, property) in element.properties.enumerated() {
        switch property.kind {
        case .scalar(let type):
            let fieldType: PLYReader.PropertyType = convert && index.isMultiple(of: 2) ? (type == .double ? .float : .double) : type
            result.fields.append(.init(propertyName: property.name, type: fieldType, offset: offset))
            offset += fieldType.size

        case let .list(_, itemType):
            let fieldType: PLYReader.PropertyType = convert ? .double : itemType
            result.fields.append(.init(propertyName: property.name, type: fieldType, offset: offset, list: .init(countType: .uchar, length: 3)))
            offset += fieldType.size * 3
        }
    }
    result.stride = max(offset, 1)
    return result
}

private func compare(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let reader = try? PLYReader(data: data) else {
        return
    }
    for element in reader.elements where !element.properties.isEmpty {
        for convert in [false, true] {
            let fieldDefinition = definition(for: element, convert: convert)
            let byteCount = reader.maximumRecordCount(of: element) * fieldDefinition.stride
            let propertyIndices = Array(element.properties.indices)
            let new = outcome({ try reader.read(element: element, into: $0, definition: fieldDefinition) }, byteCount: byteCount)
            let old = outcome({ buffer in
                guard let base = buffer.baseAddress else {
                    return 0
                }
                return try reader.readWithValues(element: element, into: base, definition: fieldDefinition, propertyIndices: propertyIndices)
            }, byteCount: byteCount)
            #expect(canonical(new, fieldDefinition) == canonical(old, fieldDefinition), "\(element.name) convert: \(convert) \(summary(new)) vs old \(summary(old)) format \(reader.format)", sourceLocation: sourceLocation)
        }
    }
}

// The value path converts every value through Double, which can change the payload bits of a NaN. The record
// readers copy the bits. Both are NaN, so NaN payloads are made the same before comparing.
private func canonical(_ outcome: Outcome, _ definition: PLYStructureDefinition) -> Outcome {
    guard case let .records(count, allBytes) = outcome else {
        return outcome
    }
    // Memory after the returned records is not specified.
    var bytes = Array(allBytes.prefix(count * definition.stride))
    bytes.withUnsafeMutableBytes { raw in
        for record in 0..<count {
            for field in definition.fields {
                for item in 0..<(field.list?.length ?? 1) {
                    let offset = record * definition.stride + field.offset + item * field.type.size
                    if field.type == .float, raw.loadUnaligned(fromByteOffset: offset, as: Float.self).isNaN {
                        raw.storeBytes(of: Float.nan, toByteOffset: offset, as: Float.self)
                    }
                    if field.type == .double, raw.loadUnaligned(fromByteOffset: offset, as: Double.self).isNaN {
                        raw.storeBytes(of: Double.nan, toByteOffset: offset, as: Double.self)
                    }
                }
            }
        }
    }
    return .records(count, bytes)
}

private func summary(_ outcome: Outcome) -> String {
    switch outcome {
    case let .records(count, bytes):
        "records \(count) checksum \(bytes.reduce(0) { $0 &* 31 &+ Int($1) })"
    case .error(let error):
        "error \(error)"
    }
}

private func fixtureData() throws -> [Data] {
    let urls = try FileManager.default.subpathsOfDirectory(atPath: fixturesURL.path)
        .filter { $0.hasSuffix(".ply") }
        .map { fixturesURL.appendingPathComponent($0) }
    return try urls.map { try Data(contentsOf: $0) }
}

@Suite("Record readers match the value path")
internal struct RecordReaderTests {
    @Test("Fixtures")
    func fixtures() throws {
        for data in try fixtureData() {
            compare(data)
        }
    }

    @Test("Mutated fixtures")
    func mutated() throws {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("0123456789 -+.eE\n\r\tx\u{00}".utf8) + [0xC3, 0xA9, 0xFF]
        for data in try fixtureData() {
            guard let reader = try? PLYReader(data: data) else {
                continue
            }
            for _ in 0..<40 {
                var mutated = data
                for _ in 0..<Int.random(in: 1...4, using: &generator) {
                    let index = Int.random(in: reader.bodyOffset..<max(reader.bodyOffset + 1, mutated.count), using: &generator)
                    guard index < mutated.count else {
                        continue
                    }
                    mutated[index] = reader.format == .ascii ? alphabet[Int.random(in: alphabet.indices, using: &generator)] : UInt8.random(in: 0...255, using: &generator)
                }
                if Bool.random(using: &generator) {
                    mutated = mutated.prefix(Int.random(in: reader.bodyOffset...mutated.count, using: &generator))
                }
                compare(mutated)
            }
        }
    }

    // Large enough that the readers split the element into parts on several cores.
    @Test("Large elements", arguments: ["none", "blank line", "blank non-ASCII line", "bad value", "short line", "no final line feed"])
    func largeElements(damage: String) {
        // Wide lines, so that the element is over 2 MB with few records.
        let count = 15_000
        let extra = (0..<20).map { "property float extra\($0)\n" }.joined()
        var text = "ply\nformat ascii 1.0\nelement vertex \(count)\nproperty float x\nproperty uchar red\nproperty list uchar int i\n\(extra)end_header\n"
        var lines = (0..<count).map { record in
            "\(Float(record) * 0.25) \(record % 256) 3 \(record) \(record + 1) \(record + 2) " + (0..<20).map { "\(Float(record * 20 + $0) * 0.125)" }.joined(separator: " ")
        }
        switch damage {
        case "blank line":
            lines[count / 2] = ""
        case "bad value":
            lines[count * 3 / 4] = "1.5 300 3 1 2 3"
        case "short line":
            lines[count / 3] = "1.5"
        case "blank non-ASCII line":
            lines[count / 2] = "\u{2003}"
        default:
            break
        }
        text += lines.joined(separator: "\n") + (damage == "no final line feed" ? "" : "\n")
        let ascii = Data(text.utf8)
        compare(ascii)
    }

    @Test("Large binary elements with lists", arguments: [PLYReader.Format.binaryLittleEndian, .binaryBigEndian], ["none", "wrong length", "bad value"])
    func largeBinaryLists(format: PLYReader.Format, damage: String) throws {
        // More than 8 checkpoints, so the reader uses several parts.
        let count = 9 * PLYReader.checkpointInterval + 123
        let element = PLYReader.Element(name: "face", count: count, properties: [
            .init(name: "i", kind: .list(count: .uchar, item: .int)), .init(name: "red", kind: .scalar(.short))
        ])
        var writer = PLYWriter(header: PLYHeader(format: format, elements: [element]))
        for record in 0..<count {
            let late = record == count * 3 / 4
            let items: [PLYReader.PropertyValue] = (0..<(damage == "wrong length" && late ? 4 : 3)).map { .int(Int32(record + $0)) }
            try writer.write([.list(items), .short(damage == "bad value" && late ? 300 : Int16(record % 256))])
        }
        let data = try writer.finish()
        compare(data)

        let reader = try PLYReader(data: data)
        let triangles = PLYStructureDefinition(stride: 16, fields: [
            .init(propertyName: "i", type: .int, offset: 0, list: .init(countType: .uchar, length: 3)),
            .init(propertyName: "red", type: .uchar, offset: 12)
        ])
        let new = outcome({ try reader.read(element: reader.elements[0], into: $0, definition: triangles) }, byteCount: count * 16)
        let old = outcome({ try reader.readWithValues(element: reader.elements[0], into: $0.baseAddress.unsafelyUnwrapped, definition: triangles, propertyIndices: [0, 1]) }, byteCount: count * 16)
        #expect(new == old)
        switch damage {
        case "wrong length":
            #expect(new == .error("invalidValue(\"i\")"))
        case "bad value":
            #expect(new == .error("invalidValue(\"red\")"))
        default:
            #expect(new == old && new != .error(""))
        }
    }

    @Test("Large fixed-size binary elements", arguments: [PLYReader.Format.binaryLittleEndian, .binaryBigEndian], [false, true])
    func largeBinary(format: PLYReader.Format, badValue: Bool) throws {
        // Wide records, so that the element is over 2 MB with few records.
        let count = 12_000
        let extra = (0..<30).map { PLYReader.Property(name: "y\($0)", kind: .scalar(.double)) }
        let element = PLYReader.Element(name: "vertex", count: count, properties: [
            .init(name: "x", kind: .scalar(.float)), .init(name: "red", kind: .scalar(.short))
        ] + extra)
        var writer = PLYWriter(header: PLYHeader(format: format, elements: [element]))
        for record in 0..<count {
            let red = badValue && record == count * 3 / 4 ? 300 : Int16(record % 256)
            try writer.write([.float(Float(record) * 0.5), .short(red)] + (0..<30).map { .double(Double(record * 30 + $0)) })
        }
        let data = try writer.finish()
        #expect(data.count > 2 << 20)
        compare(data)

        // `red` narrows from short to uchar, so 300 fails in one late record.
        let reader = try PLYReader(data: data)
        let narrowing = PLYStructureDefinition(stride: 8, fields: [
            .init(propertyName: "x", type: .float, offset: 0), .init(propertyName: "red", type: .uchar, offset: 4)
        ])
        let new = outcome({ try reader.read(element: reader.elements[0], into: $0, definition: narrowing) }, byteCount: count * 8)
        let old = outcome({ try reader.readWithValues(element: reader.elements[0], into: $0.baseAddress.unsafelyUnwrapped, definition: narrowing, propertyIndices: [0, 1]) }, byteCount: count * 8)
        #expect(new == old)
        #expect((new == .error("invalidValue(\"red\")")) == badValue)
    }

    @Test("ASCII number parsing matches Swift", arguments: [
        "0", "-0", "+1", "1.", ".5", "-.5", "1e5", "1E-5", "1e", "e1", ".", "+", "-", "", "1.5e+3", "3.4028235e38",
        "1e39", "-1e39", "1e-46", "1.4e-45", "0.1", "16777217", "9007199254740993", "1.17549435e-38", "--1", "1-",
        "00012", "1e400", "123456789012345678901234567890", "0.30000000000000004", "inf", "nan", "0x1p3", "1,5"
    ])
    func numbers(text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { raw in
            let token = 0..<raw.count
            #expect(PLYASCIIRecordReader.parseFloat(raw, token).map(\.bitPattern) == Float(text).map(\.bitPattern))
            #expect(PLYASCIIRecordReader.parseDouble(raw, token).map(\.bitPattern) == Double(text).map(\.bitPattern))
            #expect(PLYASCIIRecordReader.parseInteger(raw, token, as: Int8.self) == Int8(text))
            #expect(PLYASCIIRecordReader.parseInteger(raw, token, as: UInt32.self) == UInt32(text))
            #expect(PLYASCIIRecordReader.parseInteger(raw, token, as: Int.self) == Int(text))
        }
    }

    @Test("Random decimal numbers parse like Swift")
    func randomNumbers() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let value = Double(bitPattern: UInt64.random(in: 0...UInt64.max, using: &generator))
            let small = Double(Int.random(in: -99_999_999...99_999_999, using: &generator)) / Double([1, 10, 100, 1_000, 1e6, 1e9].randomElement(using: &generator) ?? 1)
            let texts = [
                value.description, Float(value).description, String(format: "%.9g", value), String(Int64.random(in: .min ... .max, using: &generator)),
                small.description, Float(small).description, String(format: "%.\(Int.random(in: 0...12, using: &generator))f", small)
            ]
            for text in texts {
                let bytes = Array(text.utf8)
                bytes.withUnsafeBytes { raw in
                    #expect(PLYASCIIRecordReader.parseFloat(raw, 0..<raw.count).map(\.bitPattern) == Float(text).map(\.bitPattern), "\(text)")
                    #expect(PLYASCIIRecordReader.parseDouble(raw, 0..<raw.count).map(\.bitPattern) == Double(text).map(\.bitPattern), "\(text)")
                }
            }
        }
    }
}

@Suite("PLYLineFeeds")
internal struct PLYLineFeedsTests {
    @Test("Counts and line ends match a byte-by-byte scan")
    func matchesNaive() {
        var generator = SystemRandomNumberGenerator()
        // Some buffers are over 64 KB, the block size for skipping lines.
        for _ in 0..<40 {
            let size = Int.random(in: 0...150_000, using: &generator)
            let density = Int.random(in: 1...200, using: &generator)
            let bytes = (0..<size).map { _ in Int.random(in: 0..<density, using: &generator) == 0 ? UInt8(0x0A) : UInt8(0x41) }
            bytes.withUnsafeBytes { raw in
                let lower = Int.random(in: 0...size, using: &generator)
                let upper = Int.random(in: lower...size, using: &generator)
                #expect(PLYLineFeeds.count(in: raw, lower..<upper) == bytes[lower..<upper].count { $0 == 0x0A })

                let lineCount = Int.random(in: 0...(size / density + 5), using: &generator)
                var offset = lower
                var remaining = lineCount
                while remaining > 0, offset < size {
                    offset = (bytes[offset...].firstIndex(of: 0x0A) ?? size) + 1
                    remaining -= 1
                }
                #expect(PLYLineFeeds.end(ofLines: lineCount, in: raw, from: lower) == offset)
            }
        }
    }
}

@Suite("PLYParallel")
internal struct PLYParallelTests {
    @Test("A part that fails makes the whole range run again on this thread")
    func rerun() throws {
        // The first run of the part with index 0 fails. The rerun on the whole range succeeds.
        let failedOnce = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        defer { failedOnce.deallocate() }
        failedOnce.initialize(to: false)
        var ranges: [Range<Int>] = []
        try PLYParallel.forEachChunk(count: 100, minimumChunkSize: 10) { range in
            if range.contains(0), !failedOnce.pointee {
                failedOnce.pointee = true
                throw PLYError.invalidData
            }
            if range == 0..<100 {
                ranges.append(range)
            }
        }
        #expect(ranges == [0..<100])
    }

    @Test("Parts cover every index once", arguments: [0, 1, 2, 7, 33, 62, 64, 1_000, 99_999])
    func parts(count: Int) throws {
        for minimumChunkSize in [1, 2, 4, 5, 100] {
            let seen = UnsafeMutableBufferPointer<Int>.allocate(capacity: max(count, 1))
            defer { seen.deallocate() }
            seen.initialize(repeating: 0)
            try PLYParallel.forEachChunk(count: count, minimumChunkSize: minimumChunkSize) { range in
                for index in range {
                    seen[index] += 1
                }
            }
            #expect(seen.prefix(count).allSatisfy { $0 == 1 }, "count \(count) minimum \(minimumChunkSize)")
        }
    }
}
