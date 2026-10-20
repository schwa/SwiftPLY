// Metal and Model I/O exist only on Apple platforms. Elsewhere this library is empty.
#if canImport(Metal) && canImport(MetalKit) && canImport(ModelIO)
import Metal
import MetalKit
import ModelIO
import SwiftPLY

public extension PLYStructureDefinition {
    /// Makes a definition from the attributes of `descriptor` that use `bufferIndex`.
    ///
    /// Attribute names map to property names with `defaultPropertyNames(field:count:)`, so a `position` float3 maps
    /// to `position_0 position_1 position_2`. `names` replaces the property names for an attribute, for example
    /// `[MDLVertexAttributePosition: ["x", "y", "z"]]`.
    /// Normalized integer formats map to their integer type. For example, `uChar4Normalized` stores the same bytes
    /// as four `uchar` properties. Half-float and packed formats throw.
    init(_ descriptor: MDLVertexDescriptor, bufferIndex: Int = 0, names: [String: [String]] = [:]) throws {
        guard let layout = descriptor.layouts[safe: bufferIndex] as? MDLVertexBufferLayout else {
            throw PLYError.invalidValue("layout \(bufferIndex)")
        }
        self.init(stride: layout.stride)
        for case let attribute as MDLVertexAttribute in descriptor.attributes where attribute.format != .invalid && attribute.bufferIndex == bufferIndex {
            guard !attribute.name.isEmpty, let (type, count) = Self.propertyType(for: attribute.format) else {
                throw PLYError.invalidValue(attribute.name)
            }
            try append(attribute.name, type: type, offset: attribute.offset, count: count, propertyNames: names[attribute.name, default: []])
        }
    }

    /// Makes a definition from the attributes of `descriptor` that use `bufferIndex`.
    ///
    /// `MTLVertexDescriptor` has no attribute names, so `attributeNames` gives a name for each attribute index that
    /// the buffer uses, for example `[0: "position", 1: "normal"]`. Then the rules of `init(_:bufferIndex:names:)` apply.
    init(_ descriptor: MTLVertexDescriptor, attributeNames: [Int: String], bufferIndex: Int = 0, names: [String: [String]] = [:]) throws {
        let modelIO = MTKModelIOVertexDescriptorFromMetal(descriptor)
        for (index, name) in attributeNames {
            guard let attribute = modelIO.attributes[safe: index] as? MDLVertexAttribute else {
                throw PLYError.invalidValue(name)
            }
            attribute.name = name
        }
        try self.init(modelIO, bufferIndex: bufferIndex, names: names)
    }

    // The low 16 bits of an MDLVertexFormat are the component count. The high bits are the component kind.
    // Packed formats set other low bits, so their count is not 1...4.
    static func propertyType(for format: MDLVertexFormat) -> (PLYReader.PropertyType, Int)? {
        let count = Int(format.rawValue & 0xFFFF)
        guard (1...4).contains(count) else {
            return nil
        }
        let kinds: [MDLVertexFormat: PLYReader.PropertyType] = [
            .charBits: .char, .charNormalizedBits: .char,
            .uCharBits: .uchar, .uCharNormalizedBits: .uchar,
            .shortBits: .short, .shortNormalizedBits: .short,
            .uShortBits: .ushort, .uShortNormalizedBits: .ushort,
            .intBits: .int, .uIntBits: .uint,
            .floatBits: .float
        ]
        let kind = format.rawValue & ~0xFFFF
        guard let type = kinds.first(where: { $0.key.rawValue == kind })?.value else {
            return nil
        }
        return (type, count)
    }
}

private extension NSMutableArray {
    subscript(safe index: Int) -> Any? {
        indices.contains(index) ? self[index] : nil
    }

    var indices: Range<Int> {
        0..<count
    }
}
#endif
