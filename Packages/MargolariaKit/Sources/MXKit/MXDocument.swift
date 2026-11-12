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
    /// The element's name, unique among its siblings.
    public let name: String
    /// The XML tag, such as "surfacematerial", "nodegraph" or "open_pbr_surface".
    public let category: String
    /// The `type` attribute, such as "material" or "surfaceshader". Empty if untyped.
    public let type: String
    /// Number of direct children (inputs, outputs, nested nodes).
    public let childCount: Int
    /// The path from the document root, such as "NG_copper/grain". The same
    /// as `name` for top-level elements.
    public let path: String

    /// Required by `Identifiable`. The path is unique in the whole document.
    ///
    /// SWIFT: A computed property again (no storage, see MXError.swift). For a
    /// one-line getter, the `return` keyword can be left out.
    public var id: String { path }
}

// SWIFT: An extension in the same file, adding an initializer. Keeping it out
// of the struct's body means the struct still gets its automatic memberwise
// initializer (`MXElementSummary(name:category:...)`); defining any `init`
// inside the body would remove it.
extension MXElementSummary {
    /// Converts the bridge's C++ struct.
    init(_ element: mxbridge.ElementSummary) {
        self.init(name: element.name.swiftString,
                  category: element.category.swiftString,
                  type: element.type.swiftString,
                  childCount: Int(element.childCount),
                  path: element.path.swiftString)
    }
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
/// A document's preview text with a material that shows one element on its
/// own (``MXDocument/soloPreview(for:)``).
public struct MXSoloPreview: Hashable, Sendable {
    /// MaterialX XML, self-contained like the preview text.
    public let xml: String
    /// The material to bind: the one added, or the element if it is a
    /// material itself.
    public let materialName: String
    /// The MaterialX type of what is shown, such as "float" or
    /// "surfaceshader".
    public let outputType: String
}

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
    ///
    /// `package` rather than `private`, so the edits in MXEdit.swift,
    /// another file of this module, can use it, and so can ScriptKit, which
    /// hands the document to Python (M6). The app still can't: it only sees
    /// `public` members.
    ///
    /// SWIFT: `package` is the access level between `internal` (this module
    /// only) and `public` (anyone who imports it): every module of the same
    /// Swift package (MargolariaKit) sees it, nothing outside does.
    package var handle: mxbridge.Document

    /// The file the document was read from, or nil if it came from a string.
    /// Relative texture paths and xi:includes are resolved against its folder.
    public let fileURL: URL?

