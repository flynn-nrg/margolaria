// ColorError.swift
//
// The errors ColorKit can throw, and the C++ string conversion it needs.
//
// Introduces (SWIFT): nothing new (see MXError.swift and CxxString.swift).

import CxxStdlib
import Foundation

/// Errors thrown by ColorKit.
public enum ColorError: Error, Sendable {
    /// The OCIO config could not be loaded.
    case configLoadFailed(String)
    /// No conversion between two colour spaces: one of them is unknown.
    case conversionFailed(String)
}

extension ColorError: LocalizedError {
    /// A message for the UI.
    public var errorDescription: String? {
        switch self {
        case .configLoadFailed(let message):
            return "The colour config could not be loaded: \(message)"
        case .conversionFailed(let message):
            return "The colour conversion failed: \(message)"
        }
    }
}

extension std.string {
    /// This C++ string as a Swift `String`.
    ///
    /// The same workaround as MXKit's `swiftString` (see CxxString.swift
    /// there), under another name: MXKit's is internal to MXKit, and two
    /// modules adding the same name to `std.string` would make it ambiguous
    /// in any file that imports both.
    var colorKitString: String {
        description
    }
}
