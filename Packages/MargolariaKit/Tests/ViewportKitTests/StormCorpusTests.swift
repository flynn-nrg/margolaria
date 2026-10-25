// StormCorpusTests.swift
//
// Renders every material of every example in MaterialX's
// resources/Materials/Examples with Storm, at a small size, and checks that
// something other than the background was drawn in the middle. Storm
// compiles each material's shader, so this catches materials that fail to
// translate (UsdMtlx) or compile (Storm's MaterialX code generator).
//
// Fetch the examples with scripts/fetch-materialx-examples.sh; without them
// the test is skipped. With VIEWPORT_SNAPSHOT_DIR set, every render is saved.
//
// Introduces (SWIFT): adding tests to a suite from another file with an
// `extension`.

import CoreGraphics
import Foundation
import Testing
import MXKit
import ViewportKit

/// The examples, as in MXKitTests/MXCorpusTests.swift (test targets can't
/// share code, so the lookup is repeated).
enum Examples {
    static let files: [URL] = {
        var root = URL(filePath: #filePath)
        for _ in 0..<5 {
            root = root.deletingLastPathComponent()
        }
        root = root.appending(path: "Vendor/MaterialX/resources/Materials/Examples")
        guard let enumerator = FileManager.default.enumerator(atPath: root.path(percentEncoded: false)) else {
            return []
        }
        var files: [URL] = []
        while let path = enumerator.nextObject() as? String {
            if path.hasSuffix(".mtlx") {
                files.append(root.appending(path: path))
            }
        }
        return files.sorted(by: { $0.path < $1.path })
    }()
}

// SWIFT: An `extension` of the suite type adds these tests to the same
// suite, so they inherit its `.serialized` trait and never render at the
// same time as the other Storm tests.
extension StormRendererTests {
    @Test("Every material in MaterialX's examples renders",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Examples.files)
    func rendersExample(_ url: URL) throws {
        let renderer = try MGStormRenderer(materialXFile: url)
        for path in renderer.materialPaths {
            #expect(renderer.bindMaterial(atPath: path))
            let image: CGImage = try #require(renderer.snapshot(width: 96, height: 96), "\(path)")
            if ProcessInfo.processInfo.environment["VIEWPORT_SNAPSHOT_DIR"] != nil {
                let name: String = url.deletingPathExtension().lastPathComponent + "_" + (path as NSString).lastPathComponent
                _ = try Fixtures.save(image, as: name + ".png")
            }
            // The middle of the image is the sphere: it must differ from the
            // background in the corner.
            let corner = Fixtures.pixel(image, x: 1, y: 1)
            let centre = Fixtures.pixel(image, x: 48, y: 48)
            let difference: Int = abs(Int(centre.r) - Int(corner.r)) + abs(Int(centre.g) - Int(corner.g))
                + abs(Int(centre.b) - Int(corner.b))
            #expect(difference > 6, "\(path): the sphere looks like the background \(corner)")
        }
    }
}

extension StormUpdateTests {
    /// M2c renders the document from MXKit's preview text instead of the
    /// file. For every example, both must show the same materials, and the
    /// same image (within rounding): includes inlined and texture paths
    /// made absolute correctly.
    @Test("Every example renders the same from its preview text as from its file",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Examples.files)
    func previewTextMatchesFile(_ url: URL) throws {
        let fromFile = try MGStormRenderer(materialXFile: url)
        let text: String = try MXDocument.read(from: url).previewXMLString()
        let fromText = try MGStormRenderer(materialXString: text)
        #expect(fromText.materialPaths == fromFile.materialPaths)

        for path in fromFile.materialPaths where fromText.materialPaths.contains(path) {
            #expect(fromFile.bindMaterial(atPath: path))
            #expect(fromText.bindMaterial(atPath: path))
            let a: CGImage = try #require(fromFile.snapshot(width: 96, height: 96))
            let b: CGImage = try #require(fromText.snapshot(width: 96, height: 96))
            // A few points across the sphere.
            for (x, y) in [(48, 48), (35, 35), (60, 40), (48, 65)] {
                let p = Fixtures.pixel(a, x: x, y: y)
                let q = Fixtures.pixel(b, x: x, y: y)
                let difference: Int = abs(Int(p.r) - Int(q.r)) + abs(Int(p.g) - Int(q.g)) + abs(Int(p.b) - Int(q.b))
                #expect(difference <= 6, "\(path) at (\(x), \(y)): file \(p), text \(q)")
            }
        }
    }
}
