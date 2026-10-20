import Foundation

// Writes records from memory with a structure definition, without making `PropertyValue`s. The bytes are the same
// as `PLYWriter.write(_: [PLYReader.PropertyValue])` gives for the same values.
internal struct PLYRecordWriter {
    enum Item {
        // One scalar, or the items of a list, at `source` in the record in memory.
        case values(source: Int, type: PLYReader.PropertyType, count: Int)
        // The count of a list. All records have the same count.
        case listCount(Int, type: PLYReader.PropertyType)
    }

    let items: [Item]
    let stride: Int

    // Throws `invalidValue` for the first property with no field of the same name and kind, or a list length that
    // does not fit the count type, as the value path does.
    init(element: PLYReader.Element, definition: PLYStructureDefinition) throws {
        stride = definition.stride
        items = try element.properties.flatMap { property -> [Item] in
            guard let field = definition.fields.first(where: { $0.propertyName == property.name }), property.kind == field.kind else {
                throw PLYError.invalidValue(property.name)
            }
            guard let list = field.list else {
                return [.values(source: field.offset, type: field.type, count: 1)]
            }
            guard PLYWriter.encodedCount(list.length, type: list.countType) != nil else {
                throw PLYError.invalidValue(property.name)
            }
            return [.listCount(list.length, type: list.countType), .values(source: field.offset, type: field.type, count: list.length)]
        }
    }

    // MARK: ASCII

    // Appends one line for each record: the values separated by spaces, as `PropertyValue.asciiText` gives them.
    func writeASCII(records: Range<Int>, from source: UnsafeRawPointer, into text: inout [UInt8]) {
        for record in records {
            let sourceRecord = source + record * stride
            var first = true
            for item in items {
                switch item {
                case let .listCount(count, _):
                    Self.appendSeparator(&first, &text)
                    Self.appendInteger(Int64(count), to: &text)

                case let .values(offset, type, count):
                    for index in 0..<count {
                        Self.appendSeparator(&first, &text)
                        Self.appendText(of: sourceRecord + offset + index * type.size, type: type, to: &text)
                    }
                }
            }
            text.append(0x0A)
        }
    }

    @inline(__always)
    private static func appendSeparator(_ first: inout Bool, _ text: inout [UInt8]) {
        if first {
            first = false
        } else {
            text.append(0x20)
        }
    }

    private static func appendText(of value: UnsafeRawPointer, type: PLYReader.PropertyType, to text: inout [UInt8]) {
        switch type {
        case .char:
            appendInteger(Int64(value.load(as: Int8.self)), to: &text)
        case .uchar:
            appendInteger(Int64(value.load(as: UInt8.self)), to: &text)
        case .short:
            appendInteger(Int64(value.loadUnaligned(as: Int16.self)), to: &text)
        case .ushort:
            appendInteger(Int64(value.loadUnaligned(as: UInt16.self)), to: &text)
        case .int:
            appendInteger(Int64(value.loadUnaligned(as: Int32.self)), to: &text)
        case .uint:
            appendInteger(Int64(value.loadUnaligned(as: UInt32.self)), to: &text)
        case .float:
            text.append(contentsOf: value.loadUnaligned(as: Float.self).description.utf8)
        case .double:
            text.append(contentsOf: value.loadUnaligned(as: Double.self).description.utf8)
        }
    }

    // The text of a scalar, as `PropertyValue.asciiText` gives it. Lists are not passed here.
    // A list adds each item followed by a space. A scalar adds no space.
    static func appendASCII(_ value: PLYReader.PropertyValue, to text: inout [UInt8]) {
        switch value {
        case .char(let number):
            appendInteger(Int64(number), to: &text)
        case .uchar(let number):
            appendInteger(Int64(number), to: &text)
        case .short(let number):
            appendInteger(Int64(number), to: &text)
        case .ushort(let number):
            appendInteger(Int64(number), to: &text)
        case .int(let number):
            appendInteger(Int64(number), to: &text)
        case .uint(let number):
            appendInteger(Int64(number), to: &text)
        case .float(let number):
            text.append(contentsOf: number.description.utf8)
        case .double(let number):
            text.append(contentsOf: number.description.utf8)
        case .list(let items):
            for item in items {
                appendASCII(item, to: &text)
                text.append(0x20)
            }
        }
    }

    // Stores the bytes of a value at `destination` and returns their count. A list stores its items only.
    @inline(__always)
    static func storeBinary(_ value: PLYReader.PropertyValue, littleEndian: Bool, at destination: UnsafeMutableRawPointer) -> Int {
        func store<I: FixedWidthInteger>(_ number: I) -> Int {
            destination.storeBytes(of: littleEndian ? number.littleEndian : number.bigEndian, as: I.self)
            return MemoryLayout<I>.size
        }
        switch value {
        case .char(let number):
            return store(number)
        case .uchar(let number):
            return store(number)
        case .short(let number):
            return store(number)
        case .ushort(let number):
            return store(number)
        case .int(let number):
            return store(number)
        case .uint(let number):
            return store(number)
        case .float(let number):
            return store(number.bitPattern)
        case .double(let number):
            return store(number.bitPattern)
        case .list(let items):
            return storeBinary(items: items, littleEndian: littleEndian, at: destination)
        }
    }

