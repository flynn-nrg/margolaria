// StormRendererTests.swift
//
// Renders the brushed-copper fixture with Storm and checks the result. Each
// test also writes its image to a PNG so a person can look at it; the path is
// printed in the test output. Set VIEWPORT_SNAPSHOT_DIR to choose the folder.
//
// Introduces (SWIFT): `ProcessInfo` environment lookup, ImageIO from Swift,
// reading raw pixel bytes with `withUnsafeBytes`.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ViewportKit

/// Helpers shared by the tests.
enum Fixtures {
    /// The URL of a file in Tests/ViewportKitTests/Fixtures.
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    /// Writes `image` as a PNG named `name` and returns where it went.
    static func save(_ image: CGImage, as name: String) throws -> URL {
        // SWIFT: `??` supplies a default when the optional on the left is nil,
        // like Go's `if v, ok := m[k]; !ok { v = def }` in one expression.
        let folderPath: String = ProcessInfo.processInfo.environment["VIEWPORT_SNAPSHOT_DIR"]
            ?? FileManager.default.temporaryDirectory.path
        let url: URL = URL(fileURLWithPath: folderPath).appendingPathComponent(name)

        // ImageIO's C API, used from Swift. `CFURL` and `URL` are toll-free
        // bridged, as in Objective-C, so `as CFURL` is free.
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// The RGBA8 pixel at (x, y), top-left origin.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        // SWIFT: `(r: UInt8, g: UInt8, b: UInt8)` is a tuple with labelled
        // elements: a lightweight anonymous struct, like returning a small
        // struct by value in C.
        let data: CFData = image.dataProvider!.data!
        let offset: Int = y * image.bytesPerRow + x * 4
        // SWIFT: `withUnsafeBytes` lends a raw pointer to the bytes for the
        // duration of the closure only, like borrowing a `const uint8_t *`
        // that must not escape. "Unsafe" means Swift doesn't bounds-check it.
        return (data as Data).withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            (bytes[offset], bytes[offset + 1], bytes[offset + 2])
        }
    }
}

// SWIFT: `.serialized` is a *trait* that runs this suite's tests one after
// another instead of in parallel (Swift Testing's default). Storm renders
// on the GPU and isn't designed for several engines rendering at once.
@Suite("Storm renderer", .serialized)
struct StormRendererTests {
    @Test("Binds the material from the .mtlx file")
    func bindsMaterial() throws {
        let renderer = try MGStormRenderer(materialXFile: Fixtures.url("brushed_copper.mtlx"))
        #expect(renderer.boundMaterialPath == "/World/MaterialX/Materials/M_BrushedCopper")
    }

    @Test("Renders a copper-coloured sphere on a grey background")
    func rendersSphere() throws {
        let renderer = try MGStormRenderer(materialXFile: Fixtures.url("brushed_copper.mtlx"))
        let image: CGImage = try #require(renderer.snapshot(width: 512, height: 512))

        let url: URL = try Fixtures.save(image, as: "storm_brushed_copper.png")
        print("Storm snapshot (\(renderer.rendererName)): \(url.path)")

        // A corner is the clear colour, a mid grey.
        let corner = Fixtures.pixel(image, x: 2, y: 2)
        #expect(corner.r == corner.g && corner.g == corner.b, "background should be grey, got \(corner)")

        // The centre is the sphere. Copper reflects more red than blue.
        let centre = Fixtures.pixel(image, x: 256, y: 256)
        #expect(centre.r > centre.b, "sphere should look like copper, got \(centre)")
    }

