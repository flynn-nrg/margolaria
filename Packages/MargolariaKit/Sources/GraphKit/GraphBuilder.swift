// GraphBuilder.swift
//
// Turns one level of a MaterialX document (an MXGraph from MXKit) into the
// canvas's model: one canvas node per MaterialX node, plus small nodes for a
// nodegraph's own inputs and outputs, and a wire for every connection.
//
// What a node shows (PLAN.md §4.1): its outputs, then the inputs the
// document sets or connects. Inputs left at their nodedef default are
// counted, not listed: a `standard_surface` has 42 inputs, and the examples
// set about 8. They appear as one "+N more inputs" row; clicking it
// expands the node (M2d), which the app remembers by path and passes back
// in `expanded`.
//
// Nodes with a saved position (`xpos`/`ypos`) are placed there; the
// others get position zero, and `positioned` says which are which, so that
// GraphAutoLayout only places the rest (see `layout()`).
//
// Units: MaterialX's Graph Editor stores positions in node sizes (its nodes
// are 138 × 116 points). Our nodes are 220 points wide, so one unit is 220
// points across and 220 × 116 / 138 ≈ 185 down: a layout keeps its
// proportions in both editors (PLAN.md §8.1).
//
// Introduces (SWIFT): `filter`, dictionary lookups returning optionals,
// `enumerated()`, `firstIndex(where:)`, `map`/`flatMap` on an optional,
// `URL.lastPathComponent`.

import CoreGraphics
import Foundation
import MXKit

/// What kind of MaterialX element a canvas node stands for. Wiring needs
/// it: each kind is connected with a different edit.
public enum ElementKind: Sendable {
    /// One of a nodegraph's own inputs, drawn with one output.
    case interfaceInput
    /// A node, or a nodegraph shown as a node.
    case node
    /// An `<output>` element, drawn with one input.
    case output
}

/// A canvas model built from a MaterialX graph, with the element behind each
/// canvas node.
public struct DocumentGraph: Sendable {
    /// What the canvas draws.
    public var model: GraphModel
    /// The MaterialX path of each canvas node, by index: `elementPaths[i]`
    /// belongs to `model.nodes[i]`. Interface inputs and outputs are
    /// elements too ("NG_copper/roughness_out"), so every node has one.
    public let elementPaths: [String]
    /// The kind of element behind each canvas node, by index.
    public let kinds: [ElementKind]
    /// The path of the graph level this was built from ("" for the document).
    public let graphPath: String

    /// The nodes whose position came from the document.
    public let positioned: Set<Int>

    /// Canvas points per MaterialX position unit (see the file comment).
    public static let pointsPerUnit = CGSize(width: GraphLayout.nodeWidth, height: GraphLayout.nodeWidth * 116 / 138)

    /// Converts a canvas position to MaterialX units, for `xpos`/`ypos`.
    public static func units(fromPoints point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / pointsPerUnit.width, y: point.y / pointsPerUnit.height)
    }

    /// Places every node without a saved position with GraphAutoLayout,
    /// leaving the others where the document put them; then moves nodes
    /// down where they overlap (GraphAutoLayout.separate), on screen only.
    public mutating func layout() {
        var laidOut: GraphModel = model
        GraphAutoLayout.apply(to: &laidOut)
        for id in model.nodes.indices where !positioned.contains(id) {
            model.nodes[id].position = laidOut.nodes[id].position
        }
        // Auto-layout never overlaps nodes; saved positions can, with
        // nodes taller than when they were saved (M3c).
        if !positioned.isEmpty {
            GraphAutoLayout.separate(&model)
        }
    }

    /// The canvas node for the element at `path`, if it is on this level.
    public func nodeIndex(forPath path: String) -> Int? {
        elementPaths.firstIndex(of: path)
    }
}

