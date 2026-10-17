// MaterialXFileDocument.swift
//
// Connects SwiftUI's document system (open, save, autosave) to MXKit.
//
// Introduces (SWIFT): `ReferenceFileDocument`, `ObservableObject`, protocol
// requirements (`static var`, `required init`, `typealias`), extensions on
// Apple types, `try!`, raw strings, labelled tuples, `Data`, `FileWrapper`,
// `CocoaError`.

import SwiftUI
// SWIFT: UniformTypeIdentifiers is the framework behind `UTType`, Swift's
// name for UTIs, the identifiers macOS uses for file types.
import UniformTypeIdentifiers
import MXKit

// SWIFT: Extending Apple's `UTType` struct with a static property, so the rest
// of the code can write `.materialX` wherever a UTType is expected.
extension UTType {
    /// MaterialX documents (.mtlx). The identifier must match the
    /// UTImportedTypeDeclarations entry in App/Info.plist.
    static let materialX = UTType(importedAs: "org.materialx.mtlx", conformingTo: .xml)
}

/// One open .mtlx file, as SwiftUI's document system sees it.
///
/// SWIFT: SwiftUI offers two document protocols:
/// - `FileDocument` for value-type (struct) documents, copied on every change.
/// - `ReferenceFileDocument` for class documents, shared by reference.
/// A MaterialX document is a large shared object graph in C++ (MXDocument), so
/// it can't be a value. We use the reference form.
///
/// SWIFT: `ReferenceFileDocument` requires `ObservableObject`, the older
/// (Combine-based) way for SwiftUI views to observe an object. We'll need it
/// once edits exist; for this read-only skeleton nothing changes after loading.
///
/// SWIFT: Why `final class` and not `struct`, see MXLibrary.swift.
final class MaterialXFileDocument: ReferenceFileDocument {
    /// The value captured when the document is saved: the XML text.
    ///
    /// SWIFT: `typealias` gives a type a second name, like C's `typedef`.
    /// ReferenceFileDocument has an *associated type* named Snapshot, a type
    /// placeholder each conforming type fills in. Here, a String.
    ///
    /// Saving happens in two steps: `snapshot` runs on the main thread and
    /// captures the state; `fileWrapper` then writes it on a background thread.
    /// String is a value type and `Sendable`, so handing it to the background
    /// thread is safe. Handing over the MXDocument itself would not be.
    typealias Snapshot = String

    /// The file types this app can open. A requirement of the protocol.
    ///
    /// SWIFT: `static var` with only a getter: a computed type property.
    /// `[.materialX]` is an array with one element; the compiler infers that
    /// `.materialX` means `UTType.materialX` from the declared element type.
    static var readableContentTypes: [UTType] { [.materialX] }

    /// The parsed MaterialX document.
    let document: MXDocument

    /// The document's top-level elements, computed once when it is opened.
    let elements: [MXElementSummary]

    /// The XML text as MaterialX writes it (after upgrading and normalising).
    let xml: String

    /// The validation result, or `nil` if the data libraries failed to load.
    let validation: MXValidationResult?

    /// Creates a new, empty document (File > New).
    init() {
        // An empty MaterialX document always parses, so `try!` ("crash if
        // this throws") is safe here: the input is a constant we control.
        // Wherever input comes from outside, use `try` and handle the error.
        //
        // SWIFT: `#"..."#` is a *raw string*: backslashes and double quotes
        // inside it are literal, so the XML's quotes need no escaping.
        let empty = try! MXDocument(xml: #"<?xml version="1.0"?><materialx version="1.39" />"#)
        let info = Self.inspect(empty)
        self.document = empty
        self.elements = info.elements
        self.xml = info.xml
        self.validation = info.validation
    }

    /// Opens an existing document (File > Open, double-click in Finder).
    ///
    /// SWIFT: `required` means every subclass must also implement this
    /// initializer. The protocol demands it so it can create instances of
    /// whatever the concrete class is. Since our class is `final`, the keyword
    /// changes nothing in practice, but Swift still insists on it.
    ///
    /// SWIFT: `ReadConfiguration` is a typealias the protocol provides; it
    /// holds the file's contents as a `FileWrapper`.
    required init(configuration: ReadConfiguration) throws {
        // SWIFT: `regularFileContents` is `Data?`: nil if the file is a
        // directory. `Data` is Foundation's byte buffer (NSData).
        guard let data = configuration.file.regularFileContents else {
            // SWIFT: CocoaError is Foundation's standard error type. The
            // document system shows it to the user in a standard alert.
            throw CocoaError(.fileReadCorruptFile)
        }
        // Decode the bytes as UTF-8. Invalid byte sequences become U+FFFD
        // instead of failing; the XML parser will then report the problem.
        let xml = String(decoding: data, as: UTF8.self)
        let document = try MXDocument(xml: xml)
        let info = Self.inspect(document)
        self.document = document
        self.elements = info.elements
        self.xml = info.xml
        self.validation = info.validation
    }

    /// Captures the current state for saving. Called on the main thread.
    func snapshot(contentType: UTType) throws -> String {
        try document.xmlString()
    }

    /// Turns a snapshot into file contents. Called on a background thread.
    ///
    /// This method must not touch `document`: it runs in the background, and
    /// MXDocument may only be used from one thread (it is not `Sendable`).
    func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        // SWIFT: `Data(snapshot.utf8)` copies the string's UTF-8 bytes into a
        // byte buffer. `.utf8` is a view of the String as UTF-8 code units.
        FileWrapper(regularFileWithContents: Data(snapshot.utf8))
    }

    /// Computes what the window shows: element list, XML text, validation.
    ///
    /// SWIFT: Returns a *tuple*, an anonymous fixed group of values, like
    /// `std::tuple`, but its elements can have labels, so callers write
    /// `info.xml` instead of `std::get<1>(info)`. For anything used in more
    /// than one place, a named struct is usually clearer. `Self` (capital S)
    /// means "this type", here MaterialXFileDocument.
    private static func inspect(_ document: MXDocument) -> (elements: [MXElementSummary], xml: String, validation: MXValidationResult?) {
        let elements = document.topLevelElements
        // If writing fails, show the error text in place of the XML.
        // SWIFT: `(try? x) ?? y`: `try?` turns a thrown error into `nil`, and
        // `??` ("nil-coalescing") substitutes `y` when the left side is nil.
        let xml = (try? document.xmlString()) ?? "<!-- MaterialX could not write this document -->"

        // SWIFT: `switch` on the Result: `.success(let library)` matches the
        // success case and binds its value. Validation needs the libraries; if
        // they failed to load, there's no validation result.
        let validation: MXValidationResult?
        switch MXLibrary.bundled {
        case .success(let library):
            document.setDataLibrary(library)
            validation = document.validate()
        case .failure:
            validation = nil
        }
        return (elements: elements, xml: xml, validation: validation)
    }
}
