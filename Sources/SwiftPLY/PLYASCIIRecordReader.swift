import Foundation

// Reads an ASCII element into memory with a structure definition, without making Strings or `PropertyValue`s for
// lines that are plain ASCII. The results and errors are the same as `PLYReader.readValues(element:callback:)`
// followed by `PLYStructureDefinition.Field.store(_:in:)`.
internal struct PLYASCIIRecordReader {
    struct ScalarField {
        var destination: Int
        var type: PLYReader.PropertyType
        var nameIndex: Int
    }

    struct ListField {
        var destination: Int
        var type: PLYReader.PropertyType
        var length: Int
        var nameIndex: Int
    }

    enum Step {
        case scalar(type: PLYReader.PropertyType, field: ScalarField?)
        case list(itemType: PLYReader.PropertyType, field: ListField?)
    }

    let steps: [Step]
    let stride: Int
    // Property names by field index, for errors. Steps hold indices so that the loops do not retain Strings.
    let names: [String]

    init(element: PLYReader.Element, definition: PLYStructureDefinition) {
        stride = definition.stride
        names = definition.fields.map(\.propertyName)
        let fields = Dictionary(uniqueKeysWithValues: definition.fields.enumerated().map { ($1.propertyName, (index: $0, field: $1)) })
        steps = element.properties.map { property in
            let entry = fields[property.name]
            let field = entry?.field
            let nameIndex = entry?.index ?? 0
            switch property.kind {
            case .scalar(let type):
                // `read(element:into:definition:)` checks that a field of a scalar property is not a list.
                let scalarField = field.map { ScalarField(destination: $0.offset, type: $0.type, nameIndex: nameIndex) }
                return .scalar(type: type, field: scalarField)

            case .list(_, let itemType):
                let listField = field.flatMap { field in
                    field.list.map { ListField(destination: field.offset, type: field.type, length: $0.length, nameIndex: nameIndex) }
                }
                return .list(itemType: itemType, field: listField)
            }
        }
    }

