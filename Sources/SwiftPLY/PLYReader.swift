import Foundation

/// Reads PLY files in ASCII and binary formats.
///
/// Parses the header, then sends element records to a callback.
public struct PLYReader {
    /// The encoding of a PLY file's body, as declared in its header.
    public enum Format {
        case ascii
        case binaryLittleEndian
        case binaryBigEndian
    }

    public enum PropertyType {
        case char, uchar
        case short, ushort
        case int, uint
        case float, double
    }

    public struct Property {
        public enum Kind {
            case scalar(PropertyType)
            case list(count: PropertyType, item: PropertyType)
        }

        public var name: String
        public var kind: Kind

        public init(name: String, kind: Kind) {
            self.name = name
            self.kind = kind
        }
    }

    public struct Element {
        public var name: String
        public var count: Int
        public var properties: [Property]

        public init(name: String, count: Int, properties: [Property]) {
            self.name = name
            self.count = count
            self.properties = properties
        }
    }

    public enum PropertyValue {
        case char(Int8)
        case uchar(UInt8)
        case short(Int16)
        case ushort(UInt16)
        case int(Int32)
        case uint(UInt32)
        case float(Float)
        case double(Double)
        case list([Self])
    }

    public typealias Record = [String: PropertyValue]

    public let data: Data
    public let header: PLYHeader
    public let bodyOffset: Int

    public var format: Format {
        header.format
    }

    public var elements: [Element] {
        header.elements
    }

    public var primaryElement: Element? {
        elements.first
    }

    public var recordCount: Int {
        primaryElement?.count ?? 0
    }

    // Start offset of each element, plus the end of the last one. Nil from the first element whose data is not valid.
    private var elementOffsets: [Int?] = []
    private var recordCheckpoints: [[Int]] = []

    public init(data: Data) throws {
        self.data = data
        (header, bodyOffset) = try PLYHeader.parse(data)
        elementOffsets = locateElements()
    }

    public func read(_ callback: (Record) throws -> Void) throws {
        guard let element = primaryElement else {
            throw PLYError.noElements
        }
        try read(element: element, callback: callback)
    }

    public func read(element: Element, callback: (Record) throws -> Void) throws {
        let properties = element.properties
        // Records with every value reuse one dictionary: the values change through saved indices, so the keys are
        // not hashed again. If the callback keeps a record, the next change copies it, as Dictionary always does.
        // A record with a missing value is made again from its values, because its keys differ.
        var reusable: Record?
        var slots: [Record.Index] = []
        try readValues(element: element) { values in
            if var record = reusable.take(), !values.contains(nil) {
                for (slot, value) in zip(slots, values) {
                    record.values[slot] = value.unsafelyUnwrapped
                }
                reusable = record
                try callback(record)
                return
            }
            var record = Record(minimumCapacity: properties.count)
            for (index, value) in values.enumerated() {
                if let value {
                    record[properties[index].name] = value
                }
            }
            if !values.contains(nil) {
                slots = properties.map { record.index(forKey: $0.name).unsafelyUnwrapped }
                reusable = record
            }
            try callback(record)
        }
    }

    /// Sends each record as property values, in the order of the header.
    ///
    /// The callback gets the same array each time. An entry is nil if an
    /// ASCII value cannot be parsed.
    public func readValues(element: Element, callback: ([PropertyValue?]) throws -> Void) throws {
        switch format {
        case .ascii:
            try readASCII(element: element, callback: callback)

        case .binaryLittleEndian:
            try readBinary(element: element, littleEndian: true, callback: callback)

        case .binaryBigEndian:
            try readBinary(element: element, littleEndian: false, callback: callback)
        }
    }

    private func readASCII(element: Element, callback: ([PropertyValue?]) throws -> Void) throws {
        let start = try startOffset(of: element)
        let kinds = element.properties.map(\.kind)
        try data.withUnsafeBytes { bytes in
            try PLYASCIIRecordReader.readValueRows(kinds: kinds, count: element.count, from: bytes, start: start, callback: callback)
        }
    }

    // An element that is not in the header starts after the last element.
    func startOffset(of element: Element) throws -> Int {
        let index = elements.firstIndex { $0.name == element.name } ?? elements.count
        guard let offset = elementOffsets[index] else {
            throw PLYError.invalidData
        }
        return offset
    }

