// GraphWiringTests.swift
//
// Tests for wiring on the canvas (M2d): the rules (GraphWiring.swift), the
// gestures (GraphCanvasController), and the document edits they become
// (DocumentWiring.swift), first on a small nodegraph, then on every wire
// in MaterialX's examples.
//
// Gestures are played through the controller, as GraphEventView would:
// with zoom 1 and no offset, view and graph coordinates are the same.
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import Testing
@testable import GraphKit
import MXKit

@MainActor
@Suite("Wiring on the canvas")
struct GraphWiringTests {
    /// A nodegraph with a little of everything:
    ///   0 amount (the graph's input) → 1 scale.in1
    ///   1 scale → 2 offset.in1, 2 offset → 5 out
    ///   3 tex: an image, with uniform inputs, all hidden
    ///   4 blend: a mix with three float inputs, all hidden
    static let xml = """
        <?xml version="1.0"?>
        <materialx version="1.39">
          <nodegraph name="NG">
            <input name="amount" type="float" value="0.5" />
            <multiply name="scale" type="float">
              <input name="in1" type="float" interfacename="amount" />
              <input name="in2" type="float" value="2" />
            </multiply>
            <add name="offset" type="float">
              <input name="in1" type="float" nodename="scale" />
            </add>
            <image name="tex" type="float" />
            <mix name="blend" type="float" />
            <output name="out" type="float" nodename="offset" />
          </nodegraph>
        </materialx>
        """

    /// The document, its NG level, and a controller showing it.
    struct Setup {
        let document: MXDocument
        let graph: DocumentGraph
        let controller: GraphCanvasController
    }

    func setup(expanded: Set<String> = []) throws -> Setup {
        let document = try MXDocument(xml: Self.xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        var graph: DocumentGraph = GraphBuilder.build(try document.graph(at: "NG"), expanded: expanded)
        graph.layout()
        let controller = GraphCanvasController(model: graph.model)
        controller.zoom = 1
        controller.offset = .zero
        return Setup(document: document, graph: graph, controller: controller)
    }

    /// Where pins and nodes are, in the controller's (view) coordinates.
    func output(_ node: Int, _ index: Int = 0, in controller: GraphCanvasController) -> CGPoint {
        GraphLayout.outputPoint(of: controller.model.nodes[node], index: index)
    }

    func input(_ node: Int, _ index: Int = 0, in controller: GraphCanvasController) -> CGPoint {
        GraphLayout.inputPoint(of: controller.model.nodes[node], index: index)
    }

    /// A point in a node's header: on the node, but on no row.
    func header(_ node: Int, in controller: GraphCanvasController) -> CGPoint {
        let frame: CGRect = GraphLayout.frame(of: controller.model.nodes[node])
        return CGPoint(x: frame.midX, y: frame.minY + 5)
    }

    /// Presses at `from`, drags to `to` in two steps, and releases.
    @discardableResult
    func drag(from: CGPoint, to: CGPoint, in controller: GraphCanvasController, cut: Bool = false) -> WireMenu? {
        controller.mouseDown(at: from, extend: false, cut: cut)
        controller.mouseDragged(to: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2))
        controller.mouseDragged(to: to)
        return controller.mouseUp()
    }

    @Test("The test graph is laid out as expected")
    func shape() throws {
        let model: GraphModel = try setup().graph.model
        #expect(model.nodes.map(\.title) == ["amount", "scale", "offset", "tex", "blend", "out"])
        #expect(model.nodes[2].inputs.map(\.name) == ["in1"])
        #expect(model.nodes[2].hiddenInputs.map(\.name) == ["in2"])
        #expect(model.nodes[3].hiddenInputs.contains(where: { $0.name == "file" && $0.isUniform }))
        #expect(model.nodes[4].hiddenInputs.map(\.name) == ["fg", "bg", "mix"])
    }

