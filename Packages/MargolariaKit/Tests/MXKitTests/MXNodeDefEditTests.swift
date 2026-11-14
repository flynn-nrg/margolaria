// MXNodeDefEditTests.swift
//
// Tests for M4c1's edits (MXNodeDefEdit.swift): a nodegraph made into a
// node definition, its node put where the graph was used, the Library
// listing it, and the definition edited in its own document (since M7c,
// its outputs and its node's name too). M4c1's exit
// criterion, for the document: every example's nodegraphs made into
// definitions stay valid. (ViewportKitTests checks that Storm renders the
// node as it rendered the graph.)
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import Testing
@testable import MXKit

@Suite("MXNodeDefEdit")
struct MXNodeDefEditTests {
    /// A graph with two inputs, one read from outside, read by a shader.
    static let xml = """
        <?xml version="1.0"?>
        <materialx version="1.39">
          <constant name="base" type="color3"><input name="value" type="color3" value="0.2, 0.4, 0.8" /></constant>
          <nodegraph name="NG_tint" xpos="3" ypos="1">
            <input name="color" type="color3" nodename="base" />
            <input name="amount" type="float" value="0.5" uiname="Amount" uimin="0" uimax="1" />
            <multiply name="scale" type="color3">
              <input name="in1" type="color3" interfacename="color" />
              <input name="in2" type="float" interfacename="amount" />
            </multiply>
            <output name="out" type="color3" nodename="scale" />
          </nodegraph>
          <open_pbr_surface name="SR" type="surfaceshader">
            <input name="base_color" type="color3" nodegraph="NG_tint" output="out" />
          </open_pbr_surface>
          <surfacematerial name="M" type="material">
            <input name="surfaceshader" type="surfaceshader" nodename="SR" />
          </surfacematerial>
        </materialx>
        """

