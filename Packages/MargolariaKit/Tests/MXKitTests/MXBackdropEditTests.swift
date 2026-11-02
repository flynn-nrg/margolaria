// MXBackdropEditTests.swift
//
// Tests for M4d's edits (MXBackdropEdit.swift): backdrops added, moved,
// resized, annotated and removed, and their `contains` kept current by the
// other edits. M4d's exit criterion, for the document: a backdrop around
// every level of every example round-trips through the file, and undo
// (restoring the copy taken before) gives back the document it was. (The
// canvas moving a backdrop's nodes is in GraphKitTests.)
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import Testing
@testable import MXKit

@Suite("MXBackdropEdit")
struct MXBackdropEditTests {
    /// The nodes of MXNodeGraphEditTests: two textures mixed, read by a shader.
    func document() throws -> MXDocument {
        let document = try MXDocument(xml: MXNodeGraphEditTests.xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        return document
    }

    /// The level's backdrop called `name`.
    func backdrop(_ name: String, in document: MXDocument, at level: String = "") throws -> MXBackdrop {
        try #require(try document.graph(at: level).backdrops.first(where: { $0.name == name }))
    }

    @Test("Added around nodes: written as MaterialX's <backdrop>, read back the same")
    func addAndRoundTrip() throws {
        let document = try document()
        let path: String = try document.addBackdrop(containing: ["dirt", "paint"],
                                                    frame: CGRect(x: 1.5, y: -0.25, width: 2.5, height: 3.75),
                                                    named: "Textures")
        #expect(path == "Textures")
        try document.setNote("Both tiled 4×", ofBackdrop: path)
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        let text: String = try document.xmlString()
        #expect(text.contains(#"<backdrop name="Textures" contains="dirt,paint" xpos="1.5" ypos="-0.25" width="2.5" height="3.75" note="Both tiled 4×" />"#),
                "\(text)")
        let reread = try MXDocument(xml: text)
        reread.setDataLibrary(try MXLibrary.bundled.get())
        #expect(reread.difference(from: document) == nil)
        let read: MXBackdrop = try backdrop("Textures", in: reread)
        #expect(read.contains == ["dirt", "paint"])
        #expect(read.note == "Both tiled 4×")
        #expect(read.position == CGPoint(x: 1.5, y: -0.25))
        #expect(read.size == CGSize(width: 2.5, height: 3.75))
        #expect(!read.isIncluded)
        #expect(try reread.inspectable(at: "Textures") == .backdrop(read))

        // A second one gets a name of its own.
        #expect(try document.addBackdrop(containing: [], frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                                         named: "Textures") == "Textures2")
        // A name taken by a node.
        #expect(try document.addBackdrop(containing: [], frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                                         named: "dirt") == "dirt2")
    }

    @Test("Moved, resized, given other contents and removed; its nodes stay")
    func edit() throws {
        let document = try document()
        let path: String = try document.addBackdrop(containing: ["dirt"], frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        try document.setFrame(CGRect(x: 3, y: 4, width: 5, height: 6), ofBackdrop: path)
        try document.setContents(["dirt", "blend", "SR"], ofBackdrop: path)
        let edited: MXBackdrop = try backdrop(path, in: document)
        #expect(edited.position == CGPoint(x: 3, y: 4))
        #expect(edited.size == CGSize(width: 5, height: 6))
        #expect(edited.contains == ["dirt", "blend", "SR"])

        try document.setNote("", ofBackdrop: path)
        try document.setContents([], ofBackdrop: path)
        #expect(try !document.xmlString().contains("contains="))
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        let nodes: Int = try document.graph(at: "").nodes.count
        try document.removeBackdrop(at: path)
        #expect(try document.graph(at: "").backdrops.isEmpty)
        #expect(try document.graph(at: "").nodes.count == nodes)
    }

    @Test("Refused: framing what isn't there, no size, and anything not a backdrop")
    func refusals() throws {
        let document = try document()
        #expect(throws: MXError.self) {
            try document.addBackdrop(containing: ["nothing"], frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(throws: MXError.self) {
            try document.addBackdrop(containing: ["dirt"], frame: CGRect(x: 0, y: 0, width: 0, height: 1))
        }
        let path: String = try document.addBackdrop(containing: ["dirt"], frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        // Backdrops don't contain backdrops (MaterialX: only typed elements).
        #expect(throws: MXError.self) {
            try document.setContents([path], ofBackdrop: path)
        }
        #expect(throws: MXError.self) {
            try document.setNote("x", ofBackdrop: "dirt")
        }
        #expect(throws: MXError.self) {
            try document.removeBackdrop(at: "dirt")
        }
    }