/// Builds a ``DocumentGraph`` from an MXGraph.
public enum GraphBuilder {
    /// Builds the canvas for `graph`. Nodes whose path is in `expanded`
    /// show all their inputs, not only the set ones; nodes for which
    /// `hasThumbnail` is true have room for a swatch (M3c; the app decides,
    /// with PreviewKit, which nodes can show one).
    ///
    /// SWIFT: A closure parameter with a default value, `{ _ in false }`:
    /// callers that don't care leave it out. `_ in` ignores the argument.
    public static func build(_ graph: MXGraph, expanded: Set<String> = [],
                             hasThumbnail: (MXNode) -> Bool = { _ in false }) -> DocumentGraph {
        var nodes: [GraphNode] = []
        var paths: [String] = []
        var kinds: [ElementKind] = []

        // Canvas indices by MaterialX name, one dictionary per kind of
        // source a connection can name.
        var nodeIndex: [String: Int] = [:]
        var interfaceIndex: [String: Int] = [:]
        var positioned: Set<Int> = []

        // 1. A nodegraph's interface inputs: small nodes with one output.
        for input in graph.interfaceInputs {
            let id: Int = nodes.count
            interfaceIndex[input.name] = id
            nodes.append(GraphNode(id: id, title: input.name, category: .graphInterface, position: .zero,
                                   inputs: [],
                                   // The output row shows the input's value, or its type.
                                   outputs: [GraphPort(name: displayValue(of: input) ?? input.type, type: PortType(input.type))],
                                   hasThumbnail: false, subtitle: "input"))
            paths.append(childPath(graph.path, input.name))
            kinds.append(.interfaceInput)
        }

        // 2. The nodes, nodegraphs included. `shownInputs` keeps each
        // node's rows, for the wires below.
        var shownInputs: [Int: [MXPort]] = [:]
        for node in graph.nodes {
            let id: Int = nodes.count
            nodeIndex[node.name] = id
            // SWIFT: A closure stored in a `let`, with its function type
            // `(MXPort) -> Bool` written out, can be passed by name where a
            // closure is expected: `filter(isSet)`. `filter` keeps the
            // elements for which it is true. (A connected input is always
            // authored; checking both states the rule plainly.)
            let isSet: (MXPort) -> Bool = { $0.isAuthored || $0.connection != nil }
            let unset: [MXPort] = node.inputs.filter { !isSet($0) }
            // An expanded node shows every input, in the nodedef's order;
            // only a node with something to hide can be expanded.
            let isExpanded: Bool = expanded.contains(node.path) && !unset.isEmpty
            let shown: [MXPort] = isExpanded ? node.inputs : node.inputs.filter(isSet)
            shownInputs[id] = shown
            var position: CGPoint = .zero
            if let saved = node.position {
                position = CGPoint(x: saved.x * DocumentGraph.pointsPerUnit.width,
                                   y: saved.y * DocumentGraph.pointsPerUnit.height)
                positioned.insert(id)
            }
            nodes.append(GraphNode(id: id, title: node.name,
                                   category: node.isNodeGraph ? .nodeGraph : NodeCategory(nodeGroup: node.nodeGroup),
                                   position: position,
                                   inputs: shown.map { port(for: $0) },
                                   outputs: node.outputs.map { GraphPort(name: $0.name, type: PortType($0.type)) },
                                   hasThumbnail: hasThumbnail(node),
                                   // Included nodes say so, after their category.
                                   subtitle: node.isIncluded ? node.category + " · included" : node.category,
                                   hiddenInputs: isExpanded ? [] : unset.map { port(for: $0) },
                                   isExpanded: isExpanded,
                                   isLocked: node.isIncluded))
            paths.append(node.path)
            kinds.append(.node)
        }

        // 3. The level's <output> elements: small nodes with one input.
        for output in graph.outputs {
            let id: Int = nodes.count
            nodes.append(GraphNode(id: id, title: output.name, category: .graphInterface, position: .zero,
                                   inputs: [GraphPort(name: output.type, type: PortType(output.type))],
                                   outputs: [],
                                   hasThumbnail: false, subtitle: "output"))
            paths.append(childPath(graph.path, output.name))
            kinds.append(.output)
        }

        // 4. Wires. Inputs are visited in the order the nodes show them, so
        // `index` below is the input's row.
        var wires: [GraphWire] = []
        func connect(_ connection: MXConnection?, to target: PortReference) {
            guard let connection else {
                return
            }
            let source: PortReference?
            switch connection {
            case .node(let name, let output), .nodeGraph(let name, let output):
                // SWIFT: `nodeIndex[name]` looks a key up in a dictionary and
                // returns an optional: nil if the key isn't there.
                if let sourceIndex = nodeIndex[name] {
                    // The named output's row, or the first output.
                    // SWIFT: `flatMap` on an optional: if `output` is nil the
                    // result is nil; otherwise the closure runs and its
                    // (optional) result is returned. `??` then supplies 0.
                    let outputIndex: Int = output.flatMap { outputName in
                        nodes[sourceIndex].outputs.firstIndex(where: { $0.name == outputName })
                    } ?? 0
                    source = PortReference(node: sourceIndex, index: outputIndex)
                } else {
                    source = nil
                }
            case .interface(let name):
                source = interfaceIndex[name].map { PortReference(node: $0, index: 0) }
            case .output:
                // `output="…"` alone names a top-level <output> element.
                // None of MaterialX's examples uses it; not drawn yet.
                source = nil
            }
            if let source {
                wires.append(GraphWire(from: source, to: target))
            }
        }

        for node in graph.nodes {
            guard let id = nodeIndex[node.name], let shown = shownInputs[id] else {
                continue
            }
            // SWIFT: `enumerated()` pairs each element with its position,
            // like Python's `enumerate`: `(offset, element)`.
            for (row, input) in shown.enumerated() {
                connect(input.connection, to: PortReference(node: id, index: row))
            }
        }
        let firstOutput: Int = graph.interfaceInputs.count + graph.nodes.count
        for (offset, output) in graph.outputs.enumerated() {
            connect(output.connection, to: PortReference(node: firstOutput + offset, index: 0))
        }

        return DocumentGraph(model: GraphModel(nodes: nodes, wires: wires), elementPaths: paths, kinds: kinds,
                             graphPath: graph.path, positioned: positioned)
    }

    /// The canvas row for an input: its name, type and, unless connected,
    /// its value.
    static func port(for input: MXPort) -> GraphPort {
        GraphPort(name: input.name, type: PortType(input.type),
                  value: input.connection == nil ? displayValue(of: input) : nil,
                  isUniform: input.isUniform)
    }

    /// The value as shown on a node: as written, except that file paths are
    /// shortened to the file name (the full path is in the inspector, M2).
    static func displayValue(of port: MXPort) -> String? {
        guard let value = port.value else {
            return nil
        }
        if port.type == "filename" {
            // SWIFT: `lastPathComponent` is the part after the last "/".
            return URL(filePath: value).lastPathComponent
        }
        return value
    }

    /// "parent/name", or just "name" at the document root.
    static func childPath(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }
}
