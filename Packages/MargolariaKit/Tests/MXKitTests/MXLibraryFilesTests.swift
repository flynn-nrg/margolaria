// MXLibraryFilesTests.swift
//
// Tests for library files (MXLibraryFiles.swift, M4c2): a definition
// written to a file of its own, listed from a folder, and included in a
// document by a relative or absolute path. (M4's exit criterion, with
// Storm, is LibraryRoundTripTests in ViewportKitTests.)
//
// Introduces (SWIFT): nothing new.

import Foundation
import Testing
@testable import MXKit

@Suite("Library files")
struct MXLibraryFilesTests {
    /// A document defining `tint`, with an unused implementation.
    func definingDocument() throws -> (MXDocument, String) {
        let document = try MXDocument(xml: #"<?xml version="1.0"?><materialx version="1.39" />"#)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let node: String = try document.addNode(nodeDef: "ND_multiply_color3", named: "scale")
        let graph: String = try document.collapse([node])
        try document.addOutput(type: "color3", to: graph)
        try document.connect(input: "", on: graph + "/out", to: "scale")
        try document.promote(input: "in2", on: graph + "/scale", as: "tint")
        let made = try document.makeNodeDefinition(from: graph, as: MXNodeDefSpec(node: "tint", name: "ND_tint_color3"))
        return (document, try #require(document.implementation(of: made.nodeDef)))
    }

    /// A new, empty temporary folder, removed by the caller.
    func folder() throws -> URL {
        let url: URL = FileManager.default.temporaryDirectory.appending(path: "MXLibraryFilesTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Paths: relative inside the document's folder, absolute elsewhere")
    func hrefs() {
        let folder = URL(filePath: "/Users/me/project/")
        #expect(MXDocument.href(for: URL(filePath: "/Users/me/project/lib/tint.mtlx"), from: folder) == "lib/tint.mtlx")
        #expect(MXDocument.href(for: URL(filePath: "/Users/me/other/tint.mtlx"), from: folder) == "/Users/me/other/tint.mtlx")
        #expect(MXDocument.href(for: URL(filePath: "/Users/me/other/tint.mtlx"), from: nil) == "/Users/me/other/tint.mtlx")
    }

    @Test("A library file holds the nodedef and its graph; a folder lists it, not the document itself")
    func writeAndList() throws {
        let (document, implementation) = try definingDocument()
        let text: String = try document.libraryText(forDefinitionAt: implementation)
        let library = try MXDocument(xml: text)
        #expect(library.topLevelElements.map(\.category) == ["nodedef", "nodegraph"])
        #expect(!text.contains("xpos"))

        let root: URL = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try text.write(to: root.appending(path: "tint.mtlx"), atomically: true, encoding: .utf8)
        try #"<?xml version="1.0"?><materialx version="1.39" />"#.write(to: root.appending(path: "empty.mtlx"),
                                                                          atomically: true, encoding: .utf8)
        try "not xml".write(to: root.appending(path: "broken.mtlx"), atomically: true, encoding: .utf8)
        #expect(MXLibraryFolders.files(in: root).map(\.name) == ["tint"])
        #expect(MXLibraryFolders.files(in: root, except: root.appending(path: "tint.mtlx")).isEmpty)
    }

    @Test("Included from the document's folder, the include is relative and survives reopening")
    func relativeInclude() throws {
        let (document, implementation) = try definingDocument()
        let root: URL = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "lib"), withIntermediateDirectories: true)
        let file: URL = root.appending(path: "lib/tint.mtlx")
        try document.libraryText(forDefinitionAt: implementation).write(to: file, atomically: true, encoding: .utf8)

        let user = try MXDocument(xml: #"<?xml version="1.0"?><materialx version="1.39" />"#)
        user.setDataLibrary(try MXLibrary.bundled.get())
        try user.include(library: file, from: root)
        try user.addNode(nodeDef: "ND_tint_color3")
        let saved: URL = root.appending(path: "user.mtlx")
        try user.xmlString().write(to: saved, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: saved, encoding: .utf8).contains(#"<xi:include href="lib/tint.mtlx" />"#))

        let reopened = try MXDocument.read(from: saved)
        reopened.setDataLibrary(try MXLibrary.bundled.get())
        #expect(reopened.validationIssues().isEmpty, "\(reopened.validationIssues())")
        #expect(reopened.isIncluded("ND_tint_color3"))
        // Its nodes open the included implementation, read-only.
        let included: String = try #require(reopened.implementation(of: "ND_tint_color3"))
        #expect(reopened.isIncluded(included))
        #expect(MXNodeCatalog(document: reopened).kind(named: "tint") != nil)
    }

    @Test("Refused: a name the document already uses, and a definition using another made in its document")
    func refusals() throws {
        let (document, implementation) = try definingDocument()
        let root: URL = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file: URL = root.appending(path: "tint.mtlx")
        try document.libraryText(forDefinitionAt: implementation).write(to: file, atomically: true, encoding: .utf8)
        // The defining document has its own ND_tint_color3.
        #expect(throws: MXError.self) {
            try document.include(library: file, from: root)
        }

        // A second definition using `tint` inside can't be saved alone.
        let node: String = try document.addNode(nodeDef: "ND_tint_color3", named: "inner")
        let graph: String = try document.collapse([node])
        try document.addOutput(type: "color3", to: graph)
        try document.connect(input: "", on: graph + "/out", to: "inner")
        let made = try document.makeNodeDefinition(from: graph, as: MXNodeDefSpec(node: "outer", name: "ND_outer_color3"))
        let outer: String = try #require(document.implementation(of: made.nodeDef))
        #expect(throws: MXError.self) {
            try document.libraryText(forDefinitionAt: outer)
        }
    }
}
