// MXEditTests.swift
//
// Tests for changing documents (MXEdit.swift): each edit does what it says,
// refuses what it should, and leaves the document valid; copies are
// independent; included elements can't be changed.
//
// Introduces (SWIFT): a helper that builds a fresh document per test from
// a string, `#expect(throws:)` with a specific error type.

import CoreGraphics
import Foundation
import Testing
@testable import MXKit

@Suite("MXEdit")
struct MXEditTests {
    /// A small document: a nodegraph with an interface input, feeding a
    /// shader, feeding a material, in a look.
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
            <output name="out" type="float" nodename="offset" />
          </nodegraph>
          <open_pbr_surface name="SR" type="surfaceshader">
            <input name="base_color" type="color3" value="0.8, 0.2, 0.1" />
            <input name="specular_roughness" type="float" nodegraph="NG" output="out" />
          </open_pbr_surface>
          <surfacematerial name="M" type="material">
            <input name="surfaceshader" type="surfaceshader" nodename="SR" />
          </surfacematerial>
          <look name="L">
            <materialassign name="assign" geom="/mesh" material="M" />
          </look>
        </materialx>
        """

    /// A fresh copy of the document, with the data libraries.
    func document() throws -> MXDocument {
        let document = try MXDocument(xml: Self.xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        #expect(document.validationIssues().isEmpty, "the starting document is valid")
        return document
    }

    /// The input `name` of the node at `path`, as the graph shows it.
    func input(_ name: String, of path: String, in document: MXDocument) throws -> MXPort {
        let parent: String = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
        let graph: MXGraph = try document.graph(at: parent)
        let node: MXNode = try #require(graph.nodes.first(where: { $0.path == path }))
        return try #require(node.inputs.first(where: { $0.name == name }))
    }

    @Test("Setting a value: stored, disconnects, and refuses nonsense")
    func setValue() throws {
        let document = try document()
        try document.setValue("0.1, 0.9, 0.1", ofInput: "base_color", on: "SR")
        #expect(try input("base_color", of: "SR", in: document).value == "0.1, 0.9, 0.1")

        // An input the file doesn't set yet is added.
        try document.setValue("0.25", ofInput: "coat_weight", on: "SR")
        #expect(try input("coat_weight", of: "SR", in: document).isAuthored)

        // Setting a connected input disconnects it.
        try document.setValue("0.4", ofInput: "specular_roughness", on: "SR")
        #expect(try input("specular_roughness", of: "SR", in: document).connection == nil)

        #expect(throws: MXError.self) {
            try document.setValue("green", ofInput: "base_color", on: "SR")
        }
        #expect(document.validationIssues().isEmpty)
    }

    @Test("Resetting an input returns it to the nodedef default")
    func reset() throws {
        let document = try document()
        try document.resetInput("base_color", on: "SR")
        #expect(try !input("base_color", of: "SR", in: document).isAuthored)
    }

    @Test("Connecting: types must match, loops are refused")
    func connect() throws {
        let document = try document()
        // offset.in2 ← scale (float to float).
        try document.connect(input: "in2", on: "NG/offset", to: "scale")
        #expect(try input("in2", of: "NG/offset", in: document).connection == .node("scale", output: nil))

        // A float can't feed a color3.
        #expect(throws: MXError.self) {
            try document.connect(input: "base_color", on: "SR", to: "NG", output: "out")
        }
        // scale reads from offset, which reads from scale: a loop.
        #expect(throws: MXError.self) {
            try document.connect(input: "in2", on: "NG/scale", to: "offset")
        }
        // An <output> element can be reconnected too.
        try document.connect(input: "", on: "NG/out", to: "scale")
        #expect(document.validationIssues().isEmpty)
    }

    @Test("Interface connections and disconnecting")
    func interfaceAndDisconnect() throws {
        let document = try document()
        try document.connect(input: "in2", on: "NG/scale", toInterface: "amount")
        #expect(try input("in2", of: "NG/scale", in: document).connection == .interface("amount"))

        // An input with no value of its own goes back to its default.
        try document.disconnect(input: "in1", on: "NG/offset")
        #expect(try !input("in1", of: "NG/offset", in: document).isAuthored)
        #expect(document.validationIssues().isEmpty)
    }

    @Test("Adding a node from a nodedef, with a unique name")
    func addNode() throws {
        let document = try document()
        let first: String = try document.addNode(nodeDef: "ND_multiply_float", in: "NG", named: "scale")
        // "scale" is taken, so MaterialX numbers the new one ("scale2").
        #expect(first != "NG/scale" && first.hasPrefix("NG/scale"))
        let second: String = try document.addNode(nodeDef: "ND_image_color3", in: "")
        #expect(second.hasPrefix("image"))
        #expect(try document.graph().node(named: second)?.nodeDefName == "ND_image_color3")
        #expect(throws: MXError.self) {
            try document.addNode(nodeDef: "ND_no_such_thing")
        }
    }

    @Test("Removing a node disconnects what used it")
    func removeNode() throws {
        let document = try document()
        try document.removeNode(at: "NG/scale")
        #expect(try document.graph(at: "NG").node(named: "scale") == nil)
        #expect(try !input("in1", of: "NG/offset", in: document).isAuthored)
        try document.removeNode(at: "SR")
        #expect(try !input("surfaceshader", of: "M", in: document).isAuthored)
        #expect(document.validationIssues().isEmpty)
    }

    @Test("Renaming updates connections and material assignments")
    func rename() throws {
        let document = try document()
        #expect(try document.renameNode(at: "NG/scale", to: "gain") == "NG/gain")
        #expect(try input("in1", of: "NG/offset", in: document).connection == .node("gain", output: nil))
        try document.renameNode(at: "M", to: "M_Copper")
        #expect(try document.xmlString().contains(#"material="M_Copper""#))
        try document.renameNode(at: "NG", to: "NG_Copper")
        #expect(try input("specular_roughness", of: "SR", in: document).connection == .nodeGraph("NG_Copper", output: "out"))

        #expect(throws: MXError.self) {
            try document.renameNode(at: "SR", to: "has space")
        }
        #expect(throws: MXError.self) {
            try document.renameNode(at: "SR", to: "M_Copper")
        }
        #expect(document.validationIssues().isEmpty)
    }

    @Test("Positions are stored compactly and read back")
    func positions() throws {
        let document = try document()
        try document.setPosition(CGPoint(x: 1.5, y: -2), of: "SR")
        #expect(try document.graph().node(named: "SR")?.position == CGPoint(x: 1.5, y: -2))
        #expect(try document.xmlString().contains(#"xpos="1.5" ypos="-2""#))
    }

    @Test("Copies are independent, and restore puts one back")
    func copies() throws {
        let document = try document()
        let snapshot: MXDocument = document.copy()
        try document.removeNode(at: "SR")
        #expect(try snapshot.graph().node(named: "SR") != nil, "the copy is unaffected")
        #expect(snapshot.hasDataLibrary)

        document.restore(from: snapshot)
        #expect(try document.graph().node(named: "SR") != nil)
        #expect(document.difference(from: snapshot) == nil)
    }

    @Test("Included elements can't be edited, and copies remember where they came from")
    func included() throws {
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "MXEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <open_pbr_surface name="SR_shared" type="surfaceshader" />
            </materialx>
            """.write(to: folder.appending(path: "shared.mtlx"), atomically: true, encoding: .utf8)
        try """
            <?xml version="1.0"?>
            <materialx version="1.39" xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="shared.mtlx" />
              <surfacematerial name="M" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="SR_shared" />
              </surfacematerial>
            </materialx>
            """.write(to: folder.appending(path: "main.mtlx"), atomically: true, encoding: .utf8)

