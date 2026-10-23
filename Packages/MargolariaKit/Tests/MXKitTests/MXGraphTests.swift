// MXGraphTests.swift
//
// Tests for reading a document's graph (MXGraph, MXNode, MXPort,
// MXConnection) and for issues (validation attached to elements, and
// Margolaria's lint rules). The corpus test (MXCorpusTests.swift) runs the
// same code over MaterialX's examples; these pin down the details on small
// documents.
//
// Introduces (SWIFT): `FileManager.temporaryDirectory`, `UUID`, writing a
// String to a file, `defer` for clean-up in a test.

import Foundation
import Testing
@testable import MXKit

@Suite("MXGraph")
struct MXGraphTests {
    /// The test fixture, read from its file, with the data libraries set.
    func copper() throws -> MXDocument {
        let document = try MXDocument.read(from: Fixtures.url("brushed_copper.mtlx"))
        document.setDataLibrary(try MXLibrary.bundled.get())
        return document
    }

    @Test("The document root lists nodes and nodegraphs in file order")
    func rootNodes() throws {
        let graph: MXGraph = try copper().graph()
        #expect(graph.path == "")
        #expect(graph.nodes.map(\.name) == ["NG_copper", "SR_copper", "M_BrushedCopper"])
        #expect(graph.nodes[0].isNodeGraph)
        #expect(!graph.nodes[1].isNodeGraph)
        #expect(graph.interfaceInputs.isEmpty)
    }

    @Test("A node lists every nodedef input, authored or not")
    func nodedefInputs() throws {
        let graph: MXGraph = try copper().graph()
        // SWIFT: `#require` is like `#expect`, but stops the test if it fails,
        // and unwraps an optional: the rest of the test can use `shader`.
        let shader: MXNode = try #require(graph.node(named: "SR_copper"))
        #expect(shader.nodeDefName == "ND_open_pbr_surface_surfaceshader")
        #expect(shader.inputs.count > 40, "OpenPBR has about 50 inputs")
        #expect(shader.outputs.map(\.name) == ["out"])

        let baseColor: MXPort = try #require(shader.inputs.first(where: { $0.name == "base_color" }))
        #expect(baseColor.isAuthored)
        #expect(baseColor.value == "0.95, 0.64, 0.54")
        #expect(baseColor.uiFolder == "Base")

        // Not in the file: the nodedef's default.
        let coatWeight: MXPort = try #require(shader.inputs.first(where: { $0.name == "coat_weight" }))
        #expect(!coatWeight.isAuthored)
        #expect(coatWeight.value == "0.0", "written as in the nodedef")
        #expect(coatWeight.connection == nil)
    }

    @Test("Connections to nodes, nodegraphs and their outputs")
    func connections() throws {
        let document: MXDocument = try copper()
        let root: MXGraph = try document.graph()
        let shader: MXNode = try #require(root.node(named: "SR_copper"))
        let roughness: MXPort = try #require(shader.inputs.first(where: { $0.name == "specular_roughness" }))
        #expect(roughness.connection == .nodeGraph("NG_copper", output: "roughness_out"))
        #expect(roughness.connection?.sourceNodeName == "NG_copper")

        let material: MXNode = try #require(root.node(named: "M_BrushedCopper"))
        #expect(material.inputs.first?.connection == .node("SR_copper", output: nil))

        // The nodegraph as a node: its outputs are its <output> elements.
        let nodeGraph: MXNode = try #require(root.node(named: "NG_copper"))
        #expect(nodeGraph.outputs.map(\.name) == ["roughness_out"])
        #expect(nodeGraph.type == "float")

        // Inside the nodegraph.
        let inside: MXGraph = try document.graph(at: "NG_copper")
        #expect(inside.nodes.map(\.path) == ["NG_copper/grain"])
        #expect(inside.nodes[0].nodeDefName == "ND_noise3d_float")
        #expect(inside.outputs.first?.connection == .node("grain", output: nil))
        #expect(document.nodeGraphs.map(\.path) == ["NG_copper"])
    }

