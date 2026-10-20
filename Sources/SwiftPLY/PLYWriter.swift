import Foundation

/// Writes a PLY file one record at a time.
///
/// Write the records of each element in header order, then call `finish()`.
public struct PLYWriter {
    public let header: PLYHeader
    private var data: Data
    private var elementIndex = 0
    private var recordIndex = 0
    // The bytes of the record being written, reused so that each record is one append to `data`.
    private var scratch: [UInt8] = []
    // The property kinds of the element at `kindsElementIndex`.
    private var kinds: [PLYReader.Property.Kind] = []
    private var kindsElementIndex = -1
    // Checked ASCII records whose text is not in `data` yet, all of the element at `pendingElementIndex`.
    private var pendingRecords: [[PLYReader.PropertyValue]] = []
    private var pendingKinds: [PLYReader.Property.Kind] = []
    private var pendingElementIndex = -1

    public init(header: PLYHeader) {
        self.header = header
        data = Data(header.serialized.utf8)
        skipEmptyElements()
    }

    /// Writes the next record. `values` must be in the order of the element's properties and match their types.
    public mutating func write(_ values: [PLYReader.PropertyValue]) throws {
        guard elementIndex < header.elements.count else {
            throw PLYError.recordCountMismatch
        }
        if kindsElementIndex != elementIndex {
            kinds = header.elements[elementIndex].properties.map(\.kind)
            kindsElementIndex = elementIndex
        }
        guard values.count == kinds.count else {
            throw PLYError.invalidValue(header.elements[elementIndex].name)
        }
        if header.format != .ascii {
            try writeBinary(values)
            advance(by: 1)
            return
        }
        // Check the whole record first, in property order, so that an error writes nothing. The kinds hold no
        // Strings, so this loop does not retain the property names.
        for index in kinds.indices {
            switch (kinds[index], values[index]) {
            case let (.scalar(type), value) where value.scalarType == type:
                continue

            case let (.list(countType, itemType), .list(items)) where items.allSatisfy { $0.scalarType == itemType }:
                guard Self.encodedCount(items.count, type: countType) != nil else {
                    throw PLYError.invalidValue(header.elements[elementIndex].properties[index].name)
                }

            default:
                throw PLYError.invalidValue(header.elements[elementIndex].properties[index].name)
            }
        }

        // ASCII records wait in a batch, so that their text can be made on all cores. The records are checked, so
        // making the text cannot fail. `finish()` adds the text of a batch that is not full.
        if pendingElementIndex != elementIndex {
            flushPendingASCII()
            pendingElementIndex = elementIndex
            pendingKinds = kinds
        }
        pendingRecords.append(values)
        if pendingRecords.count >= Self.asciiBatchSize {
            flushPendingASCII()
        }
        advance(by: 1)
    }

    private static let asciiBatchSize = 1 << 16

    private mutating func flushPendingASCII() {
        guard !pendingRecords.isEmpty else {
            return
        }
        data.append(contentsOf: Self.asciiText(of: pendingRecords, kinds: pendingKinds))
        pendingRecords.removeAll(keepingCapacity: true)
    }