        let document = try MXDocument.read(from: folder.appending(path: "main.mtlx"))
        #expect(document.isIncluded("SR_shared"))
        #expect(!document.isIncluded("M"))
        #expect(try document.graph().node(named: "SR_shared")?.isIncluded == true)
        #expect(throws: MXError.self) {
            try document.setValue("0.5", ofInput: "base_weight", on: "SR_shared")
        }
        #expect(throws: MXError.self) {
            try document.removeNode(at: "SR_shared")
        }
        // The material, from the main file, can be edited.
        try document.setPosition(CGPoint(x: 1, y: 1), of: "M")
        // A copy still knows which elements came from the include.
        #expect(document.copy().isIncluded("SR_shared"))
        // Saving writes the include back, not its contents.
        #expect(try document.xmlString().contains(#"<xi:include href="shared.mtlx""#))
    }

    @Test("A nodegraph implementing a nodedef doesn't take values of its own")
    func functionalNodeGraph() throws {
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodedef name="ND_tint" node="tint">
                <input name="amount" type="float" value="0.5" />
                <output name="out" type="float" />
              </nodedef>
              <nodegraph name="NG_tint" nodedef="ND_tint">
                <output name="out" type="float" interfacename="amount" />
              </nodegraph>
            </materialx>
            """)
        // Its defaults belong to the nodedef, which M4 edits.
        #expect(throws: MXError.self) {
            try document.setValue("0.7", ofInput: "amount", on: "NG_tint")
        }
    }

    @Test("The file's version is remembered when MaterialX upgrades it")
    func fileVersion() throws {
        let url: URL = FileManager.default.temporaryDirectory.appending(path: "old-\(UUID().uuidString).mtlx")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"<?xml version="1.0"?><materialx version="1.38"><standard_surface name="SR" type="surfaceshader" /></materialx>"#
            .write(to: url, atomically: true, encoding: .utf8)
        let document = try MXDocument.read(from: url)
        #expect(document.fileVersion == "1.38")
        #expect(document.documentVersion == "1.39")
    }
}