    @Test("The colour comes from the MaterialX shader")
    func usesMaterialXColour() throws {
        // A plain green plastic. If Storm ignored the MaterialX graph, it
        // would fall back to its default grey material and this would fail.
        // SWIFT: `#"..."#` is a *raw string*: backslashes and quotes inside
        // are literal, so XML needs no escaping. A multi-line string uses
        // `"""` on lines of their own; the indentation of the closing `"""`
        // is removed from every line.
        let xml: String = #"""
            <?xml version="1.0"?>
            <materialx version="1.39">
              <open_pbr_surface name="SR_green" type="surfaceshader">
                <input name="base_color" type="color3" value="0.05, 0.8, 0.05" />
                <input name="base_metalness" type="float" value="0.0" />
                <input name="specular_roughness" type="float" value="0.6" />
              </open_pbr_surface>
              <surfacematerial name="M_Green" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="SR_green" />
              </surfacematerial>
            </materialx>
            """#
        let url: URL = FileManager.default.temporaryDirectory.appendingPathComponent("green.mtlx")
        try xml.write(to: url, atomically: true, encoding: .utf8)

        let renderer = try MGStormRenderer(materialXFile: url)
        let image: CGImage = try #require(renderer.snapshot(width: 256, height: 256))
        let saved: URL = try Fixtures.save(image, as: "storm_green.png")
        print("Storm snapshot: \(saved.path)")

        // Upper left of the sphere, away from the key light's highlight.
        let lit = Fixtures.pixel(image, x: 110, y: 110)
        #expect(lit.g > lit.r + 40 && lit.g > lit.b + 40, "sphere should be green, got \(lit)")
    }

    @Test("Lists every material, and switches between them")
    func switchesMaterials() throws {
        let xml: String = #"""
            <?xml version="1.0"?>
            <materialx version="1.39">
              <open_pbr_surface name="SR_red" type="surfaceshader">
                <input name="base_color" type="color3" value="0.8, 0.05, 0.05" />
              </open_pbr_surface>
              <surfacematerial name="M_Red" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="SR_red" />
              </surfacematerial>
              <open_pbr_surface name="SR_blue" type="surfaceshader">
                <input name="base_color" type="color3" value="0.05, 0.05, 0.8" />
              </open_pbr_surface>
              <surfacematerial name="M_Blue" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="SR_blue" />
              </surfacematerial>
            </materialx>
            """#
        let url: URL = FileManager.default.temporaryDirectory.appendingPathComponent("red_blue.mtlx")
        try xml.write(to: url, atomically: true, encoding: .utf8)

        let renderer = try MGStormRenderer(materialXFile: url)
        #expect(renderer.materialPaths == ["/World/MaterialX/Materials/M_Red", "/World/MaterialX/Materials/M_Blue"])
        #expect(renderer.boundMaterialPath == "/World/MaterialX/Materials/M_Red")
        let red = Fixtures.pixel(try #require(renderer.snapshot(width: 128, height: 128)), x: 55, y: 55)
        #expect(red.r > red.b + 40, "first material is red, got \(red)")

        #expect(renderer.bindMaterial(atPath: "/World/MaterialX/Materials/M_Blue"))
        #expect(renderer.boundMaterialPath == "/World/MaterialX/Materials/M_Blue")
        let blue = Fixtures.pixel(try #require(renderer.snapshot(width: 128, height: 128)), x: 55, y: 55)
        #expect(blue.b > blue.r + 40, "after switching, blue, got \(blue)")

        // Not a material: refused, nothing changes.
        #expect(!renderer.bindMaterial(atPath: "/World/Sphere"))
        #expect(renderer.boundMaterialPath == "/World/MaterialX/Materials/M_Blue")
    }

    @Test("A file without materials is an error, not a crash")
    func noMaterial() throws {
        let folder: URL = FileManager.default.temporaryDirectory
        let url: URL = folder.appendingPathComponent("no_material.mtlx")
        try #"<?xml version="1.0"?><materialx version="1.39"/>"#.write(to: url, atomically: true, encoding: .utf8)

        // SWIFT: `#expect(throws:)` passes only if the closure throws.
        #expect(throws: (any Error).self) {
            _ = try MGStormRenderer(materialXFile: url)
        }
    }
}
