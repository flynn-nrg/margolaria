// SwatchWorkingSpaceTests.swift
//
// M7e's exit criterion: swatches compute in the document's working space,
// as the Generated Shader tab does, and a coloured default is the same
// colour after a change of working space.
//
//  - The swatch shader of an ACEScg document is the Generated Shader tab's
//    MSL, and says it computes in acescg.
//  - The same colour, written in lin_rec709 in one document and in ACEScg
//    in another, gives the same swatch: the display transform starts from
//    the shader's space.
//  - A white surface lit by StinsonBeach.hdr (a blue sky, a warm sun)
//    looks the same in both: the environment's light is converted to the
//    working space too, or the ACEScg swatch would take the sky's numbers
//    for more saturated colours.
//  - A node whose definition has a coloured default keeps its swatch when
//    the working space changes with Convert Colours, and doesn't with Keep
//    Numbers.
//
// Introduces (SWIFT): nothing new.

import ColorKit
import CoreGraphics
import Foundation
import MXKit
import PreviewKit
import Testing

@Suite("Swatches in the working space (M7e)", .serialized)
struct SwatchWorkingSpaceTests {
    let renderer: SwatchRenderer

    init() throws {
        renderer = try SwatchRenderer()
    }

    /// `body` in a document whose working space is `space`.
    static func document(_ space: String, _ body: String) -> String {
        """
        <?xml version="1.0"?>
        <materialx version="1.39" colorspace="\(space)">
        \(body)
        </materialx>
        """
    }

    /// `numbers` (lin_rec709) in ACEScg, as text, by OCIO.
    static func acescg(_ numbers: [Double]) throws -> String {
        try InputColorSpace.convert(numbers, from: "lin_rec709", to: "acescg").map { String(Float($0)) }
            .joined(separator: ", ")
    }

    /// The largest difference between two swatches' channels, over a grid
    /// of pixels inside the sphere.
    static func difference(_ a: CGImage, _ b: CGImage) -> Int {
        var largest: Int = 0
        for y in stride(from: 16, to: 48, by: 4) {
            for x in stride(from: 16, to: 48, by: 4) {
                let (p, q) = (Fixtures.pixel(a, x: x, y: y), Fixtures.pixel(b, x: x, y: y))
                largest = max(largest, abs(p.r - q.r), abs(p.g - q.g), abs(p.b - q.b))
            }
        }
        return largest
    }

    @Test("An ACEScg document's swatch shader is the Generated Shader tab's, computing in acescg")
    func generatesInWorkingSpace() throws {
        let (document, library) = try Fixtures.document(xml: Self.document("acescg", """
              <image name="tex" type="color3">
                <input name="file" type="filename" value="missing.png" colorspace="srgb_texture" />
              </image>
            """))
        let swatch: MXGeneratedShader = try document.generateMSL(for: "tex", library: library, colorSpace: "acescg")
        #expect(swatch.colorSpace == "acescg")
        let tab: MXShaderCode = try document.generateCode(for: "tex", in: .msl, library: library, colorSpace: "acescg")
        #expect(tab.colorSpace == "acescg")
        #expect(swatch.pixelSource == tab.pixelSource)
        #expect(swatch.vertexSource == tab.vertexSource)
        // Without a transform to the space, lin_rec709, as the tab does.
        #expect(try document.generateMSL(for: "tex", library: library, colorSpace: "g18_ap1").colorSpace == "lin_rec709")
    }

