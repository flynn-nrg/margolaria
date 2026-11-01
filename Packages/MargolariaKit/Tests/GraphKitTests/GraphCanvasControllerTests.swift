// GraphCanvasControllerTests.swift
//
// Tests for the canvas model and behaviour: the synthetic graph, hit
// testing, marquee selection, zooming. Renderers are measured by the
// GraphSpike app's benchmark instead (they need a window).
//
// Introduces (SWIFT): `@MainActor` on a test suite.

import AppKit
import CoreGraphics
import Testing
@testable import GraphKit

// SWIFT: GraphCanvasController is `@MainActor`, so the tests that use it
// must run on the main actor too. Marking the suite does that for every test.
@MainActor
@Suite("Graph canvas")
struct GraphCanvasControllerTests {
    @Test("The synthetic graph is repeatable and only connects left to right")
    func synthetic() {
        let a = GraphModel.synthetic(nodeCount: 500, seed: 7)
        let b = GraphModel.synthetic(nodeCount: 500, seed: 7)
        #expect(a.nodes.count == 500)
        #expect(a.wires.count > 500)
        #expect(a.wires == b.wires)
        for wire in a.wires {
            // Sources come from earlier nodes, so the graph has no cycles.
            #expect(wire.from.node < wire.to.node)
            #expect(a.nodes[wire.to.node].inputs[wire.to.index].value == nil, "connected inputs show no value")
        }
    }

    @Test("Hit testing finds pins, node bodies and empty space")
    func hitTesting() {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 50))
        let node: GraphNode = controller.model.nodes[10]
        let frame: CGRect = GraphLayout.frame(of: node)

        #expect(controller.hitTest(CGPoint(x: frame.midX, y: frame.minY + 5)) == .node(10))
        #expect(controller.hitTest(GraphLayout.outputPoint(of: node, index: 0))
                == .output(PortReference(node: 10, index: 0)))
        #expect(controller.hitTest(GraphLayout.inputPoint(of: node, index: 0))
                == .input(PortReference(node: 10, index: 0)))
        #expect(controller.hitTest(CGPoint(x: -1000, y: -1000)) == .empty)
    }

    @Test("Clicking selects, Shift-click toggles, clicking empty space clears")
    func clickSelection() {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 50))
        controller.zoom = 1
        controller.offset = .zero
        let first: CGRect = GraphLayout.frame(of: controller.model.nodes[3])
        let second: CGRect = GraphLayout.frame(of: controller.model.nodes[4])

        controller.mouseDown(at: CGPoint(x: first.midX, y: first.midY), extend: false)
        controller.mouseUp()
        #expect(controller.selection == [3])

        controller.mouseDown(at: CGPoint(x: second.midX, y: second.midY), extend: true)
        controller.mouseUp()
        #expect(controller.selection == [3, 4])

        controller.mouseDown(at: CGPoint(x: second.midX, y: second.midY), extend: true)
        controller.mouseUp()
        #expect(controller.selection == [3])

        controller.mouseDown(at: CGPoint(x: -500, y: -500), extend: false)
        controller.mouseUp()
        #expect(controller.selection.isEmpty)
    }

    @Test("Dragging a selected node moves it, and only it")
    func dragMovesNodes() {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 50))
        controller.zoom = 0.5
        controller.offset = CGPoint(x: 100, y: 100)
        let before: [CGPoint] = controller.model.nodes.map(\.position)
        let frame: CGRect = GraphLayout.frame(of: controller.model.nodes[5])
        let start: CGPoint = controller.viewPoint(fromGraph: CGPoint(x: frame.midX, y: frame.midY))

        controller.mouseDown(at: start, extend: false)
        controller.mouseDragged(to: CGPoint(x: start.x + 30, y: start.y - 20))
        controller.mouseUp()

        // 30 view points at zoom 0.5 is 60 graph points.
        #expect(controller.model.nodes[5].position == CGPoint(x: before[5].x + 60, y: before[5].y - 40))
        #expect(controller.model.nodes[6].position == before[6])
    }

    @Test("A marquee selects every node it touches")
    func marquee() {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 200))
        controller.zoom = 1
        controller.offset = .zero
        let bounds: CGRect = GraphLayout.bounds(of: controller.model)
        // Start above-left of everything, so the press lands on empty canvas.
        let start = CGPoint(x: bounds.minX - 20, y: bounds.minY - 20)
        let end = CGPoint(x: bounds.minX + 300, y: bounds.minY + 500)

        controller.mouseDown(at: start, extend: false)
        controller.mouseDragged(to: end)
        #expect(controller.marquee != nil)
        let expected: Set<Int> = controller.nodes(in: CGRect(x: start.x, y: start.y,
                                                             width: end.x - start.x, height: end.y - start.y))
        #expect(!expected.isEmpty)
        #expect(controller.selection == expected)
        controller.mouseUp()
        #expect(controller.marquee == nil)
    }

    @Test("Zooming keeps the point under the pointer still")
    func zoomAnchor() {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 10))
        let pointer = CGPoint(x: 300, y: 200)
        let before: CGPoint = controller.graphPoint(fromView: pointer)
        controller.zoom(by: 1.7, at: pointer)
        let after: CGPoint = controller.graphPoint(fromView: pointer)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)

        controller.zoom(by: 1000, at: pointer)
        #expect(controller.zoom == GraphCanvasController.zoomRange.upperBound)
    }

    @Test("Hit testing stays fast: 1,000 hit tests in a 5,000-node graph")
    func hitTestSpeed() {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 5000))
        let bounds: CGRect = GraphLayout.bounds(of: controller.model)
        var random = SeededRandom(seed: 3)
        let clock = ContinuousClock()
        let elapsed: Duration = clock.measure {
            for _ in 0..<1000 {
                let point = CGPoint(x: bounds.minX + CGFloat(random.next(below: Int(bounds.width))),
                                    y: bounds.minY + CGFloat(random.next(below: Int(bounds.height))))
                _ = controller.hitTest(point)
            }
        }
        print("1,000 hit tests in 5,000 nodes: \(elapsed)")
        // One mouse event per frame needs one hit test in well under a
        // millisecond; this allows 1 ms each, in a debug build.
        #expect(elapsed < .seconds(1))
    }
}

