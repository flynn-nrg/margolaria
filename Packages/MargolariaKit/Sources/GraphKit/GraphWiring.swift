// GraphWiring.swift
//
// The rules for wiring on the canvas (M2d), worked out on the canvas model
// alone: which inputs an output may feed, which connections would make a
// loop, and the requests the canvas sends to the app when the user connects
// or disconnects something.
//
// The rules are MaterialX's (the bridge checks them again when the app
// makes the edit), applied here so the canvas can dim what won't connect
// while a wire is being dragged:
//   - the types must be the same ("float" to "float"; MaterialX has no
//     implicit conversions);
//   - nothing may read from itself, directly or through other nodes;
//   - a `uniform` input takes a value or a nodegraph's own input, never a
//     node's output;
//   - a nodegraph's `<output>` can't pass one of the graph's inputs
//     straight through (MaterialX allows `interfacename` only on inputs);
//   - locked (included) nodes can't be rewired;
//   - wires from a top-level `<output>` (`output="…"`, M7b) are drawn but
//     not made or moved here.
//
// Introduces (SWIFT): a depth-first search with a `Set` of seen nodes,
// `Set.insert(_:).inserted`, `popLast()`, closures as parameters choosing a
// direction, `dict[key, default:]`, `indices.dropFirst()`.

import CoreGraphics

/// An input, named by its node and name rather than its row: hidden inputs
/// (the "+N more inputs") have no row, and edits name inputs anyway.
public struct InputSlot: Hashable, Sendable {
    /// The canvas node (its index in ``GraphModel/nodes``).
    public var node: Int
    /// The input's name, as in ``GraphPort/name``.
    public var name: String

    public init(node: Int, name: String) {
        self.node = node
        self.name = name
    }
}

/// A connection made on the canvas, for the app to make in the document.
public struct WireConnection: Hashable, Sendable {
    /// The output the wire comes from.
    public var output: PortReference
    /// The input it goes to. If it was connected, the new wire replaces
    /// the old one (an input takes one connection).
    public var input: InputSlot
    /// Set when an existing wire was pulled off one input and dropped on
    /// another: the input it came from, which loses its connection.
    public var movedFrom: InputSlot?

    public init(output: PortReference, input: InputSlot, movedFrom: InputSlot? = nil) {
        self.output = output
        self.input = input
        self.movedFrom = movedFrom
    }
}

/// What a wire being dragged may connect to. Everything else is dimmed.
public struct WireCandidates: Equatable, Sendable {
    /// When dragging from an output: the input rows that can take the wire.
    public var inputs: Set<PortReference> = []
    /// When dragging from an output: the hidden inputs that can take it,
    /// by node. A node in here keeps its "+N more inputs" row bright.
    public var hiddenInputs: [Int: [String]] = [:]
    /// When dragging from an input: the outputs that can feed it.
    public var outputs: Set<PortReference> = []
    /// True when looking for outputs (the drag started at an input).
    public var seeksOutputs: Bool = false

    /// The inputs of `node` that can take the wire: shown rows first, then
    /// hidden ones, in the node's order.
    func inputSlots(on node: GraphNode) -> [InputSlot] {
        var slots: [InputSlot] = []
        for (index, port) in node.inputs.enumerated() where inputs.contains(PortReference(node: node.id, index: index)) {
            slots.append(InputSlot(node: node.id, name: port.name))
        }
        // SWIFT: `dict[key, default: []]` reads the value, or the default
        // if the key is missing, instead of an optional.
        for name in hiddenInputs[node.id, default: []] {
            slots.append(InputSlot(node: node.id, name: name))
        }
        return slots
    }

    /// The outputs of `node` that can feed the wire.
    func outputRefs(on node: GraphNode) -> [PortReference] {
        node.outputs.indices.map { PortReference(node: node.id, index: $0) }.filter { outputs.contains($0) }
    }
}

extension GraphModel {
    /// The nodes `node` reads from, directly or through others, and `node`
    /// itself. Connecting `node`'s output into any of them would make a loop.
    public func upstream(of node: Int) -> Set<Int> {
        reachable(from: node, following: { wire in wire.to.node }, to: { wire in wire.from.node })
    }

