// MXNodeGraphEditTests.swift
//
// Tests for M4a's edits (MXNodeGraphEdit.swift): collapsing nodes into a
// nodegraph and ungrouping it, empty nodegraphs, a nodegraph's outputs,
// and copying and pasting nodes. M4a's exit criterion, for the document:
// collapsing a connected group of nodes in every example, at every level,
// keeps it valid, and ungrouping gives back the document it was.
// (ViewportKitTests checks that Storm renders the same.)
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import Testing
@testable import MXKit

@Suite("MXNodeGraphEdit")
struct MXNodeGraphEditTests {
    /// Two textures mixed, feeding a shader: a group with connections in
    /// (from `uv`), out (to the shader, twice) and inside.
    static let xml = """
        <?xml version="1.0"?>
        <materialx version="1.39">
          <texcoord name="uv" type="vector2" xpos="0" ypos="0" />
          <image name="dirt" type="color3" xpos="2" ypos="0">
            <input name="file" type="filename" value="dirt.png" />
            <input name="texcoord" type="vector2" nodename="uv" />
          </image>
          <image name="paint" type="color3" xpos="2" ypos="2">
            <input name="file" type="filename" value="paint.png" />
            <input name="texcoord" type="vector2" nodename="uv" />
          </image>
          <mix name="blend" type="color3" xpos="4" ypos="1">
            <input name="fg" type="color3" nodename="dirt" />
            <input name="bg" type="color3" nodename="paint" />
            <input name="mix" type="float" value="0.3" />
          </mix>
          <open_pbr_surface name="SR" type="surfaceshader" xpos="6" ypos="1">
            <input name="base_color" type="color3" nodename="blend" />
            <input name="specular_color" type="color3" nodename="blend" />
          </open_pbr_surface>
          <surfacematerial name="M" type="material">
            <input name="surfaceshader" type="surfaceshader" nodename="SR" />
          </surfacematerial>
        </materialx>
        """

