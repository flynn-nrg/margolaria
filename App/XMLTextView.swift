// XMLTextView.swift
//
// The XML tab (PLAN.md §4.1, editable since M4e, §8.5): the document's XML,
// with syntax colouring, in an AppKit text view (TextKit 2), and a bar under
// it that says whether the text reads and validates, and where the first
// problem is. The element selected on the canvas is highlighted and
// scrolled into view; the other way, clicking in the text (or moving the
// caret) selects the node it is in on the canvas (M7b), while the text is
// the document's own. ⌘F searches (the standard find bar).
//
// The text is MaterialX's own serialisation of the document (what Save
// would write), not the file's original bytes: identical for files
// MaterialX wrote, normalised for others.
//
// Editing: typing changes only the tab's text (XMLDraft), never the
// document; most text is invalid while it is typed. ⌘↩ (Apply) replaces
// the document with it, as one undo step, if MaterialX can read it.
// Escape (Revert) puts the document's text back. Typing has an undo
// history of its own (XMLEditingTextView), so ⌘Z in the text undoes typing
// and Revert, and, once nothing is typed, the document's last edit, as
// anywhere else. If the document changes while the text is edited (a
// canvas edit, Undo), the edited text stays, the bar says so, and Apply
// asks before replacing those changes.
//
// Introduces (SWIFT): an `NSViewRepresentable` with a `Coordinator` (state
// that lives as long as the AppKit view), `NSAttributedString` attributes,
// `NSRange(_:in:)` to convert Swift string ranges for AppKit, subclassing
// NSTextView and overriding a property, `@objc` action methods, a
// coordinator as a delegate
// (`NSTextViewDelegate`), `.alert(_:isPresented:actions:message:)`,
// debouncing with `.task(id:)` and `Task.sleep`; `Range(_:in:)` from an
// NSRange (M7b).

import AppKit
import MXKit
import Observation
import SwiftUI

/// The XML tab's text while the user edits it, kept by the window
/// (ContentView), so switching tabs or hiding the panel doesn't lose it.
///
/// SWIFT: `@Observable` (see MaterialXDocument): the views that read
/// `edits` update when it changes.
@Observable
final class XMLDraft {
    /// The edited text, or nil while the tab shows the document's own text.
    private(set) var edits: String? = nil

    /// The document's text when editing began. If the document's text is
    /// no longer this, the document changed meanwhile, and applying the
    /// edits would replace that change.
    private(set) var base: String = ""

    /// The tab's text view, while it is on screen: Revert and Apply act on
    /// its typing, and problems are shown in it.
    ///
    /// SWIFT: `weak`: the view belongs to AppKit and SwiftUI; the draft
    /// mustn't keep it alive after the tab closes. A weak reference is
    /// always an optional, set to nil when the object goes away.
    @ObservationIgnored weak var textView: XMLEditingTextView? = nil

    /// What the tab shows: the edits, or the document's text.
    func text(for documentXML: String) -> String {
        edits ?? documentXML
    }

    /// True if the document changed after editing began (see `base`).
    func isStale(against documentXML: String) -> Bool {
        edits != nil && base != documentXML
    }

    /// The user typed: the tab's text is now `text`. Text that is the
    /// document's own again isn't an edit.
    func typed(_ text: String, documentXML: String) {
        if text == documentXML {
            edits = nil
            return
        }
        if edits == nil {
            base = documentXML
        }
        edits = text
    }

    /// Puts the document's text back (Escape, Revert). In the text view
    /// it is a change the user can undo, like typing: ⌘Z brings the edits
    /// back.
    func revert(to documentXML: String) {
        guard edits != nil else {
            return
        }
        guard let textView else {
            edits = nil
            return
        }
        // typed(_:documentXML:) clears `edits`, from the text view's delegate.
        textView.replaceAll(with: documentXML, actionName: "Revert XML")
    }

    /// The edits were applied: the tab shows the document's text again, and
    /// what was typed is no longer undone in the text, but by undoing the
    /// document's edit ("Undo Edit XML").
    func applied() {
        edits = nil
        textView?.forgetTyping()
    }