/// The canvas's keyboard shortcuts, sent straight to the view (focus is
/// AppKit's business; this checks what the view does with the keys).
@MainActor
@Suite("Canvas keys")
struct CanvasKeyTests {
    /// A key-down event for `characters`, as AppKit would deliver it.
    func key(_ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    @Test("A frames everything, F the selection, U asks to go up")
    func shortcuts() {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 50))
        let view = GraphEventView(controller: controller)
        view.setFrameSize(NSSize(width: 800, height: 600))

        var wentUp: Bool = false
        controller.onNavigateUp = { wentUp = true }
        view.keyDown(with: key("u"))
        #expect(wentUp)

        // Select one node and frame it: zoomed in on it.
        controller.selection = [0]
        view.keyDown(with: key("f"))
        let selectionZoom: CGFloat = controller.zoom
        // A shows everything: further out.
        view.keyDown(with: key("a"))
        #expect(controller.zoom < selectionZoom)
    }

    @Test("S solos the selected node, as ⌥-click does; only with one node selected")
    func soloKey() {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 5))
        let view = GraphEventView(controller: controller)
        var soloed: [Int] = []
        controller.onSoloNode = { soloed.append($0) }
        controller.selection = [3]
        view.keyDown(with: key("s"))
        #expect(soloed == [3])
        controller.selection = [1, 2]
        #expect(!controller.soloSelection())
        controller.selection = []
        #expect(!controller.soloSelection())
        #expect(soloed == [3])
    }

    @Test("A new node goes with its header centred on the point asked for")
    func newNodePosition() {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 5))
        controller.zoom = 2
        controller.offset = CGPoint(x: 100, y: 50)
        let position: CGPoint = controller.newNodePosition(atView: CGPoint(x: 300, y: 250))
        // View (300, 250) is graph (100, 100) at this zoom and offset.
        #expect(position == CGPoint(x: 100 - GraphLayout.nodeWidth / 2, y: 100 - GraphLayout.headerHeight / 2))
        // So the point is in the middle of the new node's header.
        var node: GraphNode = controller.model.nodes[0]
        node.position = position
        let frame: CGRect = GraphLayout.frame(of: node)
        #expect(frame.midX == 100 && frame.minY + GraphLayout.headerHeight / 2 == 100)
    }
}

