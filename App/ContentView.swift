// ContentView.swift
//
// The document window: a sidebar listing the document's top-level
// elements (or, in its Library tab, the nodes that can be added), the graph canvas (or the XML) in the main area, the issue count
// in the toolbar and library information along the bottom.
//
// The layout of docs/PLAN.md §4.1: the canvas with the bottom panel (XML,
// Issues) under it, and on the right the viewport above the inspector
// (M2b). The toolbar shows or hides each of the right-hand panels. A new
// document first asks what to start from (TemplateSheet, M2e). ⌘K opens
// the command palette over the window (M4f, NodeSearchPopup.swift). A
// Python script running for longer than a moment shows a sheet with Stop
// (M6c, ScriptRunningSheet).
//
// Introduces (SWIFT): the `View` protocol, observing an `@Observable` class, `@State`,
// bindings (`$selection`), view modifiers, `NavigationSplitView`, `List`,
// `ForEach`, `ViewBuilder` helpers, private sub-views, enums for view
// modes, `Picker` in a toolbar; `.overlayPreferenceValue` and
// `Set.insert(_:).inserted` (M4f); `.interactiveDismissDisabled()` (M6c);
// `.hidden()` to keep a view without showing it (M7c).

import GraphKit
import MXKit
import ScriptKit
import SwiftUI

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

    /// The XML tab's edits not applied yet (M4e). Here, not in the tab,
    /// so they stay when the tab or the panel is hidden.
    @State private var xmlDraft = XMLDraft()

    /// The graph level the canvas shows: "" for the document's top level,
    /// or a nodegraph's path. GraphPanel changes it too (double-click, U).
    @State private var graphPath: String = ""

    /// A node for the canvas to select and frame (set from the sidebar).
    @State private var focus: String? = nil

    /// The element shown alone in the viewport instead (solo preview,
    /// M3d), by path; nil when the viewport shows a material.
    @State private var soloPath: String? = nil

    /// A node to add in the middle of the canvas (its nodedef's name),
    /// from the Library tab; GraphPanel adds it and clears this.
    @State private var nodeToAdd: NodeDefinitionDrag? = nil

    var body: some View {
        // The window, with a thin bar along its bottom. In a VStack, not
        // `.safeAreaInset(edge: .bottom)`: the split views (AppKit's
        // NSSplitView underneath) ignore safe areas, and ran under the bar,
        // hiding the bottom of the XML tab and the inspector.
        VStack(spacing: 0) {
            columns
            LibraryStatusBar(documentVersion: document.content.documentVersion)
        }
        // A hidden inspector is still there, unseen, so the command
        // palette lists its commands (M7c): a view not in the window
        // offers none.
        //
        // SWIFT: `.hidden()` keeps a view in the tree (its state, its
        // preferences, its sheets) but doesn't draw it or let it be
        // clicked, unlike leaving it out with `if`.
        .background {
            if !document.showsInspector {
                inspector
                    .frame(width: 1, height: 1)
                    .hidden()
            }
        }
        // The command palette (⌘K, M4f), over the top of the window while
        // open: what the views offer (the inspector's commands, then the
        // ones above), the menus' and the nodes.
        //
        // SWIFT: `.overlayPreferenceValue` reads a preference the views
        // inside passed up (PaletteCommandsKey), and builds an overlay
        // from it.
        .overlayPreferenceValue(PaletteCommandsKey.self, alignment: .top) { offered in
            if let menuCommands = document.paletteCommands {
                ZStack(alignment: .top) {
                    // A click anywhere else closes it. Nearly transparent,
                    // not `.clear`, which clicks would go through.
                    Color.black.opacity(0.001)
                        .onTapGesture(perform: document.closeCommandPalette)
                    CommandPalette(commands: unique(offered + ordered(menuCommands) + nodeCommands),
                                   onClose: document.closeCommandPalette)
                        .padding(.top, 40)
                }
            }
        }
    }

    // MARK: Command palette (M4f)

    /// The inspector for the selection. Clicking a connection, or
    /// renaming, shows that node on the canvas, selected.
    private var inspector: some View {
        InspectorPanel(document: document, selectedPath: document.selectedPath, soloPath: $soloPath,
                       onShow: { path in focus = path }, levelPath: graphPath,
                       onOpen: { path in
                           if document.viewMode == .text {
                               document.viewMode = .split
                           }
                           graphPath = path
                       })
    }

    /// Every node the document can add (the Tab search's, and an empty
    /// nodegraph, as the Library offers), added in the middle of the
    /// canvas; since M7c, the library files' definitions too, whose file
    /// adding one includes.
    private var nodeCommands: [PaletteCommand] {
        // Listed once something is typed: before, they would only push
        // the commands down.
        let emptyGraph = PaletteCommand(title: "nodegraph", group: "Add Node", listsBeforeTyping: false) {
            add(NodeDefinitionDrag(nodeDef: NodeDefinitionDrag.emptyNodeGraph))
        }
        // SWIFT: `[emptyGraph] + ...map { }`: an array literal joined to
        // the mapped array.
        return [emptyGraph] + document.catalog.kinds.map { kind in
            PaletteCommand(title: kind.node, group: Self.paletteGroup(of: kind), listsBeforeTyping: false) {
                add(NodeDefinitionDrag(nodeDef: kind.defaultVariant.name, libraryFile: kind.libraryFile))
            }
        }
    }

    /// The palette's group for adding a node of `kind`: "Add Node · math",
    /// or, for a library file's, "Add Node · tiles.mtlx" (M7c).
    private static func paletteGroup(of kind: MXNodeKind) -> String {
        guard let detail = kind.libraryFile?.lastPathComponent ?? kind.group else {
            return "Add Node"
        }
        return "Add Node · " + detail
    }

    /// Adds a node in the middle of the canvas, showing the canvas first.
    private func add(_ node: NodeDefinitionDrag) {
        if document.viewMode == .text {
            document.viewMode = .split
        }
        nodeToAdd = node
    }

    /// The menus' commands, the app menu's (About, Hide, Quit) last
    /// rather than first: they are the least likely to be looked for here,
    /// and lead the list before anything is typed.
    private func ordered(_ menuCommands: [PaletteCommand]) -> [PaletteCommand] {
        let appMenu: String = ProcessInfo.processInfo.processName
        // SWIFT: `filter` twice keeps each half in its order.
        return menuCommands.filter { $0.group != appMenu } + menuCommands.filter { $0.group == appMenu }
    }

    /// `commands` without repeats (the same group and title), keeping the
    /// first of each.
    ///
    /// SWIFT: `Set.insert` returns a tuple whose `inserted` is false if
    /// the element was already there: a one-line "first time seen?" test.
    private func unique(_ commands: [PaletteCommand]) -> [PaletteCommand] {
        var seen: Set<String> = []
        return commands.filter { seen.insert($0.id).inserted }
    }

    /// The sidebar and the detail: canvas, bottom panel, viewport and inspector.
    private var columns: some View {
        // A two-column layout: sidebar on the left, detail on the right.
        NavigationSplitView {
            // SWIFT: `$selection` is a *binding*, a read/write reference to
            // the `@State` storage. The List writes the user's selection into
            // it. Writing the property name without `$` reads the value; with
            // `$`, you pass the storage itself.
            VStack(spacing: 0) {
                Picker("Sidebar", selection: Bindable(document).sidebarTab) {
                    ForEach(SidebarTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("The document's elements (\(Shortcut.documentSidebar.symbols)), or the nodes to add "
                      + "(\(Shortcut.librarySidebar.symbols))")
                .padding(8)
                // SWIFT: A `switch` in a view body, like `if`: each case
                // is one possible view.
                switch document.sidebarTab {
                case .document:
                    List(document.elements, selection: $selection) { element in
                        ElementRow(element: element)
                    }
                case .library:
                    LibraryPanel(catalog: document.catalog, documentFolder: document.fileURL?.deletingLastPathComponent(),
                                 documentFile: document.fileURL) { item in
                        add(item)
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
                    if document.viewMode != .text {
                        GraphPanel(document: document, levelPath: $graphPath, focus: $focus,
                                   selectedPath: Bindable(document).selectedPath, nodeToAdd: $nodeToAdd, soloPath: $soloPath)
                            .frame(minHeight: 200, maxHeight: .infinity)
                    }
                    if document.viewMode != .graph {
                        BottomPanel(document: document, tab: Bindable(document).bottomTab, xmlDraft: xmlDraft, selectedPath: document.selectedPath,
                                    onSelectIssue: show, onSelectElement: follow)
                            .frame(minHeight: 120, idealHeight: 260, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 300, maxWidth: .infinity)
                // The right-hand column (PLAN.md §4.1): the viewport above
                // the inspector, either of them hidden from the toolbar.
                if document.showsViewport || document.showsInspector {
                    VSplitView {
                        if document.showsViewport {
                            // SWIFT: `Bindable(document)` makes bindings to an
                            // @Observable object's properties, as `$` does
                            // for @State: the picker changes the document's.
                            ViewportPanel(document: document, materialName: Bindable(document).previewMaterial,
                                          soloPath: $soloPath)
                                .frame(minHeight: 160, idealHeight: 320, maxHeight: .infinity)
                        }
                        if document.showsInspector {
                            inspector
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
                Picker("View", selection: Bindable(document).viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("The graph (\(Shortcut.graphView.symbols)), the graph with the panel under it "
                      + "(\(Shortcut.splitView.symbols)), or the panel alone (\(Shortcut.textView.symbols))")
            }
            ToolbarItem(placement: .status) {
                // Clicking the badge opens the Issues tab.
                Button {
                    if document.viewMode == .graph {
                        document.viewMode = .split
                    }
                    document.bottomTab = .issues
                } label: {
                    IssuesBadge(issues: document.issues, libraryLoaded: document.libraryLoaded)
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .primaryAction) {
                // SWIFT: `Toggle` bound to a Bool; `.toggleStyle(.button)`
                // draws it as a toolbar button that stays pressed when on.
                Toggle(isOn: Bindable(document).showsViewport) {
                    Label("Viewport", systemImage: "cube.transparent")
                }
                .toggleStyle(.button)
                .help("Show or hide the 3D preview (\(Shortcut.viewport.symbols))")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: Bindable(document).showsInspector) {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                .help("Show or hide the inspector (\(Shortcut.inspector.symbols))")
            }
        }
        // A script's `margolaria.select()` (M6b): the element's graph, and
        // the element selected in it.
        // A library file saved (Save to Library…): the node searches list
        // its definitions (M7c).
        .onReceive(NotificationCenter.default.publisher(for: .margolariaLibrariesChanged)) { _ in
            document.refreshCatalog()
        }
        .onChange(of: document.selectionRequest) {
            guard let path = document.selectionRequest else {
                return
            }
            document.selectionRequest = nil
            if document.viewMode == .text {
                document.viewMode = .split
            }
            graphPath = path.split(separator: "/").dropLast().joined(separator: "/")
            focus = path
        }
        // Clicking in the sidebar opens a nodegraph, or selects a top-level
        // node in the document's graph.
        .onChange(of: selection) {
            guard let path = selection,
                  let element = document.elements.first(where: { $0.path == path }) else {
                return
            }
            if document.viewMode == .text {
                document.viewMode = .split
            }
            if element.type == "material" {
                // Materials also go to the preview.
                document.previewMaterial = element.name
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
        // A script running for longer than a moment (M6c), with Stop. It
        // closes by itself when the script ends.
        //
        // SWIFT: A second `.sheet` on the same view: SwiftUI shows one at
        // a time, and these never come together (a new document's
        // template question comes before any script).
        .sheet(isPresented: Binding(get: { document.scriptRun != nil }, set: { _ in })) {
            ScriptRunningSheet(run: document.scriptRun)
        }
        // A script run from File > Run Script… or the Scripts menu printed
        // something, or failed, or a startup script did (M6d): the Console
        // shows it. Also when that came before the window was open.
        .onChange(of: document.consoleRequests) {
            document.showPanel(.console)
        }
        .onAppear {
            if document.consoleRequests > 0 {
                document.showPanel(.console)
            }
        }
    }

    /// Selects on the canvas the element the caret is in, in the XML tab
    /// (M7b): its node (an input's node), on its graph level. Only for
    /// elements the canvas shows, and only while it is open: the caret
    /// in a nodedef leaves the canvas where it is.
    private func follow(_ path: String) {
        let location = document.content.canvasLocation(of: path)
        guard document.viewMode != .text, let node = location.nodePath, node != document.selectedPath,
              let level = try? document.content.graph(at: location.graphPath) else {
            return
        }
        let name: String = String(node.split(separator: "/").last ?? "")
        let isShown: Bool = level.nodes.contains { $0.name == name } || level.outputs.contains { $0.name == name }
            || level.interfaceInputs.contains { $0.name == name } || level.backdrops.contains { $0.name == name }
        guard isShown else {
            return
        }
        graphPath = location.graphPath
        focus = node
    }

    /// Shows an issue's element: opens its graph level and selects its node.
    private func show(_ issue: MXIssue) {
        let location = document.content.canvasLocation(of: issue.elementPath)
        if document.viewMode == .text {
            document.viewMode = .split
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

/// Shown while a script runs for longer than a moment (M6c): its name, and
/// Stop, which raises KeyboardInterrupt in it. Behind it, the window shows
/// the document as it was before the script.
private struct ScriptRunningSheet: View {
    let run: ScriptRun?

    @State private var stopping: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Running \(run?.name ?? "Script")…")
                .font(.headline)
            Text(stopping
                ? "Stopping at the script's next line of Python. Its changes will be taken back."
                : "The window shows the document as it was before the script, until it ends.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Stop") {
                stopping = true
                run?.stop()
            }
            // Escape, and ⌘. as AppKit's Cancel buttons.
            .keyboardShortcut(.cancelAction)
            .disabled(stopping)
        }
        .padding(20)
        .frame(width: 320)
        // SWIFT: `.interactiveDismissDisabled()`: the sheet can't be closed
        // by the user (Escape is Stop's); it closes when the script ends.
        .interactiveDismissDisabled()
    }
}
