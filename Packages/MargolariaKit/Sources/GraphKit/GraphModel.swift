// GraphModel.swift
//
// The data a graph canvas draws: nodes with typed ports, and wires between
// them. Spike M0d (docs/spikes/M0d-graph-canvas.md) uses synthetic graphs;
// in M1 this is filled from an MXDocument instead.
//
// Plain value types with no MaterialX or UI dependency, so the canvas can be
// tested and benchmarked on its own.
//
// Introduces (SWIFT): `CaseIterable`, enums with raw values, a seeded random
// number generator conforming to `RandomNumberGenerator`, `mutating` methods,
// `&+`/`&*` wrapping arithmetic.

import CoreGraphics

/// A port's MaterialX type, which decides its colour.
public enum PortType: String, CaseIterable, Sendable {
    case float, integer, boolean, color3, color4, vector2, vector3, vector4
    case filename, string, surfaceshader, displacementshader, material
}

/// A node's category, which decides its header colour (PLAN.md §4.3:
/// muted, so selection and errors stand out).
///
/// SWIFT: `CaseIterable` makes the compiler generate `allCases`, an array of
/// every case, used below to pick random categories.
public enum NodeCategory: String, CaseIterable, Sendable {
    case pbr, texture, procedural, geometry, math, adjustment, compositing, conditional, channel
}

/// One input or output of a node.
public struct GraphPort: Sendable {
    /// The port's name, such as "base_color".
    public var name: String
    /// Its MaterialX type.
    public var type: PortType
    /// For an unconnected input, its value as shown inline ("0.8, 0.2, 0.1").
    public var value: String?

    public init(name: String, type: PortType, value: String? = nil) {
        self.name = name
        self.type = type
        self.value = value
    }
}

/// One node on the canvas.
public struct GraphNode: Identifiable, Sendable {
    /// Unique within the graph; also the index in ``GraphModel/nodes``.
    public let id: Int
    /// The node's name, shown in its header.
    public var title: String
    public var category: NodeCategory
    /// Top-left corner, in graph coordinates (points at zoom 1, y down).
    public var position: CGPoint
    public var inputs: [GraphPort]
    public var outputs: [GraphPort]
    /// Whether the node shows a preview thumbnail (PLAN.md §4.1).
    public var hasThumbnail: Bool
}

/// Identifies one port: which node, which side, which row.
public struct PortReference: Hashable, Sendable {
    public var node: Int
    public var index: Int

    public init(node: Int, index: Int) {
        self.node = node
        self.index = index
    }
}

/// A connection from an output to an input.
public struct GraphWire: Hashable, Sendable {
    /// The output it starts from.
    public var from: PortReference
    /// The input it ends at.
    public var to: PortReference
}

/// A whole graph.
public struct GraphModel: Sendable {
    /// All nodes. `nodes[i].id == i`; later nodes draw on top.
    public var nodes: [GraphNode]
    public var wires: [GraphWire]

    public init(nodes: [GraphNode], wires: [GraphWire]) {
        self.nodes = nodes
        self.wires = wires
    }

    /// A synthetic graph shaped like a big material: nodes in columns, each
    /// node's inputs fed from nodes in the columns to its left, ending in a
    /// few shader and material nodes on the right. The same `seed` always
    /// gives the same graph, so benchmarks are repeatable.
    public static func synthetic(nodeCount: Int, seed: UInt64 = 1) -> GraphModel {
        // SWIFT: `var` because generating random numbers changes the
        // generator's state (its methods are `mutating`).
        var random = SeededRandom(seed: seed)
        let inputNames: [String] = ["in", "in1", "in2", "amount", "scale", "offset", "texcoord", "position", "mix", "low", "high"]
        let shortTypes: [PortType] = [.float, .color3, .vector2, .vector3, .float, .color3]

        // Roughly square: as many columns as fit about 14 nodes each.
        let columns: Int = max(2, nodeCount / 14)
        var nodes: [GraphNode] = []
        var wires: [GraphWire] = []

        for id in 0..<nodeCount {
            let column: Int = id * columns / nodeCount
            let isLast: Bool = column == columns - 1
            let category: NodeCategory = isLast ? .pbr : NodeCategory.allCases[random.next(below: NodeCategory.allCases.count)]

            var inputs: [GraphPort] = []
            let inputCount: Int = isLast ? 8 : 1 + random.next(below: 4)
            for i in 0..<inputCount {
                let type: PortType = shortTypes[random.next(below: shortTypes.count)]
                inputs.append(GraphPort(name: inputNames[i % inputNames.count], type: type,
                                        value: type == .float ? "0.5" : "0.8, 0.8, 0.8"))
            }
            let outputType: PortType = isLast ? .surfaceshader : shortTypes[random.next(below: shortTypes.count)]
            let outputs: [GraphPort] = [GraphPort(name: "out", type: outputType)]

            // Spread nodes in their column with a little jitter, like an
            // auto-layout would.
            let row: Int = id - (column * nodeCount + columns - 1) / columns
            let position = CGPoint(x: Double(column) * 260 + Double(random.next(below: 30)),
                                   y: Double(max(row, 0)) * (isLast ? 340 : 240) + Double(random.next(below: 30)))

            nodes.append(GraphNode(id: id, title: "\(category.rawValue)_\(id)", category: category,
                                   position: position, inputs: inputs, outputs: outputs,
                                   hasThumbnail: true))

            // Connect most inputs to a node in an earlier column, which keeps
            // the graph acyclic. The rest stay unconnected and show values.
            if column > 0 {
                let earliest: Int = max(0, (column - 3) * nodeCount / columns)
                let latest: Int = column * nodeCount / columns
                for input in 0..<inputCount where random.next(below: 10) < 7 {
                    let source: Int = earliest + random.next(below: max(1, latest - earliest))
                    wires.append(GraphWire(from: PortReference(node: source, index: 0),
                                           to: PortReference(node: id, index: input)))
                    nodes[id].inputs[input].value = nil
                }
            }
        }
        return GraphModel(nodes: nodes, wires: wires)
    }
}

/// A small, fast, seedable random number generator (SplitMix64), so
/// synthetic graphs are the same on every run. Swift's default generator is
/// seeded randomly and can't be seeded by hand.
///
/// SWIFT: Conforming to `RandomNumberGenerator` only requires `next() -> UInt64`;
/// the standard library then lets it drive `Int.random(in:using:)` and friends.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// SWIFT: `mutating` because it changes `state`; a struct's methods
    /// can't modify its properties without it (like a non-const C++ method).
    /// `&+` and `&*` are *wrapping* arithmetic: plain `+` traps on overflow
    /// in Swift, unlike C, and this algorithm relies on overflow wrapping.
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z: UInt64 = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A random integer in 0..<bound.
    mutating func next(below bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}
