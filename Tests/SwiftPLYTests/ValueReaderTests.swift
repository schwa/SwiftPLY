import Foundation
@testable import SwiftPLY
import Testing

private let fixturesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

private func fixtureData() throws -> [Data] {
    try FileManager.default.subpathsOfDirectory(atPath: fixturesURL.path)
        .filter { $0.hasSuffix(".ply") }
        .map { try Data(contentsOf: fixturesURL.appendingPathComponent($0)) }
}

// Records as `read(element:callback:)` made them before it reused dictionaries.
private func referenceRecords(_ reader: PLYReader, _ element: PLYReader.Element) throws -> [PLYReader.Record] {
    var records: [PLYReader.Record] = []
    try reader.readValues(element: element) { values in
        var record = PLYReader.Record()
        for (index, value) in values.enumerated() {
            if let value {
                record[element.properties[index].name] = value
            }
        }
        records.append(record)
    }
    return records
}

// NaN values are never equal, so records compare by their sorted text.
private func text(_ records: [PLYReader.Record]) -> [String] {
    records.map { record in record.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }
}

// The result or the error, for files that are not valid.
private func outcome(_ body: () throws -> [PLYReader.Record]) -> [String] {
    do {
        return try text(body())
    } catch {
        return ["error \(error)"]
    }
}

// The rows, as text so that NaN compares equal, then the error if there is one.
private func rows(_ read: (([PLYReader.PropertyValue?]) throws -> Void) throws -> Void) -> [String] {
    var result: [String] = []
    do {
        try read { result.append("\($0)") }
    } catch {
        result.append("error \(error)")
    }
    return result
}

private func compareASCII(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let reader = try? PLYReader(data: data), reader.format == .ascii else {
        return
    }
    for element in reader.elements {
        let new = rows { try reader.readValues(element: element, callback: $0) }
        let old = rows { try reader.referenceASCIIRows(element: element, callback: $0) }
        #expect(new == old, "\(element.name)", sourceLocation: sourceLocation)
    }
}

@Suite("Callback reading")
internal struct ValueReaderTests {
    @Test("ASCII rows match the String-based reader on fixtures and mutations")
    func asciiRows() throws {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("0123456789 -+.eE\n\r\tx\u{00}".utf8) + [0xC3, 0xA9, 0xFF, 0xC2, 0xA0]
        for data in try fixtureData() {
            compareASCII(data)
            guard let reader = try? PLYReader(data: data), reader.format == .ascii, data.count > reader.bodyOffset else {
                continue
            }
            for _ in 0..<60 {
                var mutated = data
                for _ in 0..<Int.random(in: 1...4, using: &generator) {
                    mutated[Int.random(in: reader.bodyOffset..<mutated.count, using: &generator)] = alphabet[Int.random(in: alphabet.indices, using: &generator)]
                }
                compareASCII(mutated)
            }
        }
    }

    @Test("Large ASCII rows match the String-based reader")
    func largeASCIIRows() {
        let count = 50_000
        var file = "ply\nformat ascii 1.0\nelement v \(count)\nproperty float x\nproperty uchar red\nproperty double d\nproperty list uchar int i\nend_header\n"
        file += (0..<count).map { "\(Float($0) * 0.1) \($0 % 300) \(Double($0) / 7) 3 \($0) -\($0) x" }.joined(separator: "\n")
        compareASCII(Data(file.utf8))
    }

    @Test("Records match the values, for fixtures and a file with missing values and repeated names")
    func records() throws {
        let missing = Data("""
        ply
        format ascii 1.0
        element v 4
        property float x
        property uchar x
        property float y
        end_header
        1 2 3
        4 x 6
        7 8 9
        x 1 y

        """.utf8)
        for data in try fixtureData() + [missing] {
            let reader = try PLYReader(data: data)
            for element in reader.elements {
                let records = outcome {
                    var records: [PLYReader.Record] = []
                    try reader.read(element: element) { records.append($0) }
                    return records
                }
                #expect(records == outcome { try referenceRecords(reader, element) })
            }
        }
    }

    @Test("A callback that keeps and changes records does not change later records")
    func keptRecords() throws {
        let data = Data("ply\nformat ascii 1.0\nelement v 3\nproperty int a\nproperty int b\nend_header\n1 2\n3 4\n5 6\n".utf8)
        let reader = try PLYReader(data: data)
        var kept: [PLYReader.Record] = []
        try reader.read(element: reader.elements[0]) { record in
            var changed = record
            changed["a"] = .int(0)
            kept.append(record)
            kept.append(changed)
        }
        #expect(kept.map { $0["a"] } == [.int(1), .int(0), .int(3), .int(0), .int(5), .int(0)])
        #expect(kept.map { $0["b"] } == [.int(2), .int(2), .int(4), .int(4), .int(6), .int(6)])
    }
}