    // The bytes of the lines of an ASCII element in the header, or nil for other elements.
    func asciiRange(of element: Element) -> Range<Int>? {
        guard let index = elements.firstIndex(of: element), let start = elementOffsets[index], let end = elementOffsets[index + 1] else {
            return nil
        }
        let upper = min(end, data.count)
        return start <= upper ? start..<upper : nil
    }

    // The bytes of a binary element. Throws if the data is too short or a list count is not valid, so callers can read
    // inside the range without more checks.
    func binaryRange(of element: Element) throws -> Range<Int> {
        let start = try startOffset(of: element)
        // `endOfBinaryRecords` throws if the records do not fit in the data, so the end is never past it.
        let end: Int = if let index = elements.firstIndex(of: element), let headerEnd = elementOffsets[index + 1] {
            headerEnd
        } else {
            try endOfBinaryRecords(of: element, from: start, littleEndian: format == .binaryLittleEndian)
        }
        return start..<end
    }

    private mutating func locateElements() -> [Int?] {
        var offsets: [Int?] = [bodyOffset]
        var offset = bodyOffset
        for element in elements {
            var checkpoints: [Int] = []
            switch format {
            case .ascii:
                offset = endOfLines(count: element.count, from: offset)

            case .binaryLittleEndian, .binaryBigEndian:
                guard let end = try? endOfBinaryRecords(of: element, from: offset, littleEndian: format == .binaryLittleEndian, checkpoints: &checkpoints) else {
                    offsets += Array(repeating: nil, count: elements.count + 1 - offsets.count)
                    return offsets
                }
                offset = end
            }
            recordCheckpoints.append(checkpoints)
            offsets.append(offset)
        }
        return offsets
    }

    // Records between checkpoints of a binary element with lists.
    static let checkpointInterval = 1 << 12

    // For a binary element in the header with lists: the offset of every `checkpointInterval`th record, from record
    // 0. Parts of the element can then be read on several cores. Empty for other elements.
    func binaryCheckpoints(of element: Element) -> [Int] {
        guard let index = elements.firstIndex(of: element), index < recordCheckpoints.count else {
            return []
        }
        return recordCheckpoints[index]
    }

    /// The number of records of `element` that the data can hold, at most `element.count`.
    ///
    /// Use this instead of `element.count` to size a buffer, because the header count can be much larger than the
    /// data. An ASCII record needs one line. A binary record needs its scalars and list counts. It is 0 if an earlier
    /// element's data is not valid.
    public func maximumRecordCount(of element: Element) -> Int {
        guard let start = try? startOffset(of: element) else {
            return 0
        }
        let remaining = max(0, data.count - start)
        let minimumRecordSize = element.properties.reduce(0) { size, property in
            switch property.kind {
            case .scalar(let type):
                size + type.size
            case .list(let countType, _):
                size + countType.size
            }
        }
        let limit = switch format {
        case .ascii:
            remaining + 1
        case .binaryLittleEndian, .binaryBigEndian:
            minimumRecordSize == 0 ? element.count : remaining / minimumRecordSize
        }
        return min(element.count, limit)
    }

    private func endOfLines(count: Int, from start: Int) -> Int {
        // The data is never empty here, because it has a header.
        data.withUnsafeBytes { bytes in
            PLYLineFeeds.end(ofLines: count, in: bytes, from: start)
        }
    }

    // List data has variable length, so elements with lists are walked record by record.
    func endOfBinaryRecords(of element: Element, from start: Int, littleEndian: Bool) throws -> Int {
        var checkpoints: [Int] = []
        return try endOfBinaryRecords(of: element, from: start, littleEndian: littleEndian, checkpoints: &checkpoints)
    }

