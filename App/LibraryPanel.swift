// LibraryPanel.swift
//
// The sidebar's Library tab (M2e): every node the document can add, from
// the MaterialX data libraries and the document's own nodedefs, grouped by
// `nodegroup`, with a search field. Each node is listed once; it is added
// as its default type variant, and the inspector's Type menu changes it
// afterwards (see MXNodeCatalog).
//
// A node is added by dragging it onto the canvas, or by double-clicking it
// (or pressing Return), which puts it in the middle of the canvas.
//
// Introduces (SWIFT): `Transferable` and `CodableRepresentation` (drag and
// drop of our own data), declaring a `UTType`, `Codable`, `Section(isExpanded:)`,
// `.contextMenu(forSelectionType:primaryAction:)`.

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
struct NodeDefinitionDrag: Codable, Transferable {
    /// The nodedef's name, such as "ND_image_color3".
    let nodeDef: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .margolariaNodeDefinition)
    }
}

extension UTType {
    /// A node from the library being dragged. Declared in Info.plist
    /// (`UTExportedTypeDeclarations`), which `exportedAs:` requires.
    static let margolariaNodeDefinition = UTType(exportedAs: "eu.emerald-isle.margolaria.nodedef")
}

/// The Library tab.
struct LibraryPanel: View {
    let catalog: MXNodeCatalog
    /// Adds a node of this nodedef in the middle of the canvas.
    let onAdd: (MXNodeDefinition) -> Void

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
                if query.isEmpty {
                    ForEach(catalog.groups) { group in
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
                    ForEach(catalog.search(query)) { kind in
                        LibraryRow(kind: kind, showsGroup: true)
                    }
                }
            }
            // SWIFT: `contextMenu(forSelectionType:menu:primaryAction:)`
            // gives the list's rows a context menu, and `primaryAction` runs
            // on double-click or Return, with the IDs of the rows concerned.
            .contextMenu(forSelectionType: MXNodeKind.ID.self) { ids in
                if let kind = ids.first.flatMap({ catalog.kind(named: $0) }) {
                    Button("Add \(kind.node)") {
                        onAdd(kind.defaultVariant)
                    }
                }
            } primaryAction: { ids in
                if let kind = ids.first.flatMap({ catalog.kind(named: $0) }) {
                    onAdd(kind.defaultVariant)
                }
            }
        }
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
