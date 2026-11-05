// USDZSpikeTests.swift
//
// Spike M5a (docs/spikes/M5a-usdz.md): exports every example as USD and
// USDZ with MGUSDExporter, for opening in Quick Look and Reality Composer
// Pro by hand, and writes what OpenUSD's validators say about each file.
// Only with M5A_EXPORT_DIR set (where the files go); skipped otherwise.
//
// Each example is exported from two texts, to see which of the viewport's
// Storm workarounds other readers need:
//   <name>.preview.*   MXKit's preview text (includes inlined, absolute
//                      texture paths), nothing else changed;
//   <name>.viewport.*  the viewport's text: nodegraphs Storm misdraws
//                      ungrouped, file colour spaces moved onto images,
//                      definition nodes expanded (§8.2).
// and the USDZ is packaged both plainly and the ARKit way.
//
// Introduces (SWIFT): nothing new.

import Foundation
import MXKit
import Testing
import ViewportKit

@Suite("Spike M5a: USDZ export", .serialized)
struct USDZSpikeTests {
    static let folder: URL? = ProcessInfo.processInfo.environment["M5A_EXPORT_DIR"].map { URL(filePath: $0) }

    @Test("Every example exports", .enabled(if: folder != nil && !Examples.files.isEmpty), arguments: Examples.files)
    func export(_ url: URL) throws {
        let folder: URL = try #require(Self.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let name: String = url.deletingPathExtension().lastPathComponent
        let texts: [(String, String)] = [("preview", try document.previewXMLString()),
                                         ("viewport", try document.viewportXMLString())]
        var report: String = "# \(name)\n"
        for (kind, text) in texts {
            let files: [(String, MGUSDZPackaging)] = [("usda", .plain), ("usdz", .plain), ("arkit.usdz", .arKit)]
            for (suffix, packaging) in files {
                let out: URL = folder.appending(path: "\(name).\(kind).\(suffix)")
                try? FileManager.default.removeItem(at: out)
                do {
                    try MGUSDExporter.exportMaterialXString(text, to: out, previewSphere: true, packaging: packaging)
                    report += "\n## \(out.lastPathComponent): written\n"
                    for path in MGUSDExporter.assetPathsInFile(at: out) {
                        report += "- asset: \(path)\n"
                    }
                    for message in MGUSDExporter.validationMessagesForFile(at: out) {
                        report += "- \(message)\n"
                    }
                } catch {
                    report += "\n## \(out.lastPathComponent): FAILED\n\(error.localizedDescription)\n"
                }
            }
        }
        try report.write(to: folder.appending(path: "\(name).report.md"), atomically: true, encoding: .utf8)
    }

    /// A brick texture from MaterialX's resources.
    static let brick: String = {
        var root = URL(filePath: #filePath)
        for _ in 0..<5 {
            root = root.deletingLastPathComponent()
        }
        return root.appending(path: "Vendor/MaterialX/resources/Images/brick_base_gray.jpg").path(percentEncoded: false)
    }()

    /// The shapes M4's edits make and the viewport's text changes for Storm
    /// (§8.2), which none of the examples has: a nodegraph read by a node
    /// that isn't a shader, a file read through a graph input with a colour
    /// space, a definition made in the document whose implementation reads
    /// a file.
    @Test("M4's shapes export", .enabled(if: folder != nil && !Examples.files.isEmpty))
    func editedShapes() throws {
        let folder: URL = try #require(Self.folder)
        let library: MXLibrary = try MXLibrary.bundled.get()
        func start() throws -> (MXDocument, String) {
            let document = try MXDocument(xml: StormRendererTests.emptyDocument)
            document.setDataLibrary(library)
            let image: String = try document.addNode(nodeDef: "ND_image_color3", named: "tex")
            try document.setValue(Self.brick, ofInput: "file", on: image)
            try document.setColorSpace("srgb_texture", ofInput: "file", on: image)
            return (document, image)
        }
        var cases: [(String, MXDocument)] = []

        // A nodegraph read by a multiply, which the shader reads.
        do {
            let (document, image) = try start()
            let multiply: String = try document.addNode(nodeDef: "ND_multiply_color3", named: "darken")
            try document.connect(input: "in1", on: multiply, to: image)
            try document.setValue("0.6, 0.6, 0.6", ofInput: "in2", on: multiply)
            try StormRendererTests.addMaterial(reading: multiply, to: document)
            _ = try document.collapse([image])
            cases.append(("m4_collapsed_read_by_multiply", document))
        }
        // The image's file promoted to the graph's interface, tagged sRGB.
        do {
            let (document, image) = try start()
            try StormRendererTests.addMaterial(reading: image, to: document)
            let graph: String = try document.collapse([image])
            _ = try document.promote(input: "file", on: "\(graph)/\(image)", as: "file")
            cases.append(("m4_promoted_file", document))
        }
        // The graph made a definition; the material reads a node of it.
        do {
            let (document, image) = try start()
            try StormRendererTests.addMaterial(reading: image, to: document)
            let graph: String = try document.collapse([image])
            _ = try document.promote(input: "file", on: "\(graph)/\(image)", as: "file")
            _ = try document.makeNodeDefinition(from: graph, as: MXNodeDefSpec(node: "bricks", name: "ND_bricks_color3",
                                                                              nodeGroup: "texture2d", version: "1.0"))
            cases.append(("m4_definition", document))
        }

        for (name, document) in cases {
            #expect(document.validationIssues().isEmpty, "\(name): \(document.validationIssues())")
            for (kind, text) in [("preview", try document.previewXMLString()), ("viewport", try document.viewportXMLString())] {
                let out: URL = folder.appending(path: "\(name).\(kind).arkit.usdz")
                try? FileManager.default.removeItem(at: out)
                do {
                    try MGUSDExporter.exportMaterialXString(text, to: out, previewSphere: true, packaging: .arKit)
                } catch {
                    try "\(error.localizedDescription)\n".write(to: folder.appending(path: "\(name).\(kind).failed.txt"),
                                                                   atomically: true, encoding: .utf8)
                }
            }
        }
    }
}
