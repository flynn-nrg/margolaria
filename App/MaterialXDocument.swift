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
// Editing (M2): every change goes through `edit(_:change:)`, which keeps a
// copy of the whole document first and registers it with NSDocument's undo
// manager. Undo puts the copy back; NSDocument then handles the "Edited"
// state, autosave and Revert To by itself (PLAN.md §8.1). A slider drag
// is many edits but one undo step (M2b, `continuing:`).
//
// Introduces (SWIFT): subclassing an AppKit class (`NSDocument`) and
// overriding its methods, `override class var`, `@Observable` on an AppKit
// subclass, `NSHostingController` (SwiftUI inside AppKit), `LocalizedError`,
// `UndoManager.registerUndo(withTarget:)`, `NSAlert` sheets, labelled
// tuples, `Optional.map`.

import AppKit
import MXKit
import Observation
import PreviewKit
import SwiftUI

/// One open MaterialX document.
///
/// The class name is registered in Info.plist (`NSDocumentClass`), which is
/// how NSDocumentController knows to create a MaterialXDocument when the
/// user opens a .mtlx file.
///
/// SWIFT: `@Observable` (see GraphCanvasController.swift) makes SwiftUI
/// views that read `elements`, `xml`, `issues` or `revision` update when
/// they change: after every edit, undo and redo, and when the file is read
/// again (File > Revert To, or another app changing it).
@Observable
final class MaterialXDocument: NSDocument {
    /// The parsed document. Starts empty; replaced when a file is read;
    /// changed in place by edits (`edit(_:change:)`), undo and redo.
    ///
    /// SWIFT: `private(set)`: only this class replaces it. The views read it.
    private(set) var content: MXDocument = MaterialXDocument.emptyDocument()

    /// Counts changes to `content`: edits, undos, redos and reads. Views
    /// that show the document rebuild when it changes.
    private(set) var revision: Int = 0


    /// True once the user agreed to save an upgraded document in the
    /// current MaterialX version (see `confirmUpgrade`).
    private var upgradeConfirmed: Bool = false

    /// True while the upgrade question is on screen. Edits that arrive
    /// meanwhile (a slider still moving) are dropped, not asked about again.
    @ObservationIgnored private var askingToUpgrade: Bool = false

    /// The continuous edit in progress, such as a slider drag: its key and
    /// when it last changed the document. Edits with the same key join its
    /// undo step (see `edit(_:continuing:change:)`).
    ///
    /// SWIFT: A *tuple* with labelled parts, `(key: String, time: Date)`,
    /// is a small anonymous struct; `continuation?.key` reads one part.
    /// `@ObservationIgnored`: no view shows it.
    @ObservationIgnored private var continuation: (key: String, time: Date)? = nil

    /// How long a continuous edit may pause and still be the same undo
    /// step. Colour wells never say when the user lets go, so a pause is
    /// how their drags end; sliders end theirs explicitly.
    private static let continuationPause: TimeInterval = 1.0

    /// The document's top-level elements, for the sidebar.
    private(set) var elements: [MXElementSummary] = []

    /// The XML text as MaterialX writes it (after upgrading and normalising).
    private(set) var xml: String = ""

    /// The document as the viewport reads it (M2c): self-contained, with
    /// includes inline and absolute texture paths (MXKit's
    /// `previewXMLString()`). Changes with every edit, so the viewport
    /// shows unsaved changes. Empty if MaterialX could not write it.
    private(set) var previewXML: String = ""

    /// The same for the viewport's renderer, Storm (MXKit's
    /// `viewportXMLString()`, M4a): nodegraphs Storm would draw wrong are
    /// ungrouped. The swatches draw nodes by path, so they use `previewXML`.
    private(set) var viewportXML: String = ""

    /// Problems found by validation and Margolaria's checks. Empty when the
    /// document is fine, or when the data libraries could not be loaded
    /// (see `libraryLoaded`).
    private(set) var issues: [MXIssue] = []

    /// The nodes this document can add (M2e): the data libraries' and the
    /// document's own nodedefs, for the Library tab, the canvas's node
    /// search and the inspector's Type menu.
    private(set) var catalog: MXNodeCatalog = MXNodeCatalog(definitions: [])

    /// The names of the document's own nodedefs when `catalog` was built.
    /// The catalog is rebuilt only when they change, not after every edit:
    /// building it reads all ~800 nodedefs, and a slider drag edits many
    /// times a second.
    @ObservationIgnored private var catalogKey: [String]? = nil

    /// False if the MaterialX data libraries failed to load. Then nothing can
    /// be validated, and the UI says so instead of claiming the document is valid.
    private(set) var libraryLoaded: Bool = false

    /// The canvas's swatches (M3c): kept here, with the document, so that
    /// every graph level shows the swatches already drawn, and the
    /// inspector can say why one failed. Nil if swatches can't be drawn
    /// (no Metal device, or MaterialX's libraries missing).
    ///
    /// SWIFT: `@ObservationIgnored`: the cache is observable itself; the
    /// reference to it never changes.
    @ObservationIgnored let swatches: SwatchCache? = SwatchService.shared.map { SwatchCache(service: $0) }

