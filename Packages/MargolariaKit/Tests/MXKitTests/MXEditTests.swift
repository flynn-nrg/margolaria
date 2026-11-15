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

    @Test("Setting a colour space: tags the input, keeps the value; nil goes back to the inherited space")
    func setColorSpace() throws {
        let document = try document()
        let before: MXPort = try input("base_color", of: "SR", in: document)
        #expect(before.activeColorSpace == nil && before.inheritedColorSpace == nil)

        try document.setColorSpace("srgb_texture", ofInput: "base_color", on: "SR")
        var tagged: MXPort = try input("base_color", of: "SR", in: document)
        #expect(tagged.colorSpace == "srgb_texture" && tagged.activeColorSpace == "srgb_texture")
        #expect(tagged.inheritedColorSpace == nil)
        #expect(tagged.value == "0.8, 0.2, 0.1")

        // An input the file doesn't set yet is added, with its default.
        try document.setColorSpace("acescg", ofInput: "specular_color", on: "SR")
        tagged = try input("specular_color", of: "SR", in: document)
        #expect(tagged.isAuthored && tagged.colorSpace == "acescg" && tagged.value == tagged.defaultValue)

        try document.setColorSpace(nil, ofInput: "base_color", on: "SR")
        #expect(try input("base_color", of: "SR", in: document).colorSpace == nil)
        #expect(document.validationIssues().isEmpty)
    }

    @Test("The inherited colour space comes from the owner or the document")
    func inheritedColorSpace() throws {
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39" colorspace="acescg">
              <open_pbr_surface name="SR" type="surfaceshader">
                <input name="base_color" type="color3" value="0.8, 0.2, 0.1" colorspace="srgb_texture" />
              </open_pbr_surface>
            </materialx>
            """)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let tagged: MXPort = try input("base_color", of: "SR", in: document)
        #expect(tagged.activeColorSpace == "srgb_texture" && tagged.inheritedColorSpace == "acescg")
        let untagged: MXPort = try input("specular_color", of: "SR", in: document)
        #expect(untagged.activeColorSpace == "acescg" && untagged.inheritedColorSpace == "acescg")
    }

    /// A document in ACEScg: a colour value and a colour image at the top,
    /// a nodegraph inheriting the space (with an interface colour), one
    /// with its own, and an input tagged on its own.
    static let workingSpaceXML = """
        <?xml version="1.0"?>
        <materialx version="1.39" colorspace="acescg">
          <constant name="red" type="color3"><input name="value" type="color3" value="0.5, 0.1, 0.1" /></constant>
          <image name="tex" type="color3"><input name="file" type="filename" value="albedo.png" /></image>
          <image name="bump" type="float"><input name="file" type="filename" value="height.png" /></image>
          <constant name="tagged" type="color3">
            <input name="value" type="color3" value="0.5, 0.5, 0.5" colorspace="srgb_texture" />
          </constant>
          <nodegraph name="NG">
            <input name="tint" type="color4" value="0.2, 0.3, 0.4, 0.5" />
            <constant name="inner" type="color3"><input name="value" type="color3" value="0.1, 0.2, 0.3" /></constant>
            <output name="out" type="color3" nodename="inner" />
          </nodegraph>
          <nodegraph name="Own" colorspace="lin_rec709">
            <constant name="mine" type="color3"><input name="value" type="color3" value="1, 0, 0" /></constant>
            <output name="out" type="color3" nodename="mine" />
          </nodegraph>
        </materialx>
        """

    @Test("Working spaces: what each is, and which colours are in it")
    func workingSpaces() throws {
        let document = try MXDocument(xml: Self.workingSpaceXML)
        #expect(document.workingSpace(of: "") == MXWorkingSpace(own: "acescg", inherited: nil))
        #expect(document.workingSpace(of: "NG") == MXWorkingSpace(own: nil, inherited: "acescg"))
        #expect(document.workingSpace(of: "NG").active == "acescg")
        #expect(document.workingSpace(of: "Own").active == "lin_rec709")

        // The colour value, the colour image (not the float one), and the
        // nodegraph's colours; not the tagged input, nor the other graph's.
        let uses: [String] = document.colorsInWorkingSpace(of: "").map { "\($0.ownerPath).\($0.inputName)" }
        #expect(uses == ["red.value", "tex.file", "NG.tint", "NG/inner.value"])
        #expect(document.colorsInWorkingSpace(of: "Own").map(\.inputName) == ["value"])
    }

    @Test("Changing a working space keeps the colours, or keeps the numbers")
    func changeWorkingSpace() throws {
        // A stand-in for OCIO: doubles the numbers, so conversions show.
        // SWIFT: A class instance, so the closure can record into it.
        final class Log { var conversions: [String] = [] }
        let log = Log()
        let double: ([Double], String, String) throws -> [Double] = { numbers, from, to in
            log.conversions.append("\(from)→\(to)")
            return numbers.map { $0 * 2 }
        }
        let document = try MXDocument(xml: Self.workingSpaceXML)
        try document.setWorkingSpace("lin_rec709", of: "", convert: double)
        #expect(document.workingSpace(of: "").active == "lin_rec709")
        #expect(Set(log.conversions) == ["acescg→lin_rec709"])
        #expect(try input("value", of: "red", in: document).value == "1.0, 0.2, 0.2")
        // The image keeps its look by being tagged with the old space.
        #expect(try input("file", of: "tex", in: document).colorSpace == "acescg")
        #expect(try input("file", of: "bump", in: document).colorSpace == nil)
        // Alpha too: the stand-in doubles everything.
        #expect(try document.graph(at: "NG").interfaceInputs.first?.value == "0.4, 0.6, 0.8, 1.0")
        #expect(try input("value", of: "tagged", in: document).value == "0.5, 0.5, 0.5")
        #expect(try input("value", of: "Own/mine", in: document).value == "1, 0, 0")

        // Without converting, only the tag changes; nil removes it.
        let kept = try MXDocument(xml: Self.workingSpaceXML)
        try kept.setWorkingSpace(nil, of: "")
        #expect(kept.workingSpace(of: "") == MXWorkingSpace(own: nil, inherited: nil))
        #expect(try input("value", of: "red", in: kept).value == "0.5, 0.1, 0.1")

        // A nodegraph's own: converted from the document's space.
        log.conversions = []
        try kept.setWorkingSpace("acescg", of: "NG", convert: double)
        #expect(log.conversions == ["lin_rec709→acescg", "lin_rec709→acescg"])
        #expect(kept.workingSpace(of: "NG").own == "acescg")
        #expect(throws: MXError.self) {
            try kept.setWorkingSpace("acescg", of: "red")
        }
    }

    @Test("Coloured defaults are converted with the colours set; greys are left alone (M7e)")
    func convertDefaults() throws {
        // A stand-in for OCIO that keeps greys and changes colours, as a
        // change of primaries does: it rotates the components.
        let rotate: ([Double], String, String) throws -> [Double] = { numbers, _, _ in
            [numbers[1], numbers[2], numbers[0]] + numbers.dropFirst(3)
        }
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodedef name="ND_paint_color3" node="paint">
                <input name="tint" type="color3" value="0.9, 0.3, 0.1" />
                <input name="grey" type="color3" value="0.5, 0.5, 0.5" />
                <input name="tagged" type="color3" value="0.9, 0.3, 0.1" colorspace="srgb_texture" />
                <input name="set" type="color3" value="0.2, 0.4, 0.6" />
                <input name="weights" type="color3" value="0.2722287, 0.6740818, 0.0536895" enum="acescg, rec709"
                       enumvalues="0.2722287,0.6740818,0.0536895, 0.2126,0.7152,0.0722" />
                <input name="chosen" type="color3" value="0.2722287, 0.6740818, 0.0536895" enum="acescg, rec709"
                       enumvalues="0.2722287,0.6740818,0.0536895, 0.2126,0.7152,0.0722" />
                <output name="out" type="color3" />
              </nodedef>
              <paint name="p" type="color3">
                <input name="set" type="color3" value="0.1, 0.2, 0.3" />
                <input name="chosen" type="color3" value="0.2126, 0.7152, 0.0722" />
              </paint>
              <nodegraph name="Own" colorspace="acescg">
                <paint name="inner" type="color3" />
                <output name="out" type="color3" nodename="inner" />
              </nodegraph>
            </materialx>
            """)
        // Listed: the untagged colour defaults the nodes leave alone, not
        // the one set, nor those of a graph with its own space, nor a
        // choice from a list (as `lumacoeffs`), set or not.
        #expect(document.defaultColorsInWorkingSpace(of: "").map { "\($0.ownerPath).\($0.inputName)" }
                == ["p.tint", "p.grey"])
        #expect(document.defaultColorsInWorkingSpace(of: "").allSatisfy { $0.isDefault })
        // To convert: the colour set, and the default the conversion changes.
        let uses: [MXColorUse] = try document.colorsToConvert(of: "", to: "acescg", convert: rotate)
        #expect(uses.map { "\($0.ownerPath).\($0.inputName)" } == ["p.set", "p.tint"])
        #expect(try document.colorsToConvert(of: "", to: nil, convert: rotate).isEmpty, "no change of space")

        try document.setWorkingSpace("acescg", of: "", convert: rotate)
        let tint: MXPort = try input("tint", of: "p", in: document)
        #expect(tint.value == "0.3, 0.1, 0.9" && tint.isAuthored)
        #expect(try !input("grey", of: "p", in: document).isAuthored)
        #expect(try input("set", of: "p", in: document).value == "0.2, 0.3, 0.1")
        #expect(try input("chosen", of: "p", in: document).value == "0.2126, 0.7152, 0.0722")
        #expect(try !input("tint", of: "Own/inner", in: document).isAuthored)
    }

    @Test("Physical quantities keep their numbers, set, default, or passed on by a graph (M7e)")
    func physicalQuantitiesKept() throws {
        let rotate: ([Double], String, String) throws -> [Double] = { numbers, _, _ in
            [numbers[1], numbers[2], numbers[0]] + numbers.dropFirst(3)
        }
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <conductor_bsdf name="set" type="BSDF">
                <input name="ior" type="color3" value="0.2, 0.4, 1.3" />
                <input name="extinction" type="color3" value="3.4, 2.3, 1.7" />
              </conductor_bsdf>
              <conductor_bsdf name="unset" type="BSDF" />
              <open_pbr_surface name="skin" type="surfaceshader" />
              <standard_surface name="wax" type="surfaceshader">
                <input name="subsurface_radius" type="color3" value="1, 0.35, 0.2" />
              </standard_surface>
              <nodedef name="ND_metal_BSDF" node="metal">
                <input name="metal_ior" type="color3" value="0.2, 0.4, 1.3" />
                <input name="shine" type="color3" value="0.9, 0.3, 0.1" />
                <output name="out" type="BSDF" />
              </nodedef>
              <nodegraph name="NG_metal_BSDF" nodedef="ND_metal_BSDF">
                <conductor_bsdf name="c" type="BSDF">
                  <input name="ior" type="color3" interfacename="metal_ior" />
                  <input name="extinction" type="color3" interfacename="shine" />
                </conductor_bsdf>
                <output name="out" type="BSDF" nodename="c" />
              </nodegraph>
              <metal name="m" type="BSDF" />
              <nodegraph name="Graph">
                <input name="graph_ior" type="color3" value="0.2, 0.4, 1.3" />
                <input name="paint" type="color3" value="0.9, 0.3, 0.1" />
                <conductor_bsdf name="c" type="BSDF">
                  <input name="ior" type="color3" interfacename="graph_ior" />
                </conductor_bsdf>
                <output name="out" type="BSDF" nodename="c" />
              </nodegraph>
            </materialx>
            """)
        document.setDataLibrary(try MXLibrary.bundled.get())
        // Only the graph's `paint`: `metal_ior` and `shine` feed the
        // conductor's ior and extinction, so whatever their names say,
        // they keep their numbers too.
        let uses: [MXColorUse] = try document.colorsToConvert(of: "", to: "acescg", convert: rotate)
        #expect(uses.map { "\($0.ownerPath).\($0.inputName)" } == ["Graph.paint"])
        try document.setWorkingSpace("acescg", of: "", convert: rotate)
        #expect(try input("ior", of: "set", in: document).value == "0.2, 0.4, 1.3")
        #expect(try !input("ior", of: "unset", in: document).isAuthored)
        #expect(try !input("subsurface_radius_scale", of: "skin", in: document).isAuthored)
        #expect(try input("subsurface_radius", of: "wax", in: document).value == "1, 0.35, 0.2")
        #expect(try !input("metal_ior", of: "m", in: document).isAuthored)
        #expect(try input("graph_ior", of: "Graph", in: document).value == "0.2, 0.4, 1.3")
    }

    @Test("Templates are written in the working space chosen")
    func templateWorkingSpace() throws {
        for template in MXDocumentTemplate.allCases {
            #expect(try template.makeDocument(workingSpace: "acescg").workingSpace(of: "").own == "acescg")
            #expect(try template.makeDocument().workingSpace(of: "").own == nil)
        }
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

        // MaterialX doesn't allow `interfacename` on an <output>.
        #expect(throws: MXError.self) {
            try document.connect(input: "", on: "NG/out", toInterface: "amount")
        }
        #expect(document.validationIssues().isEmpty)
    }

    @Test("Uniform inputs take a graph's input, not a node's output")
    func uniform() throws {
        let document = try document()
        let image: String = try document.addNode(nodeDef: "ND_image_color3", in: "NG")
        try document.addNode(nodeDef: "ND_constant_integer", in: "NG", named: "mode")
        // `frameoffset` is a uniform integer: the types match, but it can't
        // read a node's output.
        let error = #expect(throws: MXError.self) {
            try document.connect(input: "frameoffset", on: image, to: "mode")
        }
        #expect(String(describing: error).contains("uniform"))
    }

    @Test("Removing an input never changes which nodedef a node matches")
    func nodeDefVariants() throws {
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <constant name="c" type="float" />
              <constant name="v" type="vector3" />
              <multiply name="m" type="vector3">
                <input name="in1" type="vector3" value="1, 1, 1" />
                <input name="in2" type="float" nodename="c" />
              </multiply>
              <separate3 name="s" type="multioutput">
                <input name="in" type="vector3" nodename="v" />
              </separate3>
            </materialx>
            """)
        document.setDataLibrary(try MXLibrary.bundled.get())
        func node(_ name: String) throws -> MXNode {
            try #require(try document.graph().node(named: name))
        }
        #expect(try node("m").nodeDefName == "ND_multiply_vector3FA")
        #expect(try node("s").outputs.map(\.name) == ["outx", "outy", "outz"])

        // Without `in2`, MaterialX would match ND_multiply_vector3 (vector3
        // in2); the input stays, at the FA variant's default.
        try document.disconnect(input: "in2", on: "m")
        #expect(try node("m").nodeDefName == "ND_multiply_vector3FA")
        #expect(try node("m").inputs.first(where: { $0.name == "in2" })?.value == "1.0")
        try document.resetInput("in2", on: "m")
        #expect(try node("m").nodeDefName == "ND_multiply_vector3FA")
        // ...but an input whose removal changes nothing still goes.
        try document.resetInput("in1", on: "m")
        #expect(try !(node("m").inputs.first(where: { $0.name == "in1" })?.isAuthored ?? true))

        // separate3 keeps its vector3 outputs, and its input's place.
        try document.disconnect(input: "in", on: "s")
        #expect(try node("s").outputs.map(\.name) == ["outx", "outy", "outz"])
        #expect(document.validationIssues().isEmpty)
    }

    @Test("Inside a nodegraph that implements a nodedef, the nodedef's inputs are the interface")
    func functionalInterface() throws {
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodedef name="ND_test" node="test">
                <input name="amount" type="float" value="0.5" />
                <output name="out" type="float" />
              </nodedef>
              <nodegraph name="NG_test" nodedef="ND_test">
                <multiply name="m" type="float" />
                <output name="out" type="float" nodename="m" />
              </nodegraph>
            </materialx>
            """)
        document.setDataLibrary(try MXLibrary.bundled.get())
        try document.connect(input: "in1", on: "NG_test/m", toInterface: "amount")
        let m: MXNode? = try document.graph(at: "NG_test").node(named: "m")
        #expect(m?.inputs.first(where: { $0.name == "in1" })?.connection == .interface("amount"))
    }

    @Test("Disconnecting a nodegraph's own input keeps it")
    func disconnectGraphInput() throws {
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <constant name="c" type="float" />
              <nodegraph name="NG">
                <input name="amount" type="float" nodename="c" />
                <output name="out" type="float" interfacename="amount" />
              </nodegraph>
            </materialx>
            """)
        try document.disconnect(input: "amount", on: "NG")
        let amount: MXPort = try #require(try document.graph().node(named: "NG")?.inputs.first)
        #expect(amount.name == "amount")
        #expect(amount.connection == nil)
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

    @Test("A nodegraph's own inputs and outputs keep positions too")
    func interfacePositions() throws {
        let document = try document()
        try document.setPosition(CGPoint(x: -2, y: 1), of: "NG/amount")
        try document.setPosition(CGPoint(x: 5, y: 1.5), of: "NG/out")
        let graph: MXGraph = try document.graph(at: "NG")
        #expect(graph.interfaceInputs.first?.position == CGPoint(x: -2, y: 1))
        #expect(graph.outputs.first?.position == CGPoint(x: 5, y: 1.5))
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
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

    @Test("The preview text is self-contained: includes inline, absolute file paths")
    func previewText() throws {
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "MXEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "lib"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // An included file in a subfolder, with a texture relative to it.
        try """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <image name="shared_tex" type="color3">
                <input name="file" type="filename" value="wood.png" />
              </image>
            </materialx>
            """.write(to: folder.appending(path: "lib/shared.mtlx"), atomically: true, encoding: .utf8)
        // The main file's own texture uses a `fileprefix`.
        try """
            <?xml version="1.0"?>
            <materialx version="1.39" xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="lib/shared.mtlx" />
              <image name="own_tex" type="float" fileprefix="textures/">
                <input name="file" type="filename" value="rough.png" />
              </image>
            </materialx>
            """.write(to: folder.appending(path: "main.mtlx"), atomically: true, encoding: .utf8)

        let document = try MXDocument.read(from: folder.appending(path: "main.mtlx"))
        let preview: String = try document.previewXMLString()
        let root: String = folder.standardizedFileURL.path(percentEncoded: false)
        // SWIFT: A path built by hand ends in "/" when `root` already does;
        // strip it so the expected text has exactly one slash.
        let base: String = root.hasSuffix("/") ? String(root.dropLast()) : root

        #expect(!preview.contains("xi:include"), "included elements are written inline")
        #expect(preview.contains("shared_tex"))
        #expect(preview.contains("\(base)/lib/wood.png"), "relative to the included file's folder")
        #expect(preview.contains("\(base)/textures/rough.png"), "with the prefix applied")
        #expect(!preview.contains("fileprefix"))
        // The document itself is unchanged: saving keeps the include.
        #expect(try document.xmlString().contains("xi:include"))
    }

    @Test("A nodegraph implementing a nodedef takes values only in its nodedef, and only one in this document")
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
        // Its defaults belong to the nodedef: in this document, they are
        // changed there (M4c1).
        try document.setValue("0.7", ofInput: "amount", on: "NG_tint")
        #expect(try document.xmlString().contains(#"<input name="amount" type="float" value="0.7" />"#))
        // A library's nodedef can't be changed.
        let library = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodegraph name="NG_add" nodedef="ND_add_float">
                <output name="out" type="float" interfacename="in1" />
              </nodegraph>
            </materialx>
            """)
        library.setDataLibrary(try MXLibrary.bundled.get())
        #expect(throws: MXError.self) {
            try library.setValue("0.7", ofInput: "in1", on: "NG_add")
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
