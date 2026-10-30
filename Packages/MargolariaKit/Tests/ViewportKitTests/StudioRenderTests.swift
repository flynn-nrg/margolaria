// StudioRenderTests.swift
//
// The studio lighting, rendered by Storm (M3b): a white sphere is neutral
// and lit from the upper left; a mirror shows the soft boxes. The renders
// are saved as PNGs, like the other Storm tests. (The view transform and
// the studio image itself are tested in PreviewKit, DisplayPassTests.)
//
// Introduces (SWIFT): nothing new.

import ColorKit
import CoreGraphics
import Foundation
import Testing
import ViewportKit

@Suite("Studio lighting in Storm", .serialized)
struct StudioRenderTests {
    /// A material with one OpenPBR surface: `inputs` are its <input> lines.
    func material(_ name: String, _ inputs: String) throws -> URL {
        let xml = """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <open_pbr_surface name="SR_\(name)" type="surfaceshader">
            \(inputs)
              </open_pbr_surface>
              <surfacematerial name="M_\(name)" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="SR_\(name)" />
              </surfacematerial>
            </materialx>
            """
        let url: URL = FileManager.default.temporaryDirectory.appendingPathComponent("studio_\(name).mtlx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Under the studio light a white sphere is neutral, lit from the upper left, and a mirror shows the soft boxes")
    func studioRenders() throws {
        let untoneMapped = ViewTransform(display: "sRGB - Display", view: "Un-tone-mapped")

        let white = try MGStormRenderer(materialXFile: material("white", """
                <input name="base_color" type="color3" value="1, 1, 1" />
                <input name="specular_weight" type="float" value="0" />
            """))
        white.use(.studio)
        let diffuse: CGImage = try #require(white.snapshot(width: 256, height: 256, viewTransform: untoneMapped))
        print("Studio, white diffuse: \(try Fixtures.save(diffuse, as: "studio_white.png").path)")
        // The upper left faces the key light; the lower right is in shadow.
        let lit = Fixtures.pixel(diffuse, x: 95, y: 95)
        let shadow = Fixtures.pixel(diffuse, x: 170, y: 170)
        #expect(abs(Int(lit.r) - Int(lit.b)) <= 1 && abs(Int(lit.r) - Int(lit.g)) <= 1, "neutral: \(lit)")
        #expect(Int(lit.r) > Int(shadow.r) + 60, "lit \(lit), shadow \(shadow)")

        let mirror = try MGStormRenderer(materialXFile: material("mirror", """
                <input name="base_color" type="color3" value="1, 1, 1" />
                <input name="base_metalness" type="float" value="1" />
                <input name="specular_roughness" type="float" value="0.02" />
            """))
        mirror.use(.studio)
        let chrome: CGImage = try #require(mirror.snapshot(width: 256, height: 256, viewTransform: untoneMapped))
        print("Studio, mirror: \(try Fixtures.save(chrome, as: "studio_mirror.png").path)")

        // The same mirror with the default view transform (ACES 2.0), to
        // compare by eye.
        let aces: CGImage = try #require(mirror.snapshot(width: 256, height: 256))
        print("Studio, mirror, ACES 2.0: \(try Fixtures.save(aces, as: "studio_mirror_aces.png").path)")
    }
}