    @Test("Wrong types, loops, uniforms and interface-to-output are ruled out")
    func candidates() throws {
        let model: GraphModel = try setup().graph.model
        // From offset's output: scale and offset itself feed it, so no loops.
        let fromOffset: WireCandidates = model.candidates(from: PortReference(node: 2, index: 0))
        #expect(!fromOffset.inputs.contains(PortReference(node: 1, index: 0)))
        #expect(!fromOffset.inputs.contains(PortReference(node: 1, index: 1)))
        #expect(fromOffset.inputs.contains(PortReference(node: 5, index: 0)))
        // Of the image's hidden inputs, only `default` is a float that isn't uniform.
        #expect(fromOffset.hiddenInputs[3] == ["default"])
        #expect(fromOffset.hiddenInputs[4] == ["fg", "bg", "mix"])

        // The graph's input can't go straight to an <output>.
        let fromAmount: WireCandidates = model.candidates(from: PortReference(node: 0, index: 0))
        #expect(!fromAmount.inputs.contains(PortReference(node: 5, index: 0)))
        #expect(fromAmount.inputs.contains(PortReference(node: 1, index: 1)))

        // Locked nodes take nothing.
        var locked: GraphModel = model
        locked.nodes[4].isLocked = true
        #expect(locked.candidates(from: PortReference(node: 2, index: 0)).hiddenInputs[4] == nil)
    }

