// GraphAutoLayout.swift
//
// Places a graph's nodes in columns, so that every wire runs left to right:
// materials and outputs in the rightmost column, the nodes feeding them in
// the column to the left, and so on. None of MaterialX's example files
// stores node positions, so every graph the app opens goes through this.
//
// The method is a simple *layered* layout (the family of algorithms named
// after Sugiyama), in three steps:
//
//   1. Columns. A node's column is the length of the longest path from it to
//      a node with nothing downstream. So every node sits left of everything
//      it feeds, and wires never run backwards.
//   2. Order. Columns are filled right to left. Within a column, nodes are
//      sorted by the average height of the pins they connect to in the
//      columns already placed (the "barycentre"), which keeps most wires
//      short and reduces crossings.
//   3. Heights. Each node goes at the height of that average, then nodes
//      that would overlap are pushed down, and the column is shifted back up
//      so that it stays centred on where its nodes wanted to be.
//
// Good enough for MaterialX's examples (at most 45 nodes per level). Real
// crossing minimisation and wire routing can come later.
//
// Introduces (SWIFT): `inout` parameters on our own functions, recursion
// with a memo dictionary, `sort(by:)` with a tuple comparison, `Array(repeating:count:)`.

import CoreGraphics

/// Lays graphs out in columns, sources on the left.
public enum GraphAutoLayout {
    /// Horizontal space between columns, for the wires.
    public static let columnGap: CGFloat = 90
    /// Vertical space between nodes in a column.
    public static let rowGap: CGFloat = 30

    /// Sets the position of every node in `model`.
    ///
    /// SWIFT: `inout` lets the function change the caller's variable: the
    /// caller writes `GraphAutoLayout.apply(to: &model)`. Swift copies the
    /// value in and back out (or, in practice, modifies it in place); the
    /// `&` at the call site makes the change visible, like a non-const
    /// reference in C++.
    public static func apply(to model: inout GraphModel) {
        let count: Int = model.nodes.count
        guard count > 0 else {
            return
        }

        // Who feeds whom. `consumers[n]` lists the wires leaving node n.
        // SWIFT: `Array(repeating:count:)` makes an array of `count` copies
        // of a value, here empty arrays.
        var consumers: [[GraphWire]] = Array(repeating: [], count: count)
        for wire in model.wires {
            consumers[wire.from.node].append(wire)
        }

        // 1. Columns, counted from the right.
        var column: [Int: Int] = [:]
        var visiting: Set<Int> = []
        // SWIFT: A nested function can call itself. `column` acts as a memo:
        // each node's column is computed once.
        func columnOf(_ node: Int) -> Int {
            if let known = column[node] {
                return known
            }
            // MaterialX graphs have no cycles, but a broken file could.
            // Treat a node met again on the current path as a sink, rather
            // than recursing forever.
            if visiting.contains(node) {
                return 0
            }
            visiting.insert(node)
            var result: Int = 0
            for wire in consumers[node] {
                result = max(result, columnOf(wire.to.node) + 1)
            }
            visiting.remove(node)
            column[node] = result
            return result
        }
        var columns: [[Int]] = []
        for node in 0..<count {
            let c: Int = columnOf(node)
            while columns.count <= c {
                columns.append([])
            }
            columns[c].append(node)
        }

        // 2 and 3, one column at a time from the right.
        let columnStep: CGFloat = GraphLayout.nodeWidth + columnGap
        for (c, members) in columns.enumerated() {
            let x: CGFloat = -CGFloat(c) * columnStep

            // Where each node would like its top edge to be.
            var wanted: [(node: Int, y: CGFloat)] = []
            for node in members {
                model.nodes[node].position = CGPoint(x: x, y: 0)
                wanted.append((node, preferredTop(of: node, in: model, consumers: consumers[node])))
            }

            // Sort by preferred height; ties keep file order.
            // SWIFT: Tuples compare element by element with `<`, so
            // `(a.y, a.node) < (b.y, b.node)` sorts by y, then by node.
            wanted.sort(by: { (a, b) in (a.y, a.node) < (b.y, b.node) })

            // Push overlapping nodes down, in order.
            var placed: [CGFloat] = []
            var nextFree: CGFloat = -.greatestFiniteMagnitude
            for entry in wanted {
                let top: CGFloat = max(entry.y, nextFree)
                placed.append(top)
                let height: CGFloat = GraphLayout.frame(of: model.nodes[entry.node]).height
                nextFree = top + height + rowGap
            }

            // Pushing only moves nodes down; move the column back up by the
            // average push, so it stays centred on where it wanted to be.
            // Every node moves by the same amount, so none overlap.
            var totalPush: CGFloat = 0
            for (i, entry) in wanted.enumerated() {
                totalPush += placed[i] - entry.y
            }
            let shift: CGFloat = totalPush / CGFloat(wanted.count)
            for (i, entry) in wanted.enumerated() {
                model.nodes[entry.node].position = CGPoint(x: x, y: placed[i] - shift)
            }
        }
    }

    /// Moves nodes down, as little as possible, until none overlaps
    /// another; nodes that don't overlap anything stay where they are.
    ///
    /// For positions saved in a document: they were made in another editor,
    /// or with shorter nodes (before swatches, M3c, or with fewer inputs
    /// shown), so taller nodes can run into their neighbours. The canvas
    /// resolves that on screen only; the document keeps its positions
    /// until a node is moved, or the level arranged.
    ///
    /// Nodes are taken from the top down (left to right at the same
    /// height). Each is pushed below every node already placed that it
    /// overlaps, with `gap` between them, so a column keeps its order, and
    /// nodes side by side don't affect each other.
    public static func separate(_ model: inout GraphModel, gap: CGFloat = rowGap) {
        // SWIFT: `indices.sorted { }` sorts node IDs by the tuple
        // (top, left, ID): by height, then from the left, then file order.
        let order: [Int] = model.nodes.indices.sorted { a, b in
            let pa: CGPoint = model.nodes[a].position
            let pb: CGPoint = model.nodes[b].position
            return (pa.y, pa.x, a) < (pb.y, pb.x, b)
        }
        var placed: [CGRect] = []
        for id in order {
            var frame: CGRect = GraphLayout.frame(of: model.nodes[id])
            // Pushing below one node can bring it onto another placed
            // further down, so look again until nothing overlaps. Each
            // push moves it below a placed node, so this ends.
            var moved: Bool = true
            while moved {
                moved = false
                for other in placed where other.intersects(frame.insetBy(dx: 0, dy: -gap / 2)) {
                    frame.origin.y = other.maxY + gap
                    moved = true
                }
            }
            model.nodes[id].position.y = frame.minY
            placed.append(frame)
        }
    }

    /// The top edge that would put `node`'s outputs level with the inputs
    /// they connect to, averaged over its wires. Nodes with nothing
    /// downstream (the rightmost column) are stacked in file order instead.
    static func preferredTop(of node: Int, in model: GraphModel, consumers: [GraphWire]) -> CGFloat {
        guard !consumers.isEmpty else {
            // Spread sinks out in file order; the overlap pass stacks them.
            return CGFloat(node)
        }
        // The output pin's height relative to the node's top edge.
        var atOrigin: GraphNode = model.nodes[node]
        atOrigin.position = .zero
        var sum: CGFloat = 0
        for wire in consumers {
            let target: CGPoint = GraphLayout.inputPoint(of: model.nodes[wire.to.node], index: wire.to.index)
            let pinOffset: CGFloat = GraphLayout.outputPoint(of: atOrigin, index: wire.from.index).y
            sum += target.y - pinOffset
        }
        return sum / CGFloat(consumers.count)
    }
}