    func document() throws -> MXDocument {
        let document = try MXDocument(xml: Self.xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        #expect(document.validationIssues().isEmpty, "the starting document is valid")
        return document
    }

    @Test("A suggested name: the graph's, without NG_, in lower case")
    func suggestion() throws {
        let graph: MXNode = try #require(try document().graph(at: "").node(named: "NG_tint"))
        let spec = MXNodeDefSpec.suggested(for: graph)
        #expect(spec.node == "tint")
        #expect(spec.name == "ND_tint_color3")
    }

    @Test("Making a definition: a nodedef of the graph's interface, and a node where the graph was")
    func make() throws {
        let document = try document()
        let spec = MXNodeDefSpec(node: "tint", name: "ND_tint_color3", nodeGroup: "adjustment", version: "1.0",
                                 documentation: "Scales a colour.")
        let made = try document.makeNodeDefinition(from: "NG_tint", as: spec)
        #expect(made.nodeDef == "ND_tint_color3")
        #expect(made.instance == "NG_tint")
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        let top: MXGraph = try document.graph(at: "")
        // The node took the graph's place and name, and its connections.
        let node: MXNode = try #require(top.node(named: "NG_tint"))
        #expect(node.category == "tint")
        #expect(node.nodeDefName == "ND_tint_color3")
        #expect(node.position == CGPoint(x: 3, y: 1))
        #expect(node.inputs.first(where: { $0.name == "color" })?.connection == .node("base", output: nil))
        // Its unset input shows the graph's value, as the default, with the metadata.
        let amount: MXPort = try #require(node.inputs.first(where: { $0.name == "amount" }))
        #expect(amount.value == "0.5")
        #expect(amount.ui.name == "Amount")
        #expect(!amount.isAuthored)
        let shader: MXNode = try #require(top.node(named: "SR"))
        // A node with one output is read without naming it.
        #expect(shader.inputs.first(where: { $0.name == "base_color" })?.connection == .node("NG_tint", output: nil))

        // The graph implements it now, under another name.
        let graph: MXNode = try #require(top.node(named: "NG_tint2") ?? top.nodes.first(where: { $0.isNodeGraph }))
        #expect(graph.nodeDefName == "ND_tint_color3")
        #expect(graph.isLocalDefinition)

        // The Library lists it, with the document's own nodes.
        let catalog = MXNodeCatalog(document: document)
        let kind: MXNodeKind = try #require(catalog.kind(named: "tint"))
        #expect(kind.isFromDocument)
        #expect(kind.group == "adjustment")
    }

    @Test("A graph nothing uses becomes a definition without a node; bad names are refused")
    func unusedAndRefusals() throws {
        let document = try document()
        let graph: String = try document.addNodeGraph(named: "NG_empty")
        #expect(throws: MXError.self) {
            try document.makeNodeDefinition(from: graph, as: MXNodeDefSpec(node: "empty", name: "ND_empty"))
        }
        try document.addOutput(type: "float", to: graph)
        #expect(throws: MXError.self) {
            try document.makeNodeDefinition(from: graph, as: MXNodeDefSpec(node: "mix", name: "ND_mine"))
        }
        #expect(throws: MXError.self) {
            try document.makeNodeDefinition(from: graph, as: MXNodeDefSpec(node: "not valid", name: "ND_x"))
        }
        #expect(throws: MXError.self) {
            try document.makeNodeDefinition(from: graph, as: MXNodeDefSpec(node: "x", name: "ND_mix_float"))
        }
        let made = try document.makeNodeDefinition(from: graph, as: MXNodeDefSpec(node: "empty", name: "ND_empty_float"))
        #expect(made.instance == nil)
        #expect(throws: MXError.self) {
            try document.makeNodeDefinition(from: "NG_empty", as: MXNodeDefSpec(node: "again", name: "ND_again"))
        }
    }

    @Test("The definition is edited in its own document: defaults, metadata, inputs and its attributes")
    func editDefinition() throws {
        let document = try document()
        try document.makeNodeDefinition(from: "NG_tint", as: MXNodeDefSpec(node: "tint", name: "ND_tint_color3"))
        let graph: String = try #require(try document.graph(at: "").nodes.first(where: { $0.isNodeGraph })?.path)
        // A default, through the graph, lands in the nodedef.
        try document.setValue("0.25", ofInput: "amount", on: graph)
        try document.setMetadata(.uiSoftMax, to: "0.8", ofInput: "amount", on: graph)
        let instance: MXNode = try #require(try document.graph(at: "").node(named: "NG_tint"))
        let amount: MXPort = try #require(instance.inputs.first(where: { $0.name == "amount" }))
        #expect(amount.value == "0.25")
        #expect(amount.ui.softMaximum == [0.8])

        // Renaming an input renames what instances set; inside, what reads it.
        try document.renameInput("color", of: graph, to: "tint_color")
        let renamed: MXNode = try #require(try document.graph(at: "").node(named: "NG_tint"))
        #expect(renamed.inputs.first(where: { $0.name == "tint_color" })?.connection == .node("base", output: nil))
        #expect(try document.graph(at: graph).node(named: "scale")?.inputs.first?.connection == .interface("tint_color"))

        // A new input, and one promoted from inside.
        try document.addInput(named: "gain", type: "float", to: graph)
        let offset: String = try document.addNode(nodeDef: "ND_add_float", in: graph)
        try document.promote(input: "in2", on: offset, as: "scale_amount")
        let inputs: [String] = try #require(try document.graph(at: "").node(named: "NG_tint")?.inputs.map(\.name))
        #expect(inputs.contains("gain") && inputs.contains("scale_amount"))

        try document.setNodeDef(.nodeGroup, to: "adjustment", of: graph)
        try document.setNodeDef(.version, to: "2.0", of: graph)
        #expect(MXNodeCatalog(document: document).kind(named: "tint")?.group == "adjustment")
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
        // Saved and read back.
        let reread = try MXDocument(xml: try document.xmlString())
        reread.setDataLibrary(try MXLibrary.bundled.get())
        #expect(reread.difference(from: document) == nil)
    }

    @Test("A definition's outputs are added, renamed and removed, and its nodes follow (M7c)")
    func editOutputs() throws {
        let document = try document()
        try document.makeNodeDefinition(from: "NG_tint", as: MXNodeDefSpec(node: "tint", name: "ND_tint_color3"))
        let graph: String = try #require(document.implementation(of: "ND_tint_color3"))
        func instance() throws -> MXNode {
            try #require(try document.graph(at: "").node(named: "NG_tint"))
        }
        func shaderReads() throws -> MXConnection? {
            try document.graph(at: "").node(named: "SR")?.inputs.first(where: { $0.name == "base_color" })?.connection
        }

        // A second output: the nodes give several, and what read them
        // names the first.
        let alpha: String = try document.addOutput(named: "alpha", type: "float", to: graph)
        let constant: String = try document.addNode(nodeDef: "ND_constant_float", in: graph)
        try document.connect(input: "", on: graph + "/" + alpha, to: String(constant.split(separator: "/").last!))
        #expect(try instance().type == "multioutput")
        #expect(try instance().outputs.map(\.name) == ["out", "alpha"])
        #expect(try shaderReads() == .node("NG_tint", output: "out"))
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        // Renamed: what reads it from the nodes follows.
        try document.renameOutput("out", of: graph, to: "colour")
        #expect(try instance().outputs.map(\.name) == ["colour", "alpha"])
        #expect(try shaderReads() == .node("NG_tint", output: "colour"))
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        // Removed: one output again, of its type, read without naming
        // it; the last one stays.
        try document.removeOutput("alpha", of: graph)
        #expect(try instance().type == "color3")
        #expect(try shaderReads() == .node("NG_tint", output: nil))
        #expect(throws: MXError.self) {
            try document.removeOutput("colour", of: graph)
        }
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        // A removed output that was read: disconnected.
        try document.addOutput(named: "extra", type: "color3", to: graph)
        try document.connect(input: "base_color", on: "SR", to: "NG_tint", output: "extra")
        try document.removeOutput("extra", of: graph)
        #expect(try shaderReads() == nil)
        // Renaming the only output: nothing names it outside.
        try document.renameOutput("colour", of: graph, to: "out")
        #expect(try instance().outputs.map(\.name) == ["out"])
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        // Saved and read back.
        let reread = try MXDocument(xml: try document.xmlString())
        reread.setDataLibrary(try MXLibrary.bundled.get())
        #expect(reread.difference(from: document) == nil)
    }

    @Test("A definition's node is renamed: its nodes, and the names made from it (M7c)")
    func renameNode() throws {
        let document = try document()
        try document.makeNodeDefinition(from: "NG_tint", as: MXNodeDefSpec(node: "tint", name: "ND_tint_color3"))
        let graph: String = try #require(document.implementation(of: "ND_tint_color3"))
        // Taken names and bad ones are refused.
        for taken in ["multiply", "open_pbr_surface", "two words", ""] {
            #expect(throws: MXError.self, "\(taken)") {
                try document.renameNodeDefinition(implementedBy: graph, to: taken)
            }
        }

        let renamed: String = try document.renameNodeDefinition(implementedBy: graph, to: "shade")
        let node: MXNode = try #require(try document.graph(at: "").node(named: "NG_tint"))
        #expect(node.category == "shade")
        #expect(node.nodeDefName == "ND_shade_color3")
        #expect(document.implementation(of: "ND_shade_color3") == renamed)
        // The graph was named after the old node only if that was free.
        #expect(renamed == (graph == "NG_tint" ? "NG_shade" : graph))
        let catalog = MXNodeCatalog(document: document)
        #expect(catalog.kind(named: "shade") != nil)
        #expect(catalog.kind(named: "tint") == nil)
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        // A nodedef name not made from the node is kept.
        let other = try self.document()
        try other.makeNodeDefinition(from: "NG_tint", as: MXNodeDefSpec(node: "tint", name: "ND_my_tint"))
        let otherGraph: String = try #require(other.implementation(of: "ND_my_tint"))
        try other.renameNodeDefinition(implementedBy: otherGraph, to: "shade")
        #expect(try other.graph(at: "").node(named: "NG_tint")?.nodeDefName == "ND_my_tint")
        #expect(try other.graph(at: "").node(named: "NG_tint")?.category == "shade")
        #expect(other.validationIssues().isEmpty, "\(other.validationIssues())")
    }

    @Test("An implementation isn't part of the graph: hidden from the level, opened from its nodes, deleted with its definition")
    func implementationIsTheDefinitionsBody() throws {
        let document = try document()
        try document.makeNodeDefinition(from: "NG_tint", as: MXNodeDefSpec(node: "tint", name: "ND_tint_color3"))
        let top: MXGraph = try document.graph(at: "")
        let graph: MXNode = try #require(top.nodes.first(where: { $0.isNodeGraph }))
        // It keeps its place; the canvas leaves it out.
        #expect(graph.position == CGPoint(x: 3, y: 1))
        #expect(!top.withoutImplementations().nodes.contains(where: { $0.path == graph.path }))
        #expect(top.withoutImplementations().node(named: "NG_tint") != nil)
        #expect(document.implementation(of: "ND_tint_color3") == graph.path)

        // Not deleted like a node, nor with its definition while a node uses it.
        #expect(throws: MXError.self) {
            try document.removeNode(at: graph.path)
        }
        #expect(throws: MXError.self) {
            try document.removeNodeDefinition(implementedBy: graph.path)
        }
        try document.removeNode(at: "NG_tint")
        try document.removeNodeDefinition(implementedBy: graph.path)
        #expect(document.implementation(of: "ND_tint_color3") == nil)
        #expect(try !document.xmlString().contains("ND_tint_color3"))
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
    }

    @Test("Definitions from the libraries stay read-only")
    func libraryDefinitions() throws {
        let url: URL = Corpus.examplesFolder.appending(path: "SimpleHair/simple_hair_default.mtlx")
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return
        }
        // The hair example defines its own node in the document: editable.
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let graph: MXNode = try #require(try document.graph(at: "").nodes.first(where: { $0.isNodeGraph }))
        #expect(graph.isLocalDefinition)
    }

    @Test("Every example's nodegraphs made into definitions stay valid",
          .enabled(if: Corpus.isAvailable, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Corpus.files)
    func corpus(_ file: String) throws {
        let document = try MXDocument.read(from: Corpus.examplesFolder.appending(path: file))
        document.setDataLibrary(try MXLibrary.bundled.get())
        let issuesBefore: Int = document.validationIssues().count
        for graph in try document.graph(at: "").nodes
        where graph.isNodeGraph && !graph.isIncluded && graph.nodeDefName == nil && !graph.outputs.isEmpty {
            var spec = MXNodeDefSpec.suggested(for: graph)
            spec.node = "mg_" + spec.node
            spec.name = MXNodeDefSpec.nodeDefName(for: spec.node, outputs: graph.outputs)
            try document.makeNodeDefinition(from: graph.path, as: spec)
        }
        #expect(document.validationIssues().count <= issuesBefore, "\(file): \(document.validationIssues())")
    }
}
