// ContentView.swift
//
// The document window: a sidebar listing the document's top-level
// elements (or, in its Library tab, the nodes that can be added), the graph canvas (or the XML) in the main area, the issue count
// in the toolbar and library information along the bottom.
//
// The layout of docs/PLAN.md §4.1: the canvas with the bottom panel (XML,
// Issues) under it, and on the right the viewport above the inspector
// (M2b). The toolbar shows or hides each of the right-hand panels. A new
// document first asks what to start from (TemplateSheet, M2e).
//
// Introduces (SWIFT): the `View` protocol, observing an `@Observable` class, `@State`,
// bindings (`$selection`), view modifiers, `NavigationSplitView`, `List`,
// `ForEach`, `ViewBuilder` helpers, private sub-views, enums for view
// modes, `Picker` in a toolbar.

import SwiftUI
import MXKit

/// What the main area shows (PLAN.md §4.1): the canvas, the canvas with
/// the bottom panel (XML, Issues) under it, or the bottom panel alone.
enum ViewMode: String, CaseIterable, Identifiable {
    case graph = "Graph"
    case split = "Split"
    case text = "Text"

    var id: String { rawValue }
}

/// What the sidebar shows: the document's elements, or the node library (M2e).
enum SidebarTab: String, CaseIterable, Identifiable {
    case document = "Document"
    case library = "Library"

    var id: String { rawValue }
}

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

    /// Graph, Split or Text.
    @State private var viewMode: ViewMode = .split

    /// The bottom panel's tab.
    @State private var bottomTab: BottomTab = .xml

    /// The node selected on the canvas (one only), for the XML panel.
    @State private var canvasSelection: String? = nil

    /// The graph level the canvas shows: "" for the document's top level,
    /// or a nodegraph's path. GraphPanel changes it too (double-click, U).
    @State private var graphPath: String = ""

    /// A node for the canvas to select and frame (set from the sidebar).
    @State private var focus: String? = nil

    /// The material shown in the viewport (its MaterialX name).
    @State private var previewMaterial: String? = nil

    /// The element shown alone in the viewport instead (solo preview,
    /// M3d), by path; nil when the viewport shows a material.
    @State private var soloPath: String? = nil

    /// The sidebar's tab.
    @State private var sidebarTab: SidebarTab = .document

    /// A node to add in the middle of the canvas (its nodedef's name),
    /// from the Library tab; GraphPanel adds it and clears this.
    @State private var nodeToAdd: String? = nil

    /// Whether the viewport is shown, at the top of the right-hand column.
    @State private var showsViewport: Bool = true

    /// Whether the inspector is shown, under the viewport.
    @State private var showsInspector: Bool = true

    var body: some View {
        // A two-column layout: sidebar on the left, detail on the right.
        NavigationSplitView {
            // SWIFT: `$selection` is a *binding*, a read/write reference to
            // the `@State` storage. The List writes the user's selection into
            // it. Writing the property name without `$` reads the value; with
            // `$`, you pass the storage itself.
            VStack(spacing: 0) {
                Picker("Sidebar", selection: $sidebarTab) {
                    ForEach(SidebarTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                // SWIFT: A `switch` in a view body, like `if`: each case
                // is one possible view.
                switch sidebarTab {
                case .document:
                    List(document.elements, selection: $selection) { element in
                        ElementRow(element: element)
                    }
                case .library:
                    LibraryPanel(catalog: document.catalog) { definition in
                        if viewMode == .text {
                            viewMode = .split
                        }
                        nodeToAdd = definition.name
                    }
                }
            }
            // SWIFT: Calls like `.navigationSplitViewColumnWidth(...)` are
            // *view modifiers*. Each returns a new view that wraps the old one
            // with extra configuration, which is why they chain.
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            // SWIFT: `HSplitView` puts its children side by side with a
            // draggable divider (AppKit's NSSplitView).
            HSplitView {
                // SWIFT: `VSplitView` stacks its children with draggable
                // dividers between them.
                VSplitView {
                    if viewMode != .text {
                        GraphPanel(document: document, levelPath: $graphPath, focus: $focus,
                                   selectedPath: $canvasSelection, nodeToAdd: $nodeToAdd, soloPath: $soloPath)
                            .frame(minHeight: 200, maxHeight: .infinity)
                    }
                    if viewMode != .graph {
                        BottomPanel(document: document, tab: $bottomTab, selectedPath: canvasSelection,
                                    onSelectIssue: show)
                            .frame(minHeight: 120, idealHeight: 260, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 300, maxWidth: .infinity)
                // The right-hand column (PLAN.md §4.1): the viewport above
                // the inspector, either of them hidden from the toolbar.
                if showsViewport || showsInspector {
                    VSplitView {
                        if showsViewport {
                            ViewportPanel(document: document, materialName: $previewMaterial, soloPath: $soloPath)
                                .frame(minHeight: 160, idealHeight: 320, maxHeight: .infinity)
                        }
                        if showsInspector {
                            // Clicking a connection, or renaming, shows that
                            // node on the canvas, selected.
                            InspectorPanel(document: document, selectedPath: canvasSelection, soloPath: $soloPath) { path in
                                focus = path
                            }
                            .frame(minHeight: 200, idealHeight: 420, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 800)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                // SWIFT: A segmented Picker bound to `viewMode`; each row's
                // `.tag` is the value it writes.
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("The graph, the graph with the XML and Issues panel, or the panel alone")
            }
            ToolbarItem(placement: .status) {
                // Clicking the badge opens the Issues tab.
                Button {
                    if viewMode == .graph {
                        viewMode = .split
                    }
                    bottomTab = .issues
                } label: {
                    IssuesBadge(issues: document.issues, libraryLoaded: document.libraryLoaded)
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .primaryAction) {
                // SWIFT: `Toggle` bound to a Bool; `.toggleStyle(.button)`
                // draws it as a toolbar button that stays pressed when on.
                Toggle(isOn: $showsViewport) {
                    Label("Viewport", systemImage: "cube.transparent")
                }
                .toggleStyle(.button)
                .help("Show or hide the 3D preview")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showsInspector) {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                .help("Show or hide the inspector")
            }
        }
        // Clicking in the sidebar opens a nodegraph, or selects a top-level
        // node in the document's graph.
        .onChange(of: selection) {
            guard let path = selection,
                  let element = document.elements.first(where: { $0.path == path }) else {
                return
            }
            if viewMode == .text {
                viewMode = .split
            }
            if element.type == "material" {
                // Materials also go to the preview.
                previewMaterial = element.name
            }
            if element.category == "nodegraph" {
                graphPath = element.path
            } else {
                graphPath = ""
                focus = element.path
            }
        }
        // File > New: what to start from, before anything else.
        .sheet(isPresented: Binding(get: { document.isChoosingTemplate }, set: { isOpen in
            if !isOpen {
                document.start(from: .empty)
            }
        })) {
            TemplateSheet { template, workingSpace in
                document.start(from: template, workingSpace: workingSpace)
            } onOpen: {
                document.openExistingInstead()
            }
        }
        // A thin bar along the bottom of the window.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryStatusBar(documentVersion: document.content.documentVersion)
        }
    }

    /// Shows an issue's element: opens its graph level and selects its node.
    private func show(_ issue: MXIssue) {
        let location = document.content.canvasLocation(of: issue.elementPath)
        if viewMode == .text {
            viewMode = .split
        }
        graphPath = location.graphPath
        focus = location.nodePath
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
