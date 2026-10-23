// MaterialXDocument.swift
//
// One open .mtlx file: an AppKit NSDocument that reads and writes it with
// MXKit, and shows it in a window whose contents are SwiftUI (ContentView).
//
// NSDocument provides the standard Mac document behaviour: Open and Open
// Recent, autosave, versions and Revert To, Duplicate, Rename, Move To, the
// "edited" dot in the close button, and asking to save on close. We
// override only reading, writing and window creation.
//
// Introduces (SWIFT): subclassing an AppKit class (`NSDocument`) and
// overriding its methods, `override class var`, `@Observable` on an AppKit
// subclass, `NSHostingController` (SwiftUI inside AppKit), `LocalizedError`.

import AppKit
import MXKit
import Observation
import SwiftUI

/// One open MaterialX document.
///
/// The class name is registered in Info.plist (`NSDocumentClass`), which is
/// how NSDocumentController knows to create a MaterialXDocument when the
/// user opens a .mtlx file.
///
/// SWIFT: `@Observable` (see GraphCanvasController.swift) makes SwiftUI
/// views that read `elements`, `xml` or `issues` update when they change.
/// They change when the file is read again: File > Revert To, or when
/// another app changes the file on disk.
@Observable
final class MaterialXDocument: NSDocument {
    /// The parsed document. Starts empty; replaced when a file is read.
    ///
    /// SWIFT: `private(set)`: only this class replaces it. The views read it.
    private(set) var content: MXDocument = MaterialXDocument.emptyDocument()

    /// The document's top-level elements, for the sidebar.
    private(set) var elements: [MXElementSummary] = []

    /// The XML text as MaterialX writes it (after upgrading and normalising).
    private(set) var xml: String = ""

    /// Problems found by validation and Margolaria's checks. Empty when the
    /// document is fine, or when the data libraries could not be loaded
    /// (see `libraryLoaded`).
    private(set) var issues: [MXIssue] = []

    /// False if the MaterialX data libraries failed to load. Then nothing can
    /// be validated, and the UI says so instead of claiming the document is valid.
    private(set) var libraryLoaded: Bool = false

    /// Creates a new, untitled document (File > New).
    ///
    /// SWIFT: `override init()`: NSDocument's own initializer is replaced,
    /// and `super.init()` must be called, after this class's properties have
    /// their values (here they all have defaults above).
    override init() {
        super.init()
        load(content)
    }

    // MARK: NSDocument configuration

    /// Saves changes automatically, without asking, as modern Mac apps do.
    /// File > Revert To brings back earlier versions.
    ///
    /// SWIFT: `override class var`: overrides a *class property*, a property
    /// of the type rather than of an instance, which subclasses can override
    /// (unlike `static`). AppKit asks the class, not an instance.
    override class var autosavesInPlace: Bool {
        true
    }

    // MARK: Reading and writing

    /// Reads the file at `url` (File > Open, Open Recent, Revert, a change
    /// on disk).
    ///
    /// NSDocument offers several read methods; this is the one that gets the
    /// file's URL, which MXKit needs to resolve `xi:include` and textures.
    /// AppKit calls it on the main thread (the default for NSDocument).
    ///
    /// - Throws: MXKit's error when the file can't be parsed. NSDocument
    ///   shows it to the user in a standard alert.
    override func read(from url: URL, ofType typeName: String) throws {
        let document: MXDocument = try MXDocument.read(from: url)
        load(document)
    }

    /// The file's contents when saving: MaterialX's XML.
    ///
    /// Until editing arrives (M2) the document never changes, so AppKit only
    /// calls this for Duplicate and Save As.
    ///
    /// SWIFT: `Data(string.utf8)` copies the string's UTF-8 bytes into
    /// Foundation's byte buffer (NSData). `.utf8` is a view of the String as
    /// UTF-8 code units, with no copy of its own.
    override func data(ofType typeName: String) throws -> Data {
        Data(try content.xmlString().utf8)
    }

    // MARK: Windows

    /// Creates the document's window. AppKit calls this once, after reading.
    override func makeWindowControllers() {
        // SWIFT: `NSHostingController` is an AppKit view controller whose
        // view is a SwiftUI view: the bridge from AppKit to SwiftUI.
        // (`NSViewRepresentable`, in ViewportKit, goes the other way.)
        let hosting = NSHostingController(rootView: ContentView(document: self))
        // Let the SwiftUI `.toolbar { }` in ContentView fill the window's
        // toolbar. The title stays NSDocument's (the file name, with the
        // "Edited" and version menus).
        hosting.sceneBridgingOptions = [.toolbars]

        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 1100, height: 700))
        // The same window style DocumentGroup used: the toolbar sits in the
        // title bar, and the sidebar runs to the top of the window.
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified

        addWindowController(NSWindowController(window: window))
    }

    // MARK: Private

    /// Replaces the document's contents and recomputes what the window shows.
    private func load(_ document: MXDocument) {
        switch MXLibrary.bundled {
        case .success(let library):
            document.setDataLibrary(library)
            issues = document.issues()
            libraryLoaded = true
        case .failure:
            issues = []
            libraryLoaded = false
        }
        content = document
        elements = document.topLevelElements
        // If writing fails, show the error text in place of the XML.
        // SWIFT: `(try? x) ?? y`: `try?` turns a thrown error into `nil`, and
        // `??` ("nil-coalescing") substitutes `y` when the left side is nil.
        xml = (try? document.xmlString()) ?? "<!-- MaterialX could not write this document -->"
    }

    /// An empty MaterialX document, for File > New.
    ///
    /// An empty document always parses, so `try!` ("crash if this throws")
    /// is safe: the input is a constant. Wherever input comes from outside,
    /// use `try` and handle the error.
    ///
    /// SWIFT: `#"..."#` is a *raw string*: backslashes and double quotes
    /// inside it are literal, so the XML's quotes need no escaping.
    private static func emptyDocument() -> MXDocument {
        try! MXDocument(xml: #"<?xml version="1.0"?><materialx version="1.39" />"#)
    }
}
