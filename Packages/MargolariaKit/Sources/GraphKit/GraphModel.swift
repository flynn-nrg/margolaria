// GraphModel.swift
//
// The data a graph canvas draws: nodes with typed ports, wires between
// them, and backdrops behind them (M4d). Spike M0d (docs/spikes/M0d-graph-canvas.md) used synthetic graphs;
// since M1 the app fills it from a MaterialX document (GraphBuilder.swift).
//
// Plain value types with no UI dependency, so the canvas can be tested and
// benchmarked on its own.
//
// Introduces (SWIFT): `CaseIterable`, enums with raw values, a struct with
// static constants standing in for an open-ended enum, a seeded random
// number generator conforming to `RandomNumberGenerator`, `mutating`
// methods, `&+`/`&*` wrapping arithmetic.

import CoreGraphics

/// A port's MaterialX type, such as "float" or "surfaceshader". It decides
/// the pin's colour.
///
/// SWIFT: A struct, not an enum: MaterialX has many types and documents can
/// define their own (custom struct types), so the set isn't closed. The
/// `static let`s give the common ones enum-like names (`.float`), and any
/// other name still works: `PortType("BSDF")`.
public struct PortType: Hashable, Sendable {
    /// The MaterialX type name.
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public static let float = PortType("float")
    public static let integer = PortType("integer")
    public static let boolean = PortType("boolean")
    public static let color3 = PortType("color3")
    public static let color4 = PortType("color4")
    public static let vector2 = PortType("vector2")
    public static let vector3 = PortType("vector3")
    public static let vector4 = PortType("vector4")
    public static let filename = PortType("filename")
    public static let string = PortType("string")
    public static let surfaceshader = PortType("surfaceshader")
    public static let displacementshader = PortType("displacementshader")
    public static let material = PortType("material")

    /// Related types share a colour (PLAN.md §4.3).
    public enum Family: Sendable {
        case scalar, color, vector, matrix, text, shader, closure, material, other
    }

    /// The family this type's colour comes from.
    public var family: Family {
        switch name {
        case "float", "integer", "boolean":
            return .scalar
        case "color3", "color4":
            return .color
        case "vector2", "vector3", "vector4":
            return .vector
        case "matrix33", "matrix44":
            return .matrix
        case "string", "filename", "geomname":
            return .text
        case "surfaceshader", "displacementshader", "volumeshader", "lightshader":
            return .shader
        case "BSDF", "EDF", "VDF":
            return .closure
        case "material":
            return .material
        default:
            // Arrays (`floatarray`), `multioutput`, custom types.
            return .other
        }
    }
}

/// A node's header colour group (PLAN.md §4.3: muted, so selection and
/// errors stand out). Most come from the nodedef's `nodegroup`; see
/// ``init(nodeGroup:)``.
///
/// SWIFT: `CaseIterable` makes the compiler generate `allCases`, an array of
/// every case.
public enum NodeCategory: String, CaseIterable, Sendable {
    case pbr, material, texture, procedural, geometry, math, adjustment, compositing, conditional, channel
    case organization
    /// A nodegraph shown as a node (double-click to enter it).
    case nodeGraph
    /// A nodegraph's own inputs and outputs, shown at the edges of its graph.
    case graphInterface
    /// Anything else, including nodes without a nodedef.
    case other

    /// The colour group for a MaterialX `nodegroup` attribute.
    public init(nodeGroup: String?) {
        switch nodeGroup {
        case "pbr", "shader", "light", "npr":
            self = .pbr
        case "material":
            self = .material
        case "texture2d", "texture3d", "convolution2d":
            self = .texture
        case "procedural", "procedural2d", "procedural3d":
            self = .procedural
        case "geometric":
            self = .geometry
        case "math":
            self = .math
        case "adjustment", "colortransform":
            self = .adjustment
        case "compositing":
            self = .compositing
        case "conditional":
            self = .conditional
        case "channel":
            self = .channel
        case "organization", "translation", "application":
            self = .organization
        default:
            self = .other
        }
    }

    /// The categories the synthetic benchmark graph uses.
    static let synthetic: [NodeCategory] = [.pbr, .texture, .procedural, .geometry, .math,
                                            .adjustment, .compositing, .conditional, .channel]
}

