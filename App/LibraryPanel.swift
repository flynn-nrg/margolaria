// LibraryPanel.swift
//
// The sidebar's Library tab (M2e): every node the document can add, from
// the MaterialX data libraries and the document's own nodedefs, grouped by
// `nodegroup`, with a search field. Each node is listed once; it is added
// as its default type variant, and the inspector's Type menu changes it
// afterwards (see MXNodeCatalog).
//
// A node is added by dragging it onto the canvas, or by double-clicking it
// (or pressing Return), which puts it in the middle of the canvas. The
// first row, "nodegraph", adds an empty nodegraph (M4a).
//
// Libraries (M4c2): the definitions saved in the user library folder (My
// Library) and in the document's folder are listed after it, until the
// document has them. Adding one includes its file in the document
// (`xi:include`), then adds the node.
//
// Introduces (SWIFT): `Transferable` and `CodableRepresentation` (drag and
// drop of our own data), declaring a `UTType`, `Codable`, `Section(isExpanded:)`,
// `.contextMenu(forSelectionType:primaryAction:)`; `.tag` on a row outside
// a `ForEach` (M4a); `.task(id:)`, `.onReceive` with a notification,
// tuples as list rows (M4c2).

import MXKit
import SwiftUI
import UniformTypeIdentifiers

/// What a node dragged from the library carries: the nodedef to add.
///
/// SWIFT: `Transferable` is SwiftUI's protocol for values that can be
/// dragged, dropped, copied and shared. `transferRepresentation` says how
/// the value travels: here, encoded (as JSON) under a type of our own, so
/// only the canvas accepts it; a text field won't take it as text.
///
/// SWIFT: `Codable` (Encodable + Decodable) lets the compiler write the
/// encoding and decoding code for a struct whose properties are Codable.
struct NodeDefinitionDrag: Codable, Equatable, Transferable {
    /// The nodedef's name, such as "ND_image_color3", or
    /// ``emptyNodeGraph``.
    let nodeDef: String
    /// The library file defining it, for a definition the document doesn't
    /// have yet (M4c2): adding the node includes the file first.
    var libraryFile: URL? = nil

    /// What the library's "nodegraph" row carries: not a nodedef (whose
    /// names start with "ND_" by convention, and never are just this), but
    /// an empty nodegraph to add.
    static let emptyNodeGraph: String = "nodegraph"

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .margolariaNodeDefinition)
    }
}

extension UTType {
    /// A node from the library being dragged. Declared in Info.plist
    /// (`UTExportedTypeDeclarations`), which `exportedAs:` requires.
    static let margolariaNodeDefinition = UTType(exportedAs: "eu.emerald-isle.margolaria.nodedef")
}

/// Posted after a library file is written (Save to Library…), so Library
/// panels read their folders again.
extension Notification.Name {
    static let margolariaLibrariesChanged = Notification.Name("MargolariaLibrariesChanged")
}

/// The Library tab.
struct LibraryPanel: View {
    let catalog: MXNodeCatalog
    /// The document's folder, whose library files are listed too (M4c2);
    /// nil for a document never saved.
    let documentFolder: URL?
    /// The document's own file, left out of its folder's list.
    let documentFile: URL?
    /// Adds a node of this nodedef (by name, or
    /// NodeDefinitionDrag.emptyNodeGraph), from a library file if it says
    /// so, in the middle of the canvas.
    let onAdd: (NodeDefinitionDrag) -> Void

    /// The library files found: the user library folder's, then the
    /// document folder's. Read when the panel appears, and again after
    /// Save to Library.
    @State private var libraries: [MXLibraryFolder] = []

    @State private var query: String = ""

    /// The groups whose nodes are shown. The document's own nodes start
    /// open; the libraries' groups are long, so they start closed.
    @State private var expandedGroups: Set<String> = ["document"]

