// SoloPreviewTests.swift
//
// Solo preview (M3d): any node's output, shown on its own in the viewport.
// MXKit wraps the node in a material (MXDocument.soloPreview); Storm must
// render it. M3d's exit criterion is that this works for every node of
// every example that has a swatch: each is soloed, rendered, and checked
// to have drawn something other than the background.
//
// Storm compiles a shader for each, so this takes a minute or two.
//
// Introduces (SWIFT): nothing new.

import ColorKit
import CoreGraphics
import Foundation
import MXKit
import PreviewKit
import Testing
import ViewportKit

@Suite("Solo preview", .serialized)
struct SoloPreviewTests {
    static let untoneMapped = ViewTransform(display: "sRGB - Display", view: "Un-tone-mapped")

    /// Renders `solo` with `renderer` (created on first use) and returns
    /// the image, or nil if Storm couldn't show it.
    static func render(_ solo: MXSoloPreview, with renderer: inout MGStormRenderer?) throws -> CGImage? {
        if let existing = renderer {
            try existing.updateMaterialXString(solo.xml)
        } else {
            renderer = try MGStormRenderer(materialXString: solo.xml)
        }
        guard let renderer,
              let path = renderer.materialPaths.first(where: { ($0 as NSString).lastPathComponent == solo.materialName }),
              renderer.bindMaterial(atPath: path)
        else {
            return nil
        }
        return renderer.snapshot(width: 64, height: 64, viewTransform: untoneMapped)
    }

    @Test("A value, a node inside a nodegraph and a BSDF are wrapped in a material; a material is shown as it is")
    func wrapping() throws {
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodegraph name="NG">
                <noise2d name="noise" type="vector2" />
                <output name="out" type="vector2" nodename="noise" />
              </nodegraph>
              <constant name="grey" type="float"><input name="value" type="float" value="0.5" /></constant>
              <oren_nayar_diffuse_bsdf name="diffuse" type="BSDF" />
              <surfacematerial name="M" type="material" />
            </materialx>
            """)
        document.setDataLibrary(try MXLibrary.bundled.get())

        let grey: MXSoloPreview = try document.soloPreview(for: "grey")
        #expect(grey.outputType == "float")
        #expect(grey.xml.contains("convert"))
        let inner: MXSoloPreview = try document.soloPreview(for: "NG/noise")
        #expect(inner.outputType == "vector2")
        // Reached through a new output of the nodegraph.
        #expect(inner.xml.contains("margolaria_solo_out"))
        #expect(try document.soloPreview(for: "diffuse").xml.contains("<surface "))
        let material: MXSoloPreview = try document.soloPreview(for: "M")
        #expect(material.materialName == "M")
        // The document itself is unchanged.
        #expect(try !document.xmlString().contains("margolaria_solo"))
        #expect(throws: MXError.self) {
            try document.soloPreview(for: "nothing")
        }
    }

    @Test("Storm shows a soloed value as it is, unlit, wherever it faces")
    func valuesAreShown() throws {
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <constant name="grey" type="float"><input name="value" type="float" value="0.5" /></constant>
              <constant name="red" type="color3"><input name="value" type="color3" value="0.8, 0.1, 0.1" /></constant>
            </materialx>
            """)
        document.setDataLibrary(try MXLibrary.bundled.get())
        var renderer: MGStormRenderer? = nil
        // 0.5 shows as sRGB 188 without tone mapping; Storm's grey
        // fallback, if the shader failed, would be shaded, not flat.
        let grey: CGImage = try #require(try Self.render(try document.soloPreview(for: "grey"), with: &renderer))
        _ = try Fixtures.save(grey, as: "solo_grey.png")
        for (x, y) in [(32, 32), (22, 22), (42, 42)] {
            let pixel = Fixtures.pixel(grey, x: x, y: y)
            #expect(abs(Int(pixel.r) - 188) <= 3 && pixel.r == pixel.g && pixel.g == pixel.b, "\(x), \(y): \(pixel)")
        }
        let red: CGImage = try #require(try Self.render(try document.soloPreview(for: "red"), with: &renderer))
        let pixel = Fixtures.pixel(red, x: 32, y: 32)
        // sRGB of 0.8 and 0.1: 231 and 89.
        #expect(abs(Int(pixel.r) - 231) <= 3 && abs(Int(pixel.g) - 89) <= 3 && abs(Int(pixel.b) - 89) <= 3, "\(pixel)")
    }

    @Test("Every node of every example with a swatch can be soloed",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Examples.files)
    func everyNode(_ url: URL) throws {
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        var renderer: MGStormRenderer? = nil
        for level in [""] + document.nodeGraphs.map(\.path) {
            for node in try document.graph(at: level).nodes where SwatchPlan.shaderPath(for: node) != nil {
                let solo: MXSoloPreview = try document.soloPreview(for: node.path)
                let image: CGImage? = try Self.render(solo, with: &renderer)
                guard let image else {
                    Issue.record("\(url.lastPathComponent) \(node.path): Storm couldn't show it")
                    continue
                }
                // Something other than the background in the middle.
                let corner = Fixtures.pixel(image, x: 1, y: 1)
                let centre = Fixtures.pixel(image, x: 32, y: 32)
                let difference: Int = abs(Int(centre.r) - Int(corner.r)) + abs(Int(centre.g) - Int(corner.g))
                    + abs(Int(centre.b) - Int(corner.b))
                #expect(difference > 3, "\(url.lastPathComponent) \(node.path): only the background, \(centre)")
            }
        }
    }
}
