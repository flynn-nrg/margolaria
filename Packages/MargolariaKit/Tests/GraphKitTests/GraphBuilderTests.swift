// GraphBuilderTests.swift
//
// Tests for building canvas graphs from MaterialX documents (GraphBuilder)
// and laying them out (GraphAutoLayout): on a small fixture in detail, and
// on every graph in MaterialX's examples for the layout's guarantees.
//
// Introduces (SWIFT): nothing new; see MXCorpusTests.swift for the corpus
// helper this file repeats.

import CoreGraphics
import Foundation
import Testing
@testable import GraphKit
import MXKit

/// Test files.
enum Fixtures {
    /// The URL of a file in Tests/GraphKitTests/Fixtures.
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    /// MaterialX's examples (scripts/fetch-materialx-examples.sh), as in
    /// MXKitTests/MXCorpusTests.swift. Test targets can't share code, so
    /// the lookup is repeated here.
    static let examples: [URL] = {
        var root = URL(filePath: #filePath)
        for _ in 0..<5 {
            root = root.deletingLastPathComponent()
        }
        root = root.appending(path: "Vendor/MaterialX/resources/Materials/Examples")
        guard let enumerator = FileManager.default.enumerator(atPath: root.path(percentEncoded: false)) else {
            return []
        }
        var files: [URL] = []
        while let path = enumerator.nextObject() as? String {
            if path.hasSuffix(".mtlx") {
                files.append(root.appending(path: path))
            }
        }
        return files.sorted(by: { $0.path < $1.path })
    }()

    /// Reads a document with the data libraries set.
    static func document(_ url: URL) throws -> MXDocument {
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        return document
    }
}

@Suite("Graph builder")
struct GraphBuilderTests {
    @Test("Nodes have room for a thumbnail when the app says so, and the graph's own inputs and outputs never")
    func thumbnails() throws {
        let document: MXDocument = try Fixtures.document(Fixtures.url("brushed_copper.mtlx"))
        // The app decides with PreviewKit's SwatchPlan; here, every node
        // but the material.
        let inner: DocumentGraph = GraphBuilder.build(try document.graph(at: "NG_copper")) { _ in true }
        for node in inner.model.nodes {
            #expect(node.hasThumbnail == (node.category != .graphInterface), "\(node.title)")
        }
        let root: DocumentGraph = GraphBuilder.build(try document.graph()) { $0.type != "material" }
        #expect(root.model.nodes.map(\.hasThumbnail) == [true, true, false])
        // Room for it: a thumbnail makes the node taller by its size and a
        // margin, and moves its rows down as much.
        let without: DocumentGraph = GraphBuilder.build(try document.graph())
        let height: CGFloat = GraphLayout.frame(of: root.model.nodes[0]).height
            - GraphLayout.frame(of: without.model.nodes[0]).height
        #expect(height == GraphLayout.thumbnailSize + 8)
    }