    func document(_ xml: String = Self.xml) throws -> MXDocument {
        let document = try MXDocument(xml: xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        #expect(document.validationIssues().isEmpty, "the starting document is valid")
        return document
    }

    @Test("Collapsing: connections across the edge become the graph's inputs and outputs")
    func collapse() throws {
        let document = try document()
        let path: String = try document.collapse(["dirt", "paint", "blend"], in: "")
        #expect(path == "NG_group")
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        let top: MXGraph = try document.graph(at: "")
        #expect(top.nodes.map(\.name) == ["uv", "NG_group", "SR", "M"])
        let group: MXNode = try #require(top.node(named: "NG_group"))
        // At the average of the nodes' positions.
        let position: CGPoint = try #require(group.position)
        #expect(abs(position.x - 8.0 / 3.0) < 0.001 && position.y == 1, "\(position)")
        // One input for `uv`, though two inputs read it, named after the first.
        #expect(group.inputs.map(\.name) == ["texcoord"])
        #expect(group.inputs.first?.connection == .node("uv", output: nil))
        // One output for `blend`, though the shader reads it twice.
        #expect(group.outputs.map(\.name) == ["out"])
        let shader: MXNode = try #require(top.node(named: "SR"))
        #expect(shader.inputs.first(where: { $0.name == "base_color" })?.connection == .nodeGraph("NG_group", output: "out"))

        let inside: MXGraph = try document.graph(at: "NG_group")
        #expect(inside.nodes.map(\.name) == ["dirt", "paint", "blend"])
        let dirt: MXNode = try #require(inside.node(named: "dirt"))
        #expect(dirt.inputs.first(where: { $0.name == "texcoord" })?.connection == .interface("texcoord"))
        #expect(dirt.position == CGPoint(x: 2, y: 0), "positions are kept inside")
        #expect(inside.outputs.first?.connection == .node("blend", output: nil))
    }

    @Test("Ungrouping gives back the document it was")
    func ungroup() throws {
        let document = try document()
        let before: MXDocument = document.copy()
        try document.collapse(["dirt", "paint", "blend"], in: "")
        let paths: [String] = try document.ungroup("NG_group")
        #expect(paths == ["dirt", "paint", "blend"])
        #expect(document.difference(from: before) == nil, "\(document.difference(from: before) ?? "")")
    }

    @Test("Ungrouping takes values from the graph's inputs, and keeps its working space")
    func ungroupValues() throws {
        let document = try document("""
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodegraph name="NG" colorspace="acescg" xpos="10" ypos="5">
                <input name="tint" type="color3" value="0.5, 0.25, 0.1" />
                <input name="unused" type="float" value="1" />
                <multiply name="dim" type="color3" xpos="0" ypos="0">
                  <input name="in1" type="color3" interfacename="tint" />
                  <input name="in2" type="color3" value="0.5, 0.5, 0.5" />
                </multiply>
                <output name="out" type="color3" nodename="dim" />
              </nodegraph>
              <open_pbr_surface name="SR" type="surfaceshader">
                <input name="base_color" type="color3" nodegraph="NG" />
              </open_pbr_surface>
            </materialx>
            """)
        let paths: [String] = try document.ungroup("NG")
        #expect(paths == ["dim"])
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
        let top: MXGraph = try document.graph(at: "")
        let dim: MXNode = try #require(top.node(named: "dim"))
        #expect(dim.inputs.first(where: { $0.name == "in1" })?.value == "0.5, 0.25, 0.1")
        // The graph was moved: its node follows.
        #expect(dim.position == CGPoint(x: 10, y: 5))
        #expect(document.workingSpace(of: "").active == "lin_rec709")
        #expect(dim.inputs.first(where: { $0.name == "in1" })?.activeColorSpace == "acescg")
        let shader: MXNode = try #require(top.node(named: "SR"))
        #expect(shader.inputs.first(where: { $0.name == "base_color" })?.connection == .node("dim", output: nil))
    }

    @Test("Names taken in the parent are made unique when ungrouping")
    func ungroupRenames() throws {
        let document = try document()
        let graph: String = try document.collapse(["blend"], in: "")
        // Another `blend` at the top level, taking the name.
        try document.addNode(nodeDef: "ND_mix_color3", named: "blend")
        let paths: [String] = try document.ungroup(graph)
        #expect(paths == ["blend2"])
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
        let shader: MXNode = try #require(try document.graph(at: "").node(named: "SR"))
        #expect(shader.inputs.first(where: { $0.name == "base_color" })?.connection == .node("blend2", output: nil))
    }

    @Test("Nodegraphs aren't nested: MaterialX can't connect to one inside another")
    func noNesting() throws {
        let document = try document()
        let graph: String = try document.collapse(["dirt", "paint"])
        #expect(throws: MXError.self) {
            try document.collapse(["dirt"], in: graph)
        }
        #expect(throws: MXError.self) {
            try document.collapse([graph, "blend"])
        }
        #expect(throws: MXError.self) {
            try document.addNodeGraph(in: graph)
        }
        let xml: String = try document.copyNodes([graph], in: "")
        #expect(throws: MXError.self) {
            try document.paste(xml, into: graph)
        }
        // Nodes can be pasted inside, though.
        let nodes: String = try document.copyNodes(["blend"], in: "")
        #expect(try document.paste(nodes, into: graph) == [graph + "/blend"])
    }

    @Test("Materials, included nodes and implementations are refused")
    func refusals() throws {
        let document = try document()
        #expect(throws: MXError.self) {
            try document.collapse(["SR", "M"], in: "")
        }
        #expect(throws: MXError.self) {
            try document.collapse([], in: "")
        }
        #expect(throws: MXError.self) {
            try document.collapse(["nothing"], in: "")
        }
        #expect(throws: MXError.self) {
            try document.ungroup("blend")
        }
    }

    @Test("An empty nodegraph, and its outputs added, renamed and removed")
    func outputs() throws {
        let document = try document()
        let graph: String = try document.addNodeGraph(named: "NG_tint")
        #expect(try document.graph(at: graph).nodes.isEmpty)
        #expect(try document.addOutput(type: "color3", to: graph) == "out")
        #expect(try document.addOutput(type: "color3", to: graph) == "out2")
        #expect(throws: MXError.self) {
            try document.addOutput(type: "colour3", to: graph)
        }

        // A reader of the only output, without naming it, names it once
        // there are two.
        let single: String = try document.collapse(["blend"], in: "")
        try document.addOutput(named: "mask", type: "float", to: single)
        let shader: MXNode = try #require(try document.graph(at: "").node(named: "SR"))
        #expect(shader.inputs.first(where: { $0.name == "base_color" })?.connection == .nodeGraph(single, output: "out"))

        try document.renameOutput("out", of: single, to: "color")
        let renamed: MXNode = try #require(try document.graph(at: "").node(named: "SR"))
        #expect(renamed.inputs.first(where: { $0.name == "base_color" })?.connection == .nodeGraph(single, output: "color"))
        #expect(throws: MXError.self) {
            try document.renameOutput("color", of: single, to: "mask")
        }
        #expect(throws: MXError.self) {
            try document.renameOutput("color", of: single, to: "not valid")
        }

        try document.removeOutput("color", of: single)
        let removed: MXNode = try #require(try document.graph(at: "").node(named: "SR"))
        #expect(removed.inputs.first(where: { $0.name == "base_color" })?.connection == nil)
        #expect(try document.graph(at: single).outputs.map(\.name) == ["mask"])
    }

    @Test("Copying keeps connections between the nodes copied, and absolute file names")
    func copy() throws {
        // Read from a file, so file names are relative to its folder.
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "MXNodeGraphEditTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url: URL = folder.appending(path: "material.mtlx")
        try Self.xml.write(to: url, atomically: true, encoding: .utf8)
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let xml: String = try document.copyNodes(["dirt", "blend"], in: "")
        let copied = try MXDocument(xml: xml)
        copied.setDataLibrary(try MXLibrary.bundled.get())
        let graph: MXGraph = try copied.graph(at: "")
        #expect(graph.nodes.map(\.name) == ["dirt", "blend"])
        let blend: MXNode = try #require(graph.node(named: "blend"))
        #expect(blend.inputs.first(where: { $0.name == "fg" })?.connection == .node("dirt", output: nil))
        // `paint` wasn't copied.
        #expect(blend.inputs.first(where: { $0.name == "bg" })?.connection == nil)
        let dirt: MXNode = try #require(graph.node(named: "dirt"))
        #expect(dirt.inputs.first(where: { $0.name == "texcoord" })?.connection == nil)
        let file: String? = dirt.inputs.first(where: { $0.name == "file" })?.value
        #expect(file == folder.appending(path: "dirt.png").path(percentEncoded: false), "\(file ?? "")")
        #expect(copied.validationIssues().isEmpty, "\(copied.validationIssues())")
    }

    @Test("Pasting renames what is taken, and keeps the colours' space")
    func paste() throws {
        let document = try document()
        let xml: String = try document.copyNodes(["dirt", "blend"], in: "")
        let paths: [String] = try document.paste(xml, into: "")
        #expect(paths == ["dirt2", "blend2"])
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
        let blend: MXNode = try #require(try document.graph(at: "").node(named: "blend2"))
        #expect(blend.inputs.first(where: { $0.name == "fg" })?.connection == .node("dirt2", output: nil))

        // Into an ACEScg nodegraph: the pasted nodes say they are in lin_rec709.
        let graph: String = try document.addNodeGraph(named: "NG_aces")
        try document.setWorkingSpace("acescg", of: graph)
        let inside: [String] = try document.paste(xml, into: graph)
        let mix: MXNode = try #require(try document.graph(at: graph).node(named: "blend"))
        #expect(inside == ["NG_aces/dirt", "NG_aces/blend"])
        #expect(mix.inputs.first(where: { $0.name == "mix" })?.activeColorSpace == "lin_rec709")

        // Materials only at the top level; text that isn't MaterialX nodes.
        let material: String = try document.copyNodes(["M"], in: "")
        #expect(throws: MXError.self) {
            try document.paste(material, into: graph)
        }
        #expect(throws: (any Error).self) {
            try document.paste("<materialx version=\"1.39\" />", into: "")
        }
        #expect(throws: (any Error).self) {
            try document.paste("hello", into: "")
        }
    }

    @Test("Duplicating inside a nodegraph keeps connections to its inputs")
    func duplicateKeepsInterface() throws {
        let document = try document()
        let graph: String = try document.collapse(["dirt", "paint", "blend"], in: "")
        let xml: String = try document.copyNodes(["dirt"], in: graph, keepingInterface: true)
        let paths: [String] = try document.paste(xml, into: graph)
        let copy: MXNode = try #require(try document.graph(at: graph).nodes.first(where: { $0.path == paths.first }))
        #expect(copy.inputs.first(where: { $0.name == "texcoord" })?.connection == .interface("texcoord"))
        // Pasted at the top level, there is no such input.
        let top: [String] = try document.paste(xml, into: "")
        let outside: MXNode = try #require(try document.graph(at: "").nodes.first(where: { $0.path == top.first }))
        #expect(outside.inputs.first(where: { $0.name == "texcoord" })?.connection == nil)
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
    }
}

