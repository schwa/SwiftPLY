import Foundation
import SwiftPLY

// These Swift runtime functions are not public API. They are the functions that `Mirror` and the standard library's
// `_forEachFieldWithKeyPath` use. `RuntimeFieldRecord` must match the runtime's `_FieldReflectionMetadata` layout.
@_silgen_name("swift_reflectionMirror_recursiveCount")
private func runtimeFieldCount(_ type: Any.Type) -> Int

@_silgen_name("swift_reflectionMirror_recursiveChildOffset")
private func runtimeFieldOffset(_ type: Any.Type, index: Int) -> Int

@_silgen_name("swift_reflectionMirror_recursiveChildMetadata")
private func runtimeFieldMetadata(_ type: Any.Type, index: Int, fieldMetadata: UnsafeMutablePointer<RuntimeFieldRecord>) -> Any.Type

private struct RuntimeFieldRecord {
    // The runtime always sets a name. Tuple fields without labels get ".0", ".1", and so on.
    var name = UnsafeRawPointer(("" as StaticString).utf8Start).assumingMemoryBound(to: CChar.self)
    var freeName: (@convention(c) (UnsafePointer<CChar>?) -> Void)?
    var isStrong = false
    var isVar = false
}

// Field type to (scalar type, lane count). Scalars and SIMD2/3/4 of each PLY scalar type.
private let supportedFieldTypes: [ObjectIdentifier: (PLYReader.PropertyType, Int)] = {
    var table: [ObjectIdentifier: (PLYReader.PropertyType, Int)] = [:]
    func add<S: SIMDScalar>(_: S.Type, _ type: PLYReader.PropertyType) {
        table[ObjectIdentifier(S.self)] = (type, 1)
        table[ObjectIdentifier(SIMD2<S>.self)] = (type, 2)
        table[ObjectIdentifier(SIMD3<S>.self)] = (type, 3)
        table[ObjectIdentifier(SIMD4<S>.self)] = (type, 4)
    }
    add(Int8.self, .char)
    add(UInt8.self, .uchar)
    add(Int16.self, .short)
    add(UInt16.self, .ushort)
    add(Int32.self, .int)
    add(UInt32.self, .uint)
    add(Float.self, .float)
    add(Double.self, .double)
    return table
}()

// Lets the reflection code find the element type and count of an `InlineArray` field from its metatype.
private protocol InlineArrayField {
    static var elementType: Any.Type { get }
    static var elementCount: Int { get }
}

extension InlineArray: InlineArrayField {
    static var elementType: Any.Type {
        Element.self
    }

    static var elementCount: Int {
        count
    }
}

// Scalar type and lane count of a field type. An InlineArray of a scalar type has one lane per element.
private func fieldLanes(of fieldType: Any.Type) -> (PLYReader.PropertyType, Int)? {
    if let lanes = supportedFieldTypes[ObjectIdentifier(fieldType)] {
        return lanes
    }
    if let array = fieldType as? any InlineArrayField.Type,
       case (let type, 1)? = supportedFieldTypes[ObjectIdentifier(array.elementType)] {
        return (type, array.elementCount)
    }
    return nil
}

public extension PLYStructureDefinition {
    /// Makes a definition from the stored fields of `T`.
    ///
    /// Each field must be a PLY scalar type, SIMD2/3/4 of one, or an `InlineArray` of one. An `InlineArray` field
    /// `f` with `n` elements maps to `f_0` … `f_(n-1)`, so `var f_rest: InlineArray<45, Float>` reads a splat file's
    /// `f_rest_0` … `f_rest_44`. Field names map to property names with
    /// `defaultPropertyNames(field:count:)`.
    ///
    /// A field whose type is another struct adds that struct's fields, with their own names. For example,
    /// `var color: RGBA` where `RGBA` has `red green blue alpha` maps to `red green blue alpha`. Two nested fields
    /// with the same property name throw when the definition is used.
    ///
    /// `names` replaces the property names for a field. Use a dotted path for a nested field, for example
    /// `["color.red": ["r"]]`.
    init<T: BitwiseCopyable>(for _: T.Type, names: [String: [String]] = [:]) throws {
        self.init(stride: MemoryLayout<T>.stride)
        try appendFields(of: T.self, offset: 0, path: "", names: names)
        guard !fields.isEmpty else {
            throw PLYError.invalidValue(String(describing: T.self))
        }
    }