    // The lines of checked records, made in parts on all cores and joined in order.
    private static func asciiText(of records: [[PLYReader.PropertyValue]], kinds: [PLYReader.Property.Kind]) -> [UInt8] {
        let partCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, records.count / 1_024))
        var texts = [[UInt8]](repeating: [], count: partCount)
        texts.withUnsafeMutableBufferPointer { texts in
            try? PLYParallel.forEachChunk(count: partCount, minimumChunkSize: 1) { parts in
                for part in parts {
                    for record in records[(part * records.count / partCount)..<((part + 1) * records.count / partCount)] {
                        appendASCIILine(record, kinds: kinds, to: &texts[part])
                    }
                }
            }
        }
        // Appending each part copies whole buffers. `joined()` would copy byte by byte.
        var result: [UInt8] = []
        result.reserveCapacity(texts.reduce(0) { $0 + $1.count })
        for text in texts {
            result.append(contentsOf: text)
        }
        return result
    }

    // Values are separated by one space. An empty list adds its count and no items.
    private static func appendASCIILine(_ values: [PLYReader.PropertyValue], kinds: [PLYReader.Property.Kind], to text: inout [UInt8]) {
        let start = text.count
        for (kind, value) in zip(kinds, values) {
            if case let .list(countType, _) = kind, case let .list(items) = value {
                PLYRecordWriter.appendASCII(encodedCount(items.count, type: countType).unsafelyUnwrapped, to: &text)
                text.append(0x20)
                PLYRecordWriter.appendASCII(value, to: &text)
            } else {
                PLYRecordWriter.appendASCII(value, to: &text)
                text.append(0x20)
            }
        }
        if text.count == start {
            text.append(0x0A)
        } else {
            text[text.count - 1] = 0x0A
        }
    }

    // Checks and writes a binary record in one pass through a pointer, then appends it to `data` once. An error
    // appends nothing. Each value takes at most 8 bytes, so the scratch buffer first gets room for the largest
    // possible record.
    private mutating func writeBinary(_ values: [PLYReader.PropertyValue]) throws {
        var largest = 0
        for value in values {
            if case .list(let items) = value {
                largest += 8 + 8 * items.count
            } else {
                largest += 8
            }
        }
        if scratch.count < largest {
            scratch = Array(repeating: 0, count: max(largest, scratch.count * 2))
        }
        let littleEndian = isLittleEndian
        let propertyKinds = kinds
        let failedIndex: Int? = scratch.withUnsafeMutableBytes { buffer in
            let base = buffer.baseAddress.unsafelyUnwrapped
            var offset = 0
            for index in propertyKinds.indices {
                switch (propertyKinds[index], values[index]) {
                case let (.scalar(type), value) where value.scalarType == type:
                    offset += PLYRecordWriter.storeBinary(value, littleEndian: littleEndian, at: base + offset)

                case let (.list(countType, itemType), .list(items)):
                    guard let count = Self.encodedCount(items.count, type: countType), items.allSatisfy({ $0.scalarType == itemType }) else {
                        return index
                    }
                    offset += PLYRecordWriter.storeBinary(count, littleEndian: littleEndian, at: base + offset)
                    offset += PLYRecordWriter.storeBinary(.list(items), littleEndian: littleEndian, at: base + offset)

                default:
                    return index
                }
            }
            data.append(contentsOf: UnsafeRawBufferPointer(rebasing: buffer[..<offset]))
            return nil
        }
        if let failedIndex {
            throw PLYError.invalidValue(header.elements[elementIndex].properties[failedIndex].name)
        }
    }

    // The count of a list as a value of its count type, or nil if it does not fit.
    static func encodedCount(_ count: Int, type: PLYReader.PropertyType) -> PLYReader.PropertyValue? {
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

    /// Returns the file. Throws if any element has fewer records than its header count.
    public func finish() throws -> Data {
        guard elementIndex == header.elements.count else {
            throw PLYError.recordCountMismatch
        }
        guard !pendingRecords.isEmpty else {
            return data
        }
        var result = data
        result.append(contentsOf: Self.asciiText(of: pendingRecords, kinds: pendingKinds))
        return result
    }

    /// The element that the next record belongs to. Throws if every record is written.
    public func currentElement() throws -> PLYReader.Element {
        guard elementIndex < header.elements.count else {
            throw PLYError.recordCountMismatch
        }
        return header.elements[elementIndex]
    }

    // Records left in the current element. Call `currentElement()` first, which throws when every record is written.
    var remainingRecordsInCurrentElement: Int {
        header.elements[elementIndex].count - recordIndex
    }

    var isLittleEndian: Bool {
        header.format == .binaryLittleEndian
    }

    // Adds `byteCount` bytes that `fill` writes, for `recordCount` records of the current element.
    mutating func appendRecords(_ recordCount: Int, byteCount: Int, fill: (UnsafeMutableRawBufferPointer) -> Void) {
        flushPendingASCII()
        let start = data.count
        data.count += byteCount
        data.withUnsafeMutableBytes { bytes in
            fill(UnsafeMutableRawBufferPointer(rebasing: bytes[start..<(start + byteCount)]))
        }
        advance(by: recordCount)
    }

    private mutating func advance(by recordCount: Int) {
        recordIndex += recordCount
        if recordIndex == header.elements[elementIndex].count {
            elementIndex += 1
            recordIndex = 0
            skipEmptyElements()
        }
    }

    private mutating func skipEmptyElements() {
        while elementIndex < header.elements.count, header.elements[elementIndex].count < 1 {
            elementIndex += 1
        }
    }
}

extension PLYWriter: Sendable {}

extension PLYReader.PropertyValue {
    var scalarType: PLYReader.PropertyType? {
        switch self {
        case .char:
            .char
        case .uchar:
            .uchar
        case .short:
            .short
        case .ushort:
            .ushort
        case .int:
            .int
        case .uint:
            .uint
        case .float:
            .float
        case .double:
            .double
        case .list:
            nil
        }
    }
}
