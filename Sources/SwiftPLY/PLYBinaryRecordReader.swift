import Foundation

// Reads a binary element into memory with a structure definition, without making `PropertyValue`s.
// `PLYReader.binaryRange(of:)` checks the bounds and list counts first, so the loops read without checks.
internal struct PLYBinaryRecordReader {
    // How to move one scalar from the file to memory.
    enum Move {
        // Same type and byte order.
        case copy(size: Int)
        // Same type, other byte order.
        case swap(size: Int)
        // Double to Float and Float to Double are common in splat and scan files, so they skip the general path.
        case doubleToFloat(swap: Bool)
        case floatToDouble(swap: Bool)
        case convert(from: PLYReader.PropertyType, to: PLYReader.PropertyType)
    }

    // One scalar move at fixed offsets.
    struct ScalarMove {
        var source: Int
        var destination: Int
        var move: Move
        var nameIndex: Int
    }

    // One property of the element, in file order.
    enum Step {
        case skip(size: Int)
        case scalar(size: Int, destination: Int, move: Move, nameIndex: Int)
        case list(countType: PLYReader.PropertyType, itemType: PLYReader.PropertyType, field: ListField?)
    }

    struct ListField {
        var destination: Int
        var length: Int
        var move: Move
        var nameIndex: Int
    }

    let littleEndian: Bool
    let stride: Int
    // Set when the element has no lists. Adjacent copies are merged.
    let fixedRecordSize: Int?
    let fixedMoves: [ScalarMove]
    let steps: [Step]
    // Property names by field index, for errors. Plans hold indices so that the loops do not retain Strings.
    let names: [String]

    init(element: PLYReader.Element, definition: PLYStructureDefinition, littleEndian: Bool) {
        self.littleEndian = littleEndian
        stride = definition.stride
        names = definition.fields.map(\.propertyName)
        let fields = Dictionary(uniqueKeysWithValues: definition.fields.enumerated().map { ($1.propertyName, (index: $0, field: $1)) })

        func move(from source: PLYReader.PropertyType, to destination: PLYReader.PropertyType) -> Move {
            guard source == destination else {
                switch (source, destination) {
                case (.double, .float):
                    return .doubleToFloat(swap: !littleEndian)
                case (.float, .double):
                    return .floatToDouble(swap: !littleEndian)
                default:
                    return .convert(from: source, to: destination)
                }
            }
            return littleEndian || source.size == 1 ? .copy(size: source.size) : .swap(size: source.size)
        }

        var plannedSteps: [Step] = []
        for property in element.properties {
            let entry = fields[property.name]
            let field = entry?.field
            let nameIndex = entry?.index ?? 0
            switch property.kind {
            case .scalar(let type):
                if let field, field.list == nil {
                    plannedSteps.append(.scalar(size: type.size, destination: field.offset, move: move(from: type, to: field.type), nameIndex: nameIndex))
                } else {
                    plannedSteps.append(.skip(size: type.size))
                }

            case let .list(countType, itemType):
                let listField = field.flatMap { field in
                    field.list.map { ListField(destination: field.offset, length: $0.length, move: move(from: itemType, to: field.type), nameIndex: nameIndex) }
                }
                plannedSteps.append(.list(countType: countType, itemType: itemType, field: listField))
            }
        }
        steps = plannedSteps

        guard let recordSize = PLYReader.Property.Kind.fixedSize(of: element.properties.map(\.kind)) else {
            fixedRecordSize = nil
            fixedMoves = []
            return
        }
        fixedRecordSize = recordSize
        var moves: [ScalarMove] = []
        var source = 0
        for step in steps {
            guard case let .scalar(size, destination, move, nameIndex) = step else {
                if case .skip(let size) = step {
                    source += size
                }
                continue
            }
            if case .copy(let addedSize) = move, let last = moves.last, case .copy(let lastSize) = last.move,
               last.source + lastSize == source, last.destination + lastSize == destination {
                moves[moves.count - 1].move = .copy(size: lastSize + addedSize)
            } else {
                moves.append(ScalarMove(source: source, destination: destination, move: move, nameIndex: nameIndex))
            }
            source += size
        }
        fixedMoves = moves
    }

    // `checkpoints` are the offsets from `source` of every `PLYReader.checkpointInterval`th record of an element
    // with lists. With them, parts of the element are read on several cores.
    func read(count: Int, from source: UnsafeRawPointer, into destination: UnsafeMutableRawPointer, checkpoints: [Int]) throws {
        if let fixedRecordSize {
            // About 1 MB of file data for each part.
            try PLYParallel.forEachChunk(count: count, minimumChunkSize: max(1, (1 << 20) / max(fixedRecordSize, 1))) { records in
                for record in records {
                    let sourceRecord = source + record * fixedRecordSize
                    let destinationRecord = destination + record * stride
                    for move in fixedMoves {
                        try apply(move.move, from: sourceRecord + move.source, to: destinationRecord + move.destination, nameIndex: move.nameIndex)
                    }
                }
            }
            return
        }

        guard checkpoints.count > 1 else {
            try readVariableSizeRecords(0..<count, from: source, into: destination)
            return
        }
        let interval = PLYReader.checkpointInterval
        try PLYParallel.forEachChunk(count: checkpoints.count, minimumChunkSize: 4) { parts in
            let records = (parts.lowerBound * interval)..<min(count, parts.upperBound * interval)
            try readVariableSizeRecords(records, from: source + checkpoints[parts.lowerBound], into: destination)
        }
    }