    /// The nodes that read from `node`, directly or through others, and
    /// `node` itself. None of them can feed one of `node`'s inputs.
    public func downstream(of node: Int) -> Set<Int> {
        reachable(from: node, following: { wire in wire.from.node }, to: { wire in wire.to.node })
    }

    /// The nodes reachable from `start` by walking wires from their `from`
    /// end to their `to` end (both given as closures, so one function
    /// serves both directions). A depth-first search with a work list.
    private func reachable(from start: Int, following from: (GraphWire) -> Int,
                           to: (GraphWire) -> Int) -> Set<Int> {
        var seen: Set<Int> = [start]
        var pending: [Int] = [start]
        // SWIFT: `popLast()` removes and returns the last element, or nil
        // when the array is empty, which ends the loop.
        while let node = pending.popLast() {
            for wire in wires where from(wire) == node {
                // SWIFT: `insert` returns a tuple whose `inserted` is false
                // if the element was already there, like std::set::insert.
                if seen.insert(to(wire)).inserted {
                    pending.append(to(wire))
                }
            }
        }
        return seen
    }

    /// The wire into input row `input`, if it is connected.
    public func wire(into input: PortReference) -> GraphWire? {
        wires.first(where: { $0.to == input })
    }

    /// Whether `output` may feed `port`, an input of `node` (shown or
    /// hidden), by every rule in the file comment except loops, which
    /// callers check with ``upstream(of:)`` or ``downstream(of:)``.
    func accepts(_ port: GraphPort, on node: Int, from output: PortReference) -> Bool {
        let target: GraphNode = nodes[node]
        let source: GraphNode = nodes[output.node]
        guard !target.isLocked, source.outputs[output.index].type == port.type else {
            return false
        }
        // Interface nodes with outputs are the graph's own inputs; those
        // with inputs are its <output>s.
        let fromInterface: Bool = source.category == .graphInterface
        if fromInterface && target.category == .graphInterface {
            return false
        }
        if port.isUniform && !fromInterface {
            return false
        }
        return true
    }

    /// Everything a wire dragged from `output` can connect to.
    public func candidates(from output: PortReference) -> WireCandidates {
        var result = WireCandidates()
        let loops: Set<Int> = upstream(of: output.node)
        for node in nodes where !loops.contains(node.id) {
            for (index, port) in node.inputs.enumerated() where accepts(port, on: node.id, from: output) {
                result.inputs.insert(PortReference(node: node.id, index: index))
            }
            let hidden: [String] = node.hiddenInputs.filter { accepts($0, on: node.id, from: output) }.map(\.name)
            if !hidden.isEmpty {
                result.hiddenInputs[node.id] = hidden
            }
        }
        return result
    }

    /// Everything that can feed a wire dragged from input row `input`.
    public func candidates(into input: PortReference) -> WireCandidates {
        var result = WireCandidates(seeksOutputs: true)
        let port: GraphPort = nodes[input.node].inputs[input.index]
        let loops: Set<Int> = downstream(of: input.node)
        for node in nodes where !loops.contains(node.id) {
            for index in node.outputs.indices where node.outputs[index].startsWires {
                let output = PortReference(node: node.id, index: index)
                if accepts(port, on: input.node, from: output) {
                    result.outputs.insert(output)
                }
            }
        }
        return result
    }

    /// The wires that the straight cut from `start` to `end` crosses.
    public func wires(crossing start: CGPoint, _ end: CGPoint) -> Set<GraphWire> {
        var crossed: Set<GraphWire> = []
        for wire in wires {
            let points: [CGPoint] = GraphLayout.wirePoints(
                from: GraphLayout.outputPoint(of: nodes[wire.from.node], index: wire.from.index),
                to: GraphLayout.inputPoint(of: nodes[wire.to.node], index: wire.to.index))
            // SWIFT: `indices.dropFirst()` is 1..<count: each point after
            // the first, paired with the one before it.
            for i in points.indices.dropFirst()
            where GraphLayout.segmentsIntersect(points[i - 1], points[i], start, end) {
                crossed.insert(wire)
                break
            }
        }
        return crossed
    }

    /// The input a wire ends at, by name.
    public func slot(of input: PortReference) -> InputSlot {
        InputSlot(node: input.node, name: nodes[input.node].inputs[input.index].name)
    }
}