    /// The MaterialX version written in the file (the root's `version`
    /// attribute), before MaterialX upgraded the document in memory. Nil
    /// if the document didn't come from a file. When it differs from
    /// ``documentVersion``, saving writes the newer version.
    public let fileVersion: String?

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
        self.fileURL = nil
        self.fileVersion = nil
    }

    /// Wraps a handle that was loaded some other way (`read(from:)`,
    /// `copy()`).
    ///
    /// SWIFT: Swift lets a class have several initializers, distinguished
    /// by their labels. This one is `internal`: other modules of the
    /// package use `sharingFile(with:)`, as Xcode's Release builds don't
    /// let them see a `package init` (M6e).
    init(handle: mxbridge.Document, fileURL: URL?, fileVersion: String?) {
        self.handle = handle
        self.fileURL = fileURL
        self.fileVersion = fileVersion
    }

    /// A document wrapping `handle`, from the same file as this one (its
    /// `fileURL` and `fileVersion`): ScriptKit wraps the copies a script's
    /// undo steps keep with it (M6b).
    package func sharingFile(with handle: mxbridge.Document) -> MXDocument {
        MXDocument(handle: handle, fileURL: fileURL, fileVersion: fileVersion)
    }

    /// Reads a .mtlx file from disk.
    ///
    /// Reading from the file, rather than from its contents, lets MaterialX
    /// follow `xi:include` elements, and records where every element came
    /// from, so relative texture paths can be resolved (``MXPort/fileURL``).
    ///
    /// SWIFT: `static func ... -> MXDocument` instead of a second public
    /// `init`, to make the file read visible at the call site:
    /// `MXDocument.read(from: url)`.
    public static func read(from url: URL) throws -> MXDocument {
        var errorMessage = std.string()
        let document = mxbridge.Document.readFromFile(std.string(url.path(percentEncoded: false)), &errorMessage)
        guard document.isLoaded() else {
            throw MXError.parseFailed(errorMessage.swiftString)
        }
        return MXDocument(handle: document, fileURL: url, fileVersion: Self.versionWritten(in: url))
    }

    /// The `version` attribute of the root element as written in the file,
    /// read straight from the text (MaterialX's own reading upgrades it).
    private static func versionWritten(in url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let match = text.firstMatch(of: #/<materialx\b[^>]*\bversion\s*=\s*"([^"]*)"/#) else {
            return nil
        }
        return String(match.1)
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

    /// The document as XML for a renderer that reads it from memory, such
    /// as the viewport (M2c): included files written inline, and texture
    /// paths made absolute, so the text means the same wherever it is read.
    /// Not for saving: the file would lose its includes and relative paths.
    ///
    /// - Throws: ``MXError/writeFailed`` if MaterialX could not serialise it.
    public func previewXMLString() throws -> String {
        let xml = handle.writeForPreview().swiftString
        guard !xml.isEmpty else {
            throw MXError.writeFailed
        }
        return xml
    }

    /// The preview text (``previewXMLString()``) for Storm, the viewport's
    /// renderer: nodegraphs Storm would draw wrong are ungrouped (their
    /// inputs read nodes, nodes other than shaders read them, or they hold
    /// a shader: OpenUSD's MaterialX reader loses those connections). The
    /// materials compute the same; only the paths of the nodes in those
    /// graphs differ, so swatches, which draw nodes by path, use the
    /// preview text.
    ///
    /// - Throws: ``MXError/writeFailed`` if MaterialX could not serialise it.
    public func viewportXMLString() throws -> String {
        let xml = handle.writeForViewport().swiftString
        guard !xml.isEmpty else {
            throw MXError.writeFailed
        }
        return xml
    }

    /// The viewport's text (``viewportXMLString()``) for USD export (M5b):
    /// also every node whose definition the document makes, or includes
    /// from a library file, becomes the definition's nodes, and the
    /// definitions are left out. A USD file has no definitions of its own:
    /// without this, OpenUSD's MaterialX reader would make the USD file
    /// depend on the `.mtlx` it was read from (spike M5a). The materials
    /// compute the same.
    ///
    /// - Throws: ``MXError/writeFailed`` if MaterialX could not serialise it.
    public func usdXMLString() throws -> String {
        let xml = handle.writeForUSD().swiftString
        guard !xml.isEmpty else {
            throw MXError.writeFailed
        }
        return xml
    }

    /// The USD export text (``usdXMLString()``) for USDZ export (M5c): also,
    /// an image node reading a greyscale file as a colour reads it as a
    /// float, converted to a colour. The same numbers, but Reality Composer
    /// Pro reads the colour version as red (spike M5a).
    ///
    /// - Throws: ``MXError/writeFailed`` if MaterialX could not serialise it.
    public func usdzXMLString() throws -> String {
        let xml = handle.writeForUSDZ().swiftString
        guard !xml.isEmpty else {
            throw MXError.writeFailed
        }
        return xml
    }

    /// One sentence per material that Quick Look and Reality Composer Pro
    /// won't draw from its graph, because its surface shader is one
    /// RealityKit doesn't know (anything but standard_surface,
    /// open_pbr_surface and UsdPreviewSurface): they draw it plain grey,
    /// or magenta. For Export as USDZ… to warn about.
    ///
    /// SWIFT: `map` over a C++ vector: Swift sees `std::vector` as a
    /// collection, so the usual collection methods work on it.
    public func quickLookIssues() -> [String] {
        handle.quickLookIssues().map { $0.swiftString }
    }

    /// The viewport's text (``viewportXMLString()``) with a material added
    /// that shows the element at `path` on its own, for the viewport's
    /// solo preview (M3d). The document itself isn't changed.
    ///
    /// - Throws: ``MXError/notFound`` if the element can't be shown alone:
    ///   it doesn't exist, has no output a sphere can show (a string, a
    ///   matrix), or sits in a nodegraph inside another.
    public func soloPreview(for path: String) throws -> MXSoloPreview {
        var solo = mxbridge.SoloPreview()
        var errorMessage = std.string()
        guard handle.writeSoloPreview(std.string(path), &solo, &errorMessage), !solo.xml.empty() else {
            throw MXError.notFound(errorMessage.swiftString)
        }
        return MXSoloPreview(xml: solo.xml.swiftString, materialName: solo.materialName.swiftString,
                             outputType: solo.outputType.swiftString)
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
        hasDataLibrary = true
    }

    /// True once ``setDataLibrary(_:)`` has been called. Without a library no
    /// nodedef can be found, so checks that depend on nodedefs are skipped.
    ///
    /// SWIFT: `public internal(set)`: readable by everyone, settable only
    /// inside MXKit (`copy()` in MXEdit.swift sets it). `private(set)` would
    /// mean "this file only": Swift's `private` is per file, not per type.
    public internal(set) var hasDataLibrary: Bool = false

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
            result.append(MXElementSummary(element))
        }
        return result
    }

    /// Every element a shader can be generated for (see ``generateMSL(for:library:)``):
    /// top-level nodes and materials, and the nodes and outputs inside nodegraphs.
    public var shadeableElements: [MXElementSummary] {
        var result: [MXElementSummary] = []
        for element in handle.shadeableElements() {
            result.append(MXElementSummary(element))
        }
        return result
    }

    /// Every problem MaterialX's validation finds, each attached to the
    /// element it is about. Empty when the document is valid. Call
    /// ``setDataLibrary(_:)`` first.
    ///
    /// ``validate()`` returns the same problems as plain lines; this is what
    /// the Issues panel uses, so that clicking an issue can select its node.
    public func validationIssues() -> [MXIssue] {
        var issues: [MXIssue] = []
        for issue in handle.validationIssues() {
            issues.append(MXIssue(elementPath: issue.elementPath.swiftString,
                                  message: issue.message.swiftString,
                                  severity: .error,
                                  source: .materialX))
        }
        return issues
    }

    /// Every problem in the document: MaterialX's validation
    /// (``validationIssues()``) followed by Margolaria's own checks
    /// (``MXLint``). Call ``setDataLibrary(_:)`` first.
    public func issues() -> [MXIssue] {
        validationIssues() + MXLint.check(self)
    }

    /// One level of the graph: the document root for "" (the default), or
    /// the nodegraph at `path`. Call ``setDataLibrary(_:)`` first, so nodes
    /// get their nodedef's inputs and outputs.
    ///
    /// - Throws: ``MXError/notFound(_:)`` if there is no nodegraph at `path`.
    ///
    /// SWIFT: `path: String = ""` is a *default argument*: callers may leave
    /// it out and write `document.graph()`.
    public func graph(at path: String = "") throws -> MXGraph {
        var info = mxbridge.GraphInfo()
        var errorMessage = std.string()
        guard handle.graph(std.string(path), &info, &errorMessage) else {
            throw MXError.notFound(errorMessage.swiftString)
        }
        return MXGraph(info)
    }

    /// Every nodegraph in the document, in file order, at any depth.
    public var nodeGraphs: [MXElementSummary] {
        handle.nodeGraphs().map { MXElementSummary($0) }
    }

    /// The document's MaterialX version, such as "1.39".
    public var documentVersion: String {
        handle.documentVersion().swiftString
    }

    /// Generates a Metal shader for the element at `path`, such as
    /// "NG_copper/grain" (a node in a nodegraph) or "M_BrushedCopper" (a
    /// material). `library` must be the one set with ``setDataLibrary(_:)``.
    ///
    /// - Throws: ``MXError/shaderGenerationFailed(_:)`` with MaterialX's message.
    public func generateMSL(for path: String, library: MXLibrary) throws -> MXGeneratedShader {
        // SWIFT: The C++ function fills in a struct passed by reference. In
        // Swift that is an `inout` argument: a `var`, passed with `&`.
        var shader = mxbridge.GeneratedShader()
        var errorMessage = std.string()
        guard handle.generateMsl(std.string(path), library.handle, &shader, &errorMessage) else {
            throw MXError.shaderGenerationFailed(errorMessage.swiftString)
        }
        return MXGeneratedShader(shader)
    }

    /// Generates `language`'s code for the element at `path`, as
    /// ``generateMSL(for:library:)`` does, to read or export (M5d).
    /// `library` must be the one set with ``setDataLibrary(_:)``.
    ///
    /// The shader computes in `colorSpace`: lin_rec709 (the default, as
    /// the swatches) or acescg; for any other space, lin_rec709. Colours
    /// and images in other spaces are converted to it, and the result is
    /// in it. ``MXShaderCode/colorSpace`` says which it is.
    ///
    /// - Throws: ``MXError/shaderGenerationFailed(_:)`` with MaterialX's
    ///   message, or, for ``MXShaderLanguage/oslNetwork``, if MaterialX's
    ///   library compiled for networks wasn't found.
    public func generateCode(for path: String, in language: MXShaderLanguage, library: MXLibrary,
                             colorSpace: String = MXWorkingSpace.documentDefault) throws -> MXShaderCode {
        var code = mxbridge.ShaderCode()
        var errorMessage = std.string()
        guard handle.generateCode(std.string(path), library.handle, language.bridgeValue, std.string(colorSpace),
                                  &code, &errorMessage) else {
            throw MXError.shaderGenerationFailed(errorMessage.swiftString)
        }
        return MXShaderCode(code, language: language)
    }

    /// The version of the MaterialX library Margolaria is linked against, such as "1.39.5".
    public static var libraryVersion: String {
        mxbridge.materialXVersion().swiftString
    }
}
