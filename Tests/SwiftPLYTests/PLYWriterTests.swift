import Foundation
@testable import SwiftPLY
import Testing

private typealias Value = PLYReader.PropertyValue

private let allTypes: [PLYReader.PropertyType] = [.char, .uchar, .short, .ushort, .int, .uint, .float, .double]

private func sampleHeader(_ format: PLYReader.Format) -> PLYHeader {
    PLYHeader(format: format, elements: [
        PLYReader.Element(name: "vertex", count: 2, properties: allTypes.map { PLYReader.Property(name: $0.name, kind: .scalar($0)) }),
        PLYReader.Element(name: "none", count: 0, properties: [PLYReader.Property(name: "x", kind: .scalar(.float))]),
        PLYReader.Element(name: "face", count: 3, properties: [
            PLYReader.Property(name: "i", kind: .list(count: .uchar, item: .int)),
            PLYReader.Property(name: "w", kind: .list(count: .ushort, item: .double))
        ])
    ])
}

private let sampleRecords: [[[Value]]] = [
    [
        [.char(-128), .uchar(255), .short(-32_768), .ushort(65_535), .int(.min), .uint(.max), .float(1.5e-7), .double(-0.1)],
        [.char(1), .uchar(0), .short(2), .ushort(3), .int(-4), .uint(5), .float(.infinity), .double(1e300)]
    ],
    [],
    [
        [.list([.int(0), .int(1), .int(2)]), .list([.double(0.5)])],
        [.list([]), .list([])],
        [.list([.int(-7)]), .list([.double(2), .double(3)])]
    ]
]

@Suite("PLY writer")
internal struct PLYWriterTests {
    @Test("Write then read back", arguments: [PLYReader.Format.ascii, .binaryLittleEndian, .binaryBigEndian])
    func roundTrip(format: PLYReader.Format) throws {
        let header = sampleHeader(format)
        var writer = PLYWriter(header: header)
        for records in sampleRecords {
            for record in records {
                try writer.write(record)
            }
        }
        let data = try writer.finish()

        let reader = try PLYReader(data: data)
        #expect(reader.header == header)
        for (element, expected) in zip(reader.elements, sampleRecords) {
            var actual: [[Value?]] = []
            try reader.readValues(element: element) { actual.append($0) }
            #expect(actual == expected.map { $0.map(Optional.some) })
        }
    }

    @Test("ASCII output is readable text")
    func asciiText() throws {
        let header = PLYHeader(format: .ascii, elements: [
            PLYReader.Element(name: "v", count: 1, properties: [
                PLYReader.Property(name: "x", kind: .scalar(.float)),
                PLYReader.Property(name: "i", kind: .list(count: .uchar, item: .int))
            ])
        ])
        var writer = PLYWriter(header: header)
        try writer.write([.float(1.5), .list([.int(1), .int(2)])])
        let text = try #require(String(bytes: writer.finish(), encoding: .utf8))
        #expect(text.hasSuffix("end_header\n1.5 2 1 2\n"))
    }

    @Test("Value that does not match the header throws", arguments: [
        [Value.int(1)],
        [Value.float(1), .list([.int(1)]), .int(0)],
        [Value.float(1), .list([.float(1)])],
        [Value.float(1), .int(1)],
        [Value.list([]), .list([])]
    ])
    func mismatch(values: [PLYReader.PropertyValue]) {
        let header = PLYHeader(format: .ascii, elements: [
            PLYReader.Element(name: "v", count: 1, properties: [
                PLYReader.Property(name: "x", kind: .scalar(.float)),
                PLYReader.Property(name: "i", kind: .list(count: .uchar, item: .int))
            ])
        ])
        var writer = PLYWriter(header: header)
        #expect(throws: PLYError.self) { try writer.write(values) }
        if values.count != 2 {
            #expect(throws: PLYError.invalidValue("v")) { try writer.write(values) }
        }
    }

    @Test("List count that does not fit its count type throws", arguments: allTypes)
    func countOverflow(countType: PLYReader.PropertyType) throws {
        let header = PLYHeader(format: .binaryLittleEndian, elements: [
            PLYReader.Element(name: "f", count: 1, properties: [PLYReader.Property(name: "i", kind: .list(count: countType, item: .uchar))])
        ])
        var writer = PLYWriter(header: header)
        switch countType {
        case .char, .uchar:
            #expect(throws: PLYError.invalidValue("i")) {
                try writer.write([.list(Array(repeating: .uchar(0), count: 256))])
            }
            try writer.write([.list([.uchar(9)])])
            #expect(try writer.finish().suffix(2) == Data([1, 9]))

        case .short, .ushort, .int, .uint:
            try writer.write([.list([.uchar(9)])])
            #expect(try writer.finish().suffix(1 + countType.size) == Data([1] + Array(repeating: 0, count: countType.size - 1) + [9]))

        case .float, .double:
            #expect(throws: PLYError.invalidValue("i")) { try writer.write([.list([.uchar(9)])]) }
        }
    }

    @Test("Wrong number of records throws")
    func recordCount() throws {
        let header = PLYHeader(format: .ascii, elements: [
            PLYReader.Element(name: "v", count: 1, properties: [PLYReader.Property(name: "x", kind: .scalar(.uchar))])
        ])
        var writer = PLYWriter(header: header)
        #expect(throws: PLYError.recordCountMismatch) { try writer.finish() }
        try writer.write([.uchar(1)])
        #expect(throws: PLYError.recordCountMismatch) { try writer.write([.uchar(2)]) }
        #expect(writer.header == header)
    }
}
