// SwatchAgreementTests.swift
//
// A node's swatch (PreviewKit, MaterialX's MSL on our own renderer) and the
// viewport (Storm) should agree (M3c): same light, same side lit, textures
// the same way up. Renders materials both ways, under the studio light and
// without tone mapping, and compares the brightness of a grid of patches
// over the sphere.
//
// The two renderers frame the sphere differently (the swatch's camera is
// closer, so the sphere fills the small image), so patches are placed by
// position on the sphere's disc, not by pixel, and the comparison is a
// correlation: whether the bright and dark patches are in the same places,
// not whether they are exactly as bright. Reflections move a little with
// the camera's distance, so the correlation isn't 1; a swatch lit from the
// wrong side, or with its texture upside down, compares much worse with
// the viewport than with its own mirror image, which the test checks.
//
// Not as bright: under the studio light Storm's diffuse light is darker
// than the swatch's, which is the one that matches the integral of the
// environment (PreviewKit's SwatchEnvironmentTests; PLAN.md §8.2). In a
// uniform environment both are right (the furnace test below).
//
// With VIEWPORT_SNAPSHOT_DIR set, each pair of images is saved.
//
// Introduces (SWIFT): nothing new.

import ColorKit
import CoreGraphics
import Foundation
import MXKit
import PreviewKit
import Testing
import ViewportKit

@Suite("Swatches agree with the viewport", .serialized)
struct SwatchAgreementTests {
    static let size: Int = 256
    static let untoneMapped = ViewTransform(display: "sRGB - Display", view: "Un-tone-mapped")

    /// The sphere's radius on screen as a fraction of half the image, for a
    /// camera `distance` from the centre of a unit sphere with a 30° field
    /// of view: tan(asin(1/d)) / tan(15°).
    static func discRadius(distance: Double) -> Double {
        (1 / (distance * distance - 1).squareRoot()) / tan(15 * Double.pi / 180)
    }

    /// The viewport's camera distance (MGStormRenderer.mm) and the swatch's
    /// (SwatchRenderer.swift).
    static let stormDisc: Double = discRadius(distance: 5)
    static let swatchDisc: Double = discRadius(distance: 4.2)

    /// The average brightness (the mean of R, G and B, 0–255 as stored) of
    /// a 7 × 7 patch around each point of a 5 × 5 grid over the middle of
    /// the sphere's disc, row by row from the top.
    static func patches(_ image: CGImage, discRadius: Double) -> [Double] {
        // Draw into a known RGBA8 sRGB layout first: Storm's snapshot and
        // the swatch don't share one.
        let size: Int = image.width
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var result: [Double] = []
        let half: Double = Double(size) / 2
        for row in -2...2 {
            for column in -2...2 {
                // From -0.7 to 0.7 of the disc's radius: the corners of the
                // grid stay just inside the edge. CGContext's memory starts
                // with the image's top row.
                let x = Int(half + Double(column) * 0.35 * discRadius * half)
                let y = Int(half + Double(row) * 0.35 * discRadius * half)
                var sum: Double = 0
                for py in (y - 3)...(y + 3) {
                    for px in (x - 3)...(x + 3) {
                        let offset: Int = py * size * 4 + px * 4
                        sum += Double(bytes[offset]) + Double(bytes[offset + 1]) + Double(bytes[offset + 2])
                    }
                }
                result.append(sum / (49 * 3))
            }
        }
        return result
    }