    @Test("Dragging from an output to an input connects, in the document too")
    func connectByDrag() throws {
        let setup = try setup()
        let controller: GraphCanvasController = setup.controller
        var connections: [WireConnection] = []
        controller.onConnect = { connections.append($0) }

        // amount → offset.in1 (replacing scale).
        controller.mouseDown(at: output(0, in: controller), extend: false)
        controller.mouseDragged(to: CGPoint(x: 300, y: 300))
        #expect(controller.wirePreview != nil)
        #expect(controller.wireCandidates != nil, "dimming starts once the drag moves")
        controller.mouseDragged(to: input(2, in: controller))
        #expect(controller.wireTarget == .input(PortReference(node: 2, index: 0)))
        controller.mouseUp()
        #expect(controller.wirePreview == nil)
        #expect(connections == [WireConnection(output: PortReference(node: 0, index: 0),
                                               input: InputSlot(node: 2, name: "in1"))])

        try setup.graph.connect(connections[0], in: setup.document)
        let offset: MXNode? = try setup.document.graph(at: "NG").node(named: "offset")
        #expect(offset?.inputs.first(where: { $0.name == "in1" })?.connection == .interface("amount"))
        #expect(setup.graph.undoName(for: connections[0]) == "Connect amount to offset.in1")
    }

    @Test("A drag onto an incompatible row, or nowhere, connects nothing")
    func incompatible() throws {
        let controller: GraphCanvasController = try setup().controller
        var connections: [WireConnection] = []
        controller.onConnect = { connections.append($0) }
        // offset → scale.in2 would be a loop.
        drag(from: output(2, in: controller), to: input(1, 1, in: controller), in: controller)
        drag(from: output(2, in: controller), to: CGPoint(x: -500, y: -500), in: controller)
        // offset → out: already connected, so nothing changes.
        drag(from: output(2, in: controller), to: input(5, in: controller), in: controller)
        #expect(connections.isEmpty)
    }

    @Test("Dropping on a node offers its compatible inputs, hidden ones included")
    func dropOnNode() throws {
        let setup = try setup()
        let controller: GraphCanvasController = setup.controller
        var connections: [WireConnection] = []
        controller.onConnect = { connections.append($0) }

        // The mix has three float inputs: a menu.
        let menu: WireMenu? = drag(from: output(1, in: controller), to: header(4, in: controller), in: controller)
        #expect(menu?.items == ["fg", "bg", "mix"])
        #expect(menu?.title == "Connect to blend")
        #expect(connections.isEmpty, "nothing until a choice is made")
        #expect(controller.wirePreview != nil, "the wire stays while the menu is up")
        controller.chooseConnection(1)
        #expect(connections.last?.input == InputSlot(node: 4, name: "bg"))
        #expect(controller.wirePreview == nil)

        // Dismissing the menu connects nothing.
        drag(from: output(1, in: controller), to: header(4, in: controller), in: controller)
        controller.chooseConnection(nil)
        #expect(connections.count == 1)

        // The image has one: connected straight away.
        #expect(drag(from: output(1, in: controller), to: header(3, in: controller), in: controller) == nil)
        #expect(connections.last?.input == InputSlot(node: 3, name: "default"))

        // A hidden input is added to the document when connected.
        try setup.graph.connect(connections[0], in: setup.document)
        let blend: MXNode? = try setup.document.graph(at: "NG").node(named: "blend")
        #expect(blend?.inputs.first(where: { $0.name == "bg" })?.connection == .node("scale", output: nil))
    }

    @Test("Pulling a wire off its input disconnects it, or moves it")
    func detach() throws {
        let setup = try setup()
        let controller: GraphCanvasController = setup.controller
        var connections: [WireConnection] = []
        var disconnected: [[InputSlot]] = []
        controller.onConnect = { connections.append($0) }
        controller.onDisconnect = { disconnected.append($0) }

        // offset.in1 (from scale) dropped on empty canvas.
        let wire = GraphWire(from: PortReference(node: 1, index: 0), to: PortReference(node: 2, index: 0))
        controller.mouseDown(at: input(2, in: controller), extend: false)
        controller.mouseDragged(to: CGPoint(x: -300, y: -300))
        #expect(controller.hiddenWires == [wire], "the wire leaves its input while dragged")
        controller.mouseUp()
        #expect(disconnected == [[InputSlot(node: 2, name: "in1")]])
        #expect(controller.hiddenWires.isEmpty)

        // offset.in1's wire moved to out.
        drag(from: input(2, in: controller), to: input(5, in: controller), in: controller)
        let moved = WireConnection(output: PortReference(node: 1, index: 0), input: InputSlot(node: 5, name: "float"),
                                   movedFrom: InputSlot(node: 2, name: "in1"))
        #expect(connections == [moved])
        try setup.graph.connect(moved, in: setup.document)
        let level: MXGraph = try setup.document.graph(at: "NG")
        #expect(level.outputs.first?.connection == .node("scale", output: nil))
        #expect(level.node(named: "offset")?.inputs.first(where: { $0.name == "in1" })?.isAuthored == false)
        #expect(setup.graph.undoName(for: moved) == "Move Connection to out")
        #expect(setup.document.validationIssues().isEmpty)
    }

    @Test("Dragging from an unconnected input looks for outputs")
    func fromInput() throws {
        let controller: GraphCanvasController = try setup().controller
        var connections: [WireConnection] = []
        controller.onConnect = { connections.append($0) }

        // scale.in2: offset reads from scale, so it can't feed it.
        drag(from: input(1, 1, in: controller), to: output(2, in: controller), in: controller)
        #expect(connections.isEmpty)
        drag(from: input(1, 1, in: controller), to: output(0, in: controller), in: controller)
        #expect(connections == [WireConnection(output: PortReference(node: 0, index: 0),
                                               input: InputSlot(node: 1, name: "in2"))])
    }

    @Test("A click on a pin selects its node; Escape abandons a drag")
    func clickAndEscape() throws {
        let controller: GraphCanvasController = try setup().controller
        var calls: Int = 0
        controller.onConnect = { _ in calls += 1 }
        controller.onDisconnect = { _ in calls += 1 }

        controller.mouseDown(at: input(2, in: controller), extend: false)
        controller.mouseUp()
        #expect(controller.selection == [2])

        controller.mouseDown(at: input(2, in: controller), extend: false)
        controller.mouseDragged(to: CGPoint(x: -300, y: -300))
        controller.cancelDrag()
        #expect(controller.wirePreview == nil && controller.hiddenWires.isEmpty)
        controller.mouseUp()
        #expect(calls == 0)
    }

    @Test("⌥-drag cuts the wires it crosses")
    func cut() throws {
        let controller: GraphCanvasController = try setup().controller
        var disconnected: [[InputSlot]] = []
        controller.onDisconnect = { disconnected.append($0) }

        // Across the middle of scale → offset.in1.
        let middle: CGPoint = GraphLayout.wirePoints(from: output(1, in: controller), to: input(2, in: controller))[12]
        controller.mouseDown(at: CGPoint(x: middle.x - 2, y: middle.y - 15), extend: false, cut: true)
        controller.mouseDragged(to: CGPoint(x: middle.x + 2, y: middle.y + 15))
        #expect(controller.cutWires == [GraphWire(from: PortReference(node: 1, index: 0),
                                                  to: PortReference(node: 2, index: 0))])
        controller.mouseUp()
        #expect(disconnected == [[InputSlot(node: 2, name: "in1")]])
        #expect(controller.cutLine == nil)
    }

    @Test("Clicking +N more inputs expands the node, and the wires follow")
    func expand() throws {
        let setup = try setup()
        let controller: GraphCanvasController = setup.controller
        var toggled: [Int] = []
        controller.onToggleInputs = { toggled.append($0) }

        let row: CGRect = try #require(GraphLayout.inputToggleRowFrame(of: controller.model.nodes[2]))
        #expect(controller.hitTest(CGPoint(x: row.midX, y: row.midY)) == .inputToggle(2))
        controller.mouseDown(at: CGPoint(x: row.midX, y: row.midY), extend: false)
        controller.mouseUp()
        #expect(toggled == [2])

        let expanded: GraphModel = try self.setup(expanded: ["NG/offset"]).graph.model
        #expect(expanded.nodes[2].isExpanded)
        #expect(expanded.nodes[2].inputs.map(\.name) == ["in1", "in2"])
        #expect(expanded.nodes[2].hiddenInputs.isEmpty)
        #expect(expanded.nodes[2].hasInputToggle, "it can be collapsed again")
        #expect(expanded.wires.contains(GraphWire(from: PortReference(node: 1, index: 0),
                                                  to: PortReference(node: 2, index: 0))))
        // Nothing to hide: not expandable.
        #expect(try !self.setup(expanded: ["NG/scale"]).graph.model.nodes[1].hasInputToggle)
    }
}