    /// Selects where `problem` is in the text view, and scrolls to it.
    func show(_ problem: MXTextProblem) {
        guard let textView, let line = problem.line else {
            return
        }
        // SWIFT: `as NSString` bridges the String to Foundation's string,
        // whose `lineRange(for:)` and UTF-16 offsets AppKit's ranges use.
        let text = textView.string as NSString
        var start: Int = 0
        var current: Int = 1
        while current < line, start < text.length {
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            current += 1
        }
        let lineRange: NSRange = text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
        // The column is a guess where a line has characters outside ASCII
        // (libxml2 counts bytes); it stays on the line.
        let caret: Int = min(lineRange.location + max((problem.column ?? 1) - 1, 0), NSMaxRange(lineRange))
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.scrollRangeToVisible(lineRange)
        textView.showFindIndicator(for: lineRange)
    }
}

/// The XML tab: the text, and the bar under it.
struct XMLTab: View {
    let document: MaterialXDocument
    let draft: XMLDraft
    /// The path of the element to highlight, such as "NG_copper/grain".
    let highlightedPath: String?
    /// Called with the path of the element the caret moved into (M7b).
    let onSelectElement: (String) -> Void

    /// What the edits last checked would do, and which text that was. Out
    /// of date while the user types: the check runs when typing pauses.
    @State private var check: MXTextCheck? = nil
    @State private var checkedText: String? = nil
    /// True while Apply asks whether to replace the document's changes.
    @State private var confirmingApply: Bool = false