    /// True for a new document (File > New) until the user has picked
    /// what it starts from (ContentView's template sheet). Documents read
    /// from a file never ask.
    private(set) var isChoosingTemplate: Bool = false

    /// Creates a new, untitled document (File > New).
    ///
    /// AppKit also calls this before reading a file (Open, Duplicate,
    /// restoring an autosaved untitled document); `read(from:ofType:)`
    /// then clears `isChoosingTemplate` again.
    ///
    /// SWIFT: `override init()`: NSDocument's own initializer is replaced,
    /// and `super.init()` must be called, after this class's properties have
    /// their values (here they all have defaults above).
    override init() {
        super.init()
        load(content)
        isChoosingTemplate = true
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
    ///
    /// SWIFT: The SDK declares this method `nonisolated`, because a document
    /// class may opt into reading on a background thread
    /// (`canConcurrentlyReadDocuments`). This one doesn't, so AppKit calls it
    /// on the main thread, and `MainActor.assumeIsolated` says so to the
    /// compiler: the closure may then touch main-actor state, and it traps if
    /// it is ever run anywhere else.
    override func read(from url: URL, ofType typeName: String) throws {
        let document: MXDocument = try MXDocument.read(from: url)
        MainActor.assumeIsolated {
            load(document)
            upgradeConfirmed = false
            isChoosingTemplate = false
        }
    }

    /// The file's contents when saving: MaterialX's XML.
    ///
    /// With autosave, AppKit calls this shortly after each edit, and for
    /// Duplicate and Save As. Elements from `xi:include`d files are written
    /// back as the include, not copied in.
    ///
    /// SWIFT: `Data(string.utf8)` copies the string's UTF-8 bytes into
    /// Foundation's byte buffer (NSData). `.utf8` is a view of the String as
    /// UTF-8 code units, with no copy of its own.
    override func data(ofType typeName: String) throws -> Data {
        Data(try content.xmlString().utf8)
    }

    /// Starts the new document from `template` (the template sheet), in
    /// `workingSpace` (nil: none written, MaterialX's default). Not an
    /// edit: there is nothing to undo back to, and an untitled document no
    /// one changes further still closes without asking.
    func start(from template: MXDocumentTemplate, workingSpace: String? = nil) {
        isChoosingTemplate = false
        // An empty document without a working space is what there is already.
        if template == .empty && workingSpace == nil {
            return
        }
        // The templates are constants that the tests read, so this only
        // fails if one is broken; then the document stays empty.
        guard let document = try? template.makeDocument(workingSpace: workingSpace) else {
            return
        }
        load(document)
    }

    /// The template sheet's "Open…": the user wanted an existing file,
    /// not a new one. Closes this untitled document (nothing in it to
    /// lose) and shows the Open dialog.
    func openExistingInstead() {
        isChoosingTemplate = false
        close()
        // SWIFT: `Task { @MainActor in ... }` runs the closure on the main
        // thread *later*, after this button's action has returned and the
        // window has gone, like `dispatch_async(dispatch_get_main_queue())`.
        Task { @MainActor in
            NSDocumentController.shared.openDocument(nil)
        }
    }

    /// Starts saving a new document in `~/Documents/Margolaria/Materials`
    /// (M4c2), rather than wherever the last save dialog was (Save to
    /// Library's folder, for one). A document saved before keeps its folder.
    ///
    /// SWIFT/AppKit: NSDocument calls this with the Save panel before
    /// showing it; returning true lets it go ahead.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        if fileURL == nil, let materials = MXLibraryFolders.materials {
            savePanel.directoryURL = materials
        }
        return super.prepareSavePanel(savePanel)
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

    // MARK: Editing

    /// Changes the document, as one undoable step called `name` (shown as
    /// "Undo Move", "Undo Delete scale"). `change` makes the edits with
    /// MXKit; if it throws, the document is put back as it was and the
    /// error is shown.
    ///
    /// A document MaterialX upgraded when reading (an older version in the
    /// file) is only changed once the user agrees to saving it in the new
    /// version: autosave will write it soon after.
    ///
    /// With `continuing`, the edit is part of a continuous change, such as
    /// dragging a slider (PLAN.md §4.2: "value scrubs coalesced into one
    /// step"). Consecutive edits with the same key, each within a second of
    /// the last, are one undo step: the first keeps the copy, the others
    /// only change the document. Any other edit, an undo, or
    /// `endContinuousEdit()` ends it.
    ///
    /// SWIFT: `@escaping`: the closure may be called after this method
    /// returns (when the user answers the upgrade question), so Swift must
    /// keep it alive. Closures passed as parameters are non-escaping by
    /// default, which lets the compiler avoid that cost.
    func edit(_ name: String, continuing key: String? = nil, change: @escaping (MXDocument) throws -> Void) {
        guard !askingToUpgrade else {
            return
        }
        guard upgradeConfirmed || !needsUpgrade else {
            confirmUpgrade { [weak self] in
                self?.edit(name, continuing: key, change: change)
            }
            return
        }

        let now = Date()
        // SWIFT: `if let key, let continuation, ...` unwraps both optionals
        // and checks the rest in one condition. The commas work like `&&`:
        // evaluation stops at the first that fails.
        var continues: Bool = false
        if let key, let continuation, continuation.key == key,
           now.timeIntervalSince(continuation.time) < Self.continuationPause {
            continues = true
        }

        // A copy even when continuing: if this step is refused, only this
        // step is taken back.
        let before: MXDocument = content.copy()
        do {
            try change(content)
        } catch {
            content.restore(from: before)
            continuation = nil
            contentChanged()
            presentError(error)
            return
        }
        if !continues {
            registerUndo(restoring: before, name: name)
        }
        // SWIFT: `key.map { ... }` on an optional: nil stays nil, a value
        // becomes the tuple. The same as `key == nil ? nil : (key!, now)`.
        continuation = key.map { (key: $0, time: now) }
        contentChanged()
    }

