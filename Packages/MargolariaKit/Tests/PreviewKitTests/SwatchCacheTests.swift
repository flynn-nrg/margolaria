// SwatchCacheTests.swift
//
// The canvas's swatches after edits (M3c): only the nodes downstream of an
// edit are drawn again, and after a value edit they are all up to date in
// under 100 ms on a typical graph, M3's exit criterion (PLAN.md §8).
//
// The typical graph is MaterialX's marble example: a nodegraph of 12 nodes
// (noise, maths, a colour mix) feeding a standard_surface. Edits are made
// with MXKit, as the app makes them, and the swatches requested again as
// the canvas does after every edit.
//
// Introduces (SWIFT): `async` tests, and collecting a `@Sendable`
// callback's results in a `@MainActor` class instance.

import ColorKit
import Foundation
import MXKit
import PreviewKit
import Testing

@Suite("Swatch cache", .serialized)
@MainActor
struct SwatchCacheTests {
    static let settings = SwatchSettings(environmentURL: StudioEnvironment.fileURL, viewTransform: .standard,
                                         pixelSize: 192)

    /// The marble example, read as the app reads documents: with the data
    /// library, so nodes find their nodedefs.
    static func readMarble() throws -> MXDocument {
        let document = try MXDocument.read(from: marble)
        document.setDataLibrary(try MXLibrary.bundled.get())
        return document
    }