// Swatches (M3c).
extension GraphCanvasControllerTests {
    @Test("The nodes near the view, for swatches: on screen or within half a screen, nearest the middle first")
    func nodesNearView() {
        // A row of nodes 300 points apart.
        let nodes: [GraphNode] = (0..<10).map { i in
            GraphNode(id: i, title: "n\(i)", category: .math, position: CGPoint(x: Double(i) * 300, y: 0),
                      inputs: [], outputs: [], hasThumbnail: true)
        }
        let controller = GraphCanvasController(model: GraphModel(nodes: nodes, wires: []))
        // Before the view has a size: none.
        #expect(controller.nodesNearView().isEmpty)
        controller.viewSize = CGSize(width: 600, height: 400)
        controller.zoom = 1
        controller.offset = CGPoint(x: -900, y: 100)
        // On screen: x 900–1500, so nodes 3 to 4 (and 5 touching the edge);
        // within half a screen, 600–1800: 2 to 5. Nearest the middle (1200)
        // first: node 4 (1200–1420 → 1310), then 3.
        let near: [Int] = controller.nodesNearView()
        #expect(Set(near) == [2, 3, 4, 5])
        #expect(near.first == 4)
        // Zoomed out below the minimum: none.
        controller.zoom = 0.3
        #expect(controller.nodesNearView(minimumZoom: 0.4).isEmpty)
    }
    @Test("⌥-click on a swatch or title bar solos the node; ⌥-drag elsewhere still cuts")
    func soloClick() {
        let node = GraphNode(id: 0, title: "noise", category: .procedural, position: .zero,
                             inputs: [GraphPort(name: "in", type: .float)], outputs: [GraphPort(name: "out", type: .float)],
                             hasThumbnail: true)
        let controller = GraphCanvasController(model: GraphModel(nodes: [node], wires: []))
        controller.zoom = 1
        controller.offset = .zero
        var soloed: [Int] = []
        controller.onSoloNode = { soloed.append($0) }

        let swatch: CGRect = GraphLayout.thumbnailFrame(of: node)
        controller.mouseDown(at: CGPoint(x: swatch.midX, y: swatch.midY), extend: false, cut: true)
        _ = controller.mouseUp()
        controller.mouseDown(at: CGPoint(x: 20, y: GraphLayout.headerHeight / 2), extend: false, cut: true)
        _ = controller.mouseUp()
        #expect(soloed == [0, 0])
        #expect(controller.cutLine == nil)

        // On the input row, or on empty canvas: a cut, as before.
        let row: CGRect = GraphLayout.inputRowFrame(of: node, index: 0)
        controller.mouseDown(at: CGPoint(x: row.midX, y: row.midY), extend: false, cut: true)
        #expect(controller.cutLine != nil)
        _ = controller.mouseUp()
        #expect(soloed.count == 2)
    }

    @Test("Menu commands apply to the selection: locked nodes aren't changed, Ungroup needs one nodegraph")
    func commands() {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 10))
        var requests: [GraphCommandRequest] = []
        controller.onCommand = { requests.append($0) }
        controller.canPaste = { false }

        #expect(!controller.canPerform(.copy), "nothing selected")
        #expect(!controller.perform(.copy, at: .zero))
        #expect(!controller.perform(.paste, at: .zero), "nothing to paste")

        controller.model.nodes[2].isLocked = true
        controller.selection = [1, 2]
        #expect(controller.perform(.copy, at: CGPoint(x: 5, y: 6)))
        #expect(controller.perform(.collapse, at: .zero))
        #expect(requests.map(\.command) == [.copy, .collapse])
        #expect(requests[0].nodes == [1, 2], "locked nodes can be copied")
        #expect(requests[0].location == CGPoint(x: 5, y: 6))
        #expect(requests[1].nodes == [1], "but not grouped")

        #expect(!controller.canPerform(.ungroup), "two nodes")
        controller.selection = [3]
        #expect(!controller.canPerform(.ungroup), "not a nodegraph")
        controller.model.nodes[3].category = .nodeGraph
        #expect(controller.canPerform(.ungroup))
    }

    @Test("⌥-dragging an unconnected input out to the left promotes it; elsewhere ⌥-drag cuts")
    func promoteDrag() {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 10))
        controller.zoom = 1
        controller.offset = .zero
        // An input with no wire.
        let model: GraphModel = controller.model
        guard let node = model.nodes.first(where: { node in
            node.inputs.indices.contains { model.wire(into: PortReference(node: node.id, index: $0)) == nil }
        }) else {
            Issue.record("the synthetic graph has an unconnected input")
            return
        }
        let index: Int = node.inputs.indices.first { model.wire(into: PortReference(node: node.id, index: $0)) == nil }!
        let pin: CGPoint = GraphLayout.inputPoint(of: node, index: index)
        let frame: CGRect = GraphLayout.frame(of: node)
        // Far to the left, where nothing is.
        let outside = CGPoint(x: frame.minX - 2000, y: pin.y)

        // Without a handler, ⌥ cuts.
        controller.mouseDown(at: pin, extend: false, cut: true)
        controller.mouseDragged(to: outside)
        #expect(controller.cutLine != nil)
        controller.mouseUp()

        var promoted: [InputSlot] = []
        controller.onPromoteInput = { promoted.append($0) }
        controller.mouseDown(at: pin, extend: false, cut: true)
        controller.mouseDragged(to: outside)
        #expect(controller.wirePreview != nil)
        controller.mouseUp()
        #expect(promoted == [controller.model.slot(of: PortReference(node: node.id, index: index))])
        #expect(controller.wirePreview == nil)

        // Dropped to the right of the node: nothing.
        controller.mouseDown(at: pin, extend: false, cut: true)
        controller.mouseDragged(to: CGPoint(x: frame.maxX + 2000, y: pin.y))
        controller.mouseUp()
        #expect(promoted.count == 1)
    }
}
