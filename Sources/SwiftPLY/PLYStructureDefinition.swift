import Foundation

/// The memory layout of one record: a stride, and the offset and type of each PLY property in the record.
public struct PLYStructureDefinition {
    public struct Field {
        /// A list property with `length` items in every record, for example 3 for triangle faces.
        public struct List {
            public var countType: PLYReader.PropertyType
            public var length: Int

            public init(countType: PLYReader.PropertyType, length: Int) {
                self.countType = countType
                self.length = length
            }
        }

        public var propertyName: String
        /// The type of the value, or of each list item.
        public var type: PLYReader.PropertyType
        public var offset: Int
        /// Nil for a scalar property. The items of a list are next to each other in memory.
        public var list: List?

        public init(propertyName: String, type: PLYReader.PropertyType, offset: Int, list: List? = nil) {
            self.propertyName = propertyName
            self.type = type
            self.offset = offset
            self.list = list
        }

        var kind: PLYReader.Property.Kind {
            if let list {
                return .list(count: list.countType, item: type)
            }
            return .scalar(type)
        }

        var size: Int {
            type.size * (list?.length ?? 1)
        }
    }

    public var stride: Int
    public var fields: [Field]

    public init(stride: Int, fields: [Field] = []) {
        self.stride = stride
        self.fields = fields
    }

    /// Adds one field for each lane of a vector of `count` values of `type` at `offset`.
    ///
    /// If `propertyNames` is empty, the names come from `defaultPropertyNames(field:count:)`.
    public mutating func append(_ name: String, type: PLYReader.PropertyType, offset: Int, count: Int = 1, propertyNames: [String] = []) throws {
        let names = propertyNames.isEmpty ? Self.defaultPropertyNames(field: name, count: count) : propertyNames
        guard names.count == count else {
            throw PLYError.invalidValue(name)
        }
        for (lane, propertyName) in names.enumerated() {
            fields.append(Field(propertyName: propertyName, type: type, offset: offset + lane * type.size))
        }
    }

    /// PLY property names for a field with `count` lanes: the field name for one lane, otherwise `f_0 f_1 f_2 …`.
    ///
    /// The names do not depend on what a field means. Pass property names to use others, for example `x y z`.
    public static func defaultPropertyNames(field: String, count: Int) -> [String] {
        count == 1 ? [field] : (0..<count).map { "\(field)_\($0)" }
    }

    // Throws if the stride is not positive, there are no fields, a field is outside the stride, or a name repeats.
    func validate() throws {
        guard stride > 0, !fields.isEmpty else {
            throw PLYError.invalidValue("stride")
        }
        var names = Set<String>()
        for field in fields {
            let validList = field.list.map { $0.countType.isInteger && $0.length > 0 } ?? true
            guard validList, field.offset >= 0, field.offset + field.size <= stride, names.insert(field.propertyName).inserted else {
                throw PLYError.invalidValue(field.propertyName)
            }
        }
    }
}

extension PLYStructureDefinition: Sendable, Equatable {}
extension PLYStructureDefinition.Field: Sendable, Equatable {}
extension PLYStructureDefinition.Field.List: Sendable, Equatable {}

public extension PLYReader.Element {
    /// Makes an element with one scalar property for each field of `definition`.
    init(name: String, count: Int, definition: PLYStructureDefinition) {
        self.init(name: name, count: count, properties: definition.fields.map { field in
            PLYReader.Property(name: field.propertyName, kind: field.kind)
        })
    }
}

public extension PLYReader {
    /// Reads the records of `element` into `buffer`, one record every `definition.stride` bytes. Returns the number of records read.
    ///
    /// `buffer` must hold `maximumRecordCount(of:)` records.
    ///
    /// Each field reads the scalar property with the same name. Values convert to the field type without scaling.
    /// Properties that no field names are skipped. Bytes that no field covers are not changed. Memory after the
    /// returned records can change.
    func read(element: Element, into buffer: UnsafeMutableRawBufferPointer, definition: PLYStructureDefinition) throws -> Int {
        try definition.validate()
        let propertyIndices = try definition.fields.map { field in
            guard let index = element.properties.firstIndex(where: { $0.name == field.propertyName && $0.isList == (field.list != nil) }) else {
                throw PLYError.invalidValue(field.propertyName)
            }
            return index
        }
        guard maximumRecordCount(of: element) <= buffer.count / definition.stride else {
            throw PLYError.recordCountMismatch
        }
        guard let base = buffer.baseAddress else {
            return 0
        }
        if format != .ascii {
            // Data that is not valid uses the value path, so the error is the one for the first record that fails.
            guard let range = try? binaryRange(of: element) else {
                return try readWithValues(element: element, into: base, definition: definition, propertyIndices: propertyIndices)
            }
            let reader = PLYBinaryRecordReader(element: element, definition: definition, littleEndian: format == .binaryLittleEndian)
            try data.withUnsafeBytes { bytes in
                let checkpoints = binaryCheckpoints(of: element).map { $0 - range.lowerBound }
                try reader.read(count: element.count, from: bytes.baseAddress.unsafelyUnwrapped + range.lowerBound, into: base, checkpoints: checkpoints)
            }
            return element.count
        }
        let start = try startOffset(of: element)
        let reader = PLYASCIIRecordReader(element: element, definition: definition)
        return try data.withUnsafeBytes { bytes in
            try reader.read(count: element.count, from: bytes, start: start, range: asciiRange(of: element), into: base)
        }
    }

