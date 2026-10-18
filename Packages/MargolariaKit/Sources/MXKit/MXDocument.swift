// MXDocument.swift
//
// A MaterialX document (the contents of one .mtlx file), as a Swift class.
//
// Introduces (SWIFT): structs with protocol conformances (`Identifiable`,
// `Hashable`), enums used as results, arrays and `append`, `.map` with a
// closure, a convenience static constructor.

import Foundation
import MXBridge

/// One top-level element of a document (a material, a nodegraph, a node, ...),
/// summarised for display.
///
/// SWIFT: A `struct`, so a plain value. Copying one copies all four strings and
/// the count, and two copies never affect each other. That suits small data
/// that travels to the UI.
///
/// SWIFT: The conformances after the colon each add abilities:
/// - `Identifiable`: has an `id` property. SwiftUI's `List` uses it to tell
///   rows apart when the data changes.
/// - `Hashable`: can be compared with `==` and used in a `Set` or as a
///   `Dictionary` key. For a struct whose properties are all Hashable, the
///   compiler writes the `==` and `hash(into:)` implementations for us.
/// - `Sendable`: safe to pass between threads (see MXError.swift).
public struct MXElementSummary: Identifiable, Hashable, Sendable {
    /// The element's name, unique among the top-level elements, so it can
    /// serve as the identifier.
    public let name: String
    /// The XML tag, such as "surfacematerial", "nodegraph" or "open_pbr_surface".
    public let category: String
    /// The `type` attribute, such as "material" or "surfaceshader". Empty if untyped.
    public let type: String
    /// Number of direct children (inputs, outputs, nested nodes).
    public let childCount: Int

    /// Required by `Identifiable`.
    ///
    /// SWIFT: A computed property again (no storage, see MXError.swift). For a
    /// one-line getter, the `return` keyword can be left out.
    public var id: String { name }
}

/// The result of ``MXDocument/validate()``.
///
/// SWIFT: An enum with associated values used as a result type. A caller can't
/// get at the messages without first checking which case it has, so it can't
/// forget to look at the outcome. Compare returning `(bool, std::string)` in
/// C++, where the string can be read even when it's meaningless.
public enum MXValidationResult: Equatable, Sendable {
    /// No problems found.
    case valid
    /// One message per problem, as reported by MaterialX.
    case invalid([String])
}

/// A MaterialX document.
///
/// A class rather than a struct because the C++ document behind it is shared:
/// the C++ handle copies a `std::shared_ptr`, so a Swift struct holding it would
/// look like a value but behave like a reference. Using a class makes the
/// sharing visible in the type.
///
/// Not `Sendable`: the document will be edited, and mutable shared state must
/// stay on one thread. The compiler enforces that: it rejects code that would
/// pass an MXDocument to another thread.
public final class MXDocument {
    /// The C++ handle; see MXBridge.h.
    ///
    /// SWIFT: `var`, not `let`, because of how C++ methods are imported. Swift
    /// imports a C++ class as a struct, a value type, and only *mutating*
    /// methods may change a struct. So a non-`const` C++ method, such as
    /// `setDataLibrary`, becomes a `mutating` Swift method, while `const`
    /// methods like `validate` don't. Calling a mutating method on a `let`
    /// constant is a compile error ("cannot use mutating member on immutable
    /// value"), so the handle must be a variable. This is how C++ `const`
    /// correctness shows up in Swift.
    private var handle: mxbridge.Document

    /// Parses MaterialX XML.
    ///
    /// Older documents (for example v1.38) are upgraded to the current
    /// MaterialX version in memory, by MaterialX itself.
    ///
    /// - Throws: ``MXError/parseFailed(_:)`` with the parser's message.
    ///
    /// SWIFT: The argument label is `xml`, so callers write `MXDocument(xml: text)`.
    public init(xml: String) throws {
        var errorMessage = std.string()
        let document = mxbridge.Document.readFromXmlString(std.string(xml), &errorMessage)
        guard document.isLoaded() else {
            throw MXError.parseFailed(errorMessage.swiftString)
        }
        self.handle = document
    }

    /// Reads a .mtlx file from disk.
    ///
    /// SWIFT: `static func ... -> MXDocument` instead of a second `init`, to
    /// make the file read visible at the call site: `MXDocument.read(from: url)`.
    /// `String(contentsOf:encoding:)` comes from Foundation and throws if the
    /// file can't be read. `try` passes that error on to our caller unchanged.
    public static func read(from url: URL) throws -> MXDocument {
        let xml = try String(contentsOf: url, encoding: .utf8)
        return try MXDocument(xml: xml)
    }

    /// The document as MaterialX XML, ready to save.
    ///
    /// - Throws: ``MXError/writeFailed`` if MaterialX could not serialise it.
    public func xmlString() throws -> String {
        let xml = handle.writeToXmlString().swiftString
        // SWIFT: `isEmpty` is a property on every collection, String included.
        // Prefer it over `count == 0`: for String, `count` has to walk the
        // whole string (it counts characters), while `isEmpty` doesn't.
        guard !xml.isEmpty else {
            throw MXError.writeFailed
        }
        return xml
    }

    /// Makes `library`'s node definitions visible to this document.
    ///
    /// Call this before ``validate()``; without it, every node is reported as
    /// having no matching nodedef.
    ///
    /// SWIFT: The `_` before `library` removes the argument label, so callers
    /// write `document.setDataLibrary(library)` rather than
    /// `document.setDataLibrary(library: library)`. Use it when the function
    /// name already says what the argument is.
    public func setDataLibrary(_ library: MXLibrary) {
        handle.setDataLibrary(library.handle)
    }

    /// Runs MaterialX's validation over the whole document.
    public func validate() -> MXValidationResult {
        var message = std.string()
        if handle.validate(&message) {
            return .valid
        }
        // MaterialX returns all problems in one string, one per line. Split it
        // into separate messages and drop empty lines.
        //
        // SWIFT: `split(separator:)` returns an array of `Substring`s, which
        // are views into the original string (no copy). `.map { String($0) }`
        // makes a real String from each. `{ String($0) }` is a *closure* (an
        // anonymous function, like an ObjC block or C++ lambda), and `$0`
        // is shorthand for its first argument. The long form is:
        //     .map({ (line: Substring) -> String in return String(line) })
        let lines = message.swiftString
            .split(separator: "\n")
            .map { String($0) }
        return .invalid(lines)
    }

    /// The direct children of the root `<materialx>` element, in file order.
    public var topLevelElements: [MXElementSummary] {
        // SWIFT: `[MXElementSummary]` is shorthand for Array<MXElementSummary>.
        // Arrays are value types (copy-on-write: the copy is only made if one
        // of the two is changed, so passing arrays around is cheap).
        var result: [MXElementSummary] = []

        // SWIFT: The C++ `std::vector<ElementSummary>` is imported as a Swift
        // collection, so a normal for-in loop works. Each `element` is the
        // imported C++ struct `mxbridge.ElementSummary`, whose std::string
        // fields we convert to Swift Strings.
        for element in handle.topLevelElements() {
            result.append(MXElementSummary(
                name: element.name.swiftString,
                category: element.category.swiftString,
                type: element.type.swiftString,
                childCount: Int(element.childCount)
            ))
        }
        return result
    }

    /// The document's MaterialX version, such as "1.39".
    public var documentVersion: String {
        handle.documentVersion().swiftString
    }

    /// The version of the MaterialX library Margolaria is linked against, such as "1.39.5".
    public static var libraryVersion: String {
        mxbridge.materialXVersion().swiftString
    }
}
