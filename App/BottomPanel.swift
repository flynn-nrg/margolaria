// BottomPanel.swift
//
// The panel under the canvas (PLAN.md §4.1, region 6), with tabs:
//   XML      the document's XML, the canvas selection highlighted;
//            editable, applied with ⌘↩ (M4e, XMLTextView.swift)
//   Issues   MaterialX's validation and Margolaria's checks; clicking one
//            shows its node on the canvas
//   Generated Shader
//            the selected element's shader, in the language picked
//            there: MSL, GLSL, or OSL as one shader or a network; with
//            Copy and Export… (M5d)
//   Console  a Python REPL on the document (M6c, ScriptKit's
//            PythonConsole): what was typed and printed, and a line to
//            type in; also what File > Run Script… printed
//
// Introduces (SWIFT): `List` with a selection of a non-`Identifiable` type
// via `id:`, `.contextMenu`, `@ViewBuilder` computed properties,
// `NSPasteboard`; `.task(id:)` with `Task.detached`, `@AppStorage` of an
// enum (M5d); an NSTextField delegate's `control(_:textView:doCommandBy:)`,
// `NSAttributedString` appended to a text view's `textStorage`, a cell's
// own field editor (M6c).

import AppKit
import MXKit
import ScriptKit
import SwiftUI

/// The bottom panel's tabs.
enum BottomTab: String, CaseIterable, Identifiable {
    case xml = "XML"
    case issues = "Issues"
    case shader = "Generated Shader"
    case console = "Console"

    var id: String { rawValue }
}

