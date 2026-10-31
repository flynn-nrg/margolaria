// InspectorPanel.swift
//
// The inspector (PLAN.md §4.1, region 5; M2b): the element selected on the
// canvas, with every input, grouped by the nodedef's `uifolder`.
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
// Read-only: elements from `xi:include`d files (saving writes the include
// back, so changes would be lost), and the inputs of a nodegraph that
// implements a nodedef (their defaults belong to the nodedef: M4).
//
// Introduces (SWIFT): `DisclosureGroup`, `ScrollView`, `let _ =` to make a
// view observe a property it doesn't otherwise use, `firstIndex(where:)`
// and changing an array element in place, `.contentShape`.

import GraphKit
import MXKit
import PreviewKit
import SwiftUI

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

    var body: some View {
        // SWIFT: Reading `document.revision` makes SwiftUI call `body`
        // again after every edit, undo and redo. `content` changes in place,
        // which Observation can't see; the revision is how it is told. `let _ =`
        // reads a value and throws it away, which is allowed in a view body.
        let _ = document.revision
        VStack(spacing: 0) {
            if let selectedPath, let element = lookUp(selectedPath) {
                ScrollView {
                    InspectedElementView(document: document, element: element, soloPath: $soloPath, onShow: onShow)
                        .padding(12)
                }
                // A new set of editors for each element. Otherwise SwiftUI
                // reuses them, and a colour well connected to the colour
                // panel stays connected while showing another node's colour:
                // the panel keeps the old colour, and dragging in it would
                // set the new node's input. A fresh well, clicked, connects
                // and sends the panel its own colour.
                .id(selectedPath)
            } else {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch element {
            case .node(let node):
                NodeHeader(document: document, node: node, soloPath: $soloPath, onShow: onShow)
                Divider()
                InputList(document: document, inputs: node.inputs, ownerPath: node.path,
                          sourceGraph: parent(of: node.path), isReadOnly: isReadOnly(node), onShow: onShow)
            case .graphInput(let input, let graphPath):
                ElementTitle(name: input.name, subtitle: "Input of \(graphPath) · \(input.type)")
                Divider()
                InputList(document: document, inputs: [input], ownerPath: graphPath,
                          sourceGraph: parent(of: graphPath), isReadOnly: isGraphReadOnly(graphPath), onShow: onShow)
            case .graphOutput(let output, let graphPath):
                ElementTitle(name: output.name,
                             subtitle: "Output of \(graphPath.isEmpty ? "the document" : graphPath) · \(output.type)")
                Divider()
                // An <output> has no value, only what it is connected to.
                InputRow(document: document, input: output, ownerPath: graphPath, sourceGraph: graphPath,
                         isReadOnly: true, onShow: onShow)
            }
        }
    }

    /// Included elements, and nodegraphs implementing a nodedef, can't be
    /// changed here.
    private func isReadOnly(_ node: MXNode) -> Bool {
        node.isIncluded || (node.isNodeGraph && node.nodeDefName != nil)
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
            // Solo (M3d): the node alone in the viewport, or back to the
            // material. For every node with a swatch, and materials.
            if SwatchPlan.shaderPath(for: node) != nil {
                let isSoloed: Bool = soloPath == node.path
                Button(isSoloed ? "Show the Material in the Viewport" : "Show in Viewport Alone",
                       systemImage: "scope") {
                    soloPath = isSoloed ? nil : node.path
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
            if node.isIncluded {
                Label("From an included file: read-only", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if node.isNodeGraph, let nodeDef = node.nodeDefName {
                Label("Implements \(nodeDef): its inputs are defined there", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
