// DocumentBackdrops.swift
//
// Turns what the canvas does with backdrops (M4d) into MXKit edits on the
// document a DocumentGraph was built from: Group in Backdrop, a drag that
// moved or resized them (GraphMove), and Delete (GraphDeletion). The canvas
// names nodes and backdrops by index and works in points; MaterialX names
// them by element name and stores MaterialX units (see GraphBuilder).
//
// Kept here rather than in the app, like DocumentWiring.swift, so the
// tests can make, move and undo backdrops the way the canvas does.
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import MXKit

extension DocumentGraph {
    /// True if canvas node `id` is an element a backdrop can name. Not a
    /// nodegraph input that exists only in the nodedef the graph
    /// implements: it isn't in the graph to be named.
    func isFramable(_ id: Int) -> Bool {
        !(kinds[id] == .interfaceInput && model.nodes[id].isLocked)
    }

    /// The element names a backdrop containing the canvas nodes `ids` saves,
    /// in canvas order (the file's).
    public func contentNames(_ ids: Set<Int>) -> [String] {
        ids.sorted().filter(isFramable).map { elementName(of: $0) }
    }

    /// Adds a backdrop around the canvas nodes `ids` as `model` (the
    /// canvas's) places them, or, for none, an empty one with its top-left
    /// corner at `point` (graph coordinates). Returns its path.
    @discardableResult
    public func addBackdrop(around ids: Set<Int>, in model: GraphModel, at point: CGPoint,
                            to document: MXDocument) throws -> String {
        let frames: [CGRect] = ids.sorted().map { GraphLayout.frame(of: model.nodes[$0]) }
        let frame: CGRect = GraphLayout.backdropFrame(around: frames)
            ?? CGRect(origin: point, size: GraphLayout.backdropMinimumSize)
        return try document.addBackdrop(containing: contentNames(ids), in: graphPath,
                                        frame: DocumentGraph.units(fromPoints: frame))
    }

    /// Saves what a drag did (see GraphMove): nodes' positions, backdrops'
    /// frames and what they contain now. Locked nodes and backdrops are
    /// left alone (the canvas doesn't move them).
    public func save(_ move: GraphMove, in document: MXDocument) throws {
        for (id, position) in move.nodes where !model.nodes[id].isLocked {
            try document.setPosition(DocumentGraph.units(fromPoints: position), of: elementPaths[id])
        }
        for (id, frame) in move.backdrops where !model.backdrops[id].isLocked {
            try document.setFrame(DocumentGraph.units(fromPoints: frame), ofBackdrop: backdropPaths[id])
        }
        for (id, contents) in move.contents where !model.backdrops[id].isLocked {
            try document.setContents(contentNames(contents), ofBackdrop: backdropPaths[id])
        }
    }

    /// Deletes nodes and backdrops. A nodegraph's own inputs and outputs
    /// (shown at the graph's edges) aren't nodes, and are left alone; what
    /// a deleted backdrop contains stays.
    public func delete(_ deletion: GraphDeletion, in document: MXDocument) throws {
        for id in deletion.backdrops.sorted() where !model.backdrops[id].isLocked {
            try document.removeBackdrop(at: backdropPaths[id])
        }
        for id in deletion.nodes.sorted() where model.nodes[id].category != .graphInterface {
            try document.removeNode(at: elementPaths[id])
        }
    }

    /// True if `deletion` would delete anything (see delete(_:in:)).
    public func deletes(_ deletion: GraphDeletion) -> Bool {
        deletion.backdrops.contains { !model.backdrops[$0].isLocked }
            || deletion.nodes.contains { model.nodes[$0].category != .graphInterface }
    }

    /// The frames that fit each backdrop around what it contains, as
    /// `model` (the canvas's, after Arrange) places them; backdrops that
    /// contain nothing, or are locked, are left out.
    public func fittedBackdropFrames(in model: GraphModel) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for backdrop in model.backdrops where !backdrop.isLocked {
            let nodes: [CGRect] = backdrop.contents.sorted().map { GraphLayout.frame(of: model.nodes[$0]) }
            frames[backdrop.id] = GraphLayout.backdropFrame(around: nodes)
        }
        return frames
    }

    /// The Edit menu's name for undoing `move`: "Move", "Move 3 Nodes",
    /// "Move notes" (a backdrop, with what it contains), "Resize notes".
    public func undoName(for move: GraphMove) -> String {
        if move.backdrops.count == 1, let (id, frame) = move.backdrops.first {
            let title: String = model.backdrops[id].title
            return move.nodes.isEmpty && model.backdrops[id].frame.origin == frame.origin ? "Resize \(title)"
                                                                                           : "Move \(title)"
        }
        if move.backdrops.count > 1 {
            return "Move \(move.backdrops.count) Backdrops"
        }
        return move.nodes.count == 1 ? "Move" : "Move \(move.nodes.count) Nodes"
    }

    /// The Edit menu's name for undoing `deletion`: "Delete dirt",
    /// "Delete 3 Nodes", "Delete 3 Items" (nodes and backdrops).
    public func undoName(forDeleting deletion: GraphDeletion) -> String {
        let backdrops: [String] = deletion.backdrops.sorted().map { model.backdrops[$0].title }
        let nodes: [String] = deletion.nodes.sorted().filter { model.nodes[$0].category != .graphInterface }
            .map { model.nodes[$0].title }
        let names: [String] = backdrops + nodes
        if names.count == 1 {
            return "Delete \(names[0])"
        }
        return backdrops.isEmpty ? "Delete \(names.count) Nodes" : "Delete \(names.count) Items"
    }
}
