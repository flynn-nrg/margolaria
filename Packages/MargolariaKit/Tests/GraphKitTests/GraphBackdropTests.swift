// GraphBackdropTests.swift
//
// Tests for backdrops on the canvas (M4d): built from a document, picked up
// by the header, moved with what they contain, resized by the grip,
// selected and deleted; nodes dragged in and out change what they contain.
// M4d's exit criterion, for the canvas: a backdrop made, moved and resized
// the way the canvas does it moves its nodes in the document, survives
// saving, and undoes (MXBackdropEditTests checks every example).
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import Testing
@testable import GraphKit
import MXKit

@MainActor
@Suite("Backdrops on the canvas")
struct GraphBackdropTests {
    /// Three nodes in a row, the first two in a backdrop.
    static let xml = """
        <?xml version="1.0"?>
        <materialx version="1.39">
          <constant name="a" type="float" xpos="0" ypos="0"><input name="value" type="float" value="1" /></constant>
          <constant name="b" type="float" xpos="2" ypos="0"><input name="value" type="float" value="2" /></constant>
          <add name="c" type="float" xpos="6" ypos="0">
            <input name="in1" type="float" nodename="a" />
            <input name="in2" type="float" nodename="b" />
          </add>
          <backdrop name="inputs" contains="a,b" xpos="-0.25" ypos="-0.5" width="3.5" height="2" note="The constants" />
        </materialx>
        """

