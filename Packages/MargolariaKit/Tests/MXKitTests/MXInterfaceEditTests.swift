// MXInterfaceEditTests.swift
//
// Tests for M4b's edits (MXInterfaceEdit.swift): promoting a node's input
// to its nodegraph's interface, adding, renaming and removing a graph's
// inputs, and their metadata. M4b's exit criterion, for the document:
// promoting every unconnected input of the examples' nodegraphs keeps
// each valid, and metadata survives saving. (ViewportKitTests checks that
// Storm renders the same.)
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import Testing
@testable import MXKit

@Suite("MXInterfaceEdit")
struct MXInterfaceEditTests {
    /// A nodegraph with an interface input, an image with a tagged file,
    /// and a node whose inputs are partly left at their defaults.
    static let xml = """
        <?xml version="1.0"?>
        <materialx version="1.39">
          <nodegraph name="NG">
            <input name="amount" type="float" value="0.5" />
            <image name="tex" type="color3">
              <input name="file" type="filename" value="paint.png" colorspace="srgb_texture" />
            </image>
            <multiply name="tint" type="color3">
              <input name="in1" type="color3" nodename="tex" />
              <input name="in2" type="color3" value="0.8, 0.4, 0.2" />
            </multiply>
            <mix name="blend" type="color3">
              <input name="fg" type="color3" nodename="tint" />
              <input name="mix" type="float" interfacename="amount" />
            </mix>
            <output name="out" type="color3" nodename="blend" />
          </nodegraph>
          <open_pbr_surface name="SR" type="surfaceshader">
            <input name="base_color" type="color3" nodegraph="NG" output="out" />
          </open_pbr_surface>
        </materialx>
        """