    @Test("Interface inputs, positions and unknown paths")
    func interfaceAndPositions() throws {
        let xml = """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodegraph name="NG_tint" xpos="10" ypos="20">
                <input name="amount" type="float" value="0.5" />
                <multiply name="scale" type="float" xpos="1.5" ypos="-2">
                  <input name="in1" type="float" interfacename="amount" />
                  <input name="in2" type="float" value="2" />
                </multiply>
                <output name="out" type="float" nodename="scale" />
              </nodegraph>
            </materialx>
            """
        let document = try MXDocument(xml: xml)
        document.setDataLibrary(try MXLibrary.bundled.get())

        let root: MXGraph = try document.graph()
        #expect(root.nodes.first?.position == CGPoint(x: 10, y: 20))
        #expect(root.nodes.first?.inputs.map(\.name) == ["amount"])

        let graph: MXGraph = try document.graph(at: "NG_tint")
        #expect(graph.interfaceInputs.map(\.name) == ["amount"])
        let scale: MXNode = try #require(graph.node(named: "scale"))
        #expect(scale.position == CGPoint(x: 1.5, y: -2))
        #expect(scale.inputs.first(where: { $0.name == "in1" })?.connection == .interface("amount"))

        // A path that isn't a nodegraph is an error, not a crash.
        #expect(throws: MXError.self) {
            try document.graph(at: "NG_tint/scale")
        }
    }
}

@Suite("MXIssue")
struct MXIssueTests {
    @Test("Validation problems are attached to the elements they are about")
    func validationIssuesHavePaths() throws {
        let xml = """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodegraph name="NG">
                <not_a_real_node name="bad" type="float" />
                <output name="out" type="float" nodename="missing" />
              </nodegraph>
            </materialx>
            """
        let document = try MXDocument(xml: xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let issues: [MXIssue] = document.validationIssues()
        let paths: Set<String> = Set(issues.map(\.elementPath))
        #expect(paths.contains("NG/out"), "connected to a node that doesn't exist")
        // MaterialX doesn't report a node it has no nodedef for (it only
        // checks nodes against nodedefs it finds); our lint rule does.
        #expect(!paths.contains("NG/bad"))
        let lint: [MXIssue] = MXLint.check(document)
        #expect(lint.map(\.elementPath) == ["NG/bad"])
        #expect(lint.first?.severity == .error)
        // The parents themselves are fine.
        #expect(!paths.contains("NG"))
        #expect(!paths.contains(""))
        // Messages no longer end with the element's quoted XML.
        #expect(issues.allSatisfy { !$0.message.contains("<") })
        #expect(issues.allSatisfy { $0.severity == .error && $0.source == .materialX })
    }

    @Test("A valid document has no issues")
    func validDocument() throws {
        let document = try MXDocument.read(from: Fixtures.url("brushed_copper.mtlx"))
        document.setDataLibrary(try MXLibrary.bundled.get())
        #expect(document.issues().isEmpty)
    }

    @Test("Missing texture files are reported as warnings")
    func missingFiles() throws {
        // A folder of our own in the temporary directory, removed at the end.
        // SWIFT: `UUID().uuidString` is a random unique name.
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "MXIssueTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // SWIFT: `defer` runs when the function exits, whether the test
        // passes, fails or throws, so the folder is always removed.
        defer { try? FileManager.default.removeItem(at: folder) }

        let xml = """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <image name="present" type="color3">
                <input name="file" type="filename" value="textures/present.png" />
              </image>
              <image name="absent" type="color3">
                <input name="file" type="filename" value="textures/absent.png" />
              </image>
            </materialx>
            """
        let file: URL = folder.appending(path: "material.mtlx")
        try xml.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appending(path: "textures"), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "textures/present.png"))

        let document = try MXDocument.read(from: file)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let issues: [MXIssue] = MXLint.check(document)
        #expect(issues.map(\.elementPath) == ["absent/file"])
        #expect(issues.first?.severity == .warning)
        #expect(issues.first?.source == .margolaria)

        // The same document read from a string has no folder, so nothing can
        // be checked, and nothing is reported.
        let fromString = try MXDocument(xml: xml)
        #expect(MXLint.check(fromString).isEmpty)
    }
}