struct BottomPanel: View {
    let document: MaterialXDocument
    @Binding var tab: BottomTab
    /// The XML tab's edits, kept by the window across tab switches.
    let xmlDraft: XMLDraft
    /// The element selected on the canvas, highlighted in the XML.
    let selectedPath: String?
    /// Called when the user picks an issue, to show its element.
    let onSelectIssue: (MXIssue) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Panel", selection: $tab) {
                    ForEach(BottomTab.allCases) { tab in
                        Text(title(for: tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
            // Fill the rest of the panel, whatever the tab shows. The XML
            // view fills by itself, but the "No Issues" placeholder only
            // takes the height it needs, and the VStack would then centre
            // everything, moving the tabs down.
            //
            // SWIFT: `maxWidth: .infinity` lets a view grow to all the
            // space offered; content smaller than that is centred inside.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The tab's content.
    ///
    /// SWIFT: `@ViewBuilder` on a computed property lets it return different
    /// views from a `switch`, like `body`.
    @ViewBuilder
    private var content: some View {
        switch tab {
        case .xml:
            XMLTab(document: document, draft: xmlDraft, highlightedPath: selectedPath)
        case .issues:
            IssuesList(issues: document.issues, libraryLoaded: document.libraryLoaded, onSelect: onSelectIssue)
        case .shader:
            GeneratedShaderTab(document: document, path: document.shaderElementPath(for: selectedPath))
        case .console:
            ConsoleTab(document: document)
        }
    }

    /// "Issues (3)" when there are any.
    private func title(for tab: BottomTab) -> String {
        if tab == .issues, !document.issues.isEmpty {
            return "Issues (\(document.issues.count))"
        }
        // A dot while the text has edits not applied, as on a document.
        if tab == .xml, xmlDraft.edits != nil {
            return "XML •"
        }
        return tab.rawValue
    }
}

/// The list of issues.
struct IssuesList: View {
    let issues: [MXIssue]
    let libraryLoaded: Bool
    let onSelect: (MXIssue) -> Void

    /// The selected row, by position (issues have no identity of their own;
    /// two can be identical).
    @State private var selection: Int? = nil

    var body: some View {
        if !libraryLoaded {
            ContentUnavailableView("Not Validated", systemImage: "questionmark.circle",
                                   description: Text("The MaterialX data libraries could not be loaded."))
        } else if issues.isEmpty {
            ContentUnavailableView("No Issues", systemImage: "checkmark.circle",
                                   description: Text("MaterialX's validation and Margolaria's checks found nothing."))
        } else {
            // SWIFT: `List(_:id:selection:)` over the indices: `id: \.self`
            // uses each index as the row's identity, and the selection
            // binding receives it.
            List(issues.indices, id: \.self, selection: $selection) { index in
                IssueRow(issue: issues[index])
                    // Right-click menu.
                    // SWIFT: `.contextMenu { }` adds a menu shown on
                    // right-click (or Control-click).
                    .contextMenu {
                        Button("Copy Message") {
                            copy("\(issues[index].elementPath): \(issues[index].message)")
                        }
                        Button("Copy Element Path") {
                            copy(issues[index].elementPath)
                        }
                    }
            }
            .onChange(of: selection) {
                if let selection, issues.indices.contains(selection) {
                    onSelect(issues[selection])
                }
            }
        }
    }

    private func copy(_ text: String) {
        // SWIFT: AppKit's pasteboard; `clearContents` must come first.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One issue: severity icon, element path, message, who found it.
private struct IssueRow: View {
    let issue: MXIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.message)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(issue.elementPath.isEmpty ? "document" : issue.elementPath)
                        .font(.system(.caption, design: .monospaced))
                    Text(issue.source == .materialX ? "MaterialX validation" : "Margolaria")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The Generated Shader tab (M5d): the shader MaterialX generates for
/// `path`, read-only, in the language picked in its bar, computing in the
/// document's working space where Margolaria can (lin_rec709 or acescg:
/// an ACEScg document's shaders are for a renderer working in ACEScg,
/// such as Izpi), and in lin_rec709 otherwise; the bar says which.
struct GeneratedShaderTab: View {
    let document: MaterialXDocument
    /// The element shown (MaterialXDocument.shaderElementPath); nil if the
    /// document has nothing to shade.
    let path: String?

    /// The language, the same in every window and remembered.
    ///
    /// SWIFT: `@AppStorage` stores an enum with `String` raw values as its
    /// raw value, and reads it back with `init(rawValue:)`.
    @AppStorage("generatedShaderLanguage") private var language: MXShaderLanguage = .osl

    /// MSL's and GLSL's two stages.
    enum Stage: String, CaseIterable {
        case fragment = "Fragment"
        case vertex = "Vertex"
    }

    @State private var stage: Stage = .fragment

    /// What to generate. When it changes, the shader is generated again.
    struct Request: Equatable {
        let previewXML: String
        let path: String
        let language: MXShaderLanguage
        /// The document's working space, asked for.
        let colorSpace: String
    }

    /// The last generated shader, or why it failed, for `generatedFor`.
    @State private var result: Result<MXShaderCode, any Error>? = nil
    @State private var generatedFor: Request? = nil

    private var request: Request? {
        path.map {
            Request(previewXML: document.previewXML, path: $0, language: language,
                    colorSpace: document.content.workingSpace(of: "").active)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // SWIFT: `.task(id:)` runs the closure when the view appears and
        // again whenever `id` changes, cancelling the previous run. The
        // work goes to `Task.detached`, off the main thread, so a large
        // graph doesn't stall the window; only `Sendable` values (strings,
        // the library, the generated code) cross between the two.
        .task(id: request) {
            guard let request else {
                result = nil
                return
            }
            let generated: Result<MXShaderCode, any Error> = await Task.detached {
                Result {
                    try MXShaderExport.generate(request.language, for: request.path, previewXML: request.previewXML,
                                                colorSpace: request.colorSpace, library: try MXLibrary.bundled.get())
                }
            }.value
            // The request may have changed while generating; the newer
            // task shows its own.
            if !Task.isCancelled {
                result = generated
                generatedFor = request
            }
        }
    }

    /// The tab's bar: what is shown, the language and stage, Copy and
    /// Export….
    private var bar: some View {
        HStack(spacing: 10) {
            Text(path ?? "Nothing to shade")
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Picker("Language", selection: $language) {
                ForEach(MXShaderLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .fixedSize()
            if language == .msl || language == .glsl {
                Picker("Stage", selection: $stage) {
                    ForEach(Stage.allCases, id: \.self) { stage in
                        Text(stage.rawValue).tag(stage)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let code = shownCode {
                Text("in \(code.colorSpace)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("The colour space the shader computes in: colours and images in other spaces are "
                        + "converted to it.")
            }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shownText ?? "", forType: .string)
            }
            .disabled(shownText == nil)
            Button("Export…") {
                if let code = shownCode, let path {
                    document.exportShader(code, named: MXShaderExport.fileName(for: path))
                }
            }
            .disabled(shownCode == nil)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// The generated code, if it is for what the bar shows now.
    private var shownCode: MXShaderCode? {
        guard generatedFor == request, case .success(let code) = result else {
            return nil
        }
        return code
    }

    /// The text shown: OSL's one source, or MSL's and GLSL's chosen stage.
    private var shownText: String? {
        shownCode.map { code in
            stage == .vertex && !code.vertexSource.isEmpty ? code.vertexSource : code.pixelSource
        }
    }

    @ViewBuilder
    private var content: some View {
        if path == nil {
            ContentUnavailableView("No Shader", systemImage: "function",
                                   description: Text("The document has no node or material to generate a shader for."))
        } else if let shownText {
            CodeTextView(text: shownText)
        } else if generatedFor == request, case .failure(let error) = result {
            ContentUnavailableView("No \(language.displayName) Shader", systemImage: "exclamationmark.triangle",
                                   description: Text("\(error)"))
        } else {
            ProgressView()
        }
    }
}

/// Read-only code in a monospaced font, scrolling both ways, with Find
/// (⌘F), for the Generated Shader tab (M5d).
struct CodeTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        // SWIFT: `scrollableTextView()` makes an NSTextView inside an
        // NSScrollView, set up as TextEdit's; the rest makes it read-only
        // code that doesn't wrap.
        let scrollView: NSScrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = XMLTextView.font
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                           height: CGFloat.greatestFiniteMagnitude)
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else {
            return
        }
        textView.string = text
        textView.scroll(.zero)
    }
}

/// The Console tab (M6c): the document's Python REPL. What was typed and
/// printed above, and the line being typed below, after its prompt (">>>",
/// or "..." in the middle of a block). Return enters the line, Up and Down
/// go through the lines typed before, Tab indents.
struct ConsoleTab: View {
    let document: MaterialXDocument

    /// The line being typed.
    @State private var line: String = ""

    /// SWIFT: `document.console` is a plain `let` of an `@Observable`
    /// object, so reading its `lines` or `prompt` in `body` redraws the
    /// tab when they change, as for the document itself.
    private var console: PythonConsole {
        document.console
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("margolaria.document() is this window's document")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    console.clear()
                }
                .help("Clear what the Console shows; its variables and history stay")
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            ConsoleTranscript(lines: console.lines)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(console.prompt)
                    .font(Font(XMLTextView.font))
                    .foregroundStyle(.secondary)
                ConsoleInputField(text: $line, isEnabled: document.scriptRun == nil, onSubmit: submit,
                                  onHistory: recall)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .onAppear {
            document.openConsole()
        }
    }

    /// Return: enters the line (or each, if several were pasted), and
    /// starts the next with the indentation the block needs.
    private func submit() {
        let lines: [String] = line.components(separatedBy: .newlines)
        line = ""
        for typed in lines {
            document.enterInConsole(typed)
        }
        line = console.indentation(after: lines.last ?? "")
    }

    /// Up (`older`) or Down: the line typed before or after the one shown.
    private func recall(older: Bool) {
        if let recalled = older ? console.older(than: line) : console.newer() {
            line = recalled
        }
    }
}

/// What the Console has shown: typed lines, output, tracebacks in red,
/// selectable, scrolled to the end as lines are added.
private struct ConsoleTranscript: NSViewRepresentable {
    let lines: [PythonConsole.Line]

    /// What the text view shows now, so updates only add the new lines.
    final class Coordinator {
        var shown: [PythonConsole.Line.ID] = []
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        // As CodeTextView's, but wrapping long lines, as a terminal does.
        let scrollView: NSScrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.textContainerInset = NSSize(width: 8, height: 6)
            textView.usesFindBar = true
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else {
            return
        }
        let coordinator: Coordinator = context.coordinator
        let ids: [PythonConsole.Line.ID] = lines.map(\.id)
        guard ids != coordinator.shown else {
            return
        }
        // New lines after those shown: add them. Otherwise (cleared), all
        // again.
        var added: ArraySlice<PythonConsole.Line> = lines[...]
        if ids.starts(with: coordinator.shown) {
            added = lines.dropFirst(coordinator.shown.count)
        } else {
            storage.setAttributedString(NSAttributedString())
        }
        // SWIFT: `NSAttributedString` is text with attributes (font,
        // colour) on ranges of it, as AppKit draws it. A text view's
        // `textStorage` is its mutable one: appending to it adds to what
        // the view shows, without setting all the text again.
        for line in added {
            storage.append(NSAttributedString(string: line.text + "\n", attributes: Self.attributes(for: line.style)))
        }
        coordinator.shown = ids
        textView.scrollToEndOfDocument(nil)
    }

    /// Typed lines in bold, tracebacks in red, the Console's own notes dim.
    private static func attributes(for style: PythonConsole.Style) -> [NSAttributedString.Key: Any] {
        switch style {
        case .input:
            return [.font: NSFont.monospacedSystemFont(ofSize: XMLTextView.font.pointSize, weight: .semibold),
                    .foregroundColor: NSColor.labelColor]
        case .output:
            return [.font: XMLTextView.font, .foregroundColor: NSColor.labelColor]
        case .error:
            return [.font: XMLTextView.font, .foregroundColor: NSColor.systemRed]
        case .note:
            return [.font: XMLTextView.font, .foregroundColor: NSColor.secondaryLabelColor]
        }
    }
}

/// The Console's line to type in: an AppKit text field, as it lets Return,
/// Up, Down and Tab be handled before the field does its own thing with
/// them (ending editing, moving the caret, moving to the next field).
private struct ConsoleInputField: NSViewRepresentable {
    @Binding var text: String
    /// False while a script runs.
    let isEnabled: Bool
    let onSubmit: () -> Void
    /// Up (true) or Down (false).
    let onHistory: (_ older: Bool) -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ConsoleInputField

        init(parent: ConsoleInputField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                parent.text = field.stringValue
            }
        }

        /// SWIFT: AppKit turns keys into commands, named by selectors
        /// (Return is `insertNewline:`, Up is `moveUp:`), and asks the
        /// field's delegate first: returning true means "handled", and the
        /// field doesn't do its own.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.moveUp(_:)):
                parent.onHistory(true)
            case #selector(NSResponder.moveDown(_:)):
                parent.onHistory(false)
            case #selector(NSResponder.insertTab(_:)):
                textView.insertText("    ", replacementRange: textView.selectedRange())
            default:
                return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.cell = ConsoleFieldCell(textCell: "")
        field.isEditable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = XMLTextView.font
        field.placeholderString = "Python"
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        // Typing goes here as soon as the tab shows.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            // The caret after the text, not selecting all of it.
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        if field.isEnabled != isEnabled {
            field.isEnabled = isEnabled
            // Disabling it took the focus; a script has ended: back to typing.
            if isEnabled {
                field.window?.makeFirstResponder(field)
            }
        }
    }
}

/// The Console field's cell, with a field editor of its own that keeps no
/// typing undo.
///
/// A text field is edited in its window's *field editor*: one NSTextView
/// shared by the window's fields, whose typing undo goes to the window's
/// undo manager, the document's. Each keystroke in the Console would be
/// an undo step between its entries. With none, ⌘Z here undoes the last
/// entry, as the Edit menu does.
///
/// SWIFT: An `NSCell` subclass's `fieldEditor(for:)` override gives its
/// field the editor it returns instead of the window's.
private final class ConsoleFieldCell: NSTextFieldCell {
    private let editor: NSTextView = {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.allowsUndo = false
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor
    }
}
