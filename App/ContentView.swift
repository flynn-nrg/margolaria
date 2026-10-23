// ContentView.swift
//
// The document window for the M0 skeleton: a sidebar listing the document's
// top-level elements, the XML in the main area, the issue count in the
// toolbar and library information along the bottom.
//
// This is a placeholder for the real interface (docs/PLAN.md §4). Its job is
// to prove that a document flows from disk, through MaterialX, to the screen.
//
// Introduces (SWIFT): the `View` protocol, observing an `@Observable` class, `@State`,
// bindings (`$selection`), view modifiers, `NavigationSplitView`, `List`,
// `ForEach`, `ViewBuilder` helpers, private sub-views.

import SwiftUI
import MXKit

/// The main window content for one document.
///
/// SWIFT: A SwiftUI view is a struct conforming to `View`, whose `body`
/// describes the UI for the current state. SwiftUI calls `body` again whenever
/// that state changes and updates only what differs. You never hold on to a
/// view or mutate it.
struct ContentView: View {
    /// The open document. It is owned by AppKit's document controller; the
    /// window only shows it.
    ///
    /// SWIFT: A plain `let`. MaterialXDocument is `@Observable`, so SwiftUI
    /// records which of its properties `body` reads (`elements`, `xml`, ...)
    /// and calls `body` again when one of those changes. No property wrapper
    /// is needed; the older `ObservableObject` protocol needed
    /// `@ObservedObject` here.
    let document: MaterialXDocument

    /// The element selected in the sidebar, identified by its name.
    ///
    /// SWIFT: `@State` is storage that SwiftUI owns and keeps alive between
    /// calls to `body`, even though this struct itself is re-created each time.
    /// Changing it triggers a redraw. `private` because state belongs to this
    /// view alone. `MXElementSummary.ID` is the element's `id` type (String),
    /// and it's optional because nothing may be selected.
    @State private var selection: MXElementSummary.ID?

    var body: some View {
        // A two-column layout: sidebar on the left, detail on the right.
        NavigationSplitView {
            // SWIFT: `$selection` is a *binding*, a read/write reference to
            // the `@State` storage. The List writes the user's selection into
            // it. Writing the property name without `$` reads the value; with
            // `$`, you pass the storage itself.
            List(document.elements, selection: $selection) { element in
                ElementRow(element: element)
            }
            // SWIFT: Calls like `.navigationSplitViewColumnWidth(...)` are
            // *view modifiers*. Each returns a new view that wraps the old one
            // with extra configuration, which is why they chain.
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            XMLTextView(xml: document.xml)
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                IssuesBadge(issues: document.issues, libraryLoaded: document.libraryLoaded)
            }
        }
        // A thin bar along the bottom of the window.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryStatusBar(documentVersion: document.content.documentVersion)
        }
    }
}

/// One row in the sidebar: icon, name, and "category · type".
///
/// SWIFT: `private` sub-views keep ContentView's `body` short. Splitting views
/// up costs nothing: SwiftUI views are plain structs, not AppKit objects.
private struct ElementRow: View {
    let element: MXElementSummary

    var body: some View {
        // SWIFT: `Label` pairs a title with an SF Symbol icon. SF Symbols are
        // Apple's built-in icon set; names like "circle.lefthalf.filled" come
        // from the SF Symbols app.
        Label {
            // SWIFT: `VStack` stacks its children vertically, `HStack`
            // horizontally. `alignment: .leading` left-aligns them.
            VStack(alignment: .leading, spacing: 1) {
                Text(element.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: iconName)
        }
    }

    /// "category · type", or just the category if the element is untyped.
    private var subtitle: String {
        // SWIFT: The ternary operator works as in C.
        element.type.isEmpty ? element.category : "\(element.category) · \(element.type)"
    }

    /// An SF Symbol name chosen by element kind.
    private var iconName: String {
        // SWIFT: `switch` on a String. Cases can't fall through, and a
        // `default` is required because Strings can't be checked exhaustively.
        // The first case matches either of two values.
        switch element.category {
        case "surfacematerial", "volumematerial":
            return "circle.lefthalf.filled"
        case "nodegraph":
            return "square.grid.3x3"
        case "nodedef":
            return "doc.text"
        case "look", "materialassign":
            return "eye"
        default:
            // Everything else at the top level is a node.
            return "circle.grid.cross"
        }
    }
}

/// The document's XML, selectable, in a monospaced font.
private struct XMLTextView: View {
    let xml: String

    var body: some View {
        // Scrolls in both directions, because MaterialX lines can be long.
        ScrollView([.horizontal, .vertical]) {
            Text(xml)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                // SWIFT: `.infinity` lets the text take all available width,
                // then aligns it to the top left instead of centring it.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
        }
    }
}

/// "Valid" in green, or the number of problems with the messages as a
/// tooltip: red if any is an error, orange for warnings only.
private struct IssuesBadge: View {
    let issues: [MXIssue]
    let libraryLoaded: Bool

    var body: some View {
        // SWIFT: `if` can appear directly inside a view body, because the
        // result builder turns each branch into one possible view.
        if !libraryLoaded {
            Label("Not validated", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help(libraryErrorDescription)
        } else if issues.isEmpty {
            Label("Valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label(issues.count == 1 ? "1 issue" : "\(issues.count) issues", systemImage: "exclamationmark.triangle.fill")
                // SWIFT: `contains(where:)` is true if the closure is true for
                // any element.
                .foregroundStyle(issues.contains(where: { $0.severity == .error }) ? .red : .orange)
                // Hover to see the messages. The Issues panel comes in M1d.
                // SWIFT: `joined(separator:)` concatenates an array of Strings.
                .help(issues.map { "\($0.elementPath): \($0.message)" }.joined(separator: "\n"))
        }
    }

    /// The library loading error, for the tooltip.
    private var libraryErrorDescription: String {
        // SWIFT: `if case .failure(let error) = ...` matches one enum case and
        // binds its value, without a full `switch`.
        if case .failure(let error) = MXLibrary.bundled {
            return String(describing: error)
        }
        return ""
    }
}

/// Library information along the bottom of the window, like the mockup's status bar.
private struct LibraryStatusBar: View {
    let documentVersion: String

    var body: some View {
        HStack {
            Text(summary)
            // SWIFT: `Spacer` takes up all the free space in a stack, pushing
            // the views on either side of it apart.
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        // SWIFT: `.bar` is the system material used for toolbars and bars.
        .background(.bar)
    }

    /// For example "Document v1.39 · MaterialX 1.39.5 · 56 library files · 807 nodedefs".
    private var summary: String {
        let versions = "Document v\(documentVersion) · MaterialX \(MXDocument.libraryVersion)"
        switch MXLibrary.bundled {
        case .success(let library):
            return "\(versions) · \(library.fileCount) library files · \(library.nodeDefinitionCount) nodedefs"
        case .failure:
            return "\(versions) · data libraries not loaded"
        }
    }
}
