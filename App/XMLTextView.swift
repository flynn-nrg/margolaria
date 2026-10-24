// XMLTextView.swift
//
// The document's XML, read-only, with syntax colouring, in an AppKit text
// view (TextKit 2). The element selected on the canvas is highlighted and
// scrolled into view. ⌘F searches (the standard find bar).
//
// The text is MaterialX's own serialisation of the document (what Save
// would write), not the file's original bytes: identical for files
// MaterialX wrote, normalised for others. Editing comes in M4 (two-way XML).
//
// Introduces (SWIFT): an `NSViewRepresentable` with a `Coordinator` (state
// that lives as long as the AppKit view), `NSAttributedString` attributes,
// `NSRange(_:in:)` to convert Swift string ranges for AppKit.

import AppKit
import MXKit
import SwiftUI

struct XMLTextView: NSViewRepresentable {
    /// The XML to show.
    let xml: String
    /// The path of the element to highlight, such as "NG_copper/grain".
    let highlightedPath: String?

    /// What the view showed last time, so updates only redo what changed.
    ///
    /// SWIFT: SwiftUI creates one coordinator per AppKit view and keeps it
    /// as long as the view exists (`context.coordinator`), unlike the
    /// representable struct itself, which is re-created on every update.
    /// It's the place for state the AppKit side needs to remember.
    final class Coordinator {
        var xml: String = ""
        var highlight: NSRange? = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        // A scroll view with a TextKit 2 text view inside, as AppKit makes it.
        let scrollView: NSScrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        // Long lines scroll sideways instead of wrapping, like a code editor.
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.hasHorizontalScroller = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else {
            return
        }
        let coordinator: Coordinator = context.coordinator
        if coordinator.xml != xml {
            storage.setAttributedString(Self.colored(xml))
            coordinator.xml = xml
            coordinator.highlight = nil
        }

        // The highlighted element.
        var range: NSRange? = nil
        if let path = highlightedPath, let found = MXXMLText.range(ofElementAt: path, in: xml) {
            // SWIFT: `NSRange(_:in:)` converts a range of String indices to
            // the UTF-16 offsets AppKit uses.
            range = NSRange(found, in: xml)
        }
        if range != coordinator.highlight {
            if let old = coordinator.highlight {
                storage.removeAttribute(.backgroundColor, range: old)
            }
            if let range {
                storage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.35), range: range)
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
            coordinator.highlight = range
        }
    }

    /// `xml` in a monospaced font, with tag names, attribute names, values
    /// and comments coloured.
    static func colored(_ xml: String) -> NSAttributedString {
        let font: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // SWIFT: The attributes are a dictionary keyed by
        // `NSAttributedString.Key`; values are `Any`.
        let text = NSMutableAttributedString(string: xml, attributes: [
            .font: font,
            .foregroundColor: NSColor.textColor,
        ])
        for token in MXXMLText.tokens(in: xml) {
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
            text.addAttribute(.foregroundColor, value: color, range: NSRange(token.range, in: xml))
        }
        return text
    }
}
