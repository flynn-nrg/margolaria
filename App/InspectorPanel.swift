// InspectorPanel.swift
//
// The inspector (PLAN.md §4.1, region 5; M2b): the element selected on the
// canvas, with every input, grouped by the nodedef's `uifolder`.
//
// With nothing selected: the document's version and working space. For a
// nodegraph, its working space too (WorkingSpaceMenu.swift), and its inputs
// and outputs, which can be added, renamed and removed (M4a, M4b); a
// selected graph input or output can be renamed and removed too, and a
// graph input's presentation (label, folder, ranges, choices, description)
// edited. Right-clicking an unconnected input of a node inside a nodegraph
// offers to promote it to the graph's interface (M4b).
//
// Node definitions (M4c1): a top-level nodegraph with outputs has a "Make
// Node Definition…" button, whose sheet names the new kind of node. A
// nodegraph implementing a definition made in this document keeps its
// inputs, defaults and presentation editable (they are the nodedef's), and
// shows the definition's group, version and description, and Save to
// Library… (M4c2), which writes it to a file other documents can use.
//
// For a node: its name (editable, to rename it), category, nodedef, type
// variant (a menu, M2e) and description, then its inputs. Inputs the document sets are marked with a
// dot; the others show the nodedef's default, dimmed, and setting one adds
// it to the document. Connected inputs show where they come from, and a
// click shows that node on the canvas. Inputs the nodedef calls advanced
// stay hidden until asked for.
//
// Every change goes through MaterialXDocument.edit, so it can be undone;
// a slider or colour drag is one undo step. The panel reads the element
// from the document again after each change (`document.revision`).
//
// Backdrops (M4d): their name (to rename them), what they contain, and their
// note, which the canvas shows under the title.
//
// The command palette (M4f) lists the panel's buttons for the selection
// (`.paletteCommands`): Edit Definition, Show in Viewport Alone, Make Node
// Definition…, Save to Library…, adding and removing a graph's inputs and
// outputs. Not the inputs' own right-click actions (Reset, Promote).
//
// Read-only: elements from `xi:include`d files (saving writes the include
// back, so changes would be lost), and the inputs of a nodegraph that
// implements a nodedef (their defaults belong to the nodedef: M4).
//
// Introduces (SWIFT): `DisclosureGroup`, `ScrollView`, `let _ =` to make a
// view observe a property it doesn't otherwise use, `firstIndex(where:)`
// and changing an array element in place, `.contentShape`; `.sheet`,
// `@Environment(\.dismiss)`, `Form`, `TextField(axis:)` (M4c1).

