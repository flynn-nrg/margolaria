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
// tuples, `Optional.map`; an `@objc` action on the document, a `weak`
// stored property (M4f); a save panel's accessory view, and a small
// `NSObject` subclass as a control's target (M5b); a function taking a
// throwing closure (M5c); `NSPathControl` and its delegate, `UserDefaults`
// read and written directly (M5d).

import AppKit
import GraphKit
import MXKit
import Observation
import PreviewKit
import ScriptKit
import SwiftUI
import UniformTypeIdentifiers
import ViewportKit

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
            // Undo steps put their copies back into `content` (MXUndo), and
            // `content` is replaced here. NSDocument clears the steps when
            // it reads the file again (Revert To) anyway; this makes sure.
            undoManager?.removeAllActions(withTarget: content)
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

    // MARK: Export (M5b, M5c, M5d)

    /// The material the viewport shows, by MaterialX name; nil before the
    /// viewport has picked one. Window state, kept here (not in
    /// ContentView) so that Export as USDZ… can put it on the sphere.
    var previewMaterial: String? = nil

    /// The node selected on the canvas (one only), by path: window state,
    /// here so that scripts can read it (`margolaria.selection()`, M6b).
    /// The canvas writes it (ContentView).
    var selectedPath: String? = nil

    /// An element a script asked the canvas to select
    /// (`margolaria.select()`); ContentView shows its graph, selects it,
    /// and clears this.
    var selectionRequest: String? = nil

    /// File > Export as USD…: writes the document's materials as a USD
    /// file, .usda (text) or .usdc (binary), chosen in the Save panel.
    ///
    /// The file holds the materials only, standing alone (no reference to
    /// the .mtlx, definitions expanded: MXDocument.usdXMLString), under
    /// one prim, /MaterialX, for referencing into a scene and binding to
    /// its models. Textures in the file's folder are referred to relative
    /// to it (MGUSDExporter.h). Not an edit: the document doesn't change.
    @objc func exportAsUSD(_ sender: Any?) {
        // The text now, from the document as it is when the command is
        // chosen, not when the panel closes.
        let text: String
        do {
            text = try content.usdXMLString()
        } catch {
            presentError(error)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export as USD"
        panel.message = "The document's materials, for referencing into a USD scene. "
            + "Textures in the same folder as the file, or inside it, are referred to by relative paths."
        let formats = USDFormatAccessory(panel: panel, name: exportName)
        panel.accessoryView = formats.view
        // SWIFT: The closure uses `formats`, so it keeps the accessory (and
        // its popup's target) alive until the panel has closed.
        runExportPanel(panel) { url in
            _ = formats
            // SWIFT: The Objective-C method ends in `error:`, so Swift sees
            // it as `throws`, returning nothing.
            try MGUSDExporter.exportMaterials(fromMaterialXString: text, to: url)
        }
    }

    /// File > Export as USDZ…: writes a USDZ package for Quick Look and
    /// Reality Composer Pro: a sphere with the material the viewport
    /// shows, the document's other materials for binding there, and every
    /// texture inside (MGUSDExporter.h). The panel says which materials
    /// they won't draw from their graphs (MXDocument.quickLookIssues).
    @objc func exportAsUSDZ(_ sender: Any?) {
        let text: String
        do {
            // Greyscale images read as colours are rewritten for Reality
            // Composer Pro (MXDocument.usdzXMLString).
            text = try content.usdzXMLString()
        } catch {
            presentError(error)
            return
        }
        let material: String? = previewMaterial
        let panel = NSSavePanel()
        panel.title = "Export as USDZ"
        var message: String = "A sphere with the material the viewport shows"
            + (material.map { " (\($0))" } ?? "")
            + ", for Quick Look and Reality Composer Pro. The other materials are included, "
            + "and every texture is packed inside."
        let issues: [String] = content.quickLookIssues()
        if !issues.isEmpty {
            message += "\n\nNot drawn as designed: plain grey in Quick Look, magenta in Reality Composer Pro.\n"
                + issues.map { "• " + $0 }.joined(separator: "\n")
        }
        panel.message = message
        panel.nameFieldStringValue = exportName + ".usdz"
        panel.allowedContentTypes = [.usdz]
        runExportPanel(panel) { url in
            try MGUSDExporter.exportPreview(fromMaterialXString: text, to: url, materialName: material)
        }
    }

    /// The element the Generated Shader tab shows (M5d), given the canvas
    /// selection: a node, a nodegraph's output or a material, as selected;
    /// for a nodegraph shown as a node, its first output; otherwise the
    /// material the viewport shows. Nil if the document has nothing to
    /// shade.
    func shaderElementPath(for selected: String?) -> String? {
        let shadeable: [MXElementSummary] = content.shadeableElements
        if let selected {
            if shadeable.contains(where: { $0.path == selected }) {
                return selected
            }
            if let output = shadeable.first(where: { $0.category == "output" && $0.path.hasPrefix(selected + "/") }) {
                return output.path
            }
        }
        if let previewMaterial, shadeable.contains(where: { $0.path == previewMaterial }) {
            return previewMaterial
        }
        return shadeable.first(where: { $0.type == "material" })?.path
    }

    /// The Generated Shader tab's Export…: writes `code` into a folder
    /// chosen in a Save panel, as MXShaderExport lays it out (the files
    /// named after `name`). For OSL, the panel offers to compile it to
    /// .oso with an oslc the user picks, remembered for next time.
    func exportShader(_ code: MXShaderCode, named name: String) {
        let panel = NSSavePanel()
        panel.title = "Export Shader"
        panel.prompt = "Export"
        panel.nameFieldLabel = "Folder:"
        panel.nameFieldStringValue = "\(name) \(code.language.displayName)"
        switch code.language {
        case .msl, .glsl:
            panel.message = "A folder with \(name)'s \(code.language.displayName) shader: "
                + "the vertex and fragment stages, as MaterialX generates them."
        case .osl:
            panel.message = "A folder with \(name)'s OSL shader, the whole graph in one .osl, "
                + "and the .oso compiled from it if oslc is set below."
        case .oslNetwork:
            panel.message = "A folder with \(name)'s OSL shader group (.oslgroup) and every compiled "
                + "shader (.oso) it names. Give the folder to the renderer as its shader search path."
        }
        panel.message += " It computes in \(code.colorSpace)."
        let compiler: OSLCompilerAccessory? = code.language == .osl ? OSLCompilerAccessory() : nil
        panel.accessoryView = compiler?.view
        runExportPanel(panel) { url in
            let oslc: URL? = compiler?.chosenCompiler()
            _ = try MXShaderExport.write(code, named: name, to: url, oslc: oslc,
                                         library: try MXLibrary.bundled.get())
        }
    }

    /// The name exported files start with: the document's, without its
    /// extension ("Untitled" for a new one).
    private var exportName: String {
        (displayName as NSString).deletingPathExtension
    }

    /// Shows `panel` as a sheet on the window, starting beside the
    /// document, and calls `export` with the chosen file; shows its error
    /// if it throws.
    ///
    /// SWIFT: `export` is a *throwing closure* (`(URL) throws -> Void`):
    /// the caller's `try` lines go in it, and this function catches what
    /// they throw, in one place for both exports.
    private func runExportPanel(_ panel: NSSavePanel, export: @escaping (URL) throws -> Void) {
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            do {
                try export(url)
            } catch {
                self?.presentError(error)
            }
        }
        if let window = windowControllers.first?.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    // MARK: Scripts (M6)

    /// A script that raised: its output, ending with the traceback.
    struct ScriptFailed: LocalizedError {
        let name: String
        let output: String

        var errorDescription: String? {
            "\(name) stopped with an error."
        }

        var recoverySuggestion: String? {
            output
        }
    }

    /// File > Run Script…: runs a Python script on this document, as one
    /// undo step named after it, or several (`with margolaria.edit(...)`),
    /// or none if it changes nothing. `margolaria.document()` in the
    /// script is this document (ScriptKit). A script that raises changes
    /// nothing: its traceback is shown. What a script prints is shown when
    /// it ends (in a sheet until the Console, M6c).
    @objc func runScript(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Run Script"
        panel.message = "A Python script to run on this document, as one step you can undo."
        panel.allowedContentTypes = [.pythonScript]
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.run(scriptAt: url)
        }
        if let window = windowControllers.first?.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Runs the script at `url` on this document; see `runScript`.
    private func run(scriptAt url: URL) {
        let code: String
        do {
            try Python.start(from: .inApp())
            code = try String(contentsOf: url, encoding: .utf8)
        } catch {
            presentError(error)
            return
        }
        let name: String = url.lastPathComponent
        // Not `edit`: the script registers its own steps, as many as it
        // makes, and puts the document back itself if it raises.
        whenEditable { [weak self] in
            guard let self else {
                return
            }
            continuation = nil
            let result: ScriptResult = Python.run(code, named: url.path(percentEncoded: false), on: content,
                                                  host: self, undoManager: undoManager,
                                                  changed: { [weak self] _ in self?.undoneOrRedone() })
            if !result.steps.isEmpty || !result.succeeded {
                contentChanged()
            }
            if !result.succeeded {
                presentError(ScriptFailed(name: name, output: result.output))
            } else if !result.output.isEmpty {
                showOutput(result.output, of: name)
            }
        }
    }

    /// Shows what a script printed, in a sheet on the window.
    private func showOutput(_ output: String, of name: String) {
        let alert = NSAlert()
        alert.messageText = "\(name) printed:"
        alert.informativeText = output
        if let window = windowControllers.first?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Command palette (M4f)

    /// The menu bar's commands while the command palette is open, read
    /// when it opened; nil while it is closed. ContentView shows the
    /// palette, adding the inspector's commands and the nodes.
    ///
    /// Window state rather than document state, kept here because the
    /// document is where ⌘K arrives: it is in the window's responder chain
    /// (after the views, the window and its controller), which SwiftUI
    /// views aren't.
    private(set) var paletteCommands: [PaletteCommand]? = nil

    /// Where the window's keyboard focus was when the palette opened, to
    /// put it back when it closes.
    ///
    /// SWIFT: `weak`: not kept alive by this (a view may go away while
    /// the palette is open); it reads nil then.
    @ObservationIgnored private weak var focusBeforePalette: NSResponder? = nil

    /// View > Command Palette… (⌘K): opens the palette, or closes it.
    ///
    /// The menus are read now, while the focus is still where it was
    /// (the canvas, the XML), so the commands listed are those the menus
    /// would offer there. Closing the palette puts the focus back before
    /// a command runs, so its action goes where the menu's would have.
    ///
    /// SWIFT: `@objc` makes the method an Objective-C action, found by
    /// the menu item's selector through the responder chain.
    @objc func showCommandPalette(_ sender: Any?) {
        guard paletteCommands == nil else {
            closeCommandPalette()
            return
        }
        guard let window = windowControllers.first?.window, let menuBar = NSApp.mainMenu else {
            return
        }
        // A text field's typing goes to a shared text view (the window's
        // *field editor*), which is then the first responder; the field is
        // its delegate. Put the focus back on the field.
        var focus: NSResponder? = window.firstResponder
        if let editor = focus as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
            focus = field
        }
        focusBeforePalette = focus
        paletteCommands = MenuCommands.commands(in: menuBar, skipping: [#selector(showCommandPalette(_:))],
                                                keys: GraphEventView.keys)
    }

    /// Closes the command palette, and puts the focus back where it was.
    func closeCommandPalette() {
        paletteCommands = nil
        if let focus = focusBeforePalette {
            windowControllers.first?.window?.makeFirstResponder(focus)
        }
        focusBeforePalette = nil
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
        whenEditable { [weak self] in
            self?.makeEdit(name, continuing: key, change: change)
        }
    }

    /// Calls `proceed` now if the document can be changed, or once the user
    /// agrees to upgrading it (see `edit`); not while the question is up.
    private func whenEditable(_ proceed: @escaping () -> Void) {
        guard !askingToUpgrade else {
            return
        }
        guard upgradeConfirmed || !needsUpgrade else {
            confirmUpgrade(then: proceed)
            return
        }
        proceed()
    }

    /// The edit itself, once the document can be changed (see `edit`).
    private func makeEdit(_ name: String, continuing key: String?, change: (MXDocument) throws -> Void) {
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

    /// Registers an undo step that puts `snapshot` back (MXUndo, which
    /// scripts' steps use too).
    private func registerUndo(restoring snapshot: MXDocument, name: String) {
        guard let undoManager else {
            return
        }
        MXUndo.register(on: undoManager, restoring: snapshot, in: content, named: name,
                        changed: { [weak self] _ in self?.undoneOrRedone() })
    }

    /// After an Undo or Redo has put a copy back into `content`.
    private func undoneOrRedone() {
        // Whatever was being dragged, the next change is a new step.
        continuation = nil
        contentChanged()
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

// MARK: - Scripts' window (M6b)

/// What a script asks of the window (ScriptKit's `margolaria.selection()`
/// and the like).
///
/// SWIFT: Adopting a protocol in an extension keeps its members together,
/// apart from the class's own.
extension MaterialXDocument: ScriptHost {
    var selection: [String] {
        selectedPath.map { [$0] } ?? []
    }

    func select(_ path: String) {
        selectedPath = path
        selectionRequest = path
    }

    var documentFolder: URL? {
        fileURL?.deletingLastPathComponent()
    }
}

/// The Export as USD panel's format menu: USDA (text) or USDC (binary).
/// Choosing one changes the panel's file type, and the extension of the
/// name typed so far.
///
/// SWIFT: An `NSObject` subclass, because AppKit controls call an
/// Objective-C method on an object (target/action, as in ObjC), not a
/// closure. Nothing else keeps it alive (a control holds its target
/// weakly), so the panel's completion handler holds it.
final class USDFormatAccessory: NSObject {
    /// The formats, as the menu lists them: title and extension.
    static let formats: [(title: String, fileExtension: String)] = [("USDA (text)", "usda"), ("USDC (binary)", "usdc")]

    /// The view the panel shows under its file browser.
    let view: NSView
    private let panel: NSSavePanel
    private let popUp: NSPopUpButton

    init(panel: NSSavePanel, name: String) {
        self.panel = panel
        popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: Self.formats.map(\.title))
        let label = NSTextField(labelWithString: "Format:")
        // SWIFT: An NSStackView lays out its views in a row, as SwiftUI's
        // HStack does; the edge insets keep it off the panel's edges.
        let stack = NSStackView(views: [label, popUp])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        view = stack
        // SWIFT: `super.init()` before `self` is used (here, as the
        // popup's target): Swift requires every stored property set first,
        // then the superclass initialised, before methods can be called.
        super.init()
        popUp.target = self
        popUp.action = #selector(formatChosen(_:))
        panel.nameFieldStringValue = name + "." + Self.formats[0].fileExtension
        setType(Self.formats[0].fileExtension)
    }

    /// The popup's action: the panel takes the chosen format's type, and
    /// the typed name its extension.
    @objc private func formatChosen(_ sender: NSPopUpButton) {
        let fileExtension: String = Self.formats[sender.indexOfSelectedItem].fileExtension
        let typed: String = (panel.nameFieldStringValue as NSString).deletingPathExtension
        setType(fileExtension)
        panel.nameFieldStringValue = typed + "." + fileExtension
    }

    /// Lets the panel save only files with `fileExtension`.
    private func setType(_ fileExtension: String) {
        // SWIFT: `UTType(filenameExtension:)` finds the system's type for an
        // extension (macOS knows USD's); nil if none, then any data.
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .data]
    }
}

/// The Export Shader panel's accessory for OSL (M5d): whether to compile
/// the shader to .oso, and with which oslc. Both are remembered in the
/// user defaults. The first time, oslc is looked for where Homebrew and
/// other installers put it; the path control's menu picks another
/// (scripts/build-osl.sh's, for one).
///
/// SWIFT: An `NSObject` subclass, as the path control's delegate must be.
final class OSLCompilerAccessory: NSObject, NSPathControlDelegate {
    /// The user defaults keys.
    private static let compilerKey: String = "oslcPath"
    private static let compilesKey: String = "compilesOSL"

    /// Where oslc is looked for when none has been chosen.
    private static let usualPlaces: [String] = ["/opt/homebrew/bin/oslc", "/usr/local/bin/oslc"]

    /// The view the panel shows under its file browser.
    let view: NSView
    private let checkbox: NSButton
    private let pathControl: NSPathControl

    override init() {
        checkbox = NSButton(checkboxWithTitle: "Compile to .oso with:", target: nil, action: nil)
        pathControl = NSPathControl()
        pathControl.pathStyle = .popUp
        // Editable: its menu has "Choose…", which opens a panel.
        pathControl.isEditable = true
        pathControl.placeholderString = "Choose oslc"
        let stack = NSStackView(views: [checkbox, pathControl])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        view = stack
        super.init()
        pathControl.delegate = self

        // SWIFT: `UserDefaults.standard` is what `@AppStorage` reads and
        // writes, here used directly, as AppKit code does. `string(forKey:)`
        // is nil for a key never set; `object(forKey:)` tells "never set"
        // from false, which `bool(forKey:)` can't.
        let defaults = UserDefaults.standard
        let saved: String? = defaults.string(forKey: Self.compilerKey)
        let path: String? = saved ?? Self.usualPlaces.first { FileManager.default.isExecutableFile(atPath: $0) }
        pathControl.url = path.map { URL(filePath: $0) }
        let compiles: Bool = defaults.object(forKey: Self.compilesKey) as? Bool ?? (path != nil)
        checkbox.state = compiles ? .on : .off
    }

    /// The oslc to compile with, or nil not to compile; remembers the
    /// choice.
    func chosenCompiler() -> URL? {
        let defaults = UserDefaults.standard
        let compiles: Bool = checkbox.state == .on
        defaults.set(compiles, forKey: Self.compilesKey)
        if let url = pathControl.url {
            defaults.set(url.path(percentEncoded: false), forKey: Self.compilerKey)
        }
        return compiles ? pathControl.url : nil
    }

    /// The path control's "Choose…" panel picks a file (oslc), not a folder.
    func pathControl(_ pathControl: NSPathControl, willDisplay openPanel: NSOpenPanel) {
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.message = "Choose oslc, OSL's compiler."
    }
}
