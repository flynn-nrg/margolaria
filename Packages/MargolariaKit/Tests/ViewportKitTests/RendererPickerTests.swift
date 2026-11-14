// RendererPickerTests.swift
//
// The viewport's renderer picker (M5e, PLAN.md §8.6): the Hydra renderers
// found, switching between them, and every example rendered by each. Storm
// is the renderer that draws MaterialX; Embree, OpenUSD's example path
// tracer, shades every surface with ambient occlusion and ignores
// materials, so what is checked there is that it draws the sphere, and
// that switching back gives Storm's image again.
//
// The app doesn't offer Embree (ViewportRenderer.unusable): with Metal's
// validation on, OpenUSD stops in its depth copy (PLAN.md §8.2). `swift
// test` runs without validation, where the colour image is right, so the
// switching is still checked here, for the renderers to come. With
// MTL_DEBUG_LAYER=1, the rendering test is skipped (since M7a), so the
// rest of the tests can run under validation.
//
// With VIEWPORT_SNAPSHOT_DIR set, every render is saved.
//
// Introduces (SWIFT): a class property of an Objective-C class
// (`@property (class)`), a throwing method made from an Objective-C
// `BOOL ... error:` method.

import CoreGraphics
import Foundation
import MXKit
import Testing
import ViewportKit

extension StormRendererTests {
    /// Storm's and Embree's plugin identifiers.
    static let storm: String = "HdStormRendererPlugin"
    static let embree: String = "HdEmbreeRendererPlugin"

    @Test("Lists Storm first, and Embree")
    func listsRenderers() {
        // SWIFT: `@property (class)` in Objective-C is a static property in
        // Swift, read on the type: `MGStormRenderer.availableRendererIDs`.
        let ids: [String] = MGStormRenderer.availableRendererIDs
        #expect(ids.first == Self.storm)
        #expect(ids.contains(Self.embree))
        #expect(MGStormRenderer.displayName(forRendererID: Self.storm) == "Storm")
        #expect(MGStormRenderer.displayName(forRendererID: Self.embree) == "Embree")
    }

    @Test("Offers Storm alone in the app, and falls back to it")
    func offersStorm() {
        #expect(ViewportRenderer.available == [.storm])
        // A choice stored before Embree was left out.
        #expect(ViewportRenderer.preferred(id: Self.embree) == .storm)
    }

    @Test("Refuses a renderer that isn't there, keeping Storm")
    func refusesUnknownRenderer() throws {
        let renderer = try MGStormRenderer(materialXFile: Fixtures.url("brushed_copper.mtlx"))
        // SWIFT: `-setRendererID:error:` returns a BOOL and fills an
        // NSError, so Swift imports it as a method that throws and returns
        // nothing: `#expect(throws:)` checks that it throws.
        #expect(throws: (any Error).self) {
            try renderer.setRendererID("HdNoSuchRendererPlugin")
        }
        #expect(renderer.rendererID == Self.storm)
        #expect(renderer.snapshot(width: 64, height: 64) != nil)
    }

    @Test("Every example renders in every renderer, and Storm's image comes back",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          .enabled(if: ProcessInfo.processInfo.environment["MTL_DEBUG_LAYER"] != "1",
                   "Embree stops under Metal's validation (PLAN.md §8.2)"),
          arguments: Examples.files)
    func rendersExampleInEveryRenderer(_ url: URL) throws {
        // From the viewport's text, as the app shows a document.
        let document = try MXDocument.read(from: url)
        let renderer = try MGStormRenderer(materialXString: try document.viewportXMLString())
        let name: String = url.deletingPathExtension().lastPathComponent

        /// Every material's image, with the renderer in use.
        func renderEveryMaterial() throws -> [String: CGImage] {
            var images: [String: CGImage] = [:]
            for path in renderer.materialPaths {
                #expect(renderer.bindMaterial(atPath: path))
                let image: CGImage = try #require(renderer.snapshot(width: 96, height: 96,
                                                                    viewTransform: Self.untoneMapped),
                                                  "\(path) in \(renderer.rendererName)")
                if ProcessInfo.processInfo.environment["VIEWPORT_SNAPSHOT_DIR"] != nil {
                    let material: String = (path as NSString).lastPathComponent
                    _ = try Fixtures.save(image, as: "\(name)_\(material)_\(renderer.rendererName).png")
                }
                images[path] = image
            }
            return images
        }

        let before: [String: CGImage] = try renderEveryMaterial()
        for id in MGStormRenderer.availableRendererIDs where id != Self.storm {
            try renderer.setRendererID(id)
            #expect(renderer.rendererID == id)
            for (path, image) in try renderEveryMaterial() {
                // The sphere is drawn: the middle differs from the corner.
                let corner = Fixtures.pixel(image, x: 1, y: 1)
                let centre = Fixtures.pixel(image, x: 48, y: 48)
                let difference: Int = abs(Int(centre.r) - Int(corner.r)) + abs(Int(centre.g) - Int(corner.g))
                    + abs(Int(centre.b) - Int(corner.b))
                #expect(difference > 6, "\(path) in \(renderer.rendererName): no sphere")
            }
        }
        try renderer.setRendererID(Self.storm)
        let after: [String: CGImage] = try renderEveryMaterial()

        // Storm's image is the same as before switching, within rounding.
        for (path, first) in before {
            let again: CGImage = try #require(after[path])
            for (x, y) in [(48, 48), (35, 35), (60, 40), (48, 65)] {
                let p = Fixtures.pixel(first, x: x, y: y)
                let q = Fixtures.pixel(again, x: x, y: y)
                let difference: Int = abs(Int(p.r) - Int(q.r)) + abs(Int(p.g) - Int(q.g)) + abs(Int(p.b) - Int(q.b))
                #expect(difference <= 3, "\(path) at (\(x), \(y)): before \(p), after \(q)")
            }
        }
    }
}
