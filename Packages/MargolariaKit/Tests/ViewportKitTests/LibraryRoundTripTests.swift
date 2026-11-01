// LibraryRoundTripTests.swift
//
// M4's exit criterion (PLAN.md §8.5, M4c2): a node definition built from an
// empty document, through the same calls as the UI, saved to a library,
// used in a second document, renders, validates, and survives saving and
// reopening both.
//
// The first document is built as BuildFromNothingTests builds a material:
// add a node, collapse it into a nodegraph, give the graph an output and
// promote the node's inputs, make the graph a definition. Its file goes to
// a library folder. The second document includes it (as the Library panel
// does when a node of it is added), uses it in a material, and must look
// like the same material built from a plain multiply node.
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import MXKit
import Testing
import ViewportKit

extension StormRendererTests {
    static let emptyDocument: String = #"<?xml version="1.0"?><materialx version="1.39" />"#

    /// A material whose base colour comes from `colorNode`, a node already
    /// in `document`.
    static func addMaterial(reading colorNode: String, to document: MXDocument) throws {
        let shader: String = try document.addNode(nodeDef: "ND_open_pbr_surface_surfaceshader", named: "SR")
        try document.connect(input: "base_color", on: shader, to: colorNode)
        let material: String = try document.addNode(nodeDef: "ND_surfacematerial", named: "M")
        try document.connect(input: "surfaceshader", on: material, to: shader)
    }

    /// Writes `document` to `url` and reads it back, as saving and opening do.
    static func saveAndReopen(_ document: MXDocument, at url: URL) throws -> MXDocument {
        try document.xmlString().write(to: url, atomically: true, encoding: .utf8)
        let reopened = try MXDocument.read(from: url)
        reopened.setDataLibrary(try MXLibrary.bundled.get())
        return reopened
    }

    @Test("A definition built from nothing, saved to a library and used elsewhere, renders and survives saving (M4)")
    func libraryRoundTrip() throws {
        let root: URL = FileManager.default.temporaryDirectory.appending(path: "LibraryRoundTrip-\(UUID())")
        let libraries: URL = root.appending(path: "Libraries")
        let elsewhere: URL = root.appending(path: "Project")
        try FileManager.default.createDirectory(at: libraries, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library: MXLibrary = try MXLibrary.bundled.get()

        // 1. The definition, from an empty document.
        let first = try MXDocument(xml: Self.emptyDocument)
        first.setDataLibrary(library)
        let multiply: String = try first.addNode(nodeDef: "ND_multiply_color3", named: "scale")
        try first.setValue("0.8, 0.2, 0.1", ofInput: "in1", on: multiply)
        try first.setValue("1, 1, 1", ofInput: "in2", on: multiply)
        let graph: String = try first.collapse([multiply])
        let output: String = try first.addOutput(type: "color3", to: graph)
        try first.connect(input: "", on: "\(graph)/\(output)", to: "scale")
        try first.promote(input: "in1", on: "\(graph)/scale", as: "color")
        try first.promote(input: "in2", on: "\(graph)/scale", as: "tint")
        try first.setMetadata(.uiName, to: "Tint", ofInput: "tint", on: graph)
        let made = try first.makeNodeDefinition(from: graph, as: MXNodeDefSpec(node: "tinted", name: "ND_tinted_color3",
                                                                            nodeGroup: "adjustment", version: "1.0"))
        #expect(first.validationIssues().isEmpty, "\(first.validationIssues())")
        let implementation: String = try #require(first.implementation(of: made.nodeDef))

        // 2. Saved to the library; the first document saved and reopened.
        let file: URL = libraries.appending(path: "tinted.mtlx")
        try first.libraryText(forDefinitionAt: implementation).write(to: file, atomically: true, encoding: .utf8)
        let firstReopened: MXDocument = try Self.saveAndReopen(first, at: root.appending(path: "first.mtlx"))
        #expect(firstReopened.validationIssues().isEmpty, "\(firstReopened.validationIssues())")
        #expect(firstReopened.difference(from: first) == nil)

        // The Library panel lists it.
        let listed: [MXLibraryFile] = MXLibraryFolders.files(in: libraries)
        #expect(listed.map(\.name) == ["tinted"])
        #expect(listed.first?.definitions.map(\.name) == ["ND_tinted_color3"])

        // 3. Used in a second document, elsewhere.
        let second = try MXDocument(xml: Self.emptyDocument)
        second.setDataLibrary(library)
        #expect(try second.include(library: file, from: elsewhere) == ["ND_tinted_color3"])
        let node: String = try second.addNode(nodeDef: "ND_tinted_color3", named: "tint1")
        try second.setValue("0.5, 0.5, 1", ofInput: "tint", on: node)
        try Self.addMaterial(reading: node, to: second)
        #expect(second.validationIssues().isEmpty, "\(second.validationIssues())")
        // Including twice adds nothing.
        try second.include(library: file, from: elsewhere)

        let saved: URL = elsewhere.appending(path: "second.mtlx")
        let secondReopened: MXDocument = try Self.saveAndReopen(second, at: saved)
        let text: String = try String(contentsOf: saved, encoding: .utf8)
        #expect(text.contains(#"<xi:include href="\#(file.standardizedFileURL.path(percentEncoded: false))""#), "\(text)")
        #expect(!text.contains("<nodedef"), "the definition stays in its file")
        #expect(secondReopened.validationIssues().isEmpty, "\(secondReopened.validationIssues())")
        // The same text again. (Not the same elements: read from a file, the
        // root keeps the `xmlns:xi` the writer adds for the include.)
        #expect(try secondReopened.xmlString() == second.xmlString())
        // Its definition is read-only here.
        #expect(secondReopened.isIncluded("ND_tinted_color3"))

        // 4. It renders like the same material from a plain multiply.
        let plain = try MXDocument(xml: Self.emptyDocument)
        plain.setDataLibrary(library)
        let reference: String = try plain.addNode(nodeDef: "ND_multiply_color3", named: "scale")
        try plain.setValue("0.8, 0.2, 0.1", ofInput: "in1", on: reference)
        try plain.setValue("0.5, 0.5, 1", ofInput: "in2", on: reference)
        try Self.addMaterial(reading: reference, to: plain)

        let renderer = try MGStormRenderer(materialXString: try plain.viewportXMLString())
        let expected: [String: CGImage] = try Self.renderMaterials(of: plain, with: renderer)
        let actual: [String: CGImage] = try Self.renderMaterials(of: secondReopened, with: renderer)
        // Something was drawn, and it is the same.
        let image: CGImage = try #require(actual["M"])
        let centre = Fixtures.pixel(image, x: 32, y: 32)
        let corner = Fixtures.pixel(image, x: 1, y: 1)
        #expect(abs(Int(centre.r) - Int(corner.r)) + abs(Int(centre.g) - Int(corner.g)) > 6, "\(centre)")
        Self.compare(expected, actual, "the library's node against a plain multiply")
    }
}