import GraphKit
import MXKit
import PreviewKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorPanel: View {
    let document: MaterialXDocument
    /// The path of the element selected on the canvas, or nil.
    let selectedPath: String?
    /// The element shown alone in the viewport (M3d); the node header's
    /// button sets and clears it.
    @Binding var soloPath: String?
    /// Shows the element at a path on the canvas (a connection's source,
    /// or a node just renamed).
    let onShow: (String) -> Void
    /// The graph level the canvas shows: with nothing selected inside a
    /// nodegraph, the inspector shows the nodegraph itself (M4c1).
    let levelPath: String
    /// Opens a graph level on the canvas ("" for the document): a
    /// definition's implementation, or back up after deleting it.
    let onOpen: (String) -> Void

    var body: some View {
        // SWIFT: Reading `document.revision` makes SwiftUI call `body`
        // again after every edit, undo and redo. `content` changes in place,
        // which Observation can't see; the revision is how it is told. `let _ =`
        // reads a value and throws it away, which is allowed in a view body.
        let _ = document.revision
        VStack(spacing: 0) {
            if let selectedPath, let element = lookUp(selectedPath) {
                ScrollView {
                    InspectedElementView(document: document, element: element, soloPath: $soloPath, onShow: onShow,
                                         onOpen: onOpen)
                        .padding(12)
                }
                // A new set of editors for each element. Otherwise SwiftUI
                // reuses them, and a colour well connected to the colour
                // panel stays connected while showing another node's colour:
                // the panel keeps the old colour, and dragging in it would
                // set the new node's input. A fresh well, clicked, connects
                // and sends the panel its own colour.
                .id(selectedPath)
            } else if !levelPath.isEmpty, let graph = lookUp(levelPath) {
                // Nothing selected inside a nodegraph: the nodegraph, its
                // interface and (for a definition) its settings.
                ScrollView {
                    InspectedElementView(document: document, element: graph, soloPath: $soloPath, onShow: onShow,
                                         onOpen: onOpen)
                        .padding(12)
                }
                .id(levelPath)
            } else {
                // Nothing selected: the document's own settings.
                DocumentSettings(document: document)
                    .padding(12)
                Divider()
                ContentUnavailableView("No Selection", systemImage: "slider.horizontal.3",
                                       description: Text("Select one node on the canvas to see its inputs."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }

    /// The element at `path`, or nil if it isn't there (any more).
    private func lookUp(_ path: String) -> MXInspectable? {
        // SWIFT: `try?` turns a thrown error into nil: an element whose
        // graph can't be read just isn't shown.
        guard let element = try? document.content.inspectable(at: path) else {
            return nil
        }
        return element
    }
}

/// The inspector's contents for one element.
private struct InspectedElementView: View {
    let document: MaterialXDocument
    let element: MXInspectable
    @Binding var soloPath: String?
    let onShow: (String) -> Void
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch element {
            case .node(let node):
                NodeHeader(document: document, node: node, soloPath: $soloPath, onShow: onShow, onOpen: onOpen)
                Divider()
                InputList(document: document, inputs: node.inputs, ownerPath: node.path,
                          sourceGraph: parent(of: node.path), isReadOnly: isReadOnly(node), onShow: onShow)
            case .graphInput(let input, let graphPath):
                if isGraphReadOnly(graphPath) {
                    ElementTitle(name: input.name, subtitle: "Input of \(graphPath) · \(input.type)")
                } else {
                    GraphPortHeader(document: document, port: input, kind: .input, graphPath: graphPath, onShow: onShow)
                }
                Divider()
                InputList(document: document, inputs: [input], ownerPath: graphPath,
                          sourceGraph: parent(of: graphPath), isReadOnly: isGraphReadOnly(graphPath), onShow: onShow)
                if !isGraphReadOnly(graphPath) {
                    InterfaceMetadataEditor(document: document, input: input, graphPath: graphPath)
                }
            case .graphOutput(let output, let graphPath):
                if graphPath.isEmpty || isGraphReadOnly(graphPath) {
                    ElementTitle(name: output.name,
                                 subtitle: "Output of \(graphPath.isEmpty ? "the document" : graphPath) · \(output.type)")
                } else {
                    GraphPortHeader(document: document, port: output, kind: .output, graphPath: graphPath, onShow: onShow)
                }
                Divider()
                // An <output> has no value, only what it is connected to.
                InputRow(document: document, input: output, ownerPath: graphPath, sourceGraph: graphPath,
                         isReadOnly: true, onShow: onShow)
            case .backdrop(let backdrop):
                BackdropSettings(document: document, backdrop: backdrop, onShow: onShow)
            }
        }
    }

    /// Included elements, and nodegraphs implementing a nodedef, can't be
    /// changed here.
    private func isReadOnly(_ node: MXNode) -> Bool {
        node.isIncluded || (node.isNodeGraph && node.nodeDefName != nil && !node.isLocalDefinition)
    }

    /// The graph level an element is in: "NG/scale" → "NG", "SR" → "".
    private func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else {
            return ""
        }
        return String(path[..<slash])
    }

    /// The same, for the nodegraph at `graphPath`, whose own input is shown.
    private func isGraphReadOnly(_ graphPath: String) -> Bool {
        guard case .node(let graph) = try? document.content.inspectable(at: graphPath) else {
            return true
        }
        return isReadOnly(graph)
    }
}

// MARK: - Document

/// What the inspector shows of the document itself: its MaterialX version
/// and its working space.
private struct DocumentSettings: View {
    let document: MaterialXDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ElementTitle(name: document.displayName ?? "Document",
                         subtitle: "MaterialX \(document.content.documentVersion)")
            WorkingSpaceMenu(document: document, path: "", isReadOnly: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Header

/// A title and a line under it.
private struct ElementTitle: View {
    let name: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The node's name (editable), category, nodedef and description.
private struct NodeHeader: View {
    let document: MaterialXDocument
    let node: MXNode
    @Binding var soloPath: String?
    let onShow: (String) -> Void
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if node.isIncluded {
                Text(node.name)
                    .font(.headline)
            } else {
                // Return renames the node.
                CommitTextField(text: node.name, onCommit: rename)
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .help("The node's name. Type a new one and press Return to rename it.")
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let kind = variantKind, let current = node.nodeDefName {
                // The type variants (M2e): "float", "color3 (in2: float)", ...
                Picker("Type", selection: Binding(get: { current }, set: { changeType(to: $0, in: kind) })) {
                    ForEach(kind.variants) { variant in
                        Text(kind.label(for: variant)).tag(variant.name)
                    }
                }
                .help("The node's type variant. Inputs and connections that don't fit the new type are removed.")
            }
            if let documentation = node.documentation {
                Text(documentation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // SWIFT: Lets the text wrap onto as many lines as it
                    // needs instead of being cut off.
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A node of a definition made here (M4c1), or included from a
            // library (M4c2, read-only): open its body.
            if let implementation = implementationToOpen {
                let isIncluded: Bool = document.content.isIncluded(implementation)
                Button(isIncluded ? "Show Definition" : "Edit Definition", systemImage: "shippingbox") {
                    onOpen(implementation)
                }
                .controlSize(.small)
                .help(isIncluded ? "Open the nodegraph that defines \(node.category), read-only: it comes from a library file "
                                   + "(or double-click the node). Change it in the document that made it, and save it to the library again."
                                 : "Open the nodegraph that defines \(node.category) (or double-click the node). "
                                   + "Changes apply to every node of it.")
            }
            // Solo (M3d): the node alone in the viewport, or back to the
            // material. For every node with a swatch, and materials.
            if canSolo {
                Button(soloTitle, systemImage: "scope") {
                    toggleSolo()
                }
                .controlSize(.small)
                .help("Solo: show this node's output on the viewport's sphere, on its own (⌥-click its swatch on the canvas, or press S)")
            }
            // A swatch that couldn't be drawn (M3c) says why here: the
            // canvas only shows "No preview".
            if case .failed(let message)? = document.swatches?.swatch(for: node.path) {
                Label("No preview: \(message)", systemImage: "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .help(message)
            }
            // A nodegraph's own working space (PLAN.md §8.3), and its
            // outputs (M4a).
            if node.isNodeGraph {
                WorkingSpaceMenu(document: document, path: node.path,
                                 isReadOnly: node.isIncluded || node.nodeDefName != nil)
                    .padding(.top, 4)
                // A definition made here (M4c1) has editable inputs; its
                // outputs are fixed, as its nodes' connections rely on them.
                GraphPortList(document: document, graph: node, kind: .input,
                              isReadOnly: node.isIncluded || (node.nodeDefName != nil && !node.isLocalDefinition))
                    .padding(.top, 4)
                GraphPortList(document: document, graph: node, kind: .output,
                              isReadOnly: node.isIncluded || node.nodeDefName != nil)
                    .padding(.top, 4)
                if node.isLocalDefinition {
                    DefinitionSettings(document: document, graph: node, onOpen: onOpen)
                        .padding(.top, 4)
                } else if canMakeDefinition {
                    Button("Make Node Definition…", systemImage: "shippingbox") {
                        isMakingDefinition = true
                    }
                    .controlSize(.small)
                    .disabled(node.outputs.isEmpty)
                    .help(node.outputs.isEmpty ? "Add an output first: a node made from this graph would give nothing"
                                               : "Make this nodegraph a kind of node, listed in the Library, with its inputs and outputs")
                    .padding(.top, 4)
                }
            }
            if node.isIncluded {
                Label("From an included file: read-only", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if node.isNodeGraph, let nodeDef = node.nodeDefName, !node.isLocalDefinition {
                Label("Implements \(nodeDef): its inputs are defined there", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // SWIFT: `.sheet(isPresented:)` shows a modal sheet over the window
        // while the binding is true; the sheet sets it back to close.
        .sheet(isPresented: $isMakingDefinition) {
            NodeDefinitionSheet(document: document, graph: node, onShow: onShow)
        }
        .paletteCommands(paletteCommands)
    }

    /// True while the Make Node Definition sheet is open.
    @State private var isMakingDefinition: Bool = false

    /// The implementation of the node's definition, if it was made here
    /// or included from a library: Edit (or Show) Definition opens it.
    private var implementationToOpen: String? {
        guard !node.isNodeGraph, let nodeDef = node.nodeDefName else {
            return nil
        }
        return document.content.implementation(of: nodeDef)
    }

    /// Whether the node can be shown alone in the viewport (it has a swatch).
    private var canSolo: Bool {
        SwatchPlan.shaderPath(for: node) != nil
    }

    private var soloTitle: String {
        soloPath == node.path ? "Show the Material in the Viewport" : "Show in Viewport Alone"
    }

    private func toggleSolo() {
        soloPath = soloPath == node.path ? nil : node.path
    }

    /// Whether Make Node Definition… is offered: for a top-level nodegraph
    /// of this document that isn't a definition yet.
    private var canMakeDefinition: Bool {
        node.isNodeGraph && !node.isIncluded && node.nodeDefName == nil && !node.path.contains("/")
    }

    /// The buttons above, for the command palette (M4f): those enabled.
    private var paletteCommands: [PaletteCommand] {
        var commands: [PaletteCommand] = []
        if let implementation = implementationToOpen {
            let title: String = document.content.isIncluded(implementation) ? "Show Definition" : "Edit Definition"
            commands.append(PaletteCommand(title: title, group: "Inspector") {
                onOpen(implementation)
            })
        }
        if canSolo {
            commands.append(PaletteCommand(title: soloTitle, group: "Inspector", shortcut: "S", run: toggleSolo))
        }
        if canMakeDefinition, !node.outputs.isEmpty {
            commands.append(PaletteCommand(title: "Make Node Definition…", group: "Inspector") {
                isMakingDefinition = true
            })
        }
        return commands
    }

    /// "open_pbr_surface · ND_open_pbr_surface_surfaceshader".
    private var subtitle: String {
        if let nodeDef = node.nodeDefName {
            return "\(node.category) · \(nodeDef)"
        }
        return node.isNodeGraph ? "nodegraph" : "\(node.category) · no nodedef found"
    }

    /// The node's kind in the library, when it has other type variants to
    /// choose from and can be changed: not included, not a nodegraph, and
    /// resolved to one of the kind's nodedefs.
    private var variantKind: MXNodeKind? {
        guard !node.isIncluded, !node.isNodeGraph, let current = node.nodeDefName,
              let kind = document.catalog.kind(named: node.category),
              kind.variants.count > 1, kind.variant(named: current) != nil else {
            return nil
        }
        return kind
    }

    /// Changes the node to the variant `nodeDef`, as one undo step.
    private func changeType(to nodeDef: String, in kind: MXNodeKind) {
        guard nodeDef != node.nodeDefName, let variant = kind.variant(named: nodeDef) else {
            return
        }
        let path: String = node.path
        document.edit("Change \(node.name) to \(kind.label(for: variant))") { content in
            try content.changeNodeDef(of: path, to: nodeDef)
        }
    }

    /// Renames the node, and keeps it selected under its new name.
    private func rename(to name: String) {
        let path: String = node.path
        document.edit("Rename \(node.name)") { content in
            let newPath: String = try content.renameNode(at: path, to: name)
            onShow(newPath)
        }
    }
}

// MARK: - Backdrops (M4d)

/// A backdrop's name, what it contains and its note.
private struct BackdropSettings: View {
    let document: MaterialXDocument
    let backdrop: MXBackdrop
    let onShow: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if backdrop.isIncluded {
                    Text(backdrop.name)
                        .font(.headline)
                } else {
                    CommitTextField(text: backdrop.name, onCommit: rename)
                        .font(.headline)
                        .textFieldStyle(.plain)
                        .help("The backdrop's name, shown in its header. Type a new one and press Return to rename it.")
                }
                Text(contents)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("Note")
                .font(.caption)
                .foregroundStyle(.secondary)
            if backdrop.isIncluded {
                Text(backdrop.note.isEmpty ? "None" : backdrop.note)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Label("From an included file: read-only", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                CommitTextField(text: backdrop.note, prompt: "What these nodes do", axis: .vertical, onCommit: setNote)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...12)
                    .help("Shown in the backdrop, under its name. Return saves it; ⌥-Return starts a new line.")
                Text("Drag nodes into the backdrop, or out of it, to change what it holds. Deleting it keeps them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Backdrop · 3 nodes".
    private var contents: String {
        switch backdrop.contains.count {
        case 0: return "Backdrop · empty"
        case 1: return "Backdrop · 1 node"
        default: return "Backdrop · \(backdrop.contains.count) nodes"
        }
    }

    /// Renames the backdrop, and keeps it selected under its new name.
    private func rename(to name: String) {
        let path: String = backdrop.path
        document.edit("Rename \(backdrop.name)") { content in
            let newPath: String = try content.renameNode(at: path, to: name)
            onShow(newPath)
        }
    }

    private func setNote(_ note: String) {
        let path: String = backdrop.path
        let trimmed: String = note.trimmingCharacters(in: .whitespacesAndNewlines)
        document.edit("Set Note of \(backdrop.name)") { content in
            try content.setNote(trimmed, ofBackdrop: path)
        }
    }
}

// MARK: - Node definitions (M4c1)

/// "Make Node Definition…": names and describes the kind of node a
/// nodegraph becomes. The node's name fills in the definition's, until the
/// user edits that.
private struct NodeDefinitionSheet: View {
    let document: MaterialXDocument
    let graph: MXNode
    let onShow: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var spec: MXNodeDefSpec
    /// True once the definition's name was typed, not derived.
    @State private var nameEdited: Bool = false

    init(document: MaterialXDocument, graph: MXNode, onShow: @escaping (String) -> Void) {
        self.document = document
        self.graph = graph
        self.onShow = onShow
        // SWIFT: `_spec = State(initialValue:)` sets a `@State` property's
        // first value from an init argument (see SWIFT_NOTES).
        _spec = State(initialValue: MXNodeDefSpec.suggested(for: graph))
    }

    /// The node groups offered: the Library's, in its order.
    private static let groups: [String] = ["texture2d", "texture3d", "procedural2d", "procedural3d", "procedural",
                                           "adjustment", "compositing", "math", "channel", "conditional",
                                           "geometric", "pbr", "shader"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make “\(graph.name)” a Node Definition")
                .font(.headline)
            Text("The nodegraph becomes a kind of node, listed in the Library under its group. Its inputs and outputs are the "
                + "graph's, and the values its inputs have now become their defaults. Where the graph is used, a node of "
                + "the new kind takes its place.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // SWIFT: `Form` lays labelled controls out in two columns.
            Form {
                TextField("Node", text: Binding(get: { spec.node }, set: { node in
                    spec.node = node
                    if !nameEdited {
                        spec.name = MXNodeDefSpec.nodeDefName(for: node, outputs: graph.outputs)
                    }
                }), prompt: Text("my_tiles"))
                .help("The node's name, which its nodes are written as: letters, digits and _")
                TextField("Definition", text: Binding(get: { spec.name }, set: { spec.name = $0; nameEdited = true }))
                    .help("The nodedef's name; by convention ND_<node>_<type>")
                Picker("Group", selection: $spec.nodeGroup) {
                    Text("None").tag("")
                    ForEach(Self.groups, id: \.self) { group in
                        Text(group).tag(group)
                    }
                }
                .help("Where the Library lists it (nodegroup)")
                TextField("Version", text: $spec.version, prompt: Text("optional, such as 1.0"))
                TextField("Description", text: $spec.documentation, prompt: Text("What the node does"), axis: .vertical)
                    .lineLimit(2...4)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Make Definition") {
                    make()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(spec.node.isEmpty || spec.name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Makes the definition as one undo step, and shows the node that took
    /// the graph's place, if any. A refusal (a taken name) is shown by
    /// `edit`, and the sheet stays open to fix it.
    private func make() {
        let path: String = graph.path
        let spec: MXNodeDefSpec = spec
        let onShow = onShow
        var succeeded: Bool = false
        document.edit("Make Node Definition \(spec.node)") { content in
            let made = try content.makeNodeDefinition(from: path, as: spec)
            succeeded = true
            if let instance = made.instance {
                onShow(instance)
            }
        }
        if succeeded {
            dismiss()
        }
    }
}

/// A definition made in this document: its name and kind, and its group,
/// version and description, editable. Its inputs are edited like a
/// nodegraph's (above); its outputs are fixed.
private struct DefinitionSettings: View {
    let document: MaterialXDocument
    let graph: MXNode
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Definition")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(graph.nodeDefName ?? "") defines the node shown in the Library; changes apply to every node of it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            field("Group", .nodeGroup, value: graph.nodeGroup, prompt: "texture2d")
            field("Version", .version, value: graph.nodeDefVersion, prompt: "1.0")
            field("Description", .documentation, value: graph.documentation, prompt: "What the node does")
            HStack {
                Button("Save to Library…", systemImage: "books.vertical") {
                    saveToLibrary()
                }
                .help("Write the definition to a file of its own, in My Library (Documents › Margolaria › Libraries, "
                    + "or any folder), "
                    + "so other documents can use it from the Library tab")
                Button("Delete Definition", systemImage: "trash", role: .destructive) {
                    deleteDefinition()
                }
                .help("Remove the definition and this nodegraph; only once no node uses it")
            }
            .controlSize(.small)
        }
        .font(.callout)
        .paletteCommands([
            PaletteCommand(title: "Save to Library…", group: "Inspector", run: saveToLibrary),
            PaletteCommand(title: "Delete Definition", group: "Inspector", run: deleteDefinition),
        ])
    }

    /// Asks where to save the definition (My Library by default, named
    /// after its node) and writes its library file. Not an edit: the
    /// document doesn't change. Library panels then list it.
    ///
    /// SWIFT/AppKit: `NSSavePanel` is the standard Save dialog; as a sheet
    /// on the window, its completion handler gets the button pressed.
    private func saveToLibrary() {
        let text: String
        do {
            text = try document.content.libraryText(forDefinitionAt: graph.path)
        } catch {
            document.presentError(error)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save to Library"
        panel.message = "Documents use the definition from this file, through an include."
        panel.directoryURL = MXLibraryFolders.user
        let node: String = document.catalog.definition(named: graph.nodeDefName ?? "")?.node ?? graph.name
        panel.nameFieldStringValue = node + ".mtlx"
        panel.allowedContentTypes = [UTType(filenameExtension: "mtlx") ?? .xml]
        let save: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                NotificationCenter.default.post(name: .margolariaLibrariesChanged, object: nil)
            } catch {
                document.presentError(error)
            }
        }
        if let window = document.windowControllers.first?.window {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }

    /// Removes the definition and its graph, as one step, and goes back to
    /// the document's level. Refused (and said why) while nodes use it.
    private func deleteDefinition() {
        let path: String = graph.path
        let onOpen = onOpen
        document.edit("Delete Definition \(graph.nodeDefName ?? graph.name)") { content in
            try content.removeNodeDefinition(implementedBy: path)
            onOpen("")
        }
    }

    private func field(_ title: String, _ attribute: MXNodeDefAttribute, value: String?, prompt: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)
            CommitTextField(text: value ?? "", prompt: prompt) { newValue in
                let path: String = graph.path
                let trimmed: String = newValue.trimmingCharacters(in: .whitespaces)
                document.edit("Set \(title) of \(graph.nodeDefName ?? graph.name)") { content in
                    try content.setNodeDef(attribute, to: trimmed.isEmpty ? nil : trimmed, of: path)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - A nodegraph's interface (M4a outputs, M4b inputs)

/// Which of a nodegraph's own ports a list or header is about.
private enum GraphPortKind {
    case input, output

    var title: String {
        self == .input ? "Input" : "Output"
    }

    /// The types offered for a new port. Outputs can also pass shaders out;
    /// inputs take values.
    var types: [String] {
        switch self {
        case .input:
            ["color3", "color4", "float", "vector2", "vector3", "vector4", "integer", "boolean", "filename", "string"]
        case .output:
            ["color3", "color4", "float", "vector2", "vector3", "vector4", "integer", "boolean",
             "BSDF", "EDF", "VDF", "surfaceshader", "displacementshader", "volumeshader"]
        }
    }

    /// The edits, by kind.
    func add(_ type: String, to graph: String, in content: MXDocument) throws {
        switch self {
        case .input: try content.addInput(type: type, to: graph)
        case .output: try content.addOutput(type: type, to: graph)
        }
    }

    func rename(_ name: String, of graph: String, to newName: String, in content: MXDocument) throws {
        switch self {
        case .input: try content.renameInput(name, of: graph, to: newName)
        case .output: try content.renameOutput(name, of: graph, to: newName)
        }
    }

    func remove(_ name: String, of graph: String, in content: MXDocument) throws {
        switch self {
        case .input: try content.removeInput(name, of: graph)
        case .output: try content.removeOutput(name, of: graph)
        }
    }
}

/// A nodegraph's inputs or outputs: each one's name (editable) and type, a
/// button to remove it, and a menu to add one.
private struct GraphPortList: View {
    let document: MaterialXDocument
    let graph: MXNode
    let kind: GraphPortKind
    let isReadOnly: Bool

    private var ports: [MXPort] {
        kind == .input ? graph.inputs : graph.outputs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind == .input ? "Inputs" : "Outputs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if ports.isEmpty {
                Text(kind == .input ? "None: promote a node's input inside (right-click it), or add one."
                                    : "None yet: nothing can read this nodegraph.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(ports, id: \.name) { port in
                HStack(spacing: 6) {
                    if isReadOnly {
                        Text(port.name)
                    } else {
                        CommitTextField(text: port.name) { name in
                            rename(port.name, to: name)
                        }
                        .textFieldStyle(.roundedBorder)
                        .help("The \(kind.title.lowercased())'s name. Type a new one and press Return to rename it.")
                    }
                    Text(port.type)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !isReadOnly {
                        Button("Remove \(port.name)", systemImage: "minus.circle") {
                            remove(port.name)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(kind == .input ? "Remove this input; the nodes inside that read it keep its value"
                                             : "Remove this output, disconnecting what reads it")
                    }
                }
            }
            if !isReadOnly {
                // SWIFT: A `Menu` whose items are buttons, one per type.
                Menu("Add \(kind.title)") {
                    ForEach(kind.types, id: \.self) { type in
                        Button(type) {
                            add(type)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(kind == .input ? "Add an input to the nodegraph; connect nodes inside to it"
                                     : "Add an output to the nodegraph; connect it inside, to the node whose result it gives")
            }
        }
        .paletteCommands(paletteCommands)
    }

    /// Adding a port of each type and removing each port, for the command
    /// palette (M4f): "Add Output: float", "Remove Input base".
    private var paletteCommands: [PaletteCommand] {
        guard !isReadOnly else {
            return []
        }
        let adding: [PaletteCommand] = kind.types.map { type in
            // Listed once something is typed ("add out", "output float"):
            // 24 of them would fill the list before.
            PaletteCommand(title: "Add \(kind.title): \(type)", group: "Inspector", listsBeforeTyping: false) {
                add(type)
            }
        }
        let removing: [PaletteCommand] = ports.map { port in
            PaletteCommand(title: "Remove \(kind.title) \(port.name)", group: "Inspector") {
                remove(port.name)
            }
        }
        return adding + removing
    }

    private func add(_ type: String) {
        let path: String = graph.path
        let kind: GraphPortKind = kind
        document.edit("Add \(kind.title) to \(graph.name)") { content in
            try kind.add(type, to: path, in: content)
        }
    }

    private func rename(_ name: String, to newName: String) {
        let path: String = graph.path
        let kind: GraphPortKind = kind
        document.edit("Rename \(name)") { content in
            try kind.rename(name, of: path, to: newName, in: content)
        }
    }

    private func remove(_ name: String) {
        let path: String = graph.path
        let kind: GraphPortKind = kind
        document.edit("Remove \(kind.title) \(name)") { content in
            try kind.remove(name, of: path, in: content)
        }
    }
}

/// A selected input or output of a nodegraph, inside it: its name
/// (editable), type, and a button to remove it.
private struct GraphPortHeader: View {
    let document: MaterialXDocument
    let port: MXPort
    let kind: GraphPortKind
    let graphPath: String
    let onShow: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CommitTextField(text: port.name, onCommit: rename)
                .font(.headline)
                .textFieldStyle(.plain)
                .help("The \(kind.title.lowercased())'s name. Type a new one and press Return to rename it.")
            Text("\(kind.title) of \(graphPath) · \(port.type)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Remove \(kind.title)", systemImage: "minus.circle", action: remove)
                .controlSize(.small)
                .help(kind == .input ? "Remove this input; the nodes that read it keep its value"
                                     : "Remove this output, disconnecting what reads it")
        }
        .paletteCommands([PaletteCommand(title: "Remove \(kind.title) \(port.name)", group: "Inspector", run: remove)])
    }

    private func remove() {
        let name: String = port.name
        let path: String = graphPath
        let kind: GraphPortKind = kind
        document.edit("Remove \(kind.title) \(name)") { content in
            try kind.remove(name, of: path, in: content)
        }
    }

    /// Renames the port, and keeps it selected under its new name.
    private func rename(to name: String) {
        let old: String = port.name
        let path: String = graphPath
        let kind: GraphPortKind = kind
        document.edit("Rename \(old)") { content in
            try kind.rename(old, of: path, to: name, in: content)
            onShow(path + "/" + name)
        }
    }
}

/// How a nodegraph's input is presented (M4b): its label, folder, ranges,
/// step, choices, description and whether it is advanced. What is set here
/// is what the graph's inspector shows, and what a node definition made
/// from the graph will show (M4c1).
private struct InterfaceMetadataEditor: View {
    let document: MaterialXDocument
    let input: MXPort
    let graphPath: String

    /// Open by default when the input has any metadata.
    @State private var isExpanded: Bool? = nil

    /// The fields, in the order shown. Choice values only matter with
    /// choices, so they follow them.
    private static let fields: [MXInputMetadata] = [.uiName, .uiFolder, .doc, .uiSoftMin, .uiSoftMax, .uiMin, .uiMax,
                                                    .uiStep, .enumNames, .enumValues]

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { isExpanded ?? !input.metadata.isEmpty },
                                            set: { isExpanded = $0 })) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.fields.filter(applies), id: \.self) { field in
                    HStack(spacing: 8) {
                        Text(field.title)
                            .frame(width: 110, alignment: .leading)
                            .foregroundStyle(.secondary)
                        CommitTextField(text: input.metadata[field] ?? "", prompt: prompt(for: field)) { value in
                            set(field, to: value)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                    .help(help(for: field))
                }
                // SWIFT: `Toggle` bound with get/set closures: the document
                // holds the value, and setting it is an edit.
                Toggle("Advanced: hidden until asked for", isOn: Binding(
                    get: { input.ui.isAdvanced },
                    set: { set(.uiAdvanced, to: $0 ? "true" : "") }))
            }
            .font(.callout)
            .padding(.top, 4)
        } label: {
            Text("Presentation")
                .font(.subheadline.weight(.semibold))
        }
    }

    /// Ranges and steps are for numbers; choices for numbers and strings.
    private func applies(_ field: MXInputMetadata) -> Bool {
        let numeric: Bool = ["float", "integer", "vector2", "vector3", "vector4", "color3", "color4"].contains(input.type)
        switch field {
        case .uiMin, .uiMax, .uiSoftMin, .uiSoftMax, .uiStep:
            return numeric
        case .enumNames, .enumValues:
            return ["integer", "string", "float"].contains(input.type)
        default:
            return true
        }
    }

    private func prompt(for field: MXInputMetadata) -> String {
        switch field {
        case .uiName: input.name
        case .enumNames: "Off, On"
        case .enumValues: "0, 1"
        case .uiStep: "0.01"
        default: field.isValue ? input.type : ""
        }
    }

    private func help(for field: MXInputMetadata) -> String {
        switch field {
        case .uiName: "The label shown instead of the name (uiname)"
        case .uiFolder: "The group the input is shown in (uifolder)"
        case .doc: "A sentence describing the input, shown when hovering over it (doc)"
        case .uiSoftMin, .uiSoftMax: "The slider's usual range, inside the limits; a \(input.type) (uisoftmin, uisoftmax)"
        case .uiMin, .uiMax: "The value's hard limits; a \(input.type) (uimin, uimax)"
        case .uiStep: "The slider's increment (uistep)"
        case .enumNames: "The allowed values' names, separated by commas (enum)"
        case .enumValues: "The value stored for each name, in the same order (enumvalues); empty when the names are the values"
        case .uiAdvanced: "An input most users can leave alone (uiadvanced)"
        }
    }

    private func set(_ field: MXInputMetadata, to value: String) {
        let name: String = input.name
        let path: String = graphPath
        let trimmed: String = value.trimmingCharacters(in: .whitespaces)
        document.edit("Set \(field.title) of \(name)") { content in
            try content.setMetadata(field, to: trimmed.isEmpty ? nil : trimmed, ofInput: name, on: path)
        }
    }
}

// MARK: - Inputs

/// Inputs that share a `uifolder`, in the nodedef's order.
private struct InputFolder: Identifiable {
    /// The folder's name; nil for inputs that have none.
    let name: String?
    var inputs: [MXPort]

    var id: String { name ?? "" }

    /// Groups `inputs` by folder, keeping the order folders first appear in
    /// (the nodedef's order: Base before Specular, ...).
    ///
    /// SWIFT: `Dictionary(grouping:by:)` would group them in one call, but
    /// a dictionary has no order; the loop keeps it.
    static func folders(of inputs: [MXPort]) -> [InputFolder] {
        var folders: [InputFolder] = []
        for input in inputs {
            if let index = folders.firstIndex(where: { $0.name == input.uiFolder }) {
                folders[index].inputs.append(input)
            } else {
                folders.append(InputFolder(name: input.uiFolder, inputs: [input]))
            }
        }
        return folders
    }
}

/// An element's inputs, grouped by folder, each folder collapsible.
private struct InputList: View {
    let document: MaterialXDocument
    let inputs: [MXPort]
    /// The node or nodegraph the inputs belong to.
    let ownerPath: String
    /// The graph level connected inputs get their values from.
    let sourceGraph: String
    let isReadOnly: Bool
    let onShow: (String) -> Void

    /// Folders the user opened or closed, by name. Others use the default
    /// (see `isExpanded`). Kept while other nodes are selected, so a
    /// folder stays open from one node of a kind to the next.
    @State private var expanded: [String: Bool] = [:]

    /// Whether inputs marked `uiadvanced` are shown.
    @State private var showsAdvanced: Bool = false

    var body: some View {
        let visible: [MXPort] = inputs.filter { showsAdvanced || !$0.ui.isAdvanced || $0.isAuthored }
        let hiddenCount: Int = inputs.count - visible.count
        let folders: [InputFolder] = InputFolder.folders(of: visible)

        VStack(alignment: .leading, spacing: 8) {
            if inputs.isEmpty {
                Text("No inputs")
                    .foregroundStyle(.secondary)
            }
            ForEach(folders) { folder in
                if let name = folder.name {
                    // SWIFT: `DisclosureGroup` is a section with a triangle
                    // that shows or hides its content; `isExpanded:` binds
                    // whether it is open.
                    DisclosureGroup(isExpanded: isExpanded(folder, first: folder.id == folders.first?.id)) {
                        rows(folder.inputs)
                            .padding(.top, 4)
                    } label: {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                    }
                } else {
                    rows(folder.inputs)
                }
            }
            if hiddenCount > 0 || showsAdvanced {
                Button(showsAdvanced ? "Hide Advanced Inputs" : "Show \(hiddenCount) Advanced Inputs") {
                    showsAdvanced.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    /// One row per input.
    private func rows(_ inputs: [MXPort]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(inputs, id: \.name) { input in
                InputRow(document: document, input: input, ownerPath: ownerPath, sourceGraph: sourceGraph,
                         isReadOnly: isReadOnly, onShow: onShow)
            }
        }
    }

    /// Whether `folder` is open: what the user chose, or by default the
    /// first folder and any folder with an input the document sets.
    private func isExpanded(_ folder: InputFolder, first: Bool) -> Binding<Bool> {
        Binding(
            get: { expanded[folder.id] ?? (first || folder.inputs.contains(where: { $0.isAuthored })) },
            set: { expanded[folder.id] = $0 }
        )
    }
}

/// One input: its label, its value or connection, and a reset button.
struct InputRow: View {
    let document: MaterialXDocument
    let input: MXPort
    /// The node or nodegraph the input belongs to; for an `<output>`, its graph.
    let ownerPath: String
    /// The graph level the input's connection points into: the owner's own
    /// level for a node's input, the graph itself for an `<output>`.
    let sourceGraph: String
    let isReadOnly: Bool
    let onShow: (String) -> Void

    /// The label: the nodedef's `uiname`, or the input's name.
    private var label: String {
        input.ui.name ?? input.name
    }

    /// Only inputs from a nodedef have a default to go back to. Removing
    /// any other input (a nodegraph's own) would delete it.
    private var canReset: Bool {
        input.isAuthored && !isReadOnly && (input.defaultValue != nil || input.ui.defaultGeomProp != nil)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 4) {
                // The document sets this input: a dot, and normal text.
                // SWIFT: `.opacity(0)` keeps the dot's space for unset
                // inputs, so labels line up.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .opacity(input.isAuthored ? 1 : 0)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(input.isAuthored ? .primary : .secondary)
            }
            .frame(width: 130, alignment: .leading)
            .help(tooltip)

            if let connection = input.connection {
                ConnectionChip(connection: connection, type: input.type) {
                    onShow(sourcePath(of: connection))
                }
            } else {
                InputEditor(input: input, actions: actions, baseFolder: document.fileURL?.deletingLastPathComponent())
                    .disabled(isReadOnly)
                    // Defaults are dimmed, like their labels.
                    .opacity(input.isAuthored ? 1 : 0.7)
            }

            Button(action: reset) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset to the default (\(input.defaultValue ?? input.ui.defaultGeomProp ?? "none"))")
            .opacity(canReset ? 1 : 0)
            .disabled(!canReset)
        }
        .font(.callout)
        // SWIFT: `.contextMenu { }`: right-click menu (see BottomPanel).
        .contextMenu {
            Button("Reset to Default", action: reset)
                .disabled(!canReset)
            Button("Copy Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(input.value ?? "", forType: .string)
            }
            .disabled(input.value == nil)
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(input.name, forType: .string)
            }
            if canPromote {
                Divider()
                Button("Promote to Nodegraph Input", action: promote)
            }
        }
    }

    /// An unconnected input of a node inside a nodegraph can become one of
    /// the graph's inputs (M4b). Not a nodegraph's own input (its owner is
    /// the graph, at the top level).
    private var canPromote: Bool {
        !isReadOnly && input.connection == nil && ownerPath.contains("/")
    }

    /// Makes the input one of its nodegraph's, with its value and
    /// presentation; the node then reads it.
    private func promote() {
        let name: String = input.name
        let ownerPath: String = ownerPath
        document.edit("Promote \(label)") { content in
            try content.promote(input: name, on: ownerPath)
        }
    }

    /// The name, type and description, for hovering over the label.
    private var tooltip: String {
        var lines: [String] = ["\(input.name) · \(input.type)\(input.isUniform ? " · uniform" : "")"]
        if let documentation = input.ui.documentation {
            lines.append(documentation)
        }
        if let geomProp = input.ui.defaultGeomProp, input.connection == nil, !input.isAuthored {
            lines.append("Unconnected, it reads the geometry's \(geomProp).")
        }
        if let unit = input.ui.unit {
            lines.append("Unit: \(unit)")
        }
        return lines.joined(separator: "\n")
    }

    /// The edits this row's editor makes.
    private var actions: InputActions {
        // SWIFT: Constants captured by the closures below, so they don't
        // capture `self` (a struct that SwiftUI re-creates freely).
        let document: MaterialXDocument = document
        let name: String = input.name
        let ownerPath: String = ownerPath
        let title: String = label
        let editName: String = "Set \(title)"
        return InputActions(
            commit: { value in
                document.edit(editName) { content in
                    try content.setValue(value, ofInput: name, on: ownerPath)
                }
            },
            scrub: { value in
                document.edit(editName, continuing: "\(ownerPath)/\(name)") { content in
                    try content.setValue(value, ofInput: name, on: ownerPath)
                }
            },
            endScrub: {
                document.endContinuousEdit()
            },
            setColorSpace: { colorSpace, value in
                let space: String = colorSpace ?? "Default"
                let editName: String = value == nil ? "Set Colour Space of \(title)" : "Convert \(title) to \(space)"
                document.edit(editName) { content in
                    // The value first: setting it adds the input if the
                    // document didn't set it yet.
                    if let value {
                        try content.setValue(value, ofInput: name, on: ownerPath)
                    }
                    try content.setColorSpace(colorSpace, ofInput: name, on: ownerPath)
                }
            }
        )
    }

    /// Removes the input from the document, so the nodedef's default applies.
    private func reset() {
        guard canReset else {
            return
        }
        let name: String = input.name
        let ownerPath: String = ownerPath
        document.edit("Reset \(label)") { content in
            try content.resetInput(name, on: ownerPath)
        }
    }

    /// The canvas path of what `connection` comes from: a node, a
    /// nodegraph, or one of the graph's inputs (the canvas shows those as
    /// nodes of their own), all in `sourceGraph`.
    private func sourcePath(of connection: MXConnection) -> String {
        let name: String
        switch connection {
        case .node(let node, _), .nodeGraph(let node, _):
            name = node
        case .interface(let interface):
            name = interface
        case .output(let output):
            name = output
        }
        return sourceGraph.isEmpty ? name : "\(sourceGraph)/\(name)"
    }
}

/// "← base_color_tex.out": where a connected input gets its value. Click
/// to show the source on the canvas.
private struct ConnectionChip: View {
    let connection: MXConnection
    let type: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // The type's pin colour, as on the canvas (PLAN.md §4.3).
                Circle()
                    .fill(pinColor)
                    .frame(width: 7, height: 7)
                Text("← \(description)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // SWIFT: `.contentShape` makes the whole rounded rectangle
            // clickable, not only the text and icons.
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(pinColor.opacity(0.8)))
        }
        .buttonStyle(.plain)
        .help("Show the source on the canvas")
    }

    /// "noise.out", "NG_copper.roughness_out", "interface: amount".
    private var description: String {
        switch connection {
        case .node(let name, let output), .nodeGraph(let name, let output):
            // SWIFT: `output.map { ".\($0)" } ?? ""` appends ".out" only
            // when the connection names an output.
            return name + (output.map { ".\($0)" } ?? "")
        case .interface(let name):
            return "interface: \(name)"
        case .output(let name):
            return "output \(name)"
        }
    }

    private var pinColor: Color {
        let rgb: (CGFloat, CGFloat, CGFloat) = GraphPalette.pin(PortType(type))
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}