    static let marble: URL = {
        var root = URL(filePath: #filePath)
        for _ in 0..<5 {
            root = root.deletingLastPathComponent()
        }
        return root.appending(path: "Vendor/MaterialX/resources/Materials/Examples/StandardSurface/standard_surface_marble_solid.mtlx")
    }()

    /// The swatches `cache.update` reported, by node path.
    ///
    /// SWIFT: The update's callback is `@Sendable`, so it can't capture a
    /// local `var`. A class instance can be captured, and its contents
    /// changed; `@MainActor` makes that safe, because the callback runs on
    /// the main actor, like the test.
    @MainActor
    final class Collected {
        var swatches: [String: Swatch] = [:]
    }

    /// The requests for the level at `path`, as the canvas makes them.
    static func requests(_ document: MXDocument, level path: String) throws -> [SwatchRequest] {
        let xml: String = try document.xmlString()
        let custom = Set(document.topLevelElements.filter { $0.category == "nodedef" }.map(\.name))
        return SwatchPlan.requests(for: try document.graph(at: path), in: document, documentText: xml,
                                   customNodeDefs: custom)
    }

    /// Updates `cache` for `level` and waits; returns what was drawn and
    /// how long it took.
    static func update(_ cache: SwatchCache, _ document: MXDocument,
                       level: String) async throws -> (swatches: [String: Swatch], time: Duration) {
        let collected = Collected()
        let clock = ContinuousClock()
        let start: ContinuousClock.Instant = clock.now
        // As the canvas does after an edit: request every node's swatch,
        // with the document's new text.
        let requests: [SwatchRequest] = try requests(document, level: level)
        cache.update(requests, xml: try document.previewXMLString(), settings: settings) { path, swatch in
            collected.swatches[path] = swatch
        }
        await cache.waitUntilDone()
        return (collected.swatches, clock.now - start)
    }

    @Test("Every node of the marble graph gets a swatch")
    func everyNode() async throws {
        let cache = SwatchCache(service: try SwatchService())
        let document = try Self.readMarble()
        let (swatches, time) = try await Self.update(cache, document, level: "NG_marble1")
        print("Marble graph, first swatches: \(time)")
        #expect(swatches.count == 12, "\(swatches.keys.sorted())")
        for (path, swatch) in swatches {
            // SWIFT: `if case .failed(let message) = swatch` tests one case
            // of an enum without a whole `switch`.
            if case .failed(let message) = swatch {
                Issue.record("\(path): \(message)")
            }
        }
        // The level above: the nodegraph shown as a node, the shader and
        // the material.
        let top = try await Self.update(cache, document, level: "")
        #expect(Set(top.swatches.keys) == ["NG_marble1", "SR_marble1", "Marble_3D"])
    }

    @Test("A value edit draws again only the edited node and those downstream, in under 100 ms")
    func valueEdit() async throws {
        let cache = SwatchCache(service: try SwatchService())
        let document = try Self.readMarble()
        _ = try await Self.update(cache, document, level: "NG_marble1")

        // The noise's strength: scale_noise feeds sum, then sin, scale,
        // bias, power and the colour mix.
        try document.setValue("2.5", ofInput: "in2", on: "NG_marble1/scale_noise")
        let (swatches, time) = try await Self.update(cache, document, level: "NG_marble1")
        print("Marble graph, value edit: \(swatches.count) swatches in \(time)")
        let downstream: Set<String> = ["scale_noise", "sum", "sin", "scale", "bias", "power", "color_mix"]
        #expect(Set(swatches.keys) == Set(downstream.map { "NG_marble1/" + $0 }))
        #expect(time < .milliseconds(100), "M3's exit criterion: \(time)")

        // A second edit while dragging a slider: the same again.
        try document.setValue("2.4", ofInput: "in2", on: "NG_marble1/scale_noise")
        let again = try await Self.update(cache, document, level: "NG_marble1")
        #expect(again.swatches.count == downstream.count)
        #expect(again.time < .milliseconds(100), "\(again.time)")

        // At the top: a value of the shader, in its own swatch and the
        // material's, not the nodegraph's.
        _ = try await Self.update(cache, document, level: "")
        try document.setValue("0.3", ofInput: "specular_roughness", on: "SR_marble1")
        let top = try await Self.update(cache, document, level: "")
        print("Marble shader, value edit: \(top.swatches.count) swatches in \(top.time)")
        #expect(Set(top.swatches.keys) == ["SR_marble1", "Marble_3D"])
        #expect(top.time < .milliseconds(100), "\(top.time)")
    }

    @Test("Moving a node draws nothing again; an edit inside a nodegraph redraws it on the level above")
    func whatChanges() async throws {
        let cache = SwatchCache(service: try SwatchService())
        let document = try Self.readMarble()
        _ = try await Self.update(cache, document, level: "")

        try document.setPosition(CGPoint(x: 3, y: 4), of: "SR_marble1")
        let moved = try await Self.update(cache, document, level: "")
        #expect(moved.swatches.isEmpty)

        // Inside the nodegraph, which isn't on screen; going back up shows
        // the nodegraph and everything downstream of it changed.
        try document.setValue("0.2, 0.5, 0.2", ofInput: "base_color_2", on: "NG_marble1")
        let up = try await Self.update(cache, document, level: "")
        #expect(Set(up.swatches.keys) == ["NG_marble1", "SR_marble1", "Marble_3D"])
    }

    @Test("A graph edit compiles the new shaders, and keeps the old swatches until then")
    func graphEdit() async throws {
        let cache = SwatchCache(service: try SwatchService())
        let document = try Self.readMarble()
        _ = try await Self.update(cache, document, level: "NG_marble1")
        let before: Swatch? = cache.swatch(for: "NG_marble1/color_mix")

        // The mix from `bias` instead of `power`: a new source for the mix.
        try document.connect(input: "mix", on: "NG_marble1/color_mix", to: "bias")
        let collected = Collected()
        cache.update(try Self.requests(document, level: "NG_marble1"), xml: try document.previewXMLString(),
                     settings: Self.settings) { path, swatch in
            collected.swatches[path] = swatch
        }
        // Until the new one is drawn, the old swatch is still there.
        #expect(cache.swatch(for: "NG_marble1/color_mix") != nil && before != nil)
        let clock = ContinuousClock()
        let start: ContinuousClock.Instant = clock.now
        await cache.waitUntilDone()
        print("Marble graph, connection edit: \(collected.swatches.count) swatches in \(clock.now - start)")
        #expect(Set(collected.swatches.keys) == ["NG_marble1/color_mix"])
    }

    @Test("A new update cancels the work of the one before")
    func cancels() async throws {
        let cache = SwatchCache(service: try SwatchService())
        let document = try Self.readMarble()
        let collected = Collected()
        // The first update is cancelled at once by the second, which asks
        // for the other level.
        cache.update(try Self.requests(document, level: "NG_marble1"), xml: try document.previewXMLString(),
                     settings: Self.settings) { path, swatch in
            collected.swatches[path] = swatch
        }
        let top = try await Self.update(cache, document, level: "")
        #expect(Set(top.swatches.keys) == ["NG_marble1", "SR_marble1", "Marble_3D"])
        // The service only ran the first one until it noticed: at most the
        // first swatch it was already drawing.
        #expect(collected.swatches.count <= 1, "\(collected.swatches.keys)")
    }
}