    func document(_ xml: String = Self.xml) throws -> MXDocument {
        let document = try MXDocument(xml: xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
        return document
    }

    /// The document's top level on the canvas, laid out, and a controller
    /// showing it at 100% with graph and view coordinates the same.
    func canvas(_ document: MXDocument) throws -> (DocumentGraph, GraphCanvasController) {
        var graph: DocumentGraph = GraphBuilder.build(try document.graph(at: ""))
        graph.layout()
        let controller = GraphCanvasController(model: graph.model)
        controller.zoom = 1
        controller.offset = .zero
        return (graph, controller)
    }

    /// A point in the backdrop's header.
    func header(_ backdrop: GraphBackdrop) -> CGPoint {
        CGPoint(x: backdrop.frame.midX, y: backdrop.frame.minY + 5)
    }

    func centre(_ node: GraphNode) -> CGPoint {
        GraphLayout.centre(of: node)
    }

    @Test("Built from the document: in points, with what it contains, its title and note")
    func built() throws {
        let (graph, controller) = try canvas(try document())
        let backdrop: GraphBackdrop = try #require(controller.model.backdrops.first)
        #expect(graph.backdropPaths == ["inputs"])
        #expect(backdrop.title == "inputs")
        #expect(backdrop.note == "The constants")
        let unit: CGSize = DocumentGraph.pointsPerUnit
        #expect(backdrop.frame == CGRect(x: -0.25 * unit.width, y: -0.5 * unit.height,
                                         width: 3.5 * unit.width, height: 2 * unit.height))
        #expect(backdrop.contents == Set([graph.nodeIndex(forPath: "a"), graph.nodeIndex(forPath: "b")].compactMap { $0 }))
        // Frame All includes it.
        #expect(GraphLayout.bounds(of: controller.model).contains(backdrop.frame))
    }

    @Test("One saved without a frame is fitted around what it contains")
    func fitted() throws {
        let xml: String = Self.xml.replacingOccurrences(of: #" xpos="-0.25" ypos="-0.5" width="3.5" height="2""#, with: "")
        let (graph, controller) = try canvas(try document(xml))
        #expect(graph.fittedBackdrops == [0])
        let frame: CGRect = controller.model.backdrops[0].frame
        for name in ["a", "b"] {
            let node: GraphNode = controller.model.nodes[try #require(graph.nodeIndex(forPath: name))]
            #expect(frame.contains(GraphLayout.frame(of: node)), "\(name) is inside")
        }
        let c: GraphNode = controller.model.nodes[try #require(graph.nodeIndex(forPath: "c"))]
        #expect(!frame.contains(centre(c)))
    }

    @Test("Hit testing: the header and the grip pick it up; its body lets clicks through; nodes are on top")
    func hitTesting() throws {
        let (_, controller) = try canvas(try document())
        let backdrop: GraphBackdrop = controller.model.backdrops[0]
        #expect(controller.hitTest(header(backdrop)) == .backdrop(0))
        #expect(controller.hitTest(CGPoint(x: backdrop.frame.maxX - 3, y: backdrop.frame.maxY - 3)) == .backdropGrip(0))
        // Below the header, beside the nodes: empty canvas, for a marquee.
        #expect(controller.hitTest(CGPoint(x: backdrop.frame.minX + 4, y: backdrop.frame.maxY - 30)) == .empty)
        #expect(controller.hitTest(centre(controller.model.nodes[0])) == .node(0))
    }

    @Test("Dragging the header moves it and what it contains, nothing else, reported once")
    func moveWithContents() throws {
        let (_, controller) = try canvas(try document())
        var moves: [GraphMove] = []
        controller.onMove = { moves.append($0) }
        let before: GraphModel = controller.model
        let start: CGPoint = header(before.backdrops[0])

        controller.mouseDown(at: start, extend: false)
        #expect(controller.backdropSelection == [0])
        #expect(controller.selection.isEmpty)
        controller.mouseDragged(to: CGPoint(x: start.x + 50, y: start.y + 20))
        controller.mouseUp()

        let after: GraphModel = controller.model
        #expect(after.backdrops[0].frame == before.backdrops[0].frame.offsetBy(dx: 50, dy: 20))
        for id in [0, 1] {
            #expect(after.nodes[id].position == CGPoint(x: before.nodes[id].position.x + 50,
                                                        y: before.nodes[id].position.y + 20))
        }
        #expect(after.nodes[2].position == before.nodes[2].position)
        #expect(moves.count == 1)
        #expect(moves.first?.nodes.keys.sorted() == [0, 1])
        #expect(moves.first?.backdrops[0] == after.backdrops[0].frame)
        #expect(moves.first?.contents.isEmpty == true, "it contains the same nodes")
    }

    @Test("A node dragged out of a backdrop leaves it; dragged into one, it joins")
    func dragInAndOut() throws {
        let (_, controller) = try canvas(try document())
        var moves: [GraphMove] = []
        controller.onMove = { moves.append($0) }

        // b, out to the far right.
        let b: CGPoint = centre(controller.model.nodes[1])
        controller.mouseDown(at: b, extend: false)
        controller.mouseDragged(to: CGPoint(x: b.x + 2000, y: b.y))
        controller.mouseUp()
        #expect(moves.last?.contents == [0: [0]])
        #expect(controller.model.backdrops[0].contents == [0])

        // c, into the backdrop, next to a.
        let c: CGPoint = centre(controller.model.nodes[2])
        let target: CGPoint = CGPoint(x: controller.model.backdrops[0].frame.maxX - 60,
                                      y: controller.model.backdrops[0].frame.midY)
        controller.mouseDown(at: c, extend: false)
        controller.mouseDragged(to: target)
        controller.mouseUp()
        #expect(moves.last?.contents == [0: [0, 2]])

        // Moved within it: nothing changes.
        controller.mouseDown(at: centre(controller.model.nodes[0]), extend: false)
        controller.mouseDragged(to: CGPoint(x: centre(controller.model.nodes[0]).x + 5, y: centre(controller.model.nodes[0]).y))
        controller.mouseUp()
        #expect(moves.last?.contents.isEmpty == true)
    }

    @Test("The grip resizes it, no smaller than the minimum, taking in the nodes its edges pass")
    func resize() throws {
        let (_, controller) = try canvas(try document())
        var moves: [GraphMove] = []
        controller.onMove = { moves.append($0) }
        let frame: CGRect = controller.model.backdrops[0].frame
        let grip = CGPoint(x: frame.maxX - 3, y: frame.maxY - 3)

        // Wider, past c: c joins, and nothing moves.
        let c: GraphNode = controller.model.nodes[2]
        controller.mouseDown(at: grip, extend: false)
        controller.mouseDragged(to: CGPoint(x: GraphLayout.frame(of: c).maxX + 20, y: grip.y))
        controller.mouseUp()
        #expect(controller.model.backdrops[0].frame.origin == frame.origin)
        #expect(moves.last?.nodes.isEmpty == true)
        #expect(moves.last?.contents == [0: [0, 1, 2]])

        // Far smaller: the minimum size, and the nodes outside it leave.
        let wide: CGRect = controller.model.backdrops[0].frame
        controller.mouseDown(at: CGPoint(x: wide.maxX - 3, y: wide.maxY - 3), extend: false)
        controller.mouseDragged(to: CGPoint(x: wide.minX - 500, y: wide.minY - 500))
        controller.mouseUp()
        #expect(controller.model.backdrops[0].frame.size == GraphLayout.backdropMinimumSize)
        #expect(moves.last?.contents[0].map { !$0.contains(2) } ?? false)
    }

    @Test("Selecting: the header selects it, Shift adds; clicking a node or empty canvas deselects; marquees take whole ones")
    func selecting() throws {
        let (_, controller) = try canvas(try document())
        let backdrop: GraphBackdrop = controller.model.backdrops[0]
        controller.selection = [2]
        controller.mouseDown(at: header(backdrop), extend: true)
        controller.mouseUp()
        #expect(controller.selection == [2] && controller.backdropSelection == [0])

        controller.mouseDown(at: centre(controller.model.nodes[2]), extend: false)
        controller.mouseUp()
        #expect(controller.selection == [2] && controller.backdropSelection == [0], "a selected node keeps the selection")
        controller.mouseDown(at: centre(controller.model.nodes[0]), extend: false)
        controller.mouseUp()
        #expect(controller.selection == [0] && controller.backdropSelection.isEmpty)

        controller.mouseDown(at: CGPoint(x: -5000, y: -5000), extend: false)
        controller.mouseUp()
        #expect(controller.backdropSelection.isEmpty && controller.selection.isEmpty)

        // A marquee around all of it selects it; across part of it, not.
        controller.mouseDown(at: CGPoint(x: backdrop.frame.minX - 10, y: backdrop.frame.minY - 10), extend: false)
        controller.mouseDragged(to: CGPoint(x: backdrop.frame.maxX + 10, y: backdrop.frame.maxY + 10))
        controller.mouseUp()
        #expect(controller.backdropSelection == [0])
        controller.mouseDown(at: CGPoint(x: backdrop.frame.minX - 10, y: backdrop.frame.minY - 10), extend: false)
        controller.mouseDragged(to: CGPoint(x: backdrop.frame.midX, y: backdrop.frame.maxY + 10))
        controller.mouseUp()
        #expect(controller.backdropSelection.isEmpty)
    }

    @Test("Delete takes selected backdrops and nodes; a locked backdrop is selected, not moved, resized or deleted")
    func deleteAndLocked() throws {
        let (_, controller) = try canvas(try document())
        var deletions: [GraphDeletion] = []
        controller.onDelete = { deletions.append($0) }
        controller.backdropSelection = [0]
        controller.selection = [2]
        controller.deleteSelection()
        #expect(deletions == [GraphDeletion(nodes: [2], backdrops: [0])])

        controller.model.backdrops[0].isLocked = true
        let frame: CGRect = controller.model.backdrops[0].frame
        controller.selection = []
        controller.deleteSelection()
        #expect(deletions.count == 1, "only a locked backdrop selected")
        var moves: [GraphMove] = []
        controller.onMove = { moves.append($0) }
        controller.mouseDown(at: header(controller.model.backdrops[0]), extend: false)
        controller.mouseDragged(to: CGPoint(x: frame.midX + 80, y: frame.minY + 5))
        controller.mouseUp()
        controller.mouseDown(at: CGPoint(x: frame.maxX - 3, y: frame.maxY - 3), extend: false)
        controller.mouseDragged(to: CGPoint(x: frame.maxX + 300, y: frame.maxY + 300))
        controller.mouseUp()
        #expect(controller.model.backdrops[0].frame == frame)
        #expect(moves.isEmpty)
    }

    @Test("Group in Backdrop works with nothing selected; F frames selected backdrops")
    func commandAndFraming() throws {
        let (_, controller) = try canvas(try document())
        var requests: [GraphCommandRequest] = []
        controller.onCommand = { requests.append($0) }
        #expect(controller.perform(.backdrop, at: CGPoint(x: 10, y: 20)))
        #expect(requests.first?.nodes.isEmpty == true)
        controller.selection = [1, 2]
        #expect(controller.perform(.backdrop, at: .zero))
        #expect(requests.last?.nodes == [1, 2])

        controller.viewSize = CGSize(width: 800, height: 600)
        controller.selection = []
        controller.backdropSelection = [0]
        controller.frame(.selection)
        let visible: CGRect = controller.visibleGraphRect(viewSize: controller.viewSize)
        #expect(visible.contains(controller.model.backdrops[0].frame))
    }

    @Test("Made, moved, resized and deleted through the document, as the app does; it round-trips and undoes (M4d)")
    func throughTheDocument() throws {
        let document = try document()
        let original: MXDocument = document.copy()

        // Group in Backdrop around b and c.
        var (graph, controller) = try canvas(document)
        let around: Set<Int> = [1, 2]
        let path: String = try graph.addBackdrop(around: around, in: controller.model, at: .zero, to: document)
        try document.setNote("Sums", ofBackdrop: path)
        (graph, controller) = try canvas(document)
        let index: Int = try #require(graph.backdropIndex(forPath: path))
        let made: GraphBackdrop = controller.model.backdrops[index]
        #expect(made.contents == around)
        #expect(made.note == "Sums")
        for id in around {
            #expect(made.frame.contains(GraphLayout.frame(of: controller.model.nodes[id])))
        }

        // Dragged: its nodes move in the document.
        var saved: GraphMove? = nil
        controller.onMove = { saved = $0 }
        let start: CGPoint = header(made)
        controller.mouseDown(at: start, extend: false)
        controller.mouseDragged(to: CGPoint(x: start.x + 185, y: start.y + 370))
        controller.mouseUp()
        let move: GraphMove = try #require(saved)
        #expect(graph.undoName(for: move) == "Move \(made.title)")
        try graph.save(move, in: document)
        let moved: MXGraph = try document.graph(at: "")
        // In MaterialX units, saved to three decimals.
        let unit: CGSize = DocumentGraph.pointsPerUnit
        let b: CGPoint = try #require(moved.node(named: "b")?.position)
        #expect(abs(b.x - (2 + 185 / unit.width)) < 0.001 && abs(b.y - 370 / unit.height) < 0.001, "\(b)")
        #expect(moved.node(named: "a")?.position == CGPoint(x: 0, y: 0), "a isn't in it")

        // Resized.
        (graph, controller) = try canvas(document)
        controller.onMove = { saved = $0 }
        let frame: CGRect = controller.model.backdrops[index].frame
        controller.mouseDown(at: CGPoint(x: frame.maxX - 3, y: frame.maxY - 3), extend: false)
        controller.mouseDragged(to: CGPoint(x: frame.maxX + 97, y: frame.maxY + 47))
        controller.mouseUp()
        let resize: GraphMove = try #require(saved)
        #expect(graph.undoName(for: resize) == "Resize \(made.title)")
        try graph.save(resize, in: document)
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        // Saved and read back: the same canvas.
        let reread = try MXDocument(xml: try document.xmlString())
        reread.setDataLibrary(try MXLibrary.bundled.get())
        #expect(reread.difference(from: document) == nil)
        let (rereadGraph, rereadCanvas) = try canvas(reread)
        #expect(rereadGraph.backdropPaths == graph.backdropPaths)
        for (a, b) in zip(rereadCanvas.model.backdrops, try canvas(document).1.model.backdrops) {
            #expect(abs(a.frame.minX - b.frame.minX) < 0.5 && abs(a.frame.width - b.frame.width) < 0.5)
            #expect(a.contents == b.contents)
        }

        // Deleted: its nodes stay.
        (graph, controller) = try canvas(document)
        let deletion = GraphDeletion(nodes: [], backdrops: [index])
        #expect(graph.deletes(deletion))
        #expect(graph.undoName(forDeleting: deletion) == "Delete \(made.title)")
        try graph.delete(deletion, in: document)
        #expect(try document.graph(at: "").nodes.count == 3)
        #expect(try document.graph(at: "").backdrops.map(\.name) == ["inputs"])

        // Undo, all the way: the document it was.
        document.restore(from: original)
        #expect(document.difference(from: original) == nil)
    }

    @Test("Arrange fits each backdrop around what it contains")
    func arrangeFits() throws {
        let (graph, controller) = try canvas(try document())
        var model: GraphModel = controller.model
        GraphAutoLayout.apply(to: &model)
        let frames: [Int: CGRect] = graph.fittedBackdropFrames(in: model)
        let frame: CGRect = try #require(frames[0])
        for id in model.backdrops[0].contents {
            #expect(frame.contains(GraphLayout.frame(of: model.nodes[id])))
        }
    }
}