    // The path that every format used before the record readers. Tests compare the record readers with it.
    internal func readWithValues(element: Element, into base: UnsafeMutableRawPointer, definition: PLYStructureDefinition, propertyIndices: [Int]) throws -> Int {
        var recordIndex = 0
        try readValues(element: element) { values in
            let record = base + recordIndex * definition.stride
            for (field, index) in zip(definition.fields, propertyIndices) {
                guard let value = values[index] else {
                    throw PLYError.invalidValue(field.propertyName)
                }
                try field.store(value, in: record)
            }
            recordIndex += 1
        }
        return recordIndex
    }
}

public extension PLYWriter {
    /// Writes one record for every `definition.stride` bytes of `records`.
    ///
    /// Each property of the current element must have a field with the same name and type. Records can continue
    /// into the next element.
    mutating func write(_ records: UnsafeRawBufferPointer, definition: PLYStructureDefinition) throws {
        try definition.validate()
        guard records.count.isMultiple(of: definition.stride) else {
            throw PLYError.invalidValue("stride")
        }
        guard let base = records.baseAddress else {
            return
        }
        let recordCount = records.count / definition.stride
        var written = 0
        while written < recordCount, header.format == .ascii {
            let element = try currentElement()
            let writer = try PLYRecordWriter(element: element, definition: definition)
            let count = min(recordCount - written, remainingRecordsInCurrentElement)
            let source = base + written * definition.stride
            // About 64k records for each part. Each part has its own text, and the texts join in order.
            let partCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount * 4, count >> 16))
            var texts = [[UInt8]](repeating: [], count: partCount)
            texts.withUnsafeMutableBufferPointer { texts in
                try? PLYParallel.forEachChunk(count: partCount, minimumChunkSize: 1) { parts in
                    for part in parts {
                        let partRecords = (part * count / partCount)..<((part + 1) * count / partCount)
                        texts[part].reserveCapacity(partRecords.count * 64)
                        writer.writeASCII(records: partRecords, from: source, into: &texts[part])
                    }
                }
            }
            let byteCount = texts.reduce(0) { $0 + $1.count }
            appendRecords(count, byteCount: byteCount) { output in
                var offset = 0
                for text in texts where !text.isEmpty {
                    text.withUnsafeBytes { output.baseAddress.unsafelyUnwrapped.advanced(by: offset).copyMemory(from: $0.baseAddress.unsafelyUnwrapped, byteCount: $0.count) }
                    offset += text.count
                }
            }
            written += count
        }
        while written < recordCount {
            let element = try currentElement()
            let plan = try PLYRecordWriter(element: element, definition: definition).binaryPlan(littleEndian: isLittleEndian)
            let count = min(recordCount - written, remainingRecordsInCurrentElement)
            let source = base + written * definition.stride
            appendRecords(count, byteCount: count * plan.recordSize) { output in
                let destination = output.baseAddress.unsafelyUnwrapped
                // About 1 MB of output for each part. The parts write disjoint bytes.
                try? PLYParallel.forEachChunk(count: count, minimumChunkSize: max(1, (1 << 20) / max(plan.recordSize, 1))) { part in
                    plan.write(records: part, from: source, into: destination)
                }
            }
            written += count
        }
    }
}

extension PLYStructureDefinition.Field {
    // Integer fields need an integer value in range. A list field needs a list of exactly `list.length` items.
    func store(_ value: PLYReader.PropertyValue, in record: UnsafeMutableRawPointer) throws {
        guard let list else {
            try storeScalar(value, at: offset, in: record)
            return
        }
        guard case .list(let items) = value, items.count == list.length else {
            throw PLYError.invalidValue(propertyName)
        }
        for (index, item) in items.enumerated() {
            try storeScalar(item, at: offset + index * type.size, in: record)
        }
    }

    func load(from record: UnsafeRawPointer) -> PLYReader.PropertyValue {
        guard let list else {
            return loadScalar(at: offset, from: record)
        }
        return .list((0..<list.length).map { loadScalar(at: offset + $0 * type.size, from: record) })
    }

    private func storeScalar(_ value: PLYReader.PropertyValue, at offset: Int, in record: UnsafeMutableRawPointer) throws {
        guard let number = value.doubleValue else {
            throw PLYError.invalidValue(propertyName)
        }
        try storeNumber(number, as: type, to: record + offset, propertyName: propertyName)
    }

    private func loadScalar(at offset: Int, from record: UnsafeRawPointer) -> PLYReader.PropertyValue {
        switch type {
        case .char:
            .char(record.loadUnaligned(fromByteOffset: offset, as: Int8.self))
        case .uchar:
            .uchar(record.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
        case .short:
            .short(record.loadUnaligned(fromByteOffset: offset, as: Int16.self))
        case .ushort:
            .ushort(record.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        case .int:
            .int(record.loadUnaligned(fromByteOffset: offset, as: Int32.self))
        case .uint:
            .uint(record.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        case .float:
            .float(record.loadUnaligned(fromByteOffset: offset, as: Float.self))
        case .double:
            .double(record.loadUnaligned(fromByteOffset: offset, as: Double.self))
        }
    }
}

extension PLYReader.PropertyValue {
    // Every PLY scalar type fits in a Double without loss.
    var doubleValue: Double? {
        switch self {
        case .char(let value):
            Double(value)
        case .uchar(let value):
            Double(value)
        case .short(let value):
            Double(value)
        case .ushort(let value):
            Double(value)
        case .int(let value):
            Double(value)
        case .uint(let value):
            Double(value)
        case .float(let value):
            Double(value)
        case .double(let value):
            value
        case .list:
            nil
        }
    }
}

extension PLYReader.Property {
    var isList: Bool {
        if case .list = kind {
            return true
        }
        return false
    }
}
