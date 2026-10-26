// GraphNodeSearchTests.swift
//
// Tests for adding a node at the end of a wire (M2e): a new wire dropped
// on empty canvas asks for the node search and stays drawn until it
// closes; the node chosen is added and connected to the wire, with the
// variant and port the catalog picked. Uses GraphWiringTests' graph and
// gesture helpers.
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import Testing
@testable import GraphKit
import MXKit

@MainActor
@Suite("Adding nodes at the end of a wire")
struct GraphNodeSearchTests {
    let wiring = GraphWiringTests()

    /// Far below and right of every node: empty canvas.
    let empty = CGPoint(x: 3000, y: 3000)

    /// The catalog for `document`.
    func catalog(_ document: MXDocument) -> MXNodeCatalog {
        MXNodeCatalog(document: document)
    }

    @Test("A wire from an output, dropped on nothing, asks for a node and stays drawn")
    func fromOutput() throws {
        let setup = try wiring.setup()
        var requests: [NodeSearchRequest] = []
        setup.controller.onRequestNodeSearch = { requests.append($0) }
        wiring.drag(from: wiring.output(2, in: setup.controller), to: empty, in: setup.controller)

        #expect(requests == [NodeSearchRequest(location: empty, wire: .fromOutput(PortReference(node: 2, index: 0),
                                                                                  type: .float))])
        // Drawn, but no longer dimming anything.
        #expect(setup.controller.wirePreview?.end == empty)
        #expect(setup.controller.wireCandidates == nil)
        setup.controller.endNodeSearch()
        #expect(setup.controller.wirePreview == nil)
    }

    @Test("Adding the chosen node connects it: a float wire into multiply's in1")
    func connectFromOutput() throws {
        let setup = try wiring.setup()
        let wire: DanglingWire = .fromOutput(PortReference(node: 2, index: 0), type: .float)
        let match: MXNodeMatch = try #require(catalog(setup.document).kind(named: "multiply")?.match(for: .input("float")))
        #expect(match.variant.name == "ND_multiply_float" && match.port == "in1")

        let path: String = try setup.document.addNode(nodeDef: match.variant.name, in: "NG")
        try setup.graph.connect(newNode: path, port: try #require(match.port),
                                outputCount: match.variant.outputs.count, to: wire, in: setup.document)
        let node: MXNode = try #require(try setup.document.graph(at: "NG").nodes.first(where: { $0.path == path }))
        #expect(node.inputs.first(where: { $0.name == "in1" })?.connection == .node("offset", output: nil))
        #expect(setup.document.validationIssues().isEmpty)
    }

    @Test("A wire from an input asks for a node to feed it; a multi-output node names its output")
    func intoInput() throws {
        let setup = try wiring.setup()
        var requests: [NodeSearchRequest] = []
        setup.controller.onRequestNodeSearch = { requests.append($0) }
        // scale.in2 (row 1) has a value and no wire.
        wiring.drag(from: wiring.input(1, 1, in: setup.controller), to: empty, in: setup.controller)
        let wire: DanglingWire = .intoInput(InputSlot(node: 1, name: "in2"), type: .float)
        #expect(requests.map(\.wire) == [wire])

        let match: MXNodeMatch = try #require(catalog(setup.document).kind(named: "separate3")?.match(for: .output("float")))
        let path: String = try setup.document.addNode(nodeDef: match.variant.name, in: "NG")
        try setup.graph.connect(newNode: path, port: try #require(match.port),
                                outputCount: match.variant.outputs.count, to: wire, in: setup.document)
        let scale: MXNode = try #require(try setup.document.graph(at: "NG").node(named: "scale"))
        let name = String(path.split(separator: "/").last!)
        #expect(scale.inputs.first(where: { $0.name == "in2" })?.connection == .node(name, output: match.port))
        #expect(setup.document.validationIssues().isEmpty)
    }

    @Test("A wire pulled off its input still disconnects; a uniform input asks for nothing")
    func notSearching() throws {
        let setup = try wiring.setup()
        var requests: [NodeSearchRequest] = []
        var disconnected: [[InputSlot]] = []
        setup.controller.onRequestNodeSearch = { requests.append($0) }
        setup.controller.onDisconnect = { disconnected.append($0) }
        // offset.in1's wire, from scale.
        wiring.drag(from: wiring.input(2, 0, in: setup.controller), to: empty, in: setup.controller)
        #expect(disconnected == [[InputSlot(node: 2, name: "in1")]])

        // The image's `file` is uniform: no node's output can feed it.
        let expanded = try wiring.setup(expanded: ["NG/tex"])
        expanded.controller.onRequestNodeSearch = { requests.append($0) }
        let file: Int = try #require(expanded.controller.model.nodes[3].inputs.firstIndex(where: { $0.name == "file" }))
        wiring.drag(from: wiring.input(3, file, in: expanded.controller), to: empty, in: expanded.controller)
        #expect(requests.isEmpty)
        #expect(expanded.controller.wirePreview == nil)
    }

    @Test("Escape, or a click, while the search is open drops the dangling wire")
    func abandon() throws {
        let setup = try wiring.setup()
        setup.controller.onRequestNodeSearch = { _ in }
        wiring.drag(from: wiring.output(2, in: setup.controller), to: empty, in: setup.controller)
        setup.controller.cancelDrag()
        #expect(setup.controller.wirePreview == nil)

        wiring.drag(from: wiring.output(2, in: setup.controller), to: empty, in: setup.controller)
        setup.controller.mouseDown(at: empty, extend: false)
        _ = setup.controller.mouseUp()
        #expect(setup.controller.wirePreview == nil)
    }

    @Test("Tab asks for a node with no wire; nodes at a wire's end sit beside it")
    func placement() throws {
        let setup = try wiring.setup()
        var requests: [NodeSearchRequest] = []
        setup.controller.onRequestNodeSearch = { requests.append($0) }
        setup.controller.requestNodeSearch(at: empty)
        #expect(requests == [NodeSearchRequest(location: empty)])

        let fromOutput: CGPoint = setup.controller.newNodePosition(
            atView: empty, for: .fromOutput(PortReference(node: 2, index: 0), type: .float))
        let intoInput: CGPoint = setup.controller.newNodePosition(
            atView: empty, for: .intoInput(InputSlot(node: 1, name: "in2"), type: .float))
        // The wire meets the new node's left edge, or its right edge.
        #expect(fromOutput.x == empty.x)
        #expect(intoInput.x + GraphLayout.nodeWidth == empty.x)
    }
}
