// MXError.swift
//
// The errors MXKit can throw.
//
// Introduces (SWIFT): `enum` with associated values, the `Error` protocol,
// `Sendable`, computed properties, `switch` pattern matching, string
// interpolation.

// For `LocalizedError`, at the end of the file.
import Foundation

/// Errors thrown by MXKit.
///
/// SWIFT: A Swift `enum` is much more than a C enum. Each `case` can carry its
/// own data, called *associated values*: `.parseFailed("line 3: ...")` holds a
/// String, `.libraryNotFound` holds nothing. It is a tagged union, like
/// `std::variant`, but with names, and the compiler checks every `switch`
/// covers all cases.
///
/// SWIFT: `: Error` declares that this type conforms to the `Error` protocol.
/// A protocol is a set of requirements, like a Go interface or an ObjC
/// @protocol. `Error` has no requirements; conforming to it just marks the type
/// as something you can `throw`. Unlike Go, errors are not returned as an
/// extra value. A function marked `throws` either returns normally or throws,
/// and the caller must acknowledge that with `try` (see MXDocument.swift).
///
/// SWIFT: `Sendable` means "safe to pass between threads/concurrent tasks".
/// The compiler checks it: an enum is Sendable if all its associated values
/// are, and String is. Swift 6 requires errors to be Sendable in many places,
/// because errors often travel from a background task to the UI.
public enum MXError: Error, Sendable {
    /// The MaterialX data libraries (stdlib, pbrlib, ...) could not be located
    /// inside the app or test bundle.
    case libraryNotFound

    /// The data libraries were found but loading them failed.
    case libraryLoadFailed(String)

    /// The document's XML could not be parsed.
    case parseFailed(String)

    /// The document could not be serialised back to XML.
    case writeFailed

    /// MaterialX could not generate a shader for an element.
    case shaderGenerationFailed(String)
    /// There is no element (of the expected kind) at a path.
    case notFound(String)
    /// An edit was refused: the message says why (an included element, a
    /// type mismatch, a loop, an invalid name, ...).
    case editRefused(String)
}

// SWIFT: An `extension` adds members to an existing type, here our own enum,
// though it works on any type, including Apple's and C++ ones. It is the Swift
// version of an Objective-C category. Extensions are also used, as here, just
// to group related code. This one adds conformance to a protocol from the
// standard library.
extension MXError: CustomStringConvertible {
    /// A human-readable message, used by `print(error)` and in the UI.
    ///
    /// SWIFT: This is a *computed property*: it has no storage, and the code in
    /// braces runs every time it is read, like a getter method in ObjC.
    /// `CustomStringConvertible` requires exactly this one property.
    public var description: String {
        // SWIFT: `switch` on an enum must be exhaustive: remove a case below
        // and the compiler refuses to build. There is no fall-through between
        // cases, so no `break` is needed.
        switch self {
        case .libraryNotFound:
            return "MaterialX data libraries not found in the application bundle."

        // SWIFT: `let message` binds the associated value to a new constant,
        // so the case body can use it.
        case .libraryLoadFailed(let message):
            // SWIFT: "\(expr)" is string interpolation. Any expression can go
            // inside the parentheses; there are no printf-style format codes.
            return "Could not load MaterialX data libraries: \(message)"

        case .parseFailed(let message):
            return "Could not read MaterialX document: \(message)"

        case .writeFailed:
            return "Could not write MaterialX document."

        case .shaderGenerationFailed(let message):
            return "Could not generate a shader: \(message)"
        case .notFound(let message):
            return message
        case .editRefused(let message):
            return message
        }
    }
}

// SWIFT: `LocalizedError` is the protocol AppKit and SwiftUI use to get a
// user-facing message from an error. Without it, an alert would show a
// generic "The operation couldn't be completed (MXKit.MXError error 2.)".
extension MXError: LocalizedError {
    /// The message shown in alerts, such as NSDocument's "could not be opened".
    public var errorDescription: String? {
        description
    }
}
