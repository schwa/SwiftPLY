import Foundation

public struct PLYHeader {
    public var format: PLYReader.Format
    public var elements: [PLYReader.Element]

    public init(format: PLYReader.Format, elements: [PLYReader.Element]) {
        self.format = format
        self.elements = elements
    }

    /// Parses the header at the start of `data`.
    ///
    /// Comment and `obj_info` lines are skipped. `bodyOffset` is the index of the first byte after `end_header`.
    public static func parse(_ data: Data) throws -> (header: Self, bodyOffset: Int) {
        guard let end = endOfHeader(in: data) else {
            throw PLYError.missingEndHeader
        }
        guard let text = String(data: data[data.startIndex..<end], encoding: .ascii) else {
            throw PLYError.invalidEncoding
        }

        var parsedFormat: PLYReader.Format?
        var parsedElements: [PLYReader.Element] = []

        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ").map(String.init)
            switch parts.first {
            case "format":
                guard parts.count >= 2 else { throw PLYError.invalidHeader }
                guard let parsed = PLYReader.Format(name: parts[1]) else {
                    throw PLYError.unsupportedFormat(parts[1])
                }
                parsedFormat = parsed

            case "element":
                // The reader finds an element's data by its name, so names must be unique.
                guard parts.count >= 3, let count = Int(parts[2]), count >= 0, !parsedElements.contains(where: { $0.name == parts[1] }) else {
                    throw PLYError.invalidHeader
                }
                parsedElements.append(PLYReader.Element(name: parts[1], count: count, properties: []))

            case "property":
                guard !parsedElements.isEmpty else { throw PLYError.invalidHeader }
                try parsedElements[parsedElements.count - 1].properties.append(PLYReader.Property(headerParts: parts))

            default:
                continue
            }
        }

        guard let parsedFormat else {
            throw PLYError.formatNotSet
        }
        return (Self(format: parsedFormat, elements: parsedElements), end)
    }

    public var serialized: String {
        var lines = ["ply", "format \(format.name) 1.0"]
        for element in elements {
            lines.append("element \(element.name) \(element.count)")
            for property in element.properties {
                switch property.kind {
                case .scalar(let type):
                    lines.append("property \(type.name) \(property.name)")

                case let .list(countType, itemType):
                    lines.append("property list \(countType.name) \(itemType.name) \(property.name)")
                }
            }
        }
        lines.append("end_header")
        return lines.joined(separator: "\n") + "\n"
    }

    // Returns the index after the `end_header` line, or nil if there is none.
    private static func endOfHeader(in data: Data) -> Int? {
        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            let line = String(bytes: data[lineStart..<newline], encoding: .ascii) ?? ""
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "end_header" {
                return newline + 1
            }
            lineStart = newline + 1
        }
        return nil
    }
}

extension PLYHeader: Sendable, Equatable {}

public extension PLYReader.Format {
    init?(name: String) {
        switch name {
        case "ascii":
            self = .ascii
        case "binary_little_endian":
            self = .binaryLittleEndian
        case "binary_big_endian":
            self = .binaryBigEndian
        default:
            return nil
        }
    }

    var name: String {
        switch self {
        case .ascii:
            "ascii"
        case .binaryLittleEndian:
            "binary_little_endian"
        case .binaryBigEndian:
            "binary_big_endian"
        }
    }
}

extension PLYReader.Property {
    // `parts` is a split `property` line: `property <type> <name>` or `property list <count> <item> <name>`.
    init(headerParts parts: [String]) throws {
        if parts.count >= 5, parts[1] == "list" {
            guard let countType = PLYReader.PropertyType(string: parts[2]), countType.isInteger,
                  let itemType = PLYReader.PropertyType(string: parts[3]) else {
                throw PLYError.invalidHeader
            }
            self.init(name: parts[4], kind: .list(count: countType, item: itemType))
        } else {
            guard parts.count >= 3, let type = PLYReader.PropertyType(string: parts[1]) else {
                throw PLYError.invalidHeader
            }
            self.init(name: parts[2], kind: .scalar(type))
        }
    }
}