    // `checkpoints` gets the offsets for `binaryCheckpoints(of:)` when the element has lists.
    func endOfBinaryRecords(of element: Element, from start: Int, littleEndian: Bool, checkpoints: inout [Int]) throws -> Int {
        let kinds = element.properties.map(\.kind)
        if let recordSize = Property.Kind.fixedSize(of: kinds) {
            let (size, overflow) = element.count.multipliedReportingOverflow(by: recordSize)
            guard !overflow, size <= data.count - start else {
                throw PLYError.invalidData
            }
            return start + size
        }
        if let (end, uniformCheckpoints) = uniformListRecords(of: element, kinds: kinds, from: start, littleEndian: littleEndian) {
            checkpoints = uniformCheckpoints
            return end
        }
        var offset = start
        var foundCheckpoints: [Int] = []
        defer { checkpoints = foundCheckpoints }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for record in 0..<element.count {
                if record.isMultiple(of: Self.checkpointInterval) {
                    foundCheckpoints.append(offset)
                }
                for kind in kinds {
                    switch kind {
                    case .scalar(let type):
                        offset += type.size

                    case let .list(countType, itemType):
                        let count = try readListCount(from: bytes, at: &offset, countType: countType, itemType: itemType, littleEndian: littleEndian)
                        offset += count * itemType.size
                    }
                }
            }
        }
        // Scalars after the last list count are not checked in the loop.
        guard offset <= data.count else {
            throw PLYError.invalidData
        }
        return offset
    }

    private func readBinary(element: Element, littleEndian: Bool, callback: ([PropertyValue?]) throws -> Void) throws {
        func readList(bytes: UnsafeRawBufferPointer, start: Int, count: Int, itemType: PropertyType) throws -> PropertyValue? {
            .list(try (0..<count).map { index in
                try readScalar(PropertyValue.self, from: bytes, at: start + index * itemType.size, type: itemType, littleEndian: littleEndian)
            })
        }
        try readBinaryRows(element: element, littleEndian: littleEndian, list: readList, callback: callback)
    }

    /// Sends each record as `Float` values, in the order of the header.
    ///
    /// List properties and ASCII values that cannot be parsed are nil. This
    /// method is faster than `readValues` because it does not create a
    /// `PropertyValue` for each value.
    public func readFloatValues(element: Element, callback: ([Float?]) throws -> Void) throws {
        switch format {
        case .ascii:
            try readASCIIFloats(element: element, callback: callback)

        case .binaryLittleEndian:
            try readBinaryFloats(element: element, littleEndian: true, callback: callback)

        case .binaryBigEndian:
            try readBinaryFloats(element: element, littleEndian: false, callback: callback)
        }
    }

    private func readASCIIFloats(element: Element, callback: ([Float?]) throws -> Void) throws {
        try readASCII(element: element) { values in
            try callback(values.map { $0?.floatValue })
        }
    }

    private func readBinaryFloats(element: Element, littleEndian: Bool, callback: ([Float?]) throws -> Void) throws {
        try readBinaryRows(element: element, littleEndian: littleEndian, list: { _, _, _, _ in nil }, callback: callback)
    }

    // `list` gets the bytes, the offset of the first item, the item count, and the item type.
    private func readBinaryRows<T: PLYScalarDecodable>(
        element: Element,
        littleEndian: Bool,
        list: (UnsafeRawBufferPointer, Int, Int, PropertyType) throws -> T?,
        callback: ([T?]) throws -> Void
    ) throws {
        var offset = try startOffset(of: element)
        // Plain enums instead of `Property` structs prevent retain and release calls for each value in Debug builds.
        let kinds = element.properties.map(\.kind)
        // The row fills in place, with one uniqueness check for each record instead of one for each value. Each
        // read checks its bounds, so data that is not valid throws at the same record as reading value by value.
        var row = [T?](repeating: nil, count: kinds.count)

        if Property.Kind.fixedSize(of: kinds) != nil {
            // With no lists, every value is a plain number with nothing to release, so each new value is written
            // over the old one without destroying it first.
            try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for _ in 0..<element.count {
                    try row.withUnsafeMutableBufferPointer { values in
                        let base = values.baseAddress.unsafelyUnwrapped
                        // Every kind is a scalar here. Iterating the kinds measured faster than a separate array of types.
                        for (index, kind) in kinds.enumerated() {
                            if case .scalar(let type) = kind {
                                try (base + index).initialize(to: readScalar(T.self, from: bytes, at: offset, type: type, littleEndian: littleEndian))
                                offset += type.size
                            }
                        }
                    }
                    try callback(row)
                }
            }
            return
        }

        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for _ in 0..<element.count {
                try row.withUnsafeMutableBufferPointer { values in
                    for (index, kind) in kinds.enumerated() {
                        switch kind {
                        case .scalar(let type):
                            values[index] = try readScalar(T.self, from: bytes, at: offset, type: type, littleEndian: littleEndian)
                            offset += type.size

                        case let .list(countType, itemType):
                            let count = try readListCount(from: bytes, at: &offset, countType: countType, itemType: itemType, littleEndian: littleEndian)
                            values[index] = try list(bytes, offset, count, itemType)
                            offset += count * itemType.size
                        }
                    }
                }
                try callback(row)
            }
        }
    }

    // Moves `offset` past the count. Throws if the count is negative or the items do not fit in `bytes`.
    // Most meshes have lists of one length, for example only triangles. If every record has the same list counts as
    // the first record, the records have one size, and the end and checkpoints follow without a serial walk. Returns
    // nil if a record differs or the first record is not valid; the serial walk then gives the result or the error.
    private func uniformListRecords(of element: Element, kinds: [Property.Kind], from start: Int, littleEndian: Bool) -> (end: Int, checkpoints: [Int])? {
        guard element.count > 1 else {
            return nil
        }
        return data.withUnsafeBytes { bytes -> (Int, [Int])? in
            // Offset in the record, size, and raw bits of each list count of the first record.
            var counts: [(offset: Int, size: Int, bits: UInt32)] = []
            var offset = start
            for kind in kinds {
                switch kind {
                case .scalar(let type):
                    offset += type.size

                case let .list(countType, itemType):
                    let countOffset = offset
                    guard let count = try? readListCount(from: bytes, at: &offset, countType: countType, itemType: itemType, littleEndian: littleEndian) else {
                        return nil
                    }
                    counts.append((countOffset - start, countType.size, Self.rawBits(bytes, at: countOffset, size: countType.size)))
                    offset += count * itemType.size
                }
            }
            let recordSize = offset - start
            let (size, overflow) = element.count.multipliedReportingOverflow(by: recordSize)
            guard recordSize > 0, !overflow, size <= bytes.count - start else {
                return nil
            }
            // Each part writes only its own flag.
            let partCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, size >> 20))
            let mismatches = UnsafeMutableBufferPointer<Bool>.allocate(capacity: partCount)
            defer { mismatches.deallocate() }
            mismatches.initialize(repeating: false)
            try? PLYParallel.forEachChunk(count: partCount, minimumChunkSize: 1) { parts in
                for part in parts {
                    let records = (part * element.count / partCount)..<((part + 1) * element.count / partCount)
                    for record in records {
                        let recordStart = start + record * recordSize
                        for count in counts where Self.rawBits(bytes, at: recordStart + count.offset, size: count.size) != count.bits {
                            mismatches[part] = true
                            break
                        }
                    }
                }
            }
            guard !mismatches.contains(true) else {
                return nil
            }
            let checkpoints = Swift.stride(from: 0, to: element.count, by: Self.checkpointInterval).map { start + $0 * recordSize }
            return (start + size, checkpoints)
        }
    }

    @inline(__always)
    private static func rawBits(_ bytes: UnsafeRawBufferPointer, at offset: Int, size: Int) -> UInt32 {
        switch size {
        case 1:
            UInt32(bytes.load(fromByteOffset: offset, as: UInt8.self))
        case 2:
            UInt32(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        default:
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
    }

    private func readListCount(from bytes: UnsafeRawBufferPointer, at offset: inout Int, countType: PropertyType, itemType: PropertyType, littleEndian: Bool) throws -> Int {
        guard countType.isInteger else {
            throw PLYError.invalidData
        }
        let count = try readScalar(Int.self, from: bytes, at: offset, type: countType, littleEndian: littleEndian)
        offset += countType.size
        guard count >= 0, offset + count * itemType.size <= bytes.count else {
            throw PLYError.invalidData
        }
        return count
    }

    private func readScalar<T: PLYScalarDecodable>(_: T.Type, from bytes: UnsafeRawBufferPointer, at offset: Int, type: PropertyType, littleEndian: Bool) throws -> T {
        guard offset + type.size <= bytes.count else {
            throw PLYError.invalidData
        }

        func load<I: FixedWidthInteger>(_: I.Type) -> I {
            let value = bytes.loadUnaligned(fromByteOffset: offset, as: I.self)
            return littleEndian ? I(littleEndian: value) : I(bigEndian: value)
        }

        switch type {
        case .char:
            return T(load(Int8.self))

        case .uchar:
            return T(load(UInt8.self))

        case .short:
            return T(load(Int16.self))

        case .ushort:
            return T(load(UInt16.self))

        case .int:
            return T(load(Int32.self))

        case .uint:
            return T(load(UInt32.self))

        case .float:
            return T(Float(bitPattern: load(UInt32.self)))

        case .double:
            return T(Double(bitPattern: load(UInt64.self)))
        }
    }
}

// Output types for `readScalar`. Each initializer converts one PLY scalar type.
internal protocol PLYScalarDecodable {
    init(_ value: Int8)
    init(_ value: UInt8)
    init(_ value: Int16)
    init(_ value: UInt16)
    init(_ value: Int32)
    init(_ value: UInt32)
    init(_ value: Float)
    init(_ value: Double)
}

extension Float: PLYScalarDecodable {}

// Only integer list counts reach this conformance. `readListCount` rejects floating-point count types.
extension Int: PLYScalarDecodable {}

extension PLYReader.PropertyValue: PLYScalarDecodable {
    init(_ value: Int8) { self = .char(value) }
    init(_ value: UInt8) { self = .uchar(value) }
    init(_ value: Int16) { self = .short(value) }
    init(_ value: UInt16) { self = .ushort(value) }
    init(_ value: Int32) { self = .int(value) }
    init(_ value: UInt32) { self = .uint(value) }
    init(_ value: Float) { self = .float(value) }
    init(_ value: Double) { self = .double(value) }
}

extension PLYReader: Sendable {}
extension PLYReader.Format: Sendable, Equatable {}
extension PLYReader.PropertyType: Sendable, Equatable {}
extension PLYReader.Property: Sendable, Equatable {}
extension PLYReader.Property.Kind: Sendable, Equatable {}

extension PLYReader.Property.Kind {
    // Nil if any kind is a list, because list data has variable length.
    static func fixedSize(of kinds: [Self]) -> Int? {
        var size = 0
        for kind in kinds {
            guard case .scalar(let type) = kind else {
                return nil
            }
            size += type.size
        }
        return size
    }
}
extension PLYReader.Element: Sendable, Equatable {}
extension PLYReader.PropertyValue: Sendable, Equatable {}

public extension PLYReader.PropertyType {
    init?(string: String) {
        switch string {
        case "char", "int8":
            self = .char
        case "uchar", "uint8":
            self = .uchar
        case "short", "int16":
            self = .short
        case "ushort", "uint16":
            self = .ushort
        case "int", "int32":
            self = .int
        case "uint", "uint32":
            self = .uint
        case "float", "float32":
            self = .float
        case "double", "float64":
            self = .double
        default:
            return nil
        }
    }

    var size: Int {
        switch self {
        case .char, .uchar:
            return 1
        case .short, .ushort:
            return 2
        case .int, .uint, .float:
            return 4
        case .double:
            return 8
        }
    }

    var isInteger: Bool {
        self != .float && self != .double
    }

    var name: String {
        switch self {
        case .char:
            "char"
        case .uchar:
            "uchar"
        case .short:
            "short"
        case .ushort:
            "ushort"
        case .int:
            "int"
        case .uint:
            "uint"
        case .float:
            "float"
        case .double:
            "double"
        }
    }
}

public extension PLYReader.PropertyValue {
    init?(string: String, type: PLYReader.PropertyType) {
        switch type {
        case .char:
            guard let v = Int8(string) else {
                return nil
            }
            self = .char(v)

        case .uchar:
            guard let v = UInt8(string) else {
                return nil
            }
            self = .uchar(v)

        case .short:
            guard let v = Int16(string) else {
                return nil
            }
            self = .short(v)

        case .ushort:
            guard let v = UInt16(string) else {
                return nil
            }
            self = .ushort(v)

        case .int:
            guard let v = Int32(string) else {
                return nil
            }
            self = .int(v)

        case .uint:
            guard let v = UInt32(string) else {
                return nil
            }
            self = .uint(v)

        case .float:
            guard let v = Float(string) else {
                return nil
            }
            self = .float(v)

        case .double:
            guard let v = Double(string) else {
                return nil
            }
            self = .double(v)
        }
    }

    var floatValue: Float? {
        switch self {
        case .char(let v):
            return Float(v)
        case .uchar(let v):
            return Float(v)
        case .short(let v):
            return Float(v)
        case .ushort(let v):
            return Float(v)
        case .int(let v):
            return Float(v)
        case .uint(let v):
            return Float(v)
        case .float(let v):
            return v
        case .double(let v):
            return Float(v)
        case .list:
            return nil
        }
    }
}