    func document() throws -> MXDocument {
        let document = try MXDocument(xml: Self.xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        #expect(document.validationIssues().isEmpty, "the starting document is valid")
        return document
    }

    /// The input `name` of the node at `path` inside NG.
    func input(_ name: String, of path: String, in document: MXDocument) throws -> MXPort {
        let node: MXNode = try #require(try document.graph(at: "NG").nodes.first(where: { $0.path == path }))
        return try #require(node.inputs.first(where: { $0.name == name }))
    }

    /// The graph's own input `name`.
    func interface(_ name: String, in document: MXDocument) throws -> MXPort {
        try #require(try document.graph(at: "NG").interfaceInputs.first(where: { $0.name == name }))
    }

    @Test("Promoting takes the input's value, and the node reads the new graph input")
    func promoteValue() throws {
        let document = try document()
        let name: String = try document.promote(input: "in2", on: "NG/tint")
        #expect(name == "in2")
        #expect(try interface("in2", in: document).value == "0.8, 0.4, 0.2")
        #expect(try input("in2", of: "NG/tint", in: document).connection == .interface("in2"))
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
    }

    @Test("Promoting a default takes the nodedef's value and metadata; names are made unique")
    func promoteDefault() throws {
        let document = try document()
        // `bg` isn't set: the nodedef's default, 0.
        try document.promote(input: "bg", on: "NG/blend", as: "amount")
        let promoted: MXPort = try interface("amount2", in: document)
        #expect(promoted.value == "0.0, 0.0, 0.0", "as the nodedef writes it")
        #expect(try input("bg", of: "NG/blend", in: document).connection == .interface("amount2"))
        // The image's `uaddressmode` has an enum in its nodedef, and is uniform.
        try document.promote(input: "uaddressmode", on: "NG/tex")
        let mode: MXPort = try interface("uaddressmode", in: document)
        #expect(mode.ui.enumOptions.map(\.name).contains("periodic"))
        #expect(mode.isUniform)
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
    }

    @Test("Promoting keeps the colour space; connected inputs and nodes outside a graph are refused")
    func promoteRules() throws {
        let document = try document()
        try document.promote(input: "file", on: "NG/tex")
        let file: MXPort = try interface("file", in: document)
        #expect(file.colorSpace == "srgb_texture")
        #expect(file.value == "paint.png")
        #expect(try input("file", of: "NG/tex", in: document).colorSpace == nil)
        // Storm ignores a file's space through a graph's input, so the
        // preview text gives the image the file and its space directly.
        let preview = try MXDocument(xml: try document.previewXMLString())
        let file2: MXPort = try #require(try preview.graph(at: "NG").node(named: "tex")?.inputs.first(where: { $0.name == "file" }))
        #expect(file2.connection == nil)
        #expect(file2.colorSpace == "srgb_texture")
        #expect(file2.value == "paint.png")

        #expect(throws: MXError.self) {
            try document.promote(input: "in1", on: "NG/tint")
        }
        #expect(throws: MXError.self) {
            try document.promote(input: "mix", on: "NG/blend")
        }
        #expect(throws: MXError.self) {
            try document.promote(input: "base_color", on: "SR")
        }
        #expect(throws: MXError.self) {
            try document.promote(input: "nothing", on: "NG/tint")
        }
    }

    @Test("Adding, renaming and removing a graph's inputs")
    func addRenameRemove() throws {
        let document = try document()
        #expect(try document.addInput(type: "color3", to: "NG") == "in")
        #expect(try interface("in", in: document).value == "0, 0, 0")
        #expect(throws: MXError.self) {
            try document.addInput(type: "surfaceshader", to: "NG")
        }

        try document.renameInput("amount", of: "NG", to: "weight")
        #expect(try input("mix", of: "NG/blend", in: document).connection == .interface("weight"))
        #expect(throws: MXError.self) {
            try document.renameInput("weight", of: "NG", to: "blend")
        }
        #expect(throws: MXError.self) {
            try document.renameInput("weight", of: "NG", to: "not valid")
        }

        // The node that read it keeps its value.
        try document.removeInput("weight", of: "NG")
        let mix: MXPort = try input("mix", of: "NG/blend", in: document)
        #expect(mix.connection == nil)
        #expect(mix.value == "0.5")
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
    }

    @Test("Metadata: set, checked against the type, removed, and kept through saving")
    func metadata() throws {
        let document = try document()
        try document.setMetadata(.uiName, to: "Amount", ofInput: "amount", on: "NG")
        try document.setMetadata(.uiFolder, to: "Blend", ofInput: "amount", on: "NG")
        try document.setMetadata(.uiMin, to: "0", ofInput: "amount", on: "NG")
        try document.setMetadata(.uiMax, to: "1", ofInput: "amount", on: "NG")
        try document.setMetadata(.uiSoftMax, to: "0.8", ofInput: "amount", on: "NG")
        try document.setMetadata(.uiStep, to: "0.05", ofInput: "amount", on: "NG")
        try document.setMetadata(.doc, to: "How much paint shows.", ofInput: "amount", on: "NG")
        try document.setMetadata(.uiAdvanced, to: "true", ofInput: "amount", on: "NG")
        #expect(throws: MXError.self) {
            try document.setMetadata(.uiMin, to: "zero", ofInput: "amount", on: "NG")
        }
        try document.addInput(named: "mode", type: "integer", to: "NG")
        try document.setMetadata(.enumNames, to: "Off, On", ofInput: "mode", on: "NG")
        try document.setMetadata(.enumValues, to: "0, 1", ofInput: "mode", on: "NG")
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        let amount: MXPort = try interface("amount", in: document)
        #expect(amount.ui.name == "Amount")
        #expect(amount.uiFolder == "Blend")
        #expect(amount.ui.sliderRange() == 0...0.8)
        #expect(amount.ui.step == 0.05)
        #expect(amount.ui.documentation == "How much paint shows.")
        #expect(amount.ui.isAdvanced)
        #expect(amount.metadata[.uiMax] == "1")
        #expect(try interface("mode", in: document).ui.enumOptions.map(\.name) == ["Off", "On"])

        // Saved and read back.
        let reread = try MXDocument(xml: try document.xmlString())
        let saved: MXPort = try #require(try reread.graph(at: "NG").interfaceInputs.first(where: { $0.name == "amount" }))
        #expect(saved.metadata == amount.metadata)

        // Removing the choices removes their values too.
        try document.setMetadata(.enumNames, to: nil, ofInput: "mode", on: "NG")
        #expect(try interface("mode", in: document).metadata.isEmpty)
    }

    @Test("A nodegraph implementing a nodedef in this document changes the nodedef; a library's can't be changed")
    func implementation() throws {
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
                  <input name="in2" type="float" value="2" />
                </multiply>
                <output name="out" type="float" nodename="scale" />
              </nodegraph>
            </materialx>
            """)
        document.setDataLibrary(try MXLibrary.bundled.get())
        try document.promote(input: "in2", on: "NG_dim/scale")
        try document.addInput(type: "float", to: "NG_dim")
        try document.setMetadata(.uiName, to: "Amount", ofInput: "amount", on: "NG_dim")
        let xml: String = try document.xmlString()
        // All in the nodedef; the graph keeps no inputs of its own.
        #expect(xml.contains(#"<input name="in2" type="float" value="2" />"#))
        #expect(xml.contains(#"uiname="Amount""#))
        #expect(try document.graph(at: "NG_dim").interfaceInputs.map(\.name) == ["amount", "in2", "in"])
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        let library = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodegraph name="NG_add" nodedef="ND_add_float">
                <add name="sum" type="float" />
                <output name="out" type="float" nodename="sum" />
              </nodegraph>
            </materialx>
            """)
        library.setDataLibrary(try MXLibrary.bundled.get())
        #expect(throws: MXError.self) {
            try library.addInput(type: "float", to: "NG_add")
        }
        #expect(throws: MXError.self) {
            try library.promote(input: "in1", on: "NG_add/sum")
        }
    }

    @Test("Promoting every unconnected input of every example's nodegraphs keeps it valid",
          .enabled(if: Corpus.isAvailable, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Corpus.files)
    func corpus(_ file: String) throws {
        let document = try MXDocument.read(from: Corpus.examplesFolder.appending(path: file))
        document.setDataLibrary(try MXLibrary.bundled.get())
        let issuesBefore: Int = document.validationIssues().count
        for graph in Self.editableGraphs(in: document) {
            for node in try document.graph(at: graph).nodes {
                for input in node.inputs where input.connection == nil {
                    try document.promote(input: input.name, on: node.path)
                }
            }
        }
        #expect(document.validationIssues().count <= issuesBefore, "\(file): \(document.validationIssues())")
    }

    /// The nodegraphs whose interface can change: not included, not
    /// implementing a nodedef.
    static func editableGraphs(in document: MXDocument) -> [String] {
        document.nodeGraphs.map(\.path).filter { path in
            guard let node = try? document.graph(at: "").node(named: path) else {
                return false
            }
            return !node.isIncluded && node.nodeDefName == nil
        }
    }
}