/// One input or output of a node.
public struct GraphPort: Sendable {
    /// The port's name, such as "base_color".
    public var name: String
    /// Its MaterialX type.
    public var type: PortType
    /// For an unconnected input, its value as shown inline ("0.8, 0.2, 0.1").
    public var value: String?
    /// For an input: declared `uniform`, so it takes a value or a
    /// nodegraph's own input, never a node's output (see GraphWiring.swift).
    public var isUniform: Bool
    /// For an output: false when its wires are drawn but none can be made
    /// or moved from it on the canvas. A top-level `<output>` read by
    /// `output="…"` (M7b): MaterialX's edits connect inputs to nodes and
    /// nodegraphs, so the canvas only shows these.
    public var startsWires: Bool

    public init(name: String, type: PortType, value: String? = nil, isUniform: Bool = false,
                startsWires: Bool = true) {
        self.name = name
        self.type = type
        self.value = value
        self.isUniform = isUniform
        self.startsWires = startsWires
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
    /// The inputs shown as rows, with pins.
    public var inputs: [GraphPort]
    public var outputs: [GraphPort]
    /// Whether the node shows a preview thumbnail (PLAN.md §4.1).
    public var hasThumbnail: Bool
    /// Shown in the header after the title, dimmed: the MaterialX category,
    /// such as "open_pbr_surface". Nil to show only the title.
    ///
    /// SWIFT: Properties with default values can be left out of the
    /// automatic memberwise initializer, so code written before they existed
    /// (the synthetic graph below) still compiles.
    public var subtitle: String? = nil
    /// The inputs that aren't shown as rows: those that use their default
    /// value. Drawn as one "+N more inputs" row; a wire dropped on the node
    /// can still connect to them (M2d).
    public var hiddenInputs: [GraphPort] = []
    /// True when the node shows all its inputs because the user expanded
    /// it; its last row then offers to show fewer.
    public var isExpanded: Bool = false
    /// True for a node that can't be changed (it comes from an included
    /// file): it can be selected, but not moved, deleted or rewired.
    public var isLocked: Bool = false

    /// How many inputs the "+N more inputs" row stands for.
    public var collapsedInputCount: Int { hiddenInputs.count }

    /// True if the node ends with a row that shows more inputs, or fewer.
    public var hasInputToggle: Bool { !hiddenInputs.isEmpty || isExpanded }
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

/// A backdrop (M4d): a frame drawn behind some nodes, with a title and a
/// note. Moving it moves the nodes it contains.
public struct GraphBackdrop: Identifiable, Sendable {
    /// Its index in ``GraphModel/backdrops``.
    public let id: Int
    /// Shown in its header: the backdrop's name.
    public var title: String
    /// Shown under the header, wrapped; "" for none.
    public var note: String
    /// Where it is, in graph coordinates: top-left corner and size.
    public var frame: CGRect
    /// The nodes it contains, by ID. Not necessarily inside ``frame``: a
    /// file can say otherwise.
    public var contents: Set<Int>
    /// True for a backdrop from an included file: it can be selected, not
    /// moved, resized or deleted.
    public var isLocked: Bool = false

    public init(id: Int, title: String, note: String = "", frame: CGRect, contents: Set<Int>, isLocked: Bool = false) {
        self.id = id
        self.title = title
        self.note = note
        self.frame = frame
        self.contents = contents
        self.isLocked = isLocked
    }
}

/// A whole graph.
public struct GraphModel: Sendable {
    /// All nodes. `nodes[i].id == i`; later nodes draw on top.
    public var nodes: [GraphNode]
    public var wires: [GraphWire]
    /// The backdrops, drawn behind everything else, later ones on top.
    /// `backdrops[i].id == i`.
    public var backdrops: [GraphBackdrop]

    public init(nodes: [GraphNode], wires: [GraphWire], backdrops: [GraphBackdrop] = []) {
        self.nodes = nodes
        self.wires = wires
        self.backdrops = backdrops
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
            let category: NodeCategory = isLast ? .pbr : NodeCategory.synthetic[random.next(below: NodeCategory.synthetic.count)]

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