    // A separate function, so that `storeBinary(_:littleEndian:at:)` does not call itself and stays inlined.
    private static func storeBinary(items: [PLYReader.PropertyValue], littleEndian: Bool, at destination: UnsafeMutableRawPointer) -> Int {
        var size = 0
        for item in items {
            size += storeBinary(item, littleEndian: littleEndian, at: destination + size)
        }
        return size
    }

    // The same digits as `description` for the PLY integer types.
    private static func appendInteger(_ value: Int64, to text: inout [UInt8]) {
        // Digits fill a stack buffer from the end, then one append adds them. Appending byte by byte checks the
        // array's uniqueness for every byte.
        var magnitude = value.magnitude
        var digits: (UInt64, UInt64, UInt64) = (0, 0, 0)
        withUnsafeMutableBytes(of: &digits) { buffer in
            var start = buffer.count
            repeat {
                start -= 1
                buffer[start] = UInt8(magnitude % 10) + 0x30
                magnitude /= 10
            } while magnitude > 0
            if value < 0 {
                start -= 1
                buffer[start] = 0x2D
            }
            text.append(contentsOf: UnsafeRawBufferPointer(rebasing: buffer[start...]))
        }
    }

    // MARK: Binary

    // How one part of a binary record is written. The plan holds no Strings, so the loop does not retain anything.
    enum BinaryMove {
        case copy(source: Int, destination: Int, size: Int)
        case swap(source: Int, destination: Int, size: Int)
        case constant(bits: UInt64, destination: Int, size: Int)
    }

    struct BinaryPlan {
        var sourceStride: Int
        var recordSize: Int
        var moves: [BinaryMove]

        func write(records: Range<Int>, from source: UnsafeRawPointer, into output: UnsafeMutableRawPointer) {
            PLYRecordWriter.writeBinary(records: records, from: source, into: output, plan: self)
        }
    }

    func binaryPlan(littleEndian: Bool) -> BinaryPlan {
        var moves: [BinaryMove] = []
        var destination = 0
        for item in items {
            switch item {
            case let .listCount(count, type):
                // The count is non-negative and fits `type`, so the first `type.size` bytes in memory of `bits` are
                // the count in that type and byte order.
                let value = UInt64(count)
                let bits = littleEndian ? value : (value << (64 - 8 * type.size)).bigEndian
                moves.append(.constant(bits: bits, destination: destination, size: type.size))
                destination += type.size

            case let .values(source, type, count):
                for index in 0..<count {
                    let from = source + index * type.size
                    if littleEndian || type.size == 1 {
                        if case let .copy(lastSource, lastDestination, lastSize)? = moves.last, lastSource + lastSize == from, lastDestination + lastSize == destination {
                            moves[moves.count - 1] = .copy(source: lastSource, destination: lastDestination, size: lastSize + type.size)
                        } else {
                            moves.append(.copy(source: from, destination: destination, size: type.size))
                        }
                    } else {
                        moves.append(.swap(source: from, destination: destination, size: type.size))
                    }
                    destination += type.size
                }
            }
        }
        return BinaryPlan(sourceStride: stride, recordSize: destination, moves: moves)
    }

    private static func writeBinary(records: Range<Int>, from source: UnsafeRawPointer, into output: UnsafeMutableRawPointer, plan: BinaryPlan) {
        for record in records {
            let sourceRecord = source + record * plan.sourceStride
            let outputRecord = output + record * plan.recordSize
            for move in plan.moves {
                switch move {
                case let .copy(from, to, size):
                    copy(from: sourceRecord + from, to: outputRecord + to, size: size)

                case let .swap(from, to, size):
                    switch size {
                    case 2:
                        (outputRecord + to).storeBytes(of: (sourceRecord + from).loadUnaligned(as: UInt16.self).byteSwapped, as: UInt16.self)
                    case 4:
                        (outputRecord + to).storeBytes(of: (sourceRecord + from).loadUnaligned(as: UInt32.self).byteSwapped, as: UInt32.self)
                    default:
                        (outputRecord + to).storeBytes(of: (sourceRecord + from).loadUnaligned(as: UInt64.self).byteSwapped, as: UInt64.self)
                    }

                case let .constant(bits, to, size):
                    withUnsafeBytes(of: bits) { (outputRecord + to).copyMemory(from: $0.baseAddress.unsafelyUnwrapped, byteCount: size) }
                }
            }
        }
    }

    // Short runs use loads and stores. A call to memcpy costs more than the copy.
    @inline(__always)
    private static func copy(from source: UnsafeRawPointer, to destination: UnsafeMutableRawPointer, size: Int) {
        guard size <= 64 else {
            destination.copyMemory(from: source, byteCount: size)
            return
        }
        var offset = 0
        while offset + 8 <= size {
            destination.storeBytes(of: source.loadUnaligned(fromByteOffset: offset, as: UInt64.self), toByteOffset: offset, as: UInt64.self)
            offset += 8
        }
        if offset + 4 <= size {
            destination.storeBytes(of: source.loadUnaligned(fromByteOffset: offset, as: UInt32.self), toByteOffset: offset, as: UInt32.self)
            offset += 4
        }
        if offset + 2 <= size {
            destination.storeBytes(of: source.loadUnaligned(fromByteOffset: offset, as: UInt16.self), toByteOffset: offset, as: UInt16.self)
            offset += 2
        }
        if offset < size {
            destination.storeBytes(of: source.load(fromByteOffset: offset, as: UInt8.self), toByteOffset: offset, as: UInt8.self)
        }
    }
}