    // `source` is the start of the first record in `records`.
    private func readVariableSizeRecords(_ records: Range<Int>, from source: UnsafeRawPointer, into destination: UnsafeMutableRawPointer) throws {
        var cursor = source
        for record in records {
            let destinationRecord = destination + record * stride
            for step in steps {
                switch step {
                case .skip(let size):
                    cursor += size

                case let .scalar(size, offset, move, nameIndex):
                    try apply(move, from: cursor, to: destinationRecord + offset, nameIndex: nameIndex)
                    cursor += size

                case let .list(countType, itemType, field):
                    // Counts are integers, at most 32 bits, so they are exact in a Double.
                    let itemCount = Int(loadDouble(countType, from: cursor))
                    cursor += countType.size
                    if let field {
                        guard itemCount == field.length else {
                            throw PLYError.invalidValue(names[field.nameIndex])
                        }
                        if case .copy = field.move {
                            try apply(.copy(size: itemCount * itemType.size), from: cursor, to: destinationRecord + field.destination, nameIndex: field.nameIndex)
                        } else {
                            for item in 0..<itemCount {
                                try apply(field.move, from: cursor + item * itemType.size, to: destinationRecord + field.destination + item * itemType.sizeAfter(field.move), nameIndex: field.nameIndex)
                            }
                        }
                    }
                    cursor += itemCount * itemType.size
                }
            }
        }
    }

    @inline(__always)
    private func apply(_ move: Move, from source: UnsafeRawPointer, to destination: UnsafeMutableRawPointer, nameIndex: Int) throws {
        switch move {
        case .copy(let size):
            // Short runs use loads and stores. A call to memcpy costs more than the copy.
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

        case .swap(let size):
            switch size {
            case 2:
                destination.storeBytes(of: source.loadUnaligned(as: UInt16.self).byteSwapped, as: UInt16.self)
            case 4:
                destination.storeBytes(of: source.loadUnaligned(as: UInt32.self).byteSwapped, as: UInt32.self)
            default:
                destination.storeBytes(of: source.loadUnaligned(as: UInt64.self).byteSwapped, as: UInt64.self)
            }

        case .doubleToFloat(let swap):
            let bits = source.loadUnaligned(as: UInt64.self)
            destination.storeBytes(of: Float(Double(bitPattern: swap ? bits.byteSwapped : bits)), as: Float.self)

        case .floatToDouble(let swap):
            let bits = source.loadUnaligned(as: UInt32.self)
            destination.storeBytes(of: Double(Float(bitPattern: swap ? bits.byteSwapped : bits)), as: Double.self)

        case let .convert(sourceType, destinationType):
            try storeNumber(loadDouble(sourceType, from: source), as: destinationType, to: destination, propertyName: names[nameIndex])
        }
    }

    @inline(__always)
    private func loadDouble(_ type: PLYReader.PropertyType, from source: UnsafeRawPointer) -> Double {
        func load<I: FixedWidthInteger>(_: I.Type) -> I {
            let value = source.loadUnaligned(as: I.self)
            return littleEndian ? I(littleEndian: value) : I(bigEndian: value)
        }
        return switch type {
        case .char:
            Double(load(Int8.self))
        case .uchar:
            Double(load(UInt8.self))
        case .short:
            Double(load(Int16.self))
        case .ushort:
            Double(load(UInt16.self))
        case .int:
            Double(load(Int32.self))
        case .uint:
            Double(load(UInt32.self))
        case .float:
            Double(Float(bitPattern: load(UInt32.self)))
        case .double:
            Double(bitPattern: load(UInt64.self))
        }
    }
}

// Integer types need an integer value in range, as `PLYStructureDefinition.Field.store(_:in:)` does.
@inline(__always)
internal func storeNumber(_ number: Double, as type: PLYReader.PropertyType, to destination: UnsafeMutableRawPointer, propertyName: @autoclosure () -> String) throws {
    func storeInteger<I: FixedWidthInteger>(_: I.Type) throws {
        guard let integer = I(exactly: number) else {
            throw PLYError.invalidValue(propertyName())
        }
        destination.storeBytes(of: integer, as: I.self)
    }
    switch type {
    case .char:
        try storeInteger(Int8.self)
    case .uchar:
        try storeInteger(UInt8.self)
    case .short:
        try storeInteger(Int16.self)
    case .ushort:
        try storeInteger(UInt16.self)
    case .int:
        try storeInteger(Int32.self)
    case .uint:
        try storeInteger(UInt32.self)
    case .float:
        destination.storeBytes(of: Float(number), as: Float.self)
    case .double:
        destination.storeBytes(of: number, as: Double.self)
    }
}

private extension PLYReader.PropertyType {
    // The size of one list item in memory after `move`.
    func sizeAfter(_ move: PLYBinaryRecordReader.Move) -> Int {
        switch move {
        case .copy, .swap:
            size
        case .doubleToFloat:
            Self.float.size
        case .floatToDouble:
            Self.double.size
        case .convert(_, let destination):
            destination.size
        }
    }
}