    /// Pearson's correlation of two series: 1 if one is the other scaled
    /// and offset, 0 if unrelated, -1 if reversed.
    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let meanA: Double = a.reduce(0, +) / Double(a.count)
        let meanB: Double = b.reduce(0, +) / Double(b.count)
        var covariance: Double = 0
        var varianceA: Double = 0
        var varianceB: Double = 0
        for (x, y) in zip(a, b) {
            covariance += (x - meanA) * (y - meanB)
            varianceA += (x - meanA) * (x - meanA)
            varianceB += (y - meanB) * (y - meanB)
        }
        return covariance / (varianceA * varianceB).squareRoot()
    }

    /// The 5 × 5 grid upside down, and mirrored left to right.
    static func upsideDown(_ grid: [Double]) -> [Double] {
        (0..<25).map { grid[(4 - $0 / 5) * 5 + $0 % 5] }
    }

    static func mirrored(_ grid: [Double]) -> [Double] {
        (0..<25).map { grid[($0 / 5) * 5 + 4 - $0 % 5] }
    }

    /// Renders the first material of `url` with Storm and as a swatch,
    /// lit by `environment` (nil: the studio).
    func render(_ url: URL, name: String, environment: URL? = nil) throws -> (storm: CGImage, swatch: CGImage) {
        let storm = try MGStormRenderer(materialXFile: url)
        storm.use(.studio)
        if let environment {
            storm.environmentURL = environment
        }
        let stormImage: CGImage = try #require(storm.snapshot(width: Self.size, height: Self.size,
                                                              viewTransform: Self.untoneMapped))

        // As the app does: from the preview text, which has absolute
        // texture paths.
        let library: MXLibrary = try MXLibrary.bundled.get()
        let document = try MXDocument(xml: try MXDocument.read(from: url).previewXMLString())
        document.setDataLibrary(library)
        let material: MXElementSummary = try #require(document.topLevelElements.first { $0.type == "material" })
        let shader: MXGeneratedShader = try document.generateMSL(for: material.path, library: library)
        let renderer = try SwatchRenderer(environment: environment ?? StudioEnvironment.fileURL,
                                          viewTransform: Self.untoneMapped)
        let swatchImage: CGImage = try renderer.image(shader, size: Self.size)

        if ProcessInfo.processInfo.environment["VIEWPORT_SNAPSHOT_DIR"] != nil {
            _ = try Fixtures.save(stormImage, as: "agree_\(name)_storm.png")
            _ = try Fixtures.save(swatchImage, as: "agree_\(name)_swatch.png")
        }
        return (stormImage, swatchImage)
    }

    /// A temporary file with one OpenPBR material.
    static func openPBR(_ name: String, _ inputs: String) throws -> URL {
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
        let url: URL = FileManager.default.temporaryDirectory.appendingPathComponent("agree_\(name).mtlx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static let white: String = """
            <input name="base_color" type="color3" value="1, 1, 1" />
            <input name="specular_weight" type="float" value="0" />
        """

    static func example(_ path: String) -> URL {
        var root = URL(filePath: #filePath)
        for _ in 0..<5 {
            root = root.deletingLastPathComponent()
        }
        return root.appending(path: "Vendor/MaterialX/resources/Materials/Examples/" + path)
    }

    /// The materials compared: a diffuse and a mirror (where the light
    /// comes from), metals, and textures (which way up they are).
    static let materials: [String] = ["white", "mirror", "gold", "brass", "wood", "marble"]

    static func url(of material: String) throws -> URL {
        switch material {
        case "white":
            return try openPBR("white", white)
        case "mirror":
            return try openPBR("mirror", """
                    <input name="base_color" type="color3" value="1, 1, 1" />
                    <input name="base_metalness" type="float" value="1" />
                    <input name="specular_roughness" type="float" value="0.02" />
                """)
        case "gold":
            return example("StandardSurface/standard_surface_gold.mtlx")
        case "brass":
            return example("StandardSurface/standard_surface_brass_tiled.mtlx")
        case "wood":
            return example("StandardSurface/standard_surface_wood_tiled.mtlx")
        default:
            return example("StandardSurface/standard_surface_marble_solid.mtlx")
        }
    }

    @Test("A swatch is lit, and textured, like the viewport's sphere",
          .enabled(if: FileManager.default.fileExists(atPath: example("StandardSurface").path),
                   "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: materials)
    func samePattern(_ material: String) throws {
        let (storm, swatch) = try render(try Self.url(of: material), name: material)
        let stormPatches: [Double] = Self.patches(storm, discRadius: Self.stormDisc)
        let swatchPatches: [Double] = Self.patches(swatch, discRadius: Self.swatchDisc)
        let same: Double = Self.correlation(stormPatches, swatchPatches)
        let flipped: Double = Self.correlation(stormPatches, Self.upsideDown(swatchPatches))
        let mirrored: Double = Self.correlation(stormPatches, Self.mirrored(swatchPatches))
        print("\(material): correlation \(same), upside down \(flipped), mirrored \(mirrored)")
        #expect(same > 0.55, "\(material): \(stormPatches) vs \(swatchPatches)")
        // Left and right differ less than top and bottom (the key light is
        // above and only a little to the left), so the mirrored margin is
        // smaller: 0.81 against 0.68 for the white sphere.
        #expect(same > flipped + 0.2 && same > mirrored + 0.1,
                "\(material): \(same), upside down \(flipped), mirrored \(mirrored)")
    }

    @Test("In a uniform environment, both show a white diffuse sphere as white")
    func furnace() throws {
        // Radiance 1 in every direction: a white diffuse surface reflects
        // all of it, whichever way it faces. RGBE for 1 is (128, 128, 128)
        // with exponent 129 (0.5 × 2¹).
        var data = Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 64 +X 128\n".utf8)
        for _ in 0..<(64 * 128) {
            data.append(contentsOf: [128, 128, 128, 129] as [UInt8])
        }
        let environment: URL = FileManager.default.temporaryDirectory.appendingPathComponent("furnace.hdr")
        try data.write(to: environment)

        let (storm, swatch) = try render(try Self.openPBR("furnace", Self.white), name: "furnace",
                                         environment: environment)
        // The middle 3 × 3 patches: the outer ones touch the edge, where
        // the swatch's anti-aliasing mixes in its transparent background.
        let middle: [Int] = [6, 7, 8, 11, 12, 13, 16, 17, 18]
        let stormPatches: [Double] = Self.patches(storm, discRadius: Self.stormDisc)
        let swatchPatches: [Double] = Self.patches(swatch, discRadius: Self.swatchDisc)
        for index in middle {
            #expect(stormPatches[index] > 245, "Storm: \(stormPatches)")
            #expect(swatchPatches[index] > 245, "swatch: \(swatchPatches)")
        }
    }
}