    @Test("The document root: nodes, collapsed inputs and wires")
    func root() throws {
        let document: MXDocument = try Fixtures.document(Fixtures.url("brushed_copper.mtlx"))
        let graph: DocumentGraph = GraphBuilder.build(try document.graph())
        let nodes: [GraphNode] = graph.model.nodes

        #expect(nodes.map(\.title) == ["NG_copper", "SR_copper", "M_BrushedCopper"])
        #expect(graph.elementPaths == ["NG_copper", "SR_copper", "M_BrushedCopper"])
        #expect(nodes[0].category == .nodeGraph)
        #expect(nodes[1].category == .pbr)
        #expect(nodes[2].category == .material)
        #expect(nodes[1].subtitle == "open_pbr_surface")

        // The shader shows the three inputs the file sets; the rest collapse.
        #expect(nodes[1].inputs.map(\.name) == ["base_color", "base_metalness", "specular_roughness"])
        #expect(nodes[1].collapsedInputCount > 30)
        #expect(nodes[1].inputs[0].value == "0.95, 0.64, 0.54")
        #expect(nodes[1].inputs[2].value == nil, "connected: no value shown")
        #expect(nodes[1].inputs[0].type.family == .color)

        // NG_copper.roughness_out → SR_copper.specular_roughness, and
        // SR_copper.out → M_BrushedCopper.surfaceshader.
        #expect(Set(graph.model.wires) == [
            GraphWire(from: PortReference(node: 0, index: 0), to: PortReference(node: 1, index: 2)),
            GraphWire(from: PortReference(node: 1, index: 0), to: PortReference(node: 2, index: 0)),
        ])
    }

    @Test("Inside a nodegraph: its outputs become nodes")
    func insideNodeGraph() throws {
        let document: MXDocument = try Fixtures.document(Fixtures.url("brushed_copper.mtlx"))
        let graph: DocumentGraph = GraphBuilder.build(try document.graph(at: "NG_copper"))
        #expect(graph.model.nodes.map(\.title) == ["grain", "roughness_out"])
        #expect(graph.elementPaths == ["NG_copper/grain", "NG_copper/roughness_out"])
        #expect(graph.model.nodes[1].category == .graphInterface)
        #expect(graph.model.wires == [GraphWire(from: PortReference(node: 0, index: 0),
                                                to: PortReference(node: 1, index: 0))])
        #expect(graph.nodeIndex(forPath: "NG_copper/grain") == 0)
    }

    @Test("Interface inputs become nodes, wired to what uses them")
    func interfaceInputs() throws {
        let xml = """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodegraph name="NG">
                <input name="amount" type="float" value="0.5" />
                <multiply name="scale" type="float">
                  <input name="in1" type="float" interfacename="amount" />
                </multiply>
                <output name="out" type="float" nodename="scale" />
              </nodegraph>
            </materialx>
            """
        let document = try MXDocument(xml: xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let graph: DocumentGraph = GraphBuilder.build(try document.graph(at: "NG"))
        #expect(graph.model.nodes.map(\.title) == ["amount", "scale", "out"])
        #expect(graph.model.nodes[0].outputs.first?.name == "0.5", "shows the value")
        #expect(Set(graph.model.wires) == [
            GraphWire(from: PortReference(node: 0, index: 0), to: PortReference(node: 1, index: 0)),
            GraphWire(from: PortReference(node: 1, index: 0), to: PortReference(node: 2, index: 0)),
        ])
    }

    @Test("A top-level <output> read by output=\"…\": the wire is drawn, but none starts there")
    @MainActor
    func topLevelOutput() throws {
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <constant name="grey" type="color3">
                <input name="value" type="color3" value="0.5, 0.5, 0.5" />
              </constant>
              <output name="base" type="color3" nodename="grey" />
              <output name="unread" type="color3" nodename="grey" />
              <standard_surface name="surface" type="surfaceshader">
                <input name="base_color" type="color3" output="base" />
              </standard_surface>
            </materialx>
            """)
        document.setDataLibrary(try MXLibrary.bundled.get())
        var graph: DocumentGraph = GraphBuilder.build(try document.graph(at: ""))
        graph.layout()
        let grey: Int = try #require(graph.nodeIndex(forPath: "grey"))
        let surface: Int = try #require(graph.nodeIndex(forPath: "surface"))
        let base: Int = try #require(graph.nodeIndex(forPath: "base"))
        let unread: Int = try #require(graph.nodeIndex(forPath: "unread"))
        // The output that is read has an output pin, the other doesn't.
        #expect(graph.model.nodes[base].outputs.map(\.startsWires) == [false])
        #expect(graph.model.nodes[unread].outputs.isEmpty)
        let fromBase = GraphWire(from: PortReference(node: base, index: 0), to: PortReference(node: surface, index: 0))
        #expect(Set(graph.model.wires) == [
            GraphWire(from: PortReference(node: grey, index: 0), to: PortReference(node: base, index: 0)),
            GraphWire(from: PortReference(node: grey, index: 0), to: PortReference(node: unread, index: 0)),
            fromBase,
        ])

        // No wire can be dragged into an input from it...
        #expect(!graph.model.candidates(into: fromBase.to).outputs.contains(fromBase.from))
        // ...nor from its pin, nor moved off the input it feeds: pressing
        // the input starts a new wire, leaving this one drawn.
        let controller = GraphCanvasController(model: graph.model)
        controller.zoom = 1
        controller.offset = .zero
        let pin: CGPoint = GraphLayout.outputPoint(of: graph.model.nodes[base], index: 0)
        controller.mouseDown(at: pin, extend: false)
        controller.mouseDragged(to: CGPoint(x: pin.x + 40, y: pin.y))
        #expect(controller.wireCandidates == nil)
        controller.mouseUp()
        let input: CGPoint = GraphLayout.inputPoint(of: graph.model.nodes[surface], index: 0)
        controller.mouseDown(at: input, extend: false)
        controller.mouseDragged(to: CGPoint(x: input.x - 40, y: input.y))
        #expect(controller.wireCandidates?.seeksOutputs == true)
        #expect(controller.hiddenWires.isEmpty)
        controller.cancelDrag()
    }
}

@Suite("Auto-layout")
struct GraphAutoLayoutTests {
    @Test("Wires run left to right, and the copper graph has three columns")
    func copper() throws {
        let document: MXDocument = try Fixtures.document(Fixtures.url("brushed_copper.mtlx"))
        var model: GraphModel = GraphBuilder.build(try document.graph()).model
        GraphAutoLayout.apply(to: &model)
        let x: [CGFloat] = model.nodes.map(\.position.x)
        #expect(x[0] < x[1] && x[1] < x[2], "nodegraph, then shader, then material")
    }

    @Test("Every example graph: no backward wires, no overlapping nodes",
          .enabled(if: !Fixtures.examples.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Fixtures.examples)
    func examples(_ url: URL) throws {
        let document: MXDocument = try Fixtures.document(url)
        var paths: [String] = [""]
        paths += document.nodeGraphs.map(\.path)
        // Without thumbnails, and with one on every node (M3c: the app
        // gives most nodes one, which makes them taller).
        for (path, thumbnails) in paths.flatMap({ [($0, false), ($0, true)] }) {
            var model: GraphModel = GraphBuilder.build(try document.graph(at: path)) { _ in thumbnails }.model
            GraphAutoLayout.apply(to: &model)

            for wire in model.wires {
                let source: CGRect = GraphLayout.frame(of: model.nodes[wire.from.node])
                let target: CGRect = GraphLayout.frame(of: model.nodes[wire.to.node])
                #expect(source.maxX < target.minX, "\(path): \(model.nodes[wire.from.node].title) → \(model.nodes[wire.to.node].title) runs backwards")
            }
            let frames: [CGRect] = model.nodes.map { GraphLayout.frame(of: $0) }
            for i in frames.indices {
                for j in frames.indices where j > i && frames[i].intersects(frames[j]) {
                    Issue.record("\(path): \(model.nodes[i].title) overlaps \(model.nodes[j].title)")
                }
            }
        }
    }
}

@Suite("Editing on the canvas")
@MainActor
struct CanvasEditingTests {
    @Test("A drag reports the moved nodes once, when the button is released")
    func moveReported() {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 20))
        controller.zoom = 1
        controller.offset = .zero
        var reports: [[Int: CGPoint]] = []
        controller.onMove = { reports.append($0.nodes) }

        let frame: CGRect = GraphLayout.frame(of: controller.model.nodes[3])
        let start = CGPoint(x: frame.midX, y: frame.midY)
        controller.mouseDown(at: start, extend: false)
        controller.mouseDragged(to: CGPoint(x: start.x + 10, y: start.y))
        controller.mouseDragged(to: CGPoint(x: start.x + 25, y: start.y + 5))
        #expect(reports.isEmpty, "nothing until the button is released")
        controller.mouseUp()
        #expect(reports.count == 1)
        #expect(reports.first?[3] == controller.model.nodes[3].position)

        // A click without movement reports nothing.
        controller.mouseDown(at: CGPoint(x: frame.midX + 25, y: frame.midY + 5), extend: false)
        controller.mouseUp()
        #expect(reports.count == 1)
    }

    @Test("Locked nodes don't move and aren't deleted")
    func locked() {
        var model: GraphModel = .synthetic(nodeCount: 10)
        model.nodes[2].isLocked = true
        let controller = GraphCanvasController(model: model)
        controller.zoom = 1
        controller.offset = .zero
        var deleted: Set<Int>? = nil
        controller.onDelete = { deleted = $0.nodes }

        controller.selection = [2]
        controller.deleteSelection()
        #expect(deleted == nil, "only a locked node selected: nothing to delete")
        controller.selection = [1, 2]
        controller.deleteSelection()
        #expect(deleted == [1])

        let before: CGPoint = controller.model.nodes[2].position
        let frame: CGRect = GraphLayout.frame(of: controller.model.nodes[2])
        controller.selection = []
        controller.mouseDown(at: CGPoint(x: frame.midX, y: frame.midY), extend: false)
        controller.mouseDragged(to: CGPoint(x: frame.midX + 40, y: frame.midY))
        controller.mouseUp()
        #expect(controller.model.nodes[2].position == before)
    }

    @Test("Saved positions are used, in Graph Editor units; auto-layout places the rest")
    func savedPositions() throws {
        let xml = """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <open_pbr_surface name="SR" type="surfaceshader" xpos="2" ypos="1" />
              <surfacematerial name="M" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="SR" />
              </surfacematerial>
            </materialx>
            """
        let document = try MXDocument(xml: xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        var graph: DocumentGraph = GraphBuilder.build(try document.graph())
        #expect(graph.positioned == [0])
        graph.layout()
        // One unit is one of our nodes across, and proportionally down.
        #expect(graph.model.nodes[0].position == CGPoint(x: 2 * GraphLayout.nodeWidth,
                                                         y: DocumentGraph.pointsPerUnit.height))
        #expect(DocumentGraph.units(fromPoints: graph.model.nodes[0].position) == CGPoint(x: 2, y: 1))
        // The material had no position: placed by the auto-layout.
        #expect(graph.model.nodes[1].position != .zero)
    }

    @Test("Saved positions that make nodes overlap are pushed apart on screen, keeping columns and order")
    func overlappingPositions() throws {
        // Three nodes stacked one Graph Editor unit apart, as an editor
        // with small nodes would save them, and one beside them; with
        // swatches, our nodes are much taller than one unit.
        let xml = """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <constant name="a" type="color3" xpos="0" ypos="0" />
              <constant name="b" type="color3" xpos="0" ypos="1" />
              <constant name="c" type="color3" xpos="0.2" ypos="2" />
              <constant name="d" type="color3" xpos="3" ypos="0.5" />
            </materialx>
            """
        let document = try MXDocument(xml: xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        var graph: DocumentGraph = GraphBuilder.build(try document.graph()) { _ in true }
        let saved: [CGPoint] = graph.model.nodes.map(\.position)
        graph.layout()
        let frames: [CGRect] = graph.model.nodes.map { GraphLayout.frame(of: $0) }
        for i in frames.indices {
            for j in frames.indices where j > i {
                #expect(!frames[i].intersects(frames[j]), "\(i) overlaps \(j)")
            }
        }
        // Only moved down, and only those in the way: the first of the
        // column and the one beside it stay put; nothing moves sideways.
        #expect(graph.model.nodes[0].position == saved[0])
        #expect(graph.model.nodes[3].position == saved[3])
        #expect(graph.model.nodes.map(\.position.x) == saved.map(\.x))
        #expect(frames[0].maxY < frames[1].minY && frames[1].maxY < frames[2].minY)
        // The document keeps its positions.
        #expect(try document.graph().nodes[1].position == CGPoint(x: 0, y: 1))
    }

    @Test("A graph's own inputs and outputs: saved positions are used; without, they go beside positioned nodes")
    func interfacePositions() throws {
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodegraph name="NG">
                <input name="amount" type="float" value="0.5" />
                <input name="placed" type="float" value="1" xpos="-3" ypos="2" />
                <multiply name="scale" type="float" xpos="4" ypos="1">
                  <input name="in1" type="float" interfacename="amount" />
                  <input name="in2" type="float" interfacename="placed" />
                </multiply>
                <add name="offset" type="float" xpos="6" ypos="1">
                  <input name="in1" type="float" nodename="scale" />
                </add>
                <output name="out" type="float" nodename="offset" />
              </nodegraph>
            </materialx>
            """)
        document.setDataLibrary(try MXLibrary.bundled.get())
        var graph: DocumentGraph = GraphBuilder.build(try document.graph(at: "NG"))
        graph.layout()
        let nodes: [GraphNode] = graph.model.nodes
        func node(_ path: String) throws -> GraphNode {
            nodes[try #require(graph.nodeIndex(forPath: path))]
        }
        let units = DocumentGraph.pointsPerUnit
        #expect(try node("NG/placed").position == CGPoint(x: -3 * units.width, y: 2 * units.height))
        #expect(graph.positioned.contains(try #require(graph.nodeIndex(forPath: "NG/placed"))))
        // Left of the leftmost node, right of the rightmost.
        #expect(try GraphLayout.frame(of: node("NG/amount")).maxX < GraphLayout.frame(of: node("NG/scale")).minX)
        #expect(try GraphLayout.frame(of: node("NG/out")).minX > GraphLayout.frame(of: node("NG/offset")).maxX)
        #expect(try !node("NG/amount").isLocked)
    }

    @Test("Inputs that only exist in a nodedef are locked: there is nowhere to save their position")
    func nodeDefInputsLocked() throws {
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodedef name="ND_dim_float" node="dim">
                <input name="amount" type="float" value="0.5" />
                <output name="out" type="float" />
              </nodedef>
              <nodegraph name="NG_dim" nodedef="ND_dim_float">
                <multiply name="scale" type="float">
                  <input name="in1" type="float" interfacename="amount" />
                </multiply>
                <output name="out" type="float" nodename="scale" />
              </nodegraph>
            </materialx>
            """)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let graph: DocumentGraph = GraphBuilder.build(try document.graph(at: "NG_dim"))
        let amount: Int = try #require(graph.nodeIndex(forPath: "NG_dim/amount"))
        #expect(graph.model.nodes[amount].isLocked)
        // The graph's own output is an element: it can move.
        #expect(try !graph.model.nodes[#require(graph.nodeIndex(forPath: "NG_dim/out"))].isLocked)
    }
}
