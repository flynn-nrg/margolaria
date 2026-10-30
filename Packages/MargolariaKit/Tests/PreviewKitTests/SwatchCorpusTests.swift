// SwatchCorpusTests.swift
//
// Every swatch of every example (M3c): for each level of each document in
// MaterialX's resources/Materials/Examples (the document and each
// nodegraph), the nodes that get a swatch (SwatchPlan) are drawn as the
// canvas draws them. All must succeed, except a few that MaterialX 1.39.5's
// MSL generator gets wrong; those are listed, so a change (fixed in a
// newer MaterialX, or broken by ours) shows up here.
//
// The first run compiles some 400 shaders and takes about a minute; macOS
// caches compiled shaders, so later runs take seconds.
//
// Fetch the examples with scripts/fetch-materialx-examples.sh; without them
// the test is skipped.
//
// Introduces (SWIFT): nothing new.

import Foundation
import MXKit
import PreviewKit
import Testing

@Suite("Swatches of every example", .serialized)
struct SwatchCorpusTests {
    static let examples: URL = {
        var root = URL(filePath: #filePath)
        for _ in 0..<5 {
            root = root.deletingLastPathComponent()
        }
        return root.appending(path: "Vendor/MaterialX/resources/Materials/Examples")
    }()

    static let files: [URL] = {
        guard let enumerator = FileManager.default.enumerator(atPath: examples.path(percentEncoded: false)) else {
            return []
        }
        var files: [URL] = []
        while let path = enumerator.nextObject() as? String {
            if path.hasSuffix(".mtlx") {
                files.append(examples.appending(path: path))
            }
        }
        return files.sorted(by: { $0.path < $1.path })
    }()

    /// Swatches MaterialX 1.39.5 can't make, by file and node, with why:
    ///
    /// - Image nodes inside a nodegraph with an interface input of the same
    ///   name as one of theirs (`uvtiling`): shading the node alone
    ///   declares two uniforms of that name, a float2 and a float, and the
    ///   generated MSL doesn't compile.
    /// - The hair nodes' helpers use `mx_environment_radiance`, which
    ///   MaterialX only includes when shading a surface.
    static let knownFailures: Set<String> = [
        "standard_surface_brick_procedural.mtlx NG_BrickPattern/node_tiledimage_vector3_27",
        "standard_surface_brick_procedural.mtlx NG_BrickPattern/node_tiledimage_float_22",
        "standard_surface_brick_procedural.mtlx NG_BrickPattern/node_tiledimage_float_10",
        "standard_surface_brick_procedural.mtlx NG_BrickPattern/node_tiledimage_float_7",
        "standard_surface_brick_procedural.mtlx NG_BrickPattern/node_tiledimage_float_26",
        "standard_surface_brick_procedural.mtlx NG_BrickPattern/node_tiledimage_float_24",
        "standard_surface_onyx_hextiled.mtlx NG_OnyxHextiled/image_color",
        "standard_surface_onyx_hextiled.mtlx NG_OnyxHextiled/image_roughness",
        "simple_hair_default.mtlx NG_simple_hair_shader/absorption_from_melanin",
        "simple_hair_default.mtlx NG_simple_hair_shader/absorption_from_color",
        "simple_hair_default.mtlx NG_simple_hair_shader/mix_melanin_basecolor",
        "simple_hair_default.mtlx NG_simple_hair_shader/spec_roughness",
    ]

    /// Collects the swatches from the cache's callback (see SwatchCacheTests).
    @MainActor
    final class Collected {
        var failures: [String: String] = [:]
        var count: Int = 0
    }

    @Test("Every node of every example gets its swatch, apart from MaterialX's known failures",
          .enabled(if: !files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"))
    // SWIFT: `@MainActor` on the test, not on the suite: on the suite it
    // would make `files` main-actor-only too, and the `.enabled(if:)`
    // trait above, evaluated elsewhere, couldn't read it.
    @MainActor
    func everyExample() async throws {
        let cache = SwatchCache(service: try SwatchService())
        let settings = SwatchSettings(environmentURL: StudioEnvironment.fileURL, viewTransform: .standard,
                                      pixelSize: 96)
        let collected = Collected()
        let library: MXLibrary = try MXLibrary.bundled.get()
        for url in Self.files {
            // With the data library, as the app reads documents: nodes find
            // their nodedefs, which give multi-output nodes their outputs.
            let document = try MXDocument.read(from: url)
            document.setDataLibrary(library)
            let xml: String = try document.xmlString()
            let custom = Set(document.topLevelElements.filter { $0.category == "nodedef" }.map(\.name))
            // The document's level, then each nodegraph's.
            let levels: [String] = [""] + document.nodeGraphs.map(\.path)
            for level in levels {
                let requests: [SwatchRequest] = SwatchPlan.requests(for: try document.graph(at: level), in: document,
                                                                    documentText: xml, customNodeDefs: custom)
                let file: String = url.lastPathComponent
                cache.update(requests, xml: try document.previewXMLString(), settings: settings) { path, swatch in
                    collected.count += 1
                    if case .failed(let message) = swatch {
                        collected.failures[file + " " + path] = message
                    }
                }
                await cache.waitUntilDone()
            }
        }
        print("Swatches of every example: \(collected.count) drawn, \(collected.failures.count) failed")
        for (name, message) in collected.failures where !Self.knownFailures.contains(name) {
            Issue.record("\(name): \(message)")
        }
        for name in Self.knownFailures where collected.failures[name] == nil {
            Issue.record("\(name) works now: remove it from the known failures")
        }
    }
}