// MARK: - M4a's exit criterion, for the document

extension MXNodeGraphEditTests {
    /// The groups to collapse at the top level: each node that isn't a
    /// material or a nodegraph, alone and with the nodes it reads directly
    /// (also not materials or nodegraphs). Connected by construction.
    static func groups(in graph: MXGraph) -> [[String]] {
        let movable: Set<String> = Set(graph.nodes.filter { $0.type != "material" && !$0.isNodeGraph }.map(\.name))
        var groups: [[String]] = []
        for node in graph.nodes where movable.contains(node.name) {
            groups.append([node.name])
            let upstream: [String] = node.inputs.compactMap { $0.connection?.sourceNodeName }.filter { movable.contains($0) }
            if !upstream.isEmpty {
                groups.append([node.name] + Set(upstream).sorted())
            }
        }
        return groups
    }

    @Test("Collapsing any connected group in every example keeps it valid, and ungrouping gives it back",
          .enabled(if: Corpus.isAvailable, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Corpus.files)
    func corpus(_ file: String) throws {
        let document = try MXDocument.read(from: Corpus.examplesFolder.appending(path: file))
        document.setDataLibrary(try MXLibrary.bundled.get())
        let issuesBefore: Int = document.validationIssues().count
        var collapsed: Int = 0
        let topLevel: MXGraph = try document.graph(at: "")
        for group in Self.groups(in: topLevel) where !group.contains(where: document.isIncluded) {
            let before: MXDocument = document.copy()
            let graph: String = try document.collapse(group)
            collapsed += 1
            #expect(document.validationIssues().count <= issuesBefore,
                    "\(file): collapsing \(group): \(document.validationIssues())")
            try document.ungroup(graph)
            let difference: String? = document.difference(from: before)
            #expect(difference == nil, "\(file): \(group): \(difference ?? "")")
            document.restore(from: before)
        }
        // Every example has a shader at the top level, unless it only
        // includes other files.
        #expect(collapsed > 0 || topLevel.nodes.allSatisfy { $0.type == "material" || $0.isNodeGraph || $0.isIncluded },
                "\(file): nothing collapsed")
    }
}
