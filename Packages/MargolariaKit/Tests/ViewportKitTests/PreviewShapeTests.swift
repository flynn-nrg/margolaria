// PreviewShapeTests.swift
//
// Tests for the preview shapes (M7a): each renders, every example renders
// on each, and going back to the sphere gives the image the sphere gave
// before (M7a's criterion; Export as USDZ… with each shape is tested in
// USDZExportTests). With VIEWPORT_SNAPSHOT_DIR set, the renders are saved,
// to look at.
//
// Introduces (SWIFT): nothing new.

import ColorKit
import CoreGraphics
import Foundation
import Testing
import ViewportKit

extension StormRendererTests {
    /// Renders `renderer` as the viewport does (studio light), `size`
    /// pixels square, saving it as `name` when asked to.
    func studioSnapshot(_ renderer: MGStormRenderer, size: Int, name: String) throws -> CGImage {
        renderer.use(.studio)
        let image: CGImage = try #require(renderer.snapshot(width: size, height: size), "\(name)")
        if ProcessInfo.processInfo.environment["VIEWPORT_SNAPSHOT_DIR"] != nil {
            _ = try Fixtures.save(image, as: name + ".png")
        }
        return image
    }

    /// How much of `image` isn't the background: the share of pixels that
    /// differ from the top-left corner's.
    func coverage(_ image: CGImage) -> Double {
        let corner = Fixtures.pixel(image, x: 0, y: 0)
        var covered: Int = 0
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                let p = Fixtures.pixel(image, x: x, y: y)
                if abs(Int(p.r) - Int(corner.r)) + abs(Int(p.g) - Int(corner.g)) + abs(Int(p.b) - Int(corner.b)) > 6 {
                    covered += 1
                }
            }
        }
        return Double(covered) / Double((image.width / 2) * (image.height / 2))
    }

    @Test("Each shape draws the material, filling about the sphere's room", arguments: ViewportShape.allCases)
    func drawsShape(_ shape: ViewportShape) throws {
        let renderer = try MGStormRenderer(materialXFile: Fixtures.url("brushed_copper.mtlx"))
        renderer.shape = shape.bridged
        #expect(renderer.shape == shape.bridged)
        let image: CGImage = try studioSnapshot(renderer, size: 256, name: "shape_" + shape.rawValue)
        // Copper in the middle: red above blue.
        let centre = Fixtures.pixel(image, x: 128, y: 128)
        #expect(Int(centre.r) > Int(centre.b) + 20, "\(shape): \(centre)")
        // The sphere covers about a third of the square; the others are
        // framed alike, neither lost in the middle nor cut off.
        let covered: Double = coverage(image)
        #expect(covered > 0.2 && covered < 0.6, "\(shape) covers \(covered)")
        for (x, y) in [(0, 128), (255, 128), (128, 0), (128, 255)] {
            let edge = Fixtures.pixel(image, x: x, y: y)
            let corner = Fixtures.pixel(image, x: 0, y: 0)
            #expect(edge == corner, "\(shape) reaches the edge at (\(x), \(y))")
        }
    }

    @Test("Back on the sphere, the image is the sphere's before the other shapes")
    func backToSphere() throws {
        let renderer = try MGStormRenderer(materialXFile: Fixtures.url("brushed_copper.mtlx"))
        let before: CGImage = try studioSnapshot(renderer, size: 128, name: "shape_sphere_before")
        for shape in ViewportShape.allCases {
            renderer.shape = shape.bridged
            _ = try studioSnapshot(renderer, size: 128, name: "shape_on_the_way_" + shape.rawValue)
        }
        renderer.shape = ViewportShape.sphere.bridged
        let after: CGImage = try studioSnapshot(renderer, size: 128, name: "shape_sphere_after")
        for y in stride(from: 0, to: 128, by: 4) {
            for x in stride(from: 0, to: 128, by: 4) {
                let p = Fixtures.pixel(before, x: x, y: y)
                let q = Fixtures.pixel(after, x: x, y: y)
                #expect(p == q, "(\(x), \(y)): before \(p), after \(q)")
            }
        }
    }

    @Test("Every material in MaterialX's examples renders on each shape",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Examples.files, ViewportShape.allCases.filter { $0 != .sphere })
    func rendersExampleOnShape(_ url: URL, shape: ViewportShape) throws {
        let renderer = try MGStormRenderer(materialXFile: url)
        renderer.shape = shape.bridged
        for path in renderer.materialPaths {
            #expect(renderer.bindMaterial(atPath: path))
            let image: CGImage = try #require(renderer.snapshot(width: 96, height: 96, viewTransform: Self.untoneMapped),
                                              "\(path)")
            if ProcessInfo.processInfo.environment["VIEWPORT_SNAPSHOT_DIR"] != nil {
                let name: String = url.deletingPathExtension().lastPathComponent + "_"
                    + (path as NSString).lastPathComponent + "_" + shape.rawValue
                _ = try Fixtures.save(image, as: name + ".png")
            }
            // Something other than the background where the shape is.
            // Except clear glass and a soap bubble on the thin shapes: a
            // sheet with no thickness doesn't bend the light behind it, so
            // they all but vanish, rightly (a glass sphere refracts, and
            // shows).
            let name: String = (path as NSString).lastPathComponent.lowercased()
            let seeThrough: Bool = name.contains("glass") || name.contains("soap_bubble")
            if !(seeThrough && (shape == .plane || shape == .cloth)) {
                #expect(coverage(image) > 0.1, "\(path) on the \(shape): nothing drawn")
            }
        }
    }
}