    /// Replaces the whole document with `text`, the XML tab's (M4e), as
    /// one undo step, "Edit XML". `applied` is called once the document
    /// is the text's; not if MaterialX can't read it (the error is shown,
    /// and the text stays in the tab), nor before the user agrees to an
    /// upgrade (see `edit`).
    func apply(text: String, applied: @escaping () -> Void) {
        edit("Edit XML") { content in
            try content.replaceContents(withText: text)
            applied()
        }
    }

    /// Ends the continuous edit in progress, if any: the next edit is a new
    /// undo step even with the same key. Sliders call it when released.
    func endContinuousEdit() {
        continuation = nil
    }

    /// Registers an undo step that puts `snapshot` back.
    ///
    /// SWIFT: `registerUndo(withTarget:handler:)` stores a closure that the
    /// undo manager calls on Undo, passing the target (`self`) back in. The
    /// target is held weakly by the undo manager, so the closure uses the
    /// parameter, not `self`. Registering during an undo is how redo works:
    /// the undo manager records that registration as the redo step.
    private func registerUndo(restoring snapshot: MXDocument, name: String) {
        guard let undoManager else {
            return
        }
        undoManager.registerUndo(withTarget: self) { document in
            // Whatever was being dragged, the next change is a new step.
            document.continuation = nil
            let current: MXDocument = document.content.copy()
            document.content.restore(from: snapshot)
            document.registerUndo(restoring: current, name: name)
            document.contentChanged()
        }
        undoManager.setActionName(name)
    }

    /// True if the file's MaterialX version is older than the document's:
    /// MaterialX upgraded it when reading, and saving writes the new version.
    private var needsUpgrade: Bool {
        guard let fileVersion = content.fileVersion else {
            return false
        }
        return fileVersion != content.documentVersion
    }

    /// Asks whether to go ahead and save in the new version; calls
    /// `proceed` if so.
    private func confirmUpgrade(then proceed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Upgrade “\(displayName ?? "this document")” to MaterialX \(content.documentVersion)?"
        alert.informativeText = "The file is MaterialX \(content.fileVersion ?? "?"). Changes are saved automatically, "
            + "and will be saved as MaterialX \(content.documentVersion), which tools that only read "
            + "\(content.fileVersion ?? "the older version") may not open. To keep the original, use Duplicate and edit the copy."
        alert.addButton(withTitle: "Upgrade and Edit")
        alert.addButton(withTitle: "Duplicate")
        alert.addButton(withTitle: "Cancel")
        askingToUpgrade = true
        // SWIFT: A trailing closure called when the sheet is dismissed, with
        // the button pressed. `[weak self]`: the window might close first.
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.askingToUpgrade = false
            switch response {
            case .alertFirstButtonReturn:
                self?.upgradeConfirmed = true
                proceed()
            case .alertSecondButtonReturn:
                self?.duplicate(nil)
            default:
                break
            }
        }
        if let window = windowControllers.first?.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    /// Recomputes what the window shows after `content` changed in place.
    private func contentChanged() {
        load(content)
    }

    // MARK: Private

    /// Replaces the document's contents and recomputes what the window shows.
    private func load(_ document: MXDocument) {
        revision += 1
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
        let ownNodeDefs: [String] = elements.filter { $0.category == "nodedef" }.map(\.name)
        if ownNodeDefs != catalogKey {
            catalog = MXNodeCatalog(document: document)
            catalogKey = ownNodeDefs
        }
        // If writing fails, show the error text in place of the XML.
        // SWIFT: `(try? x) ?? y`: `try?` turns a thrown error into `nil`, and
        // `??` ("nil-coalescing") substitutes `y` when the left side is nil.
        xml = (try? document.xmlString()) ?? "<!-- MaterialX could not write this document -->"
        previewXML = (try? document.previewXMLString()) ?? ""
        viewportXML = (try? document.viewportXMLString()) ?? ""
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
