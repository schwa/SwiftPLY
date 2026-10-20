import Foundation

public enum PLYError: Error, Equatable, Sendable {
    case invalidEncoding
    case invalidHeader
    case unsupportedFormat(String)
    case missingEndHeader
    case noElements
    case formatNotSet
    case invalidData
    case invalidValue(String)
    case recordCountMismatch
}

extension PLYError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "The PLY file does not use a supported text encoding."
        case .invalidHeader:
            "The PLY header is not valid."
        case .unsupportedFormat(let format):
            "The PLY format \"\(format)\" is not supported."
        case .missingEndHeader:
            "The PLY header does not have an end_header line."
        case .noElements:
            "The PLY file does not declare an element."
        case .formatNotSet:
            "The PLY header does not declare a format."
        case .invalidData:
            "The PLY file contains data that is not valid."
        case .invalidValue(let property):
            "The value for the PLY property or element \"\(property)\" does not match the header."
        case .recordCountMismatch:
            "The number of records written does not match the PLY header."
        }
    }
}
