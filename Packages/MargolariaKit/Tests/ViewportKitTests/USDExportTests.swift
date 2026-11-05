// USDExportTests.swift
//
// M5b's exit criterion (PLAN.md §8.6): every example exported as USD and
// read back by OpenUSD gives the same materials as UsdMtlx reading the
// .mtlx (same prims, connections and values), with no reference to the
// .mtlx and no include, and Storm renders the exported file like the
// document.
//
// "The same materials" is checked on MGUSDExporter.shadingOfFile(at:): every
// prim's type, every attribute's value and connections, of the exported
// file against the .mtlx opened by UsdMtlx. Documents that define nodes of
// their own export those nodes expanded (MXDocument.usdXMLString), so
// their reference is UsdMtlx reading that text instead.
//
// Storm compiles a shader per material and file, so this takes a few
// minutes.
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import MXKit
import Testing
import ViewportKit

extension StormRendererTests {
    /// Exports `document`'s materials as USD to `url`.
    static func exportUSD(_ document: MXDocument, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try MGUSDExporter.exportMaterials(fromMaterialXString: try document.usdXMLString(), to: url)
    }

    /// Records an issue unless the USD file at `url` stands alone: OpenUSD
    /// reads no other layer for it (no reference to a .mtlx, no sublayer),
    /// and no shader is a node `document` defines itself.
    static func expectStandsAlone(_ url: URL, defining nodeDefs: Set<String> = [], _ label: String) throws {
        let layers: [String] = MGUSDExporter.layersUsedByFile(at: url)
        #expect(layers.count == 1 && layers.first.map { $0.hasSuffix(url.lastPathComponent) } == true,
                "\(label): reads \(layers)")
        for path in MGUSDExporter.assetPathsInFile(at: url) {
            #expect(!path.hasSuffix(".mtlx"), "\(label): refers to \(path)")
        }
        let shading: [String: String] = try MGUSDExporter.shadingOfFile(at: url)
        for (path, value) in shading where path.hasSuffix(".info:id") {
            #expect(!nodeDefs.contains(value), "\(label): \(path) is the document's own \(value)")
        }
    }

    /// Records an issue for each difference between two files' shading
    /// (MGUSDExporter.shadingOfFile(at:)), the first ten at most.
    ///
    /// With `allowingExportChanges`, against UsdMtlx reading the document's
    /// own file, two differences are expected and allowed, both made on
    /// purpose (see isExportChange).
    static func compareShading(_ expected: [String: String], _ actual: [String: String], _ label: String,
                               allowingExportChanges: Bool = false) {
        // SWIFT: `Set(...).union(...)` combines both files' paths; `sorted()`
        // gives the differences in a stable order.
        let paths: [String] = Set(expected.keys).union(actual.keys).sorted()
        let differences: [String] = paths.filter {
            expected[$0] != actual[$0] && !(allowingExportChanges && isExportChange(at: $0, expected, actual))
        }.map {
            "\($0): \(expected[$0] ?? "missing") expected, \(actual[$0] ?? "missing") exported"
        }
        #expect(differences.isEmpty,
                "\(label): \(differences.count) differences\n\(differences.prefix(10).joined(separator: "\n"))")
    }

    /// True if the difference at `path` between UsdMtlx reading a
    /// document's file (`expected`) and its export (`actual`) is one export
    /// makes on purpose:
    ///
    ///  - a prim outside /MaterialX, which isn't exported: for documents
    ///    with looks, UsdMtlx's /ModelRoot, assigning the materials to
    ///    geometry, which the materials-only file leaves to the scene;
    ///  - an input connected to its nodegraph's input in the file, holding
    ///    that input's value in the export: the viewport's text gives a
    ///    file read through a graph's input to the image itself, with its
    ///    colour space, which Storm ignores otherwise (M4b, PLAN.md §8.2).
    static func isExportChange(at path: String, _ expected: [String: String], _ actual: [String: String]) -> Bool {
        if !path.hasPrefix("/MaterialX/") && path != "/MaterialX" && actual[path] == nil {
            return true
        }
        // A connection alone is described as " -> " and its path.
        guard let connection = expected[path], connection.hasPrefix(" -> "), let value = actual[path] else {
            return false
        }
        return expected[String(connection.dropFirst(4))] == value
    }

    /// Every material of the USD file at `url`, rendered by Storm, by name.
    static func renderMaterials(ofUSDFile url: URL) throws -> [String: CGImage] {
        // The renderer references the file's /MaterialX, as it does a .mtlx.
        let renderer = try MGStormRenderer(materialXFile: url)
        var images: [String: CGImage] = [:]
        for path in renderer.materialPaths {
            #expect(renderer.bindMaterial(atPath: path))
            images[(path as NSString).lastPathComponent] = renderer.snapshot(width: 64, height: 64,
                                                                            viewTransform: untoneMapped)
        }
        return images
    }

    /// A new temporary folder, for one test's files.
    static func exportFolder(_ name: String) throws -> URL {
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("Every example exports as USD: UsdMtlx's materials, standing alone, rendering like the document (M5b)",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Examples.files)
    func exportsExample(_ url: URL) throws {
        let folder: URL = try Self.exportFolder("USDExport")
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let name: String = url.deletingPathExtension().lastPathComponent

        // Both formats, which must hold the same.
        let usda: URL = folder.appending(path: "\(name).usda")
        let usdc: URL = folder.appending(path: "\(name).usdc")
        try Self.exportUSD(document, to: usda)
        try Self.exportUSD(document, to: usdc)
        try Self.expectStandsAlone(usda, name)
        try Self.expectStandsAlone(usdc, name)
        let exported: [String: String] = try MGUSDExporter.shadingOfFile(at: usda)
        Self.compareShading(exported, try MGUSDExporter.shadingOfFile(at: usdc), "\(name).usdc")

        // UsdMtlx reading the .mtlx; or, for a document with definitions
        // of its own (simple_hair), reading the text with them expanded.
        let text: String = try document.usdXMLString()
        if text == (try document.viewportXMLString()) {
            Self.compareShading(try MGUSDExporter.shadingOfFile(at: url), exported, name, allowingExportChanges: true)
        } else {
            let expanded: URL = folder.appending(path: "\(name).expanded.mtlx")
            try text.write(to: expanded, atomically: true, encoding: .utf8)
            Self.compareShading(try MGUSDExporter.shadingOfFile(at: expanded), exported, "\(name) expanded")
        }

        // Storm: the exported file against the document's viewport.
        let renderer = try MGStormRenderer(materialXString: try document.viewportXMLString())
        Self.compare(try Self.renderMaterials(of: document, with: renderer), try Self.renderMaterials(ofUSDFile: usda),
                     "\(name).usda")
    }

    @Test("Definitions made in a document export expanded: every example's nodegraphs made into definitions (M5b)",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Examples.files)
    func exportsDefinitions(_ url: URL) throws {
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        // As DefinitionRenderTests makes them.
        let graphs: [MXNode] = try document.graph(at: "").nodes
            .filter { $0.isNodeGraph && !$0.isIncluded && $0.nodeDefName == nil && !$0.outputs.isEmpty }
        guard !graphs.isEmpty else {
            return
        }
        var nodeDefs: Set<String> = []
        for graph in graphs {
            var spec = MXNodeDefSpec.suggested(for: graph)
            spec.node = "mg_" + spec.node
            spec.name = MXNodeDefSpec.nodeDefName(for: spec.node, outputs: graph.outputs)
            try document.makeNodeDefinition(from: graph.path, as: spec)
            nodeDefs.insert(spec.name)
        }
        let folder: URL = try Self.exportFolder("USDExportDefinitions")
        defer { try? FileManager.default.removeItem(at: folder) }
        let name: String = url.deletingPathExtension().lastPathComponent
        let usda: URL = folder.appending(path: "\(name).usda")
        try Self.exportUSD(document, to: usda)
        try Self.expectStandsAlone(usda, defining: nodeDefs, "\(name) with \(graphs.count) definitions")
        let renderer = try MGStormRenderer(materialXString: try document.viewportXMLString())
        Self.compare(try Self.renderMaterials(of: document, with: renderer), try Self.renderMaterials(ofUSDFile: usda),
                     "\(name) with \(graphs.count) definitions")
    }

    @Test("A definition using another, reading a texture beside the file, exports expanded with a relative path (M5b)",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"))
    func exportsNestedDefinitions() throws {
        let folder: URL = try Self.exportFolder("USDExportNested")
        defer { try? FileManager.default.removeItem(at: folder) }
        // The texture in a folder beside the exported file.
        let textures: URL = folder.appending(path: "textures")
        try FileManager.default.createDirectory(at: textures, withIntermediateDirectories: true)
        let texture: URL = textures.appending(path: "brick_base_gray.jpg")
        try FileManager.default.copyItem(at: URL(filePath: USDZSpikeTests.brick), to: texture)

        // A tint (a multiply) made a definition, then the texture and a
        // tint node made a second definition, which the material reads.
        let document = try MXDocument(xml: Self.emptyDocument)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let image: String = try document.addNode(nodeDef: "ND_image_color3", named: "tex")
        try document.setValue(texture.path(percentEncoded: false), ofInput: "file", on: image)
        try document.setColorSpace("srgb_texture", ofInput: "file", on: image)
        let multiply: String = try document.addNode(nodeDef: "ND_multiply_color3", named: "tint")
        try document.connect(input: "in1", on: multiply, to: image)
        try document.setValue("0.9, 0.5, 0.3", ofInput: "in2", on: multiply)
        try Self.addMaterial(reading: multiply, to: document)
        let tintGraph: String = try document.collapse([multiply])
        let tint = try document.makeNodeDefinition(from: tintGraph, as: MXNodeDefSpec(
            node: "tint", name: "ND_tint_color3", nodeGroup: "adjustment", version: "1.0"))
        let instance: String = try #require(tint.instance)
        let bricksGraph: String = try document.collapse([image, instance])
        _ = try document.makeNodeDefinition(from: bricksGraph, as: MXNodeDefSpec(
            node: "tinted_bricks", name: "ND_tinted_bricks_color3", nodeGroup: "texture2d", version: "1.0"))
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        let usda: URL = folder.appending(path: "bricks.usda")
        try Self.exportUSD(document, to: usda)
        try Self.expectStandsAlone(usda, defining: ["ND_tint_color3", "ND_tinted_bricks_color3"], "nested")
        // Twice: UsdMtlx writes each nodegraph inside its material and
        // under /MaterialX/NodeGraphs.
        #expect(Set(MGUSDExporter.assetPathsInFile(at: usda)) == ["./textures/brick_base_gray.jpg"])
        let renderer = try MGStormRenderer(materialXString: try document.viewportXMLString())
        Self.compare(try Self.renderMaterials(of: document, with: renderer), try Self.renderMaterials(ofUSDFile: usda),
                     "nested")

        // Exported elsewhere, the texture keeps its absolute path.
        let elsewhere: URL = try Self.exportFolder("USDExportElsewhere")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let away: URL = elsewhere.appending(path: "bricks.usda")
        try Self.exportUSD(document, to: away)
        let paths: [String] = MGUSDExporter.assetPathsInFile(at: away)
        #expect(!paths.isEmpty && paths.allSatisfy { $0.hasPrefix("/") && $0.hasSuffix("textures/brick_base_gray.jpg") },
                "\(paths)")
    }
}
