// GraphBuilder.swift
//
// Turns one level of a MaterialX document (an MXGraph from MXKit) into the
// canvas's model: one canvas node per MaterialX node, plus small nodes for a
// nodegraph's own inputs and outputs, and a wire for every connection.
//
// What a node shows (PLAN.md §4.1): its outputs, then the inputs the
// document sets or connects. Inputs left at their nodedef default are
// counted, not listed: a `standard_surface` has 42 inputs, and the examples
// set about 8. They appear as one "+N more inputs" row.
//
// Positions are all zero here; GraphAutoLayout places the nodes.
//
// Introduces (SWIFT): `filter`, dictionary lookups returning optionals,
// `enumerated()`, `firstIndex(where:)`, `map`/`flatMap` on an optional,
// `URL.lastPathComponent`.

import CoreGraphics
import Foundation
import MXKit

/// A canvas model built from a MaterialX graph, with the element behind each
/// canvas node.
public struct DocumentGraph: Sendable {
    /// What the canvas draws.
    public var model: GraphModel
    /// The MaterialX path of each canvas node, by index: `elementPaths[i]`
    /// belongs to `model.nodes[i]`. Interface inputs and outputs are
    /// elements too ("NG_copper/roughness_out"), so every node has one.
    public let elementPaths: [String]
    /// The path of the graph level this was built from ("" for the document).
    public let graphPath: String

    /// The canvas node for the element at `path`, if it is on this level.
    public func nodeIndex(forPath path: String) -> Int? {
        elementPaths.firstIndex(of: path)
    }
}

/// Builds a ``DocumentGraph`` from an MXGraph.
public enum GraphBuilder {
    public static func build(_ graph: MXGraph) -> DocumentGraph {
        var nodes: [GraphNode] = []
        var paths: [String] = []

        // Canvas indices by MaterialX name, one dictionary per kind of
        // source a connection can name.
        var nodeIndex: [String: Int] = [:]
        var interfaceIndex: [String: Int] = [:]

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
        }

        // 2. The nodes, nodegraphs included.
        for node in graph.nodes {
            let id: Int = nodes.count
            nodeIndex[node.name] = id
            // SWIFT: `filter` keeps the elements for which the closure is
            // true. A connected input is always authored; checking both
            // states the rule plainly.
            let shown: [MXPort] = node.inputs.filter { $0.isAuthored || $0.connection != nil }
            nodes.append(GraphNode(id: id, title: node.name,
                                   category: node.isNodeGraph ? .nodeGraph : NodeCategory(nodeGroup: node.nodeGroup),
                                   position: .zero,
                                   inputs: shown.map { port(for: $0) },
                                   outputs: node.outputs.map { GraphPort(name: $0.name, type: PortType($0.type)) },
                                   hasThumbnail: false,
                                   subtitle: node.category,
                                   collapsedInputCount: node.inputs.count - shown.count))
            paths.append(node.path)
        }

        // 3. The level's <output> elements: small nodes with one input.
        for output in graph.outputs {
            let id: Int = nodes.count
            nodes.append(GraphNode(id: id, title: output.name, category: .graphInterface, position: .zero,
                                   inputs: [GraphPort(name: output.type, type: PortType(output.type))],
                                   outputs: [],
                                   hasThumbnail: false, subtitle: "output"))
            paths.append(childPath(graph.path, output.name))
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
            guard let id = nodeIndex[node.name] else {
                continue
            }
            let shown: [MXPort] = node.inputs.filter { $0.isAuthored || $0.connection != nil }
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

        return DocumentGraph(model: GraphModel(nodes: nodes, wires: wires), elementPaths: paths, graphPath: graph.path)
    }

    /// The canvas row for an input: its name, type and, unless connected,
    /// its value.
    static func port(for input: MXPort) -> GraphPort {
        GraphPort(name: input.name, type: PortType(input.type),
                  value: input.connection == nil ? displayValue(of: input) : nil)
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