    @Test("Kept current: deleting, renaming, collapsing and ungrouping what it contains")
    func keptCurrent() throws {
        let document = try document()
        let path: String = try document.addBackdrop(containing: ["uv", "dirt", "paint"],
                                                    frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        try document.removeNode(at: "uv")
        #expect(try backdrop(path, in: document).contains == ["dirt", "paint"])
        try document.renameNode(at: "paint", to: "rust")
        #expect(try backdrop(path, in: document).contains == ["dirt", "rust"])
        // The backdrop itself can be renamed.
        let renamed: String = try document.renameNode(at: path, to: "Textures")
        #expect(try backdrop(renamed, in: document).contains == ["dirt", "rust"])

        // Collapsed: the nodegraph takes their place in it.
        let graph: String = try document.collapse(["dirt", "rust", "blend"])
        #expect(try backdrop(renamed, in: document).contains == [graph])
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
        // Ungrouped: the nodes are back in it.
        let nodes: [String] = try document.ungroup(graph)
        #expect(Set(try backdrop(renamed, in: document).contains) == Set(nodes))
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
    }

    @Test("Inside a nodegraph, framing its nodes and its own inputs and outputs")
    func insideNodeGraph() throws {
        let document = try document()
        let graph: String = try document.collapse(["dirt", "paint", "blend"])
        let level: MXGraph = try document.graph(at: graph)
        let names: [String] = level.nodes.map(\.name) + level.interfaceInputs.map(\.name) + level.outputs.map(\.name)
        let path: String = try document.addBackdrop(containing: names, in: graph,
                                                    frame: CGRect(x: 0, y: 0, width: 6, height: 4))
        #expect(path == graph + "/backdrop")
        #expect(try backdrop("backdrop", in: document, at: graph).contains == names)
        // Renaming the graph's input and output follows.
        let input: String = try #require(level.interfaceInputs.first?.name)
        try document.renameInput(input, of: graph, to: "uv_in")
        let output: String = try #require(level.outputs.first?.name)
        try document.renameOutput(output, of: graph, to: "colour")
        let contains: [String] = try backdrop("backdrop", in: document, at: graph).contains
        #expect(contains.contains("uv_in") && contains.contains("colour"))
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
    }

    @Test("A backdrop another tool wrote without a size, or with names that aren't there")
    func foreign() throws {
        let xml: String = MXNodeGraphEditTests.xml.replacingOccurrences(
            of: "</materialx>",
            with: #"<backdrop name="old" contains="dirt, gone" /></materialx>"#)
        let document = try MXDocument(xml: xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let read: MXBackdrop = try backdrop("old", in: document)
        #expect(read.size == nil)
        #expect(read.position == nil)
        #expect(read.contains == ["dirt", "gone"])
        // The next edit drops the missing name, and the document is valid.
        try document.setPosition(CGPoint(x: 1, y: 1), of: "SR")
        #expect(try backdrop("old", in: document).contains == ["dirt"])
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
    }

    @Test("Every level of every example framed in a backdrop round-trips, and undoes (M4d exit criterion)",
          .enabled(if: Corpus.isAvailable, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Corpus.files)
    func corpus(_ file: String) throws {
        let library = try MXLibrary.bundled.get()
        let url: URL = Corpus.examplesFolder.appending(path: file)
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(library)
        let original: MXDocument = document.copy()
        let issuesBefore: Int = document.validationIssues().count

        var added: [String: MXBackdrop] = [:]
        let levels: [String] = [""] + document.nodeGraphs.map(\.path)
        for level in levels where !document.isIncluded(level) || level.isEmpty {
            let graph: MXGraph = try document.graph(at: level)
            let names: [String] = graph.nodes.filter { !$0.isIncluded }.map(\.name) + graph.outputs.map(\.name)
            let path: String = try document.addBackdrop(containing: names, in: level,
                                                        frame: CGRect(x: -1, y: -1, width: 8, height: 6))
            try document.setNote("Everything in \(level.isEmpty ? "the document" : level)", ofBackdrop: path)
            // Moved, as the canvas moves it.
            try document.setFrame(CGRect(x: 2, y: 3, width: 8, height: 6), ofBackdrop: path)
            added[path] = try #require(try document.graph(at: level).backdrops.first(where: { $0.path == path }))
        }
        #expect(document.validationIssues().count <= issuesBefore, "\(file): \(document.validationIssues())")
        #expect(document.difference(from: original) != nil)

        let reread = try MXDocument.parse(xml: try document.xmlString(), includesFrom: url.deletingLastPathComponent())
        reread.setDataLibrary(library)
        #expect(reread.difference(from: document) == nil, "\(file)")
        for (path, backdrop) in added {
            let level: String = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
            #expect(try reread.graph(at: level).backdrops.first(where: { $0.path == path }) == backdrop, "\(file): \(path)")
        }

        document.restore(from: original)
        if let difference = document.difference(from: original) {
            Issue.record("\(file) after undo: \(difference)")
        }
    }
}
