// MXInspectableTests.swift
//
// Tests for what the inspector reads (MXInspectable.swift, MXValue.swift):
// finding the selected element by path, the nodedef metadata on each input
// (labels, folders, ranges, enums, colour spaces), and converting value
// text to numbers and back.
//
// Introduces (SWIFT): `if case` in a test to take an enum apart,
// `#require` on an enum pattern.

import Foundation
import Testing
@testable import MXKit

@Suite("MXInspectable")
struct MXInspectableTests {
    /// The small document from MXEditTests, with the data libraries.
    func document() throws -> MXDocument {
        let document = try MXDocument(xml: MXEditTests.xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        return document
    }

    /// The node at `path`, failing the test if it isn't a node.
    func node(_ path: String, in document: MXDocument) throws -> MXNode {
        // SWIFT: `if case .node(let node) = x` matches one case of an enum
        // and binds its value; the `else` handles every other case.
        if case .node(let node) = try document.inspectable(at: path) {
            return node
        }
        Issue.record("\(path) is not a node")
        throw MXError.editRefused("not a node")
    }

    @Test("Finds nodes, nodegraph inputs and outputs by path")
    func findsElements() throws {
        let document = try document()
        #expect(try node("SR", in: document).category == "open_pbr_surface")
        #expect(try node("NG/scale", in: document).category == "multiply")
        #expect(try node("NG", in: document).isNodeGraph)

        guard case .graphInput(let input, let graphPath) = try document.inspectable(at: "NG/amount") else {
            Issue.record("NG/amount is not a graph input")
            return
        }
        #expect(input.value == "0.5")
        #expect(graphPath == "NG")

        guard case .graphOutput(let output, let outputGraph) = try document.inspectable(at: "NG/out") else {
            Issue.record("NG/out is not a graph output")
            return
        }
        #expect(output.connection == .node("offset", output: nil))
        #expect(outputGraph == "NG")

        #expect(try document.inspectable(at: "NG/missing") == nil)
        #expect(try document.inspectable(at: "missing") == nil)
    }

    @Test("Inputs carry the nodedef's metadata")
    func metadata() throws {
        let shader: MXNode = try node("SR", in: try document())
        #expect(shader.nodeDefName == "ND_open_pbr_surface_surfaceshader")
        #expect(shader.documentation != nil)

        let baseColor: MXPort = try #require(shader.inputs.first(where: { $0.name == "base_color" }))
        #expect(baseColor.isAuthored)
        #expect(baseColor.value == "0.8, 0.2, 0.1")
        #expect(baseColor.defaultValue == "0.8, 0.8, 0.8")
        #expect(baseColor.ui.name == "Base Color")
        #expect(baseColor.uiFolder == "Base")
        #expect(baseColor.valueType == .color(3))
        #expect(baseColor.ui.minimum == [0, 0, 0])
        #expect(baseColor.ui.sliderRange(component: 2) == 0...1)

        // Not set in the document: the value is the default.
        let ior: MXPort = try #require(shader.inputs.first(where: { $0.name == "specular_ior" }))
        #expect(!ior.isAuthored)
        #expect(ior.value == ior.defaultValue)
        // The soft range wins over the hard limits for sliders.
        #expect(ior.ui.minimum == [0])
        #expect(ior.ui.sliderRange() == 1...3)
    }

    @Test("Enums, uniforms and geometric defaults")
    func enumsAndGeomProps() throws {
        let document = try document()
        let path: String = try document.addNode(nodeDef: "ND_image_color3", named: "tex")
        let image: MXNode = try node(path, in: document)

        let address: MXPort = try #require(image.inputs.first(where: { $0.name == "uaddressmode" }))
        #expect(address.isUniform)
        #expect(address.ui.enumOptions.map { $0.name } == ["constant", "clamp", "periodic", "mirror"])
        // A string enum stores the names themselves.
        #expect(address.ui.enumOptions.map { $0.value } == ["constant", "clamp", "periodic", "mirror"])

        let texcoord: MXPort = try #require(image.inputs.first(where: { $0.name == "texcoord" }))
        #expect(texcoord.ui.defaultGeomProp == "UV0")
        #expect(texcoord.value == nil)

        let file: MXPort = try #require(image.inputs.first(where: { $0.name == "file" }))
        #expect(file.valueType == .filename)
    }

    @Test("Integer enums map names to values")
    func integerEnum() throws {
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodedef name="ND_test" node="test">
                <input name="mode" type="integer" value="0" enum="OPAQUE, MASK, BLEND" enumvalues="0, 1, 2" />
                <output name="out" type="float" />
              </nodedef>
              <test name="t" type="float" />
            </materialx>
            """)
        let mode: MXPort = try #require(try node("t", in: document).inputs.first)
        #expect(mode.ui.enumOptions == [MXEnumOption(name: "OPAQUE", value: "0"),
                                       MXEnumOption(name: "MASK", value: "1"),
                                       MXEnumOption(name: "BLEND", value: "2")])
    }

    @Test("A nodegraph's own input carries its own metadata")
    func interfaceMetadata() throws {
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodegraph name="NG" colorspace="srgb_texture">
                <input name="tint" type="color3" value="1, 1, 1" uiname="Tint" uisoftmax="2, 2, 2" />
                <output name="out" type="color3" interfacename="tint" />
              </nodegraph>
            </materialx>
            """)
        guard case .graphInput(let tint, _) = try document.inspectable(at: "NG/tint") else {
            Issue.record("NG/tint is not a graph input")
            return
        }
        #expect(tint.ui.name == "Tint")
        #expect(tint.ui.softMaximum == [2, 2, 2])
        // Inherited from the nodegraph.
        #expect(tint.activeColorSpace == "srgb_texture")
    }

    @Test("Value text and numbers convert both ways")
    func valueText() {
        #expect(MXValueText.numbers("0.8, 0.2, 0.1") == [0.8, 0.2, 0.1])
        #expect(MXValueText.numbers("1,2") == [1, 2])
        #expect(MXValueText.numbers("") == nil)
        #expect(MXValueText.numbers("0.5, red") == nil)

        // 0.8 isn't exact in binary; the text is still "0.8".
        #expect(MXValueText.text([0.8, 0.2, 0.1], as: .color(3)) == "0.8, 0.2, 0.1")
        #expect(MXValueText.text([2.6], as: .integer) == "3")
        #expect(MXValueText.text([1], as: .float) == "1.0")

        #expect(MXValueText.boolean("true") == true)
        #expect(MXValueText.boolean(" false") == false)
        #expect(MXValueText.boolean("yes") == nil)
        #expect(MXValueText.text(true) == "true")

        #expect(MXValueType("matrix44").componentCount == 16)
        #expect(MXValueType("surfaceshader") == .other("surfaceshader"))
    }
}