    /// The node selected in the list, by category.
    @State private var selection: MXNodeKind.ID? = nil

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query, prompt: Text("Search nodes"))
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            List(selection: $selection) {
                if query.isEmpty || "nodegraph".localizedCaseInsensitiveContains(query) {
                    NodeGraphRow()
                        // SWIFT: `.tag` gives a row that isn't from a
                        // ForEach its ID, so the List can select it.
                        .tag(NodeDefinitionDrag.emptyNodeGraph)
                }
                ForEach(libraries, id: \.title) { library in
                    let rows: [(file: MXLibraryFile, definition: MXNodeDefinition)] = libraryRows(library.files)
                    if !rows.isEmpty {
                        Section(library.title) {
                            ForEach(rows, id: \.definition.name) { row in
                                LibraryFileRow(file: row.file, definition: row.definition)
                                    .tag(Self.libraryTag(row.file, row.definition))
                            }
                        }
                    }
                }
                // The catalog's "In Library Files" group (M7c, for the
                // searches) is left out: the sections above list those
                // definitions by file.
                if query.isEmpty {
                    ForEach(catalog.groups.filter { $0.name != "library" }) { group in
                        // SWIFT: `Section(isExpanded:)` makes a section the
                        // user can fold with the disclosure triangle in its
                        // header (macOS 14).
                        Section(isExpanded: isExpanded(group.name)) {
                            ForEach(group.kinds) { kind in
                                LibraryRow(kind: kind, showsGroup: false)
                            }
                        } header: {
                            Text(group.title)
                        }
                    }
                } else {
                    ForEach(catalog.search(query).filter { $0.libraryFile == nil }) { kind in
                        LibraryRow(kind: kind, showsGroup: true)
                    }
                }
            }
            // SWIFT: `contextMenu(forSelectionType:menu:primaryAction:)`
            // gives the list's rows a context menu, and `primaryAction` runs
            // on double-click or Return, with the IDs of the rows concerned.
            .contextMenu(forSelectionType: MXNodeKind.ID.self) { ids in
                if let item = ids.first.flatMap(nodeDefinition(for:)) {
                    Button(item.nodeDef == NodeDefinitionDrag.emptyNodeGraph ? "Add Empty Nodegraph"
                                                                             : "Add \(item.nodeDef)") {
                        onAdd(item)
                    }
                }
            } primaryAction: { ids in
                if let item = ids.first.flatMap(nodeDefinition(for:)) {
                    onAdd(item)
                }
            }
            // SWIFT: `.task(id:)` runs when the view appears and again when
            // the id changes (another document folder); `.onReceive` runs
            // for each notification posted.
            .task(id: documentFolder) {
                loadLibraries()
            }
            .onReceive(NotificationCenter.default.publisher(for: .margolariaLibrariesChanged)) { _ in
                loadLibraries()
            }
        }
    }

    /// What the row `id` adds: its node's default variant, an empty
    /// nodegraph, or a definition from a library file.
    private func nodeDefinition(for id: MXNodeKind.ID) -> NodeDefinitionDrag? {
        if id == NodeDefinitionDrag.emptyNodeGraph {
            return NodeDefinitionDrag(nodeDef: id)
        }
        for library in libraries {
            for (file, definition) in libraryRows(library.files) where Self.libraryTag(file, definition) == id {
                return NodeDefinitionDrag(nodeDef: definition.name, libraryFile: file.url)
            }
        }
        return catalog.kind(named: id).map { NodeDefinitionDrag(nodeDef: $0.defaultVariant.name) }
    }

    /// A library row's ID in the list: its file and nodedef, unlike any
    /// node category.
    private static func libraryTag(_ file: MXLibraryFile, _ definition: MXNodeDefinition) -> String {
        file.url.path(percentEncoded: false) + "#" + definition.name
    }

    /// The definitions of `files` to list: those the document doesn't
    /// have yet (once included, they are the document's), matching the
    /// search.
    private func libraryRows(_ files: [MXLibraryFile]) -> [(file: MXLibraryFile, definition: MXNodeDefinition)] {
        files.flatMap { file in
            file.definitions.map { (file: file, definition: $0) }
        }
        .filter { row in
            // The catalog lists library files' definitions too (M7c), with
            // their file; one without is the document's. (One it doesn't
            // list yet was just saved; the catalog follows.)
            catalog.definition(named: row.definition.name).map { $0.libraryFile != nil } ?? true
                && (query.isEmpty || row.definition.node.localizedCaseInsensitiveContains(query))
        }
    }

    /// Reads the library folders.
    private func loadLibraries() {
        libraries = MXLibraryFolders.libraries(for: documentFile)
    }

    /// A binding to whether `group` is open, stored in `expandedGroups`.
    ///
    /// SWIFT: `Binding(get:set:)` makes a binding out of two closures, for
    /// state that isn't a single property, like membership of a Set.
    private func isExpanded(_ group: String) -> Binding<Bool> {
        Binding {
            expandedGroups.contains(group)
        } set: { isOpen in
            if isOpen {
                expandedGroups.insert(group)
            } else {
                expandedGroups.remove(group)
            }
        }
    }
}

/// The first row: an empty nodegraph, to build a group of nodes in (M4a).
/// Nodes can also be collapsed into one (Graph > Collapse into Nodegraph).
private struct NodeGraphRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("nodegraph")
            Text("An empty nodegraph")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help("A nodegraph: a group of nodes with inputs and outputs of its own, shown as one node. "
            + "Selected nodes can also be collapsed into one with ⌥⌘G.")
        .draggable(NodeDefinitionDrag(nodeDef: NodeDefinitionDrag.emptyNodeGraph)) {
            Label("nodegraph", systemImage: "square.on.square")
                .padding(6)
                .background(.regularMaterial, in: .rect(cornerRadius: 6))
        }
    }
}

/// A definition in a library file (M4c2): its node, and the file it is in.
/// Adding it includes the file in the document.
private struct LibraryFileRow: View {
    let file: MXLibraryFile
    let definition: MXNodeDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(definition.node)
            Text("\(definition.type) · \(file.url.lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help((definition.documentation.map { $0 + "\n" } ?? "") + file.url.path(percentEncoded: false))
        .draggable(NodeDefinitionDrag(nodeDef: definition.name, libraryFile: file.url)) {
            Label(definition.node, systemImage: "shippingbox")
                .padding(6)
                .background(.regularMaterial, in: .rect(cornerRadius: 6))
        }
    }
}

/// One node in the library: its name, and what it makes.
private struct LibraryRow: View {
    let kind: MXNodeKind
    /// Search results mix groups, so they say which one each node is in.
    let showsGroup: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(kind.node)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(kind.documentation ?? kind.node)
        // SWIFT: `.draggable` makes the row a drag source carrying the
        // value; the canvas's `.dropDestination` receives it (GraphPanel).
        .draggable(NodeDefinitionDrag(nodeDef: kind.defaultVariant.name)) {
            Label(kind.node, systemImage: "circle.grid.cross")
                .padding(6)
                .background(.regularMaterial, in: .rect(cornerRadius: 6))
        }
    }

    /// "color3 · 19 types", or "pbr · surfaceshader" in search results.
    private var subtitle: String {
        var parts: [String] = []
        if showsGroup, let group = kind.group {
            parts.append(group)
        }
        parts.append(kind.defaultVariant.type)
        if kind.variants.count > 1 {
            parts.append("\(kind.variants.count) types")
        }
        return parts.joined(separator: " · ")
    }
}