    // `path` is the dotted path of the struct that `type` is the type of, or empty for the top-level type.
    private mutating func appendFields(of type: Any.Type, offset: Int, path: String, names: [String: [String]]) throws {
        for index in 0..<runtimeFieldCount(type) {
            var record = RuntimeFieldRecord()
            let fieldType = runtimeFieldMetadata(type, index: index, fieldMetadata: &record)
            let fieldName = String(cString: record.name)
            record.freeName?(record.name)
            let fieldPath = path.isEmpty ? fieldName : "\(path).\(fieldName)"
            let fieldOffset = offset + runtimeFieldOffset(type, index: index)

            if let (scalarType, count) = fieldLanes(of: fieldType) {
                try append(fieldName, type: scalarType, offset: fieldOffset, count: count, propertyNames: names[fieldPath, default: []])
                continue
            }
            guard isNestedStruct(fieldType) else {
                throw PLYError.invalidValue(fieldPath)
            }
            try appendFields(of: fieldType, offset: fieldOffset, path: fieldPath, names: names)
        }
    }
}

// A struct with stored fields. Standard library types such as Bool, Int, SIMD, and InlineArray store their value in
// a field whose name starts with an underscore, so they do not count.
private func isNestedStruct(_ type: Any.Type) -> Bool {
    guard runtimeFieldCount(type) > 0 else {
        return false
    }
    var record = RuntimeFieldRecord()
    _ = runtimeFieldMetadata(type, index: 0, fieldMetadata: &record)
    let firstFieldName = String(cString: record.name)
    record.freeName?(record.name)
    return !firstFieldName.hasPrefix("_")
}

public extension PLYReader.Element {
    /// Makes an element with one scalar property for each scalar (and SIMD lane) of `T`.
    init<T: BitwiseCopyable>(name: String, count: Int, fieldsOf _: T.Type, names: [String: [String]] = [:]) throws {
        try self.init(name: name, count: count, definition: PLYStructureDefinition(for: T.self, names: names))
    }
}

public extension PLYReader {
    /// Reads the records of `element` into `buffer`. See `PLYStructureDefinition.init(for:names:)` for the field mapping.
    func read<T: BitwiseCopyable>(element: Element, into buffer: UnsafeMutableBufferPointer<T>, names: [String: [String]] = [:]) throws -> Int {
        try read(element: element, into: UnsafeMutableRawBufferPointer(buffer), definition: PLYStructureDefinition(for: T.self, names: names))
    }

    /// Reads the records of `element`, or of the first element if `element` is nil, as an array of `T`.
    func read<T: BitwiseCopyable>(_: T.Type = T.self, element: Element? = nil, names: [String: [String]] = [:]) throws -> [T] {
        guard let selected = element ?? primaryElement else {
            throw PLYError.noElements
        }
        return try [T](unsafeUninitializedCapacity: maximumRecordCount(of: selected)) { buffer, initializedCount in
            UnsafeMutableRawBufferPointer(buffer).initializeMemory(as: UInt8.self, repeating: 0)
            initializedCount = try read(element: selected, into: buffer, names: names)
        }
    }
}

public extension PLYWriter {
    /// Writes one record for each value of `records`. See `PLYStructureDefinition.init(for:names:)` for the field mapping.
    mutating func write<T: BitwiseCopyable>(_ records: UnsafeBufferPointer<T>, names: [String: [String]] = [:]) throws {
        try write(UnsafeRawBufferPointer(records), definition: PLYStructureDefinition(for: T.self, names: names))
    }

    mutating func write<T: BitwiseCopyable>(_ records: [T], names: [String: [String]] = [:]) throws {
        try records.withUnsafeBufferPointer { try write($0, names: names) }
    }
}