@Suite("Wiring the MaterialX examples (M2d exit criterion)",
       .enabled(if: !Fixtures.examples.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"))
struct GraphWiringCorpusTests {
    /// A wire by names, which survive rebuilding the graph (indices don't).
    struct NamedWire: Hashable, CustomStringConvertible {
        let source: String
        let output: String
        let target: String
        let input: String

        var description: String { "\(source).\(output) → \(target).\(input)" }
    }

    static func namedWires(_ graph: DocumentGraph) -> Set<NamedWire> {
        Set(graph.model.wires.map { wire in
            NamedWire(source: graph.elementPaths[wire.from.node],
                      output: graph.model.nodes[wire.from.node].outputs[wire.from.index].name,
                      target: graph.elementPaths[wire.to.node],
                      input: graph.model.nodes[wire.to.node].inputs[wire.to.index].name)
        })
    }

    /// Every graph level of `document`: the top, and each nodegraph inside.
    static func levels(of document: MXDocument, at path: String = "") throws -> [MXGraph] {
        let graph: MXGraph = try document.graph(at: path)
        var levels: [MXGraph] = [graph]
        for node in graph.nodes where node.isNodeGraph && !node.isIncluded {
            levels += try Self.levels(of: document, at: node.path)
        }
        return levels
    }

    /// Every wire the canvas draws can be cut and drawn again: the canvas
    /// offers its input as a target, cutting removes it, connecting puts
    /// it back, and putting back the copy taken before (what undo does)
    /// restores the document.
    @Test("Every wire can be cut and redrawn, with undo",
          arguments: Fixtures.examples.map { $0.lastPathComponent })
    func rewire(_ name: String) throws {
        let url: URL = try #require(Fixtures.examples.first(where: { $0.lastPathComponent == name }))
        let document: MXDocument = try Fixtures.document(url)
        for level in try Self.levels(of: document) {
            let graph: DocumentGraph = GraphBuilder.build(level)
            let original: Set<NamedWire> = Self.namedWires(graph)
            for wire in graph.model.wires where !graph.model.nodes[wire.to.node].isLocked {
                let named = NamedWire(source: graph.elementPaths[wire.from.node],
                                      output: graph.model.nodes[wire.from.node].outputs[wire.from.index].name,
                                      target: graph.elementPaths[wire.to.node],
                                      input: graph.model.nodes[wire.to.node].inputs[wire.to.index].name)
                // The canvas would let the wire be drawn: its own wire is
                // among the candidates (dropping it there is then a no-op).
                if !graph.model.candidates(from: wire.from).inputs.contains(wire.to) {
                    Issue.record("\(name): the canvas wouldn't draw \(named)")
                    continue
                }

                let before: MXDocument = document.copy()
                let slot: InputSlot = graph.model.slot(of: wire.to)
                try graph.disconnect([slot], in: document)
                let cut: Set<NamedWire> = Self.namedWires(GraphBuilder.build(try document.graph(at: level.path)))
                #expect(cut == original.subtracting([named]), "\(name): cutting \(named)")

                try graph.connect(WireConnection(output: wire.from, input: slot), in: document)
                let redrawn: Set<NamedWire> = Self.namedWires(GraphBuilder.build(try document.graph(at: level.path)))
                #expect(redrawn == original, "\(name): redrawing \(named)")

                document.restore(from: before)
                #expect(document.difference(from: before) == nil, "\(name): undoing \(named)")
            }
        }
    }
}