    @Test("The same colour in lin_rec709 and in ACEScg gives the same swatch")
    func sameColour() throws {
        let rec709: [Double] = [0.8, 0.2, 0.05]
        let (linear, library) = try Fixtures.document(xml: Self.document("lin_rec709", """
              <constant name="c" type="color3"><input name="value" type="color3" value="0.8, 0.2, 0.05" /></constant>
            """))
        let (aces, _) = try Fixtures.document(xml: Self.document("acescg", """
              <constant name="c" type="color3"><input name="value" type="color3" value="\(try Self.acescg(rec709))" /></constant>
            """))
        let a: CGImage = try renderer.image(try linear.generateMSL(for: "c", library: library), size: 64)
        let b: CGImage = try renderer.image(try aces.generateMSL(for: "c", library: library, colorSpace: "acescg"),
                                            size: 64)
        #expect(Self.difference(a, b) <= 2, "\(Self.difference(a, b))")
        // The same numbers computed in lin_rec709 are another colour: the
        // transform did start from acescg.
        let (misread, _) = try Fixtures.document(xml: Self.document("lin_rec709", """
              <constant name="c" type="color3"><input name="value" type="color3" value="\(try Self.acescg(rec709))" /></constant>
            """))
        let c: CGImage = try renderer.image(try misread.generateMSL(for: "c", library: library), size: 64)
        #expect(Self.difference(a, c) > 8, "\(Self.difference(a, c))")
    }

    @Test("A white surface under a coloured sky looks the same in both spaces: the light is converted too")
    func lightConverted() throws {
        let renderer = try SwatchRenderer(environment: nil)
        let surface: String = """
              <standard_surface name="SR" type="surfaceshader">
                <input name="base_color" type="color3" value="1, 1, 1" />
                <input name="specular" type="float" value="0" />
              </standard_surface>
            """
        let (linear, library) = try Fixtures.document(xml: Self.document("lin_rec709", surface))
        let (aces, _) = try Fixtures.document(xml: Self.document("acescg", surface))
        let a: CGImage = try renderer.image(try linear.generateMSL(for: "SR", library: library), size: 64)
        let b: CGImage = try renderer.image(try aces.generateMSL(for: "SR", library: library, colorSpace: "acescg"),
                                            size: 64)
        try Fixtures.save(a, as: "swatch_white_lin_rec709.png")
        try Fixtures.save(b, as: "swatch_white_acescg.png")
        #expect(Self.difference(a, b) <= 3, "\(Self.difference(a, b))")
    }

    @Test("A coloured default is the same colour after a change of working space with Convert Colours")
    func defaultConverted() throws {
        // A definition of the document's own, with a coloured default; its
        // node leaves it at the default.
        let xml: String = Self.document("lin_rec709", """
              <nodedef name="ND_tinted_color3" node="tinted">
                <input name="tint" type="color3" value="0.9, 0.3, 0.1" />
                <output name="out" type="color3" />
              </nodedef>
              <nodegraph name="NG_tinted_color3" nodedef="ND_tinted_color3">
                <dot name="pass" type="color3"><input name="in" type="color3" interfacename="tint" /></dot>
                <output name="out" type="color3" nodename="pass" />
              </nodegraph>
              <tinted name="t" type="color3" />
            """)
        let convert: ([Double], String, String) throws -> [Double] = { numbers, from, to in
            try InputColorSpace.convert(numbers, from: from, to: to)
        }
        let (before, library) = try Fixtures.document(xml: xml)
        let original: CGImage = try renderer.image(try before.generateMSL(for: "t", library: library), size: 64)

        // Convert Colours: the default is set on the node, converted.
        let (converted, _) = try Fixtures.document(xml: xml)
        #expect(try converted.colorsToConvert(of: "", to: "acescg", convert: convert).map(\.inputName) == ["tint"])
        try converted.setWorkingSpace("acescg", of: "", convert: convert)
        let after: CGImage = try renderer.image(try converted.generateMSL(for: "t", library: library,
                                                                          colorSpace: "acescg"), size: 64)
        #expect(Self.difference(original, after) <= 2, "\(Self.difference(original, after))")

        // Keep Numbers: the default's numbers now mean an ACEScg colour.
        let (kept, _) = try Fixtures.document(xml: xml)
        try kept.setWorkingSpace("acescg", of: "")
        let shifted: CGImage = try renderer.image(try kept.generateMSL(for: "t", library: library,
                                                                       colorSpace: "acescg"), size: 64)
        #expect(Self.difference(original, shifted) > 8, "\(Self.difference(original, shifted))")
    }
}
