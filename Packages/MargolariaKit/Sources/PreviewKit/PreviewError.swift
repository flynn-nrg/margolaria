// PreviewError.swift
//
// The errors PreviewKit can throw.

/// Errors thrown while preparing or drawing a swatch.
public enum PreviewError: Error, Sendable, CustomStringConvertible {
    /// A Metal object could not be created (device, buffer, texture, ...).
    case metal(String)
    /// The generated MSL failed to compile. Holds the compiler's message.
    case compileFailed(String)
    /// The shader needs something the swatch renderer doesn't provide yet,
    /// such as vertex colours.
    case unsupported(String)
    /// A resource shipped with OpenUSD (the environment map) is missing.
    case resourceNotFound(String)

    public var description: String {
        switch self {
        case .metal(let message):
            return "Metal error: \(message)"
        case .compileFailed(let message):
            return "The generated shader did not compile: \(message)"
        case .unsupported(let what):
            return "Not supported by swatch previews yet: \(what)"
        case .resourceNotFound(let what):
            return "Resource not found: \(what)"
        }
    }
}