    // Returns the number of records read. Blank lines count toward `count` but give no record.
    //
    // `range` is the bytes of the element's lines, if known. Large elements are read in parts on all cores. A part
    // that finds a blank line or an error makes the whole element read again on this thread, because blank lines
    // move the records after them and the error must be the one for the first record that fails.
    func read(count: Int, from bytes: UnsafeRawBufferPointer, start: Int, range: Range<Int>?, into destination: UnsafeMutableRawPointer) throws -> Int {
        let partSize = 1 << 20
        // An element can start after the end of the data, when earlier elements need all of it.
        let serialLines = start..<max(start, bytes.count)
        guard let range, range.count >= 2 * partSize else {
            return try readLines(bytes, lines: serialLines, lineLimit: count, into: destination, failOnBlankLine: false)
        }
        let partCount = min(ProcessInfo.processInfo.activeProcessorCount, range.count / partSize)
        var boundaries = [range.lowerBound]
        for part in 1..<partCount {
            let approximate = max(boundaries[part - 1], range.lowerBound + part * range.count / partCount)
            boundaries.append(min(range.upperBound, Self.endOfLine(in: bytes, from: approximate, to: range.upperBound) + 1))
        }
        boundaries.append(range.upperBound)
        let lineCounts = boundaries.indices.dropLast().map { Self.lineCount(in: bytes, boundaries[$0]..<boundaries[$0 + 1]) }
        let firstLines = lineCounts.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1) }

        do {
            try PLYParallel.forEachChunk(count: partCount, minimumChunkSize: 1) { parts in
                for part in parts {
                    _ = try readLines(
                        bytes,
                        lines: boundaries[part]..<boundaries[part + 1],
                        lineLimit: lineCounts[part],
                        into: destination + firstLines[part] * stride,
                        failOnBlankLine: true
                    )
                }
            }
            return firstLines[partCount]
        } catch {
            return try readLines(bytes, lines: serialLines, lineLimit: count, into: destination, failOnBlankLine: false)
        }
    }

    private struct BlankLine: Error {}

    private func readLines(
        _ bytes: UnsafeRawBufferPointer,
        lines: Range<Int>,
        lineLimit: Int,
        into destination: UnsafeMutableRawPointer,
        failOnBlankLine: Bool
    ) throws -> Int {
        var tokens = TokenBuffer()
        defer { tokens.deallocate() }
        var offset = lines.lowerBound
        let end = lines.upperBound
        var recordIndex = 0
        var nonASCIILine: [UInt8] = []
        for _ in 0..<lineLimit {
            guard offset < end else {
                break
            }
            let lineEnd = Self.endOfLine(in: bytes, from: offset, to: end)
            let line = offset..<lineEnd
            offset = lineEnd + 1

            let record = destination + recordIndex * stride
            if tokens.tokenizeASCII(bytes, Self.trimmed(bytes, line), stopAtNonASCII: true) {
                guard !tokens.tokens.isEmpty else {
                    if failOnBlankLine {
                        throw BlankLine()
                    }
                    continue
                }
                try readRecord(tokens: tokens.tokens, in: bytes, into: record)
            } else {
                // Lines with other characters use Foundation for decoding and trimming, as `readValues` does.
                guard let text = String(bytes: bytes[line], encoding: .utf8) else {
                    throw PLYError.invalidEncoding
                }
                nonASCIILine = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
                guard !nonASCIILine.isEmpty else {
                    if failOnBlankLine {
                        throw BlankLine()
                    }
                    continue
                }
                try nonASCIILine.withUnsafeBytes { lineBytes in
                    tokens.tokenize(lineBytes, 0..<lineBytes.count)
                    try readRecord(tokens: tokens.tokens, in: lineBytes, into: record)
                }
            }
            recordIndex += 1
        }
        return recordIndex
    }

    // The rows of `PLYReader.readValues(element:callback:)` for an ASCII element, from bytes instead of Strings.
    // `kinds` are the element's property kinds. The row array is reused between callbacks.
    static func readValueRows(
        kinds: [PLYReader.Property.Kind],
        count: Int,
        from bytes: UnsafeRawBufferPointer,
        start: Int,
        callback: ([PLYReader.PropertyValue?]) throws -> Void
    ) throws {
        var tokens = TokenBuffer()
        defer { tokens.deallocate() }
        var row = [PLYReader.PropertyValue?](repeating: nil, count: kinds.count)
        var nonASCIILine: [UInt8] = []
        var offset = start
        for _ in 0..<count {
            guard offset < bytes.count else {
                break
            }
            let lineEnd = endOfLine(in: bytes, from: offset, to: bytes.count)
            let line = offset..<lineEnd
            offset = lineEnd + 1

            if tokens.tokenizeASCII(bytes, trimmed(bytes, line), stopAtNonASCII: true) {
                guard !tokens.tokens.isEmpty else {
                    continue
                }
                try fillRow(&row, kinds: kinds, tokens: tokens.tokens, in: bytes)
            } else {
                guard let text = String(bytes: bytes[line], encoding: .utf8) else {
                    throw PLYError.invalidEncoding
                }
                nonASCIILine = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
                guard !nonASCIILine.isEmpty else {
                    continue
                }
                try nonASCIILine.withUnsafeBytes { lineBytes in
                    tokens.tokenize(lineBytes, 0..<lineBytes.count)
                    try fillRow(&row, kinds: kinds, tokens: tokens.tokens, in: lineBytes)
                }
            }
            try callback(row)
        }
    }

    // Values that do not parse are nil, and list items that do not parse are left out, as in `readValues`.
    private static func fillRow(
        _ row: inout [PLYReader.PropertyValue?],
        kinds: [PLYReader.Property.Kind],
        tokens: UnsafeBufferPointer<Range<Int>>,
        in bytes: UnsafeRawBufferPointer
    ) throws {
        var index = 0
        try row.withUnsafeMutableBufferPointer { values in
            for (column, kind) in kinds.enumerated() {
                switch kind {
                case .scalar(let type):
                    guard index < tokens.count else {
                        throw PLYError.invalidData
                    }
                    values[column] = parseValue(bytes, tokens[index], as: type)
                    index += 1

                case .list(_, let itemType):
                    guard index < tokens.count, let itemCount = parseInteger(bytes, tokens[index], as: Int.self), itemCount >= 0 else {
                        throw PLYError.invalidData
                    }
                    index += 1
                    guard itemCount <= tokens.count - index else {
                        throw PLYError.invalidData
                    }
                    var items: [PLYReader.PropertyValue] = []
                    items.reserveCapacity(itemCount)
                    for token in tokens[index..<(index + itemCount)] {
                        if let item = parseValue(bytes, token, as: itemType) {
                            items.append(item)
                        }
                    }
                    values[column] = .list(items)
                    index += itemCount
                }
            }
        }
    }

    // The same value as `PropertyValue(string:type:)`.
    static func parseValue(_ bytes: UnsafeRawBufferPointer, _ token: Range<Int>, as type: PLYReader.PropertyType) -> PLYReader.PropertyValue? {
        switch type {
        case .char:
            parseInteger(bytes, token, as: Int8.self).map { .char($0) }
        case .uchar:
            parseInteger(bytes, token, as: UInt8.self).map { .uchar($0) }
        case .short:
            parseInteger(bytes, token, as: Int16.self).map { .short($0) }
        case .ushort:
            parseInteger(bytes, token, as: UInt16.self).map { .ushort($0) }
        case .int:
            parseInteger(bytes, token, as: Int32.self).map { .int($0) }
        case .uint:
            parseInteger(bytes, token, as: UInt32.self).map { .uint($0) }
        case .float:
            parseFloat(bytes, token).map { .float($0) }
        case .double:
            parseDouble(bytes, token).map { .double($0) }
        }
    }

    // Lines in `range`, including a last line with no line feed.
    private static func lineCount(in bytes: UnsafeRawBufferPointer, _ range: Range<Int>) -> Int {
        let lastLineHasNoLineFeed = !range.isEmpty && bytes[range.upperBound - 1] != 0x0A
        return PLYLineFeeds.count(in: bytes, range) + (lastLineHasNoLineFeed ? 1 : 0)
    }

    private func readRecord(tokens: UnsafeBufferPointer<Range<Int>>, in bytes: UnsafeRawBufferPointer, into record: UnsafeMutableRawPointer) throws {
        // Check the token counts for the whole record first, as `readValues` does before any value is stored.
        var index = 0
        for step in steps {
            switch step {
            case .scalar:
                index += 1

            case .list:
                guard index < tokens.count, let itemCount = Self.parseInteger(bytes, tokens[index], as: Int.self), itemCount >= 0 else {
                    throw PLYError.invalidData
                }
                index += 1 + itemCount
            }
            guard index <= tokens.count else {
                throw PLYError.invalidData
            }
        }

        index = 0
        for step in steps {
            switch step {
            case let .scalar(type, field):
                if let field {
                    guard let number = Self.parse(bytes, tokens[index], as: type) else {
                        throw PLYError.invalidValue(names[field.nameIndex])
                    }
                    try storeNumber(number, as: field.type, to: record + field.destination, propertyName: names[field.nameIndex])
                }
                index += 1

            case let .list(itemType, field):
                let itemCount = Self.parseInteger(bytes, tokens[index], as: Int.self).unsafelyUnwrapped
                index += 1
                if let field {
                    // Items that do not parse are left out, as in `readValues`.
                    var stored = 0
                    for token in tokens[index..<index + itemCount] {
                        guard let number = Self.parse(bytes, token, as: itemType) else {
                            continue
                        }
                        if stored < field.length {
                            try storeNumber(number, as: field.type, to: record + field.destination + stored * field.type.size, propertyName: names[field.nameIndex])
                        }
                        stored += 1
                    }
                    guard stored == field.length else {
                        throw PLYError.invalidValue(names[field.nameIndex])
                    }
                }
                index += itemCount
            }
        }
    }

    // The index of the next line feed before `end`, or `end`.
    private static func endOfLine(in bytes: UnsafeRawBufferPointer, from offset: Int, to end: Int) -> Int {
        let base = bytes.baseAddress.unsafelyUnwrapped
        guard let newline = memchr(base + offset, 0x0A, end - offset) else {
            return end
        }
        return UnsafeRawPointer(newline) - base
    }

    // ASCII whitespace and newlines: tab, line feed, vertical tab, form feed, carriage return, and space.
    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }

    private static func trimmed(_ bytes: UnsafeRawBufferPointer, _ line: Range<Int>) -> Range<Int> {
        var lower = line.lowerBound
        var upper = line.upperBound
        while lower < upper, isWhitespace(bytes[lower]) {
            lower += 1
        }
        while upper > lower, isWhitespace(bytes[upper - 1]) {
            upper -= 1
        }
        return lower..<upper
    }

    // Token ranges of the current line. Raw memory avoids the uniqueness checks of Array appends.
    struct TokenBuffer {
        private var storage = UnsafeMutableBufferPointer<Range<Int>>.allocate(capacity: 64)
        private(set) var count = 0

        var tokens: UnsafeBufferPointer<Range<Int>> {
            UnsafeBufferPointer(rebasing: storage[..<count])
        }

        func deallocate() {
            storage.deallocate()
        }

        // Splits on spaces and leaves out empty tokens, as `split(separator: " ")` does.
        mutating func tokenize(_ bytes: UnsafeRawBufferPointer, _ line: Range<Int>) {
            _ = tokenizeASCII(bytes, line, stopAtNonASCII: false)
        }

        // Returns false, with no tokens, if the line has a byte that is not ASCII.
        mutating func tokenizeASCII(_ bytes: UnsafeRawBufferPointer, _ line: Range<Int>, stopAtNonASCII: Bool) -> Bool {
            count = 0
            var tokenStart = line.lowerBound
            for index in line {
                let byte = bytes[index]
                if byte >= 0x80, stopAtNonASCII {
                    count = 0
                    return false
                }
                if byte == 0x20 {
                    if tokenStart < index {
                        append(tokenStart..<index)
                    }
                    tokenStart = index + 1
                }
            }
            if tokenStart < line.upperBound {
                append(tokenStart..<line.upperBound)
            }
            return true
        }

        private mutating func append(_ token: Range<Int>) {
            if count == storage.count {
                let larger = UnsafeMutableBufferPointer<Range<Int>>.allocate(capacity: storage.count * 2)
                _ = larger.initialize(fromContentsOf: storage)
                storage.deallocate()
                storage = larger
            }
            storage[count] = token
            count += 1
        }
    }

    // The value of a token as a property of `type`, widened to Double. Nil if `PropertyValue(string:type:)` is nil.
    static func parse(_ bytes: UnsafeRawBufferPointer, _ token: Range<Int>, as type: PLYReader.PropertyType) -> Double? {
        switch type {
        case .char:
            parseInteger(bytes, token, as: Int8.self).map(Double.init)
        case .uchar:
            parseInteger(bytes, token, as: UInt8.self).map(Double.init)
        case .short:
            parseInteger(bytes, token, as: Int16.self).map(Double.init)
        case .ushort:
            parseInteger(bytes, token, as: UInt16.self).map(Double.init)
        case .int:
            parseInteger(bytes, token, as: Int32.self).map(Double.init)
        case .uint:
            parseInteger(bytes, token, as: UInt32.self).map(Double.init)
        case .float:
            parseFloat(bytes, token).map(Double.init)
        case .double:
            parseDouble(bytes, token)
        }
    }

    // The same rules as `I(_ text: String)`: an optional sign, then one or more decimal digits.
    static func parseInteger<I: FixedWidthInteger>(_ bytes: UnsafeRawBufferPointer, _ token: Range<Int>, as _: I.Type) -> I? {
        var index = token.lowerBound
        var negative = false
        if index < token.upperBound, bytes[index] == 0x2B || bytes[index] == 0x2D {
            negative = bytes[index] == 0x2D
            index += 1
        }
        guard index < token.upperBound else {
            return nil
        }
        var value: I = 0
        while index < token.upperBound {
            let digit = bytes[index] &- 0x30
            guard digit < 10 else {
                return nil
            }
            let (multiplied, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = negative
                ? multiplied.subtractingReportingOverflow(I(digit))
                : multiplied.addingReportingOverflow(I(digit))
            guard !multiplyOverflow, !addOverflow else {
                return nil
            }
            value = next
            index += 1
        }
        return value
    }

    // Tokens of digits, signs, points, and exponents use the C library. It rounds correctly, so the result is the
    // same as `Float(_ text: String)`. Other tokens, such as "inf" or hexadecimal, and tokens that the C library
    // does not read completely, use `Float(_ text: String)`.
    static func parseFloat(_ bytes: UnsafeRawBufferPointer, _ token: Range<Int>) -> Float? {
        // Exact when the digits fit in the significand and the power of ten is exact: one correctly rounded
        // multiplication or division gives the correctly rounded result (Clinger's fast path).
        if let (digits, exponent, negative) = simpleDecimal(bytes, token), digits < 1 << 24, abs(exponent) <= 10 {
            let magnitude = Float(digits)
            let scaled = exponent < 0 ? magnitude / floatPowersOfTen[-exponent] : magnitude * floatPowersOfTen[exponent]
            return negative ? -scaled : scaled
        }
        return parseWithCLibrary(bytes, token, strtof) ?? String(bytes: bytes[token], encoding: .utf8).flatMap { Float($0) }
    }

    static func parseDouble(_ bytes: UnsafeRawBufferPointer, _ token: Range<Int>) -> Double? {
        if let (digits, exponent, negative) = simpleDecimal(bytes, token), digits < 1 << 53, abs(exponent) <= 22 {
            let magnitude = Double(digits)
            let scaled = exponent < 0 ? magnitude / doublePowersOfTen[-exponent] : magnitude * doublePowersOfTen[exponent]
            return negative ? -scaled : scaled
        }
        return parseWithCLibrary(bytes, token, strtod) ?? String(bytes: bytes[token], encoding: .utf8).flatMap { Double($0) }
    }

    private static let floatPowersOfTen: [Float] = (0...10).map { Float("1e\($0)").unsafelyUnwrapped }
    private static let doublePowersOfTen: [Double] = (0...22).map { Double("1e\($0)").unsafelyUnwrapped }

    // A token of the form [sign] digits [. digits], with 1 to 18 digits, as an integer and a power of ten. Nil for
    // other tokens, which use the slower parsers.
    private static func simpleDecimal(_ bytes: UnsafeRawBufferPointer, _ token: Range<Int>) -> (digits: UInt64, exponent: Int, negative: Bool)? {
        var index = token.lowerBound
        var negative = false
        if index < token.upperBound, bytes[index] == 0x2B || bytes[index] == 0x2D {
            negative = bytes[index] == 0x2D
            index += 1
        }
        var digits: UInt64 = 0
        var digitCount = 0
        var exponent = 0
        var seenPoint = false
        while index < token.upperBound {
            let byte = bytes[index]
            if byte == 0x2E, !seenPoint {
                seenPoint = true
            } else {
                let digit = byte &- 0x30
                guard digit < 10, digitCount < 18 else {
                    return nil
                }
                digits = digits * 10 + UInt64(digit)
                digitCount += 1
                if seenPoint {
                    exponent -= 1
                }
            }
            index += 1
        }
        guard digitCount > 0 else {
            return nil
        }
        return (digits, exponent, negative)
    }

    private static func parseWithCLibrary<F>(
        _ bytes: UnsafeRawBufferPointer,
        _ token: Range<Int>,
        _ function: (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> F
    ) -> F? {
        let maximumLength = 63
        guard !token.isEmpty, token.count <= maximumLength, bytes[token].allSatisfy(isNumberCharacter) else {
            return nil
        }
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: maximumLength + 1) { buffer in
            let start = buffer.baseAddress.unsafelyUnwrapped
            UnsafeMutableRawPointer(start).copyMemory(from: bytes.baseAddress.unsafelyUnwrapped + token.lowerBound, byteCount: token.count)
            start[token.count] = 0
            var end: UnsafeMutablePointer<CChar>?
            let value = function(start, &end)
            return end == start + token.count ? value : nil
        }
    }

    private static func isNumberCharacter(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || byte == 0x2B || byte == 0x2D || byte == 0x2E || byte == 0x45 || byte == 0x65
    }
}
