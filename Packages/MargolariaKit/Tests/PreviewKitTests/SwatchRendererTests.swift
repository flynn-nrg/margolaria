// SwatchRendererTests.swift
//
// Renders MaterialX swatches with PreviewKit and checks the pixels. Each test
// writes its PNG to VIEWPORT_SNAPSHOT_DIR (or the temporary folder) so the
// result can be looked at.

import CoreGraphics
import Foundation
import ImageIO
import MXKit
import PreviewKit
import Testing
import UniformTypeIdentifiers

/// Helpers shared by the tests.
enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    /// A document parsed from `xml`, with the standard libraries attached.
    static func document(xml: String) throws -> (MXDocument, MXLibrary) {
        let library: MXLibrary = try MXLibrary.bundled.get()
        let document = try MXDocument(xml: xml)
        document.setDataLibrary(library)
        return (document, library)
    }

    static func save(_ image: CGImage, as name: String) throws {
        let folderPath: String = ProcessInfo.processInfo.environment["VIEWPORT_SNAPSHOT_DIR"]
            ?? FileManager.default.temporaryDirectory.path
        let url = URL(fileURLWithPath: folderPath).appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        print("Swatch: \(url.path)")
    }

    /// The RGBA8 pixel at (x, y), top-left origin.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let data: CFData = image.dataProvider!.data!
        let offset: Int = y * image.bytesPerRow + x * 4
        return (data as Data).withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
        }
    }
}

// Serialized for the same reason as the Storm tests: one GPU, and these
// tests are about images, not about concurrency.
@Suite("Swatch renderer", .serialized)
struct SwatchRendererTests {
    /// A renderer for this test.
    ///
    /// SWIFT: A shared `static let renderer` would be cheaper, but Swift 6
    /// rejects it: a static is a global any thread can reach, and
    /// SwatchRenderer isn't `Sendable` (it isn't safe to use from two threads
    /// at once). Swift Testing creates a new instance of this struct for
    /// every test, so a stored property gives each test its own renderer.
    let renderer: SwatchRenderer

    /// SWIFT: A struct's `init` can throw; Swift Testing reports the error as
    /// a test failure.
    init() throws {
        renderer = try SwatchRenderer()
    }

    @Test("Timing: generate, compile and render the copper material")
    func timing() throws {
        // macOS caches compiled Metal shaders by their source text, so a
        // shader compiled in an earlier run would look free. Renaming the
        // shader node to something unique changes the generated source and
        // forces a real ("cold") compile.
        let unique: String = "SR_copper_\(UInt32.random(in: 0...UInt32.max))"
        let xml: String = try String(contentsOf: Fixtures.url("brushed_copper.mtlx"), encoding: .utf8)
            .replacingOccurrences(of: "SR_copper", with: unique)
        let (document, library) = try Fixtures.document(xml: xml)

        // SWIFT: `ContinuousClock` measures elapsed time; `measure { }` runs
        // the closure and returns how long it took, as a `Duration`.
        let clock = ContinuousClock()
        var shader: MXGeneratedShader? = nil
        let generate: Duration = try clock.measure {
            shader = try document.generateMSL(for: "M_BrushedCopper", library: library)
        }
        let generated: MXGeneratedShader = try #require(shader)
        // The first render compiles the MSL from scratch. The second finds
        // the pipeline in the renderer's cache (M3c) and only draws.
        let first: Duration = try clock.measure {
            _ = try renderer.image(generated, size: 256)
        }
        let second: Duration = try clock.measure {
            _ = try renderer.image(generated, size: 256)
        }
        print("Copper swatch timing: generate \(generate), first render (cold compile) \(first), second render (cached) \(second)")
        #expect(renderer.hasPipeline(for: generated))
        // About 2 ms: drawing, the view transform and reading the image back.
        #expect(second < .milliseconds(50), "\(second)")
    }

    @Test("A float node renders as grey noise on a sphere")
    func noiseNode() throws {
        let library: MXLibrary = try MXLibrary.bundled.get()
        let document = try MXDocument.read(from: Fixtures.url("brushed_copper.mtlx"))
        document.setDataLibrary(library)
        let shader = try document.generateMSL(for: "NG_copper/grain", library: library)

        let image: CGImage = try renderer.image(shader, size: 256)
        try Fixtures.save(image, as: "swatch_grain.png")

        // Outside the sphere: transparent.
        #expect(Fixtures.pixel(image, x: 2, y: 2).a == 0)
        // On the sphere: opaque grey (r == g == b), and not all one value.
        let a = Fixtures.pixel(image, x: 128, y: 128)
        let b = Fixtures.pixel(image, x: 90, y: 160)
        #expect(a.a == 255 && a.r == a.g && a.g == a.b, "expected grey, got \(a)")
        #expect(a.r != b.r || a.r != Fixtures.pixel(image, x: 160, y: 90).r, "noise should vary")
    }

    @Test("The copper material renders on the sphere")
    func copperMaterial() throws {
        let library: MXLibrary = try MXLibrary.bundled.get()
        let document = try MXDocument.read(from: Fixtures.url("brushed_copper.mtlx"))
        document.setDataLibrary(library)
        let shader = try document.generateMSL(for: "M_BrushedCopper", library: library)

        let image: CGImage = try renderer.image(shader, size: 256)
        try Fixtures.save(image, as: "swatch_copper.png")

        let centre = Fixtures.pixel(image, x: 128, y: 128)
        #expect(centre.a == 255)
        #expect(centre.r > centre.b, "copper reflects more red than blue, got \(centre)")
    }

    @Test("A green plastic comes out green")
    func greenMaterial() throws {
        let (document, library) = try Fixtures.document(xml: #"""
            <?xml version="1.0"?>
            <materialx version="1.39">
              <open_pbr_surface name="SR_green" type="surfaceshader">
                <input name="base_color" type="color3" value="0.05, 0.8, 0.05" />
                <input name="specular_roughness" type="float" value="0.6" />
              </open_pbr_surface>
              <surfacematerial name="M_Green" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="SR_green" />
              </surfacematerial>
            </materialx>
            """#)
        let shader = try document.generateMSL(for: "M_Green", library: library)
        let image: CGImage = try renderer.image(shader, size: 256)
        try Fixtures.save(image, as: "swatch_green.png")

        let lit = Fixtures.pixel(image, x: 128, y: 100)
        #expect(lit.g > lit.r + 40 && lit.g > lit.b + 40, "expected green, got \(lit)")
    }

    @Test("Texture coordinates reach the shader (checkerboard)")
    func checkerboard() throws {
        let (document, library) = try Fixtures.document(xml: #"""
            <?xml version="1.0"?>
            <materialx version="1.39">
              <checkerboard name="checker" type="color3">
                <input name="color1" type="color3" value="1, 0, 0" />
                <input name="color2" type="color3" value="0, 0, 1" />
                <input name="uvtiling" type="vector2" value="8, 4" />
              </checkerboard>
            </materialx>
            """#)
        let shader = try document.generateMSL(for: "checker", library: library)
        let image: CGImage = try renderer.image(shader, size: 256)
        try Fixtures.save(image, as: "swatch_checker.png")

        // Along the equator, the colour must switch between red and blue.
        // (Relative tests: ACES 2.0, the default view transform, shows pure
        // red as about 190, not 255.)
        var sawRed = false
        var sawBlue = false
        for x in stride(from: 40, to: 216, by: 4) {
            let p = Fixtures.pixel(image, x: x, y: 128)
            if p.r > p.b + 120 { sawRed = true }
            if p.b > p.r + 120 { sawBlue = true }
        }
        #expect(sawRed && sawBlue)
    }
}