    var body: some View {
        let text: String = draft.text(for: document.xml)
        VStack(spacing: 0) {
            XMLTextView(xml: document.xml, draft: draft, highlightedPath: highlightedPath,
                        onEscape: { draft.revert(to: document.xml) }, onSelectElement: onSelectElement)
            Divider()
            bar(for: text)
        }
        // Edits are checked when they stop changing for a moment. Reading
        // and validating takes tens of milliseconds, too slow for every key.
        // (The document's own text needs no check: see `shownCheck`.)
        //
        // SWIFT: `.task(id:)` cancels the running task and starts a new one
        // whenever `id` changes. A task that sleeps first is a *debounce*:
        // only the last of a burst of changes lives to the end of its sleep.
        // `Task.sleep` throws when cancelled; `try?` ignores that, and
        // `Task.isCancelled` says to stop.
        .task(id: draft.edits) {
            guard let edits = draft.edits else {
                // Applied or reverted: the next edits start unchecked.
                check = nil
                checkedText = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else {
                return
            }
            check = document.content.check(text: edits)
            checkedText = edits
        }
        // SWIFT: `.alert(_:isPresented:actions:message:)` shows an alert
        // (a sheet on the window) while the binding is true, and sets it
        // back to false when a button is pressed. A button with
        // `role: .cancel` is the one Escape presses.
        .alert("Replace the document’s changes?", isPresented: $confirmingApply) {
            Button("Apply") {
                applyNow()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The document changed after you began editing the XML (on the canvas, or by Undo). "
                + "Applying the text replaces those changes.")
        }
    }

    /// The bar: the check's result, and Revert and Apply.
    private func bar(for text: String) -> some View {
        HStack(spacing: 10) {
            status
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if draft.isStale(against: document.xml) {
                Label("The document changed", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .help("The document changed after you began editing: Apply replaces that change, Revert shows it")
            }
            Button("Revert") {
                draft.revert(to: document.xml)
            }
            .help("Show the document’s text again (Escape)")
            .disabled(draft.edits == nil)
            Button("Apply") {
                apply()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help("Replace the document with this text (⌘↩)")
            .disabled(draft.edits == nil || (checkedText == text && check?.canApply == false))
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// What the bar says about the text: for the document's own, its
    /// issues, already found (MaterialXDocument); for edits, the last
    /// check. Nil while the first check of the edits is to come.
    private var shownCheck: MXTextCheck? {
        guard draft.edits != nil else {
            return MXTextCheck(issues: document.issues, in: document.xml)
        }
        return check
    }

    /// The check's result: valid, the first problem (click to see it), or
    /// unreadable and where.
    @ViewBuilder
    private var status: some View {
        if !document.libraryLoaded {
            Label("Not validated: the MaterialX data libraries could not be loaded", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        } else {
            checkStatus
        }
    }

    @ViewBuilder
    private var checkStatus: some View {
        switch shownCheck {
        case nil:
            Text("Checking…")
                .foregroundStyle(.secondary)
        case .valid:
            Label("Valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .issues(let count, let first):
            problemButton(first, extra: count > 1 ? " (\(count - 1) more in Issues)" : "",
                          systemImage: "exclamationmark.triangle.fill", color: .orange)
        case .unreadable(let problem):
            problemButton(problem, extra: "", systemImage: "xmark.octagon.fill", color: .red)
        }
    }

    /// "Line 5, column 14: message", which selects that place when clicked.
    private func problemButton(_ problem: MXTextProblem, extra: String, systemImage: String, color: Color) -> some View {
        var place: String = ""
        if let line = problem.line {
            place = problem.column.map { "Line \(line), column \($0): " } ?? "Line \(line): "
        }
        return Button {
            draft.show(problem)
        } label: {
            Label {
                Text(place + problem.message + extra)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
            }
        }
        .buttonStyle(.plain)
        .help(problem.line == nil ? problem.message : "Show it in the text")
    }

    /// Apply (⌘↩): checks the text now, rather than trusting a check from
    /// before the last keys, and asks first if the document changed.
    private func apply() {
        guard let edits = draft.edits else {
            return
        }
        let now: MXTextCheck = document.content.check(text: edits)
        check = now
        checkedText = edits
        guard now.canApply else {
            NSSound.beep()
            if case .unreadable(let problem) = now {
                draft.show(problem)
            }
            return
        }
        if draft.isStale(against: document.xml) {
            confirmingApply = true
        } else {
            applyNow()
        }
    }

    private func applyNow() {
        guard let edits = draft.edits else {
            return
        }
        document.apply(text: edits, applied: draft.applied)
    }
}

/// A text view whose typing has an undo history of its own, and which
/// reports Escape.
///
/// The window's undo manager is the document's: typing registered there
/// would put every keystroke between the document's own edits, and undo
/// half-typed text the document never had. So, once the user types, this
/// view uses `typingUndo`, until `forgetTyping()`.
///
/// SWIFT: A subclass of an AppKit class, as in Objective-C; `override`
/// marks each replaced method or property. It inherits NSTextView's
/// initializers (it adds no stored property without a default value).
final class XMLEditingTextView: NSTextView {
    /// The undo history of typing (and Revert) in this view.
    let typingUndo = UndoManager()

    /// True once the user has typed since the text was last the
    /// document's own: Undo is then about the typing.
    private var isTyping: Bool = false

    /// Called on Escape.
    var onEscape: (() -> Void)? = nil

    /// The undo manager Edit > Undo and typing use while this view is
    /// focused.
    ///
    /// SWIFT: Overriding a read-only property with a computed one; `super`
    /// is NSResponder's, which asks the window (the document's).
    override var undoManager: UndoManager? {
        isTyping ? typingUndo : super.undoManager
    }

    /// Edit > Undo and Redo (⌘Z, ⇧⌘Z). NSTextView leaves them to the
    /// window, which would undo with its own undo manager, the document's,
    /// whatever the property above says. Answering them here makes them
    /// use that.
    ///
    /// SWIFT: `@objc` makes the method visible to Objective-C's message
    /// dispatch, which is how menu items find who handles their action:
    /// the first object in the responder chain that responds to `undo:`.
    @objc func undo(_ sender: Any?) {
        undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        undoManager?.redo()
    }

    /// Enables Undo and Redo, titled after what they would do ("Undo
    /// Typing", "Undo Edit XML"), as the window would.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let manager: UndoManager? = undoManager
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = manager?.undoMenuItemTitle ?? "Undo"
            return manager?.canUndo ?? false
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = manager?.redoMenuItemTitle ?? "Redo"
            return manager?.canRedo ?? false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    /// Called by AppKit before every change the user makes (typing, paste,
    /// Replace in the find bar), and registers its undo, with the undo
    /// manager above, so that must be the typing one already.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        isTyping = true
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    /// Escape. NSTextView's own completes the word being typed.
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// Replaces all the text, as a change the user can undo like typing.
    func replaceAll(with text: String, actionName: String) {
        let all = NSRange(location: 0, length: (string as NSString).length)
        // Its own undo step, not merged with the typing before it.
        breakUndoCoalescing()
        guard shouldChangeText(in: all, replacementString: text) else {
            return
        }
        replaceCharacters(in: all, with: text)
        didChangeText()
        undoManager?.setActionName(actionName)
        breakUndoCoalescing()
    }

    /// Forgets the typing: the text is the document's again, and Undo is
    /// the document's.
    func forgetTyping() {
        typingUndo.removeAllActions()
        isTyping = false
    }
}

struct XMLTextView: NSViewRepresentable {
    /// The document's XML.
    let xml: String
    /// The edits, if any, shown instead of `xml`.
    let draft: XMLDraft
    /// The path of the element to highlight, such as "NG_copper/grain".
    let highlightedPath: String?
    /// Called on Escape.
    let onEscape: () -> Void
    /// Called when the user moves the caret into an element, with its
    /// path (M7b): an input's, inside a node's input.
    let onSelectElement: (String) -> Void

    /// What the view showed last time, so updates only redo what changed,
    /// and the text view's delegate.
    ///
    /// SWIFT: SwiftUI creates one coordinator per AppKit view and keeps it
    /// as long as the view exists (`context.coordinator`), unlike the
    /// representable struct itself, which is re-created on every update.
    /// It's the place for state the AppKit side needs to remember, and,
    /// being an object, it can be the AppKit view's delegate. Objective-C
    /// protocols such as `NSTextViewDelegate` need an `NSObject` subclass.
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// The latest representable, for the document's text and the draft.
        var parent: XMLTextView
        /// The text in the view, as last put there or typed.
        var shown: String = ""
        /// The highlighted element's path and range.
        var highlightedPath: String? = nil
        var highlight: NSRange? = nil
        /// True while ``updateNSView(_:context:)`` changes the text or the
        /// caret: that isn't the user moving it.
        var isUpdating: Bool = false

        init(parent: XMLTextView) {
            self.parent = parent
        }

        /// The user changed the text: recolour it, find the highlighted
        /// element again, and give the text to the draft.
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else {
                return
            }
            let text: String = textView.string
            shown = text
            highlight = XMLTextView.range(of: highlightedPath, in: text)
            XMLTextView.color(storage, highlight: highlight)
            parent.draft.typed(text, documentXML: parent.xml)
        }

        /// The caret moved (M7b): if the user moved it, in the document's
        /// own text, say which element it is in. Not in edited text, whose
        /// elements may not be in the document (yet).
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, parent.draft.edits == nil,
                  let textView = notification.object as? NSTextView,
                  textView.window?.firstResponder === textView else {
                return
            }
            let text: String = textView.string
            let caret = NSRange(location: textView.selectedRange().location, length: 0)
            // SWIFT: `Range(_:in:)` converts an NSRange (UTF-16 offsets)
            // back to the string's own indices: the reverse of
            // `NSRange(_:in:)`; nil if it doesn't fit the string.
            guard let position = Range(caret, in: text)?.lowerBound,
                  let path = MXXMLText.elementPath(at: position, in: text) else {
                return
            }
            parent.onSelectElement(path)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder

        // A TextKit 2 text view, set up as NSTextView.scrollableTextView()
        // would, but of our class.
        let textView = XMLEditingTextView(usingTextLayoutManager: true)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        // Long lines scroll sideways instead of wrapping, like a code editor.
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 8)

        // Plain text for code: no fonts or styles pasted in, and none of
        // the typing helpers that would change quotes and dashes in XML.
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Self.font
        textView.typingAttributes = Self.baseAttributes

        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        draft.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? XMLEditingTextView,
              let storage = textView.textStorage else {
            return
        }
        let coordinator: Coordinator = context.coordinator
        coordinator.parent = self
        draft.textView = textView
        textView.onEscape = onEscape

        // New text from outside (the document changed, or edits applied):
        // put it in, keeping the caret where it was as far as possible.
        let text: String = draft.text(for: xml)
        let replaced: Bool = text != coordinator.shown
        coordinator.isUpdating = true
        // SWIFT: `defer` runs its block when the scope is left, however it
        // is left: here, after the text and highlight are updated.
        defer {
            coordinator.isUpdating = false
        }
        if replaced {
            let selection: NSRange = textView.selectedRange()
            storage.setAttributedString(NSAttributedString(string: text, attributes: Self.baseAttributes))
            coordinator.shown = text
            let length: Int = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            // Typing undo was about text that is gone.
            textView.forgetTyping()
        }

        // The highlighted element. Scrolled to when the selection changes,
        // or the text is replaced; not while the user types in it.
        let range: NSRange? = Self.range(of: highlightedPath, in: text)
        let pathChanged: Bool = highlightedPath != coordinator.highlightedPath
        if replaced || range != coordinator.highlight {
            Self.color(storage, highlight: range)
        }
        coordinator.highlight = range
        coordinator.highlightedPath = highlightedPath
        // Not when the user is in the text with the caret in it already:
        // they put it there (M7b), and the view shouldn't jump.
        let caret: Int = textView.selectedRange().location
        let userIsThere: Bool = textView.window?.firstResponder === textView
            && range.map { caret >= $0.location && caret <= NSMaxRange($0) } == true
        if let range, replaced || (pathChanged && !userIsThere) {
            // TextKit 2 lays text out lazily and estimates the height of
            // what it hasn't laid out yet, so scrolling to a range in
            // fresh text lands short. Lay it all out first (fine for
            // MaterialX-sized documents), on the next turn of the run
            // loop, when the view has its final size.
            DispatchQueue.main.async {
                if let layout = textView.textLayoutManager {
                    layout.ensureLayout(for: layout.documentRange)
                }
                textView.scrollRangeToVisible(range)
            }
        }
    }

    /// The font of the whole text.
    static let font: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// The attributes of text before it is coloured.
    ///
    /// SWIFT: The attributes are a dictionary keyed by
    /// `NSAttributedString.Key`; values are `Any`.
    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.textColor,
    ]

    /// Where the element at `path` is in `text`, as AppKit's range.
    static func range(of path: String?, in text: String) -> NSRange? {
        guard let path, let found = MXXMLText.range(ofElementAt: path, in: text) else {
            return nil
        }
        // SWIFT: `NSRange(_:in:)` converts a range of String indices to
        // the UTF-16 offsets AppKit uses.
        return NSRange(found, in: text)
    }

    /// Colours the text in `storage` (tag names, attribute names, values,
    /// comments) and highlights `highlight`, in place: the text, the caret
    /// and the undo history stay as they are.
    static func color(_ storage: NSTextStorage, highlight: NSRange?) {
        let text: String = storage.string
        // SWIFT: `beginEditing()`/`endEditing()` batch the changes, so the
        // layout is redone once, not once per attribute.
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        for token in MXXMLText.tokens(in: text) {
            // System colours adapt to light and dark mode.
            let color: NSColor
            switch token.kind {
            case .tagName:
                color = .systemPink
            case .attributeName:
                color = .systemOrange
            case .attributeValue:
                color = .systemTeal
            case .comment:
                color = .systemGreen
            }
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(token.range, in: text))
        }
        if let highlight, NSMaxRange(highlight) <= storage.length {
            storage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.35), range: highlight)
        }
        storage.endEditing()
    }
}
