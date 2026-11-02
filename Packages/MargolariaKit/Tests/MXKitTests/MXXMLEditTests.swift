// MXXMLEditTests.swift
//
// Tests for M4e's text edits (MXXMLEdit.swift): the XML tab's text checked
// and applied. M4e's exit criterion, for the document: applying every
// example's own text changes nothing; an applied edit undoes in one step
// (the copy the app keeps); text that can't be read is never applied.
//
// Introduces (SWIFT): `stride(from:to:by:)`.

import CoreGraphics
import Foundation
import Testing
@testable import MXKit

@Suite("MXXMLEdit")
struct MXXMLEditTests {
    /// The nodes of MXNodeGraphEditTests: two textures mixed, read by a shader.
    func document() throws -> MXDocument {
        let document = try MXDocument(xml: MXNodeGraphEditTests.xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        return document
    }

    @Test("Applying every example's own text changes nothing (M4e exit criterion)",
          .enabled(if: Corpus.isAvailable, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Corpus.files)
    func corpus(_ file: String) throws {
        let document = try MXDocument.read(from: Corpus.examplesFolder.appending(path: file))
        document.setDataLibrary(try MXLibrary.bundled.get())
        let original: MXDocument = document.copy()
        let text: String = try document.xmlString()
        let preview: String = try document.previewXMLString()
        let issues: [MXIssue] = document.issues()

        #expect(document.check(text: text).canApply, "\(file)")
        try document.replaceContents(withText: text)
        #expect(document.difference(from: original) == nil, "\(file)")
        // The same file written: includes as includes, ...
        #expect(try document.xmlString() == text, "\(file)")
        // ... the same texture paths, ...
        #expect(try document.previewXMLString() == preview, "\(file)")
        // ... and the same problems, if any.
        #expect(document.issues() == issues, "\(file)")
        for element in document.topLevelElements {
            #expect(document.isIncluded(element.path) == original.isIncluded(element.path), "\(file): \(element.path)")
        }
    }

    @Test("Applied: the document is the text's, and putting the copy back undoes it")
    func applyAndUndo() throws {
        let document = try document()
        let before: MXDocument = document.copy()
        let text: String = try document.xmlString()
            .replacingOccurrences(of: #"name="dirt""#, with: #"name="grime""#)
            .replacingOccurrences(of: #"nodename="dirt""#, with: #"nodename="grime""#)
        #expect(document.check(text: text) == .valid)

        try document.replaceContents(withText: text)
        #expect(try document.graph().node(named: "grime") != nil)
        #expect(try document.graph().node(named: "dirt") == nil)
        #expect(document.hasDataLibrary)
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        // What the app's undo does: one copy, put back.
        document.restore(from: before)
        #expect(document.difference(from: before) == nil)
    }

    @Test("Half-typed text is never applied: every unfinished prefix is unreadable, and leaves the document alone")
    func neverHalfTyped() throws {
        let document = try document()
        let text: String = try document.xmlString()
        let before: MXDocument = document.copy()
        // The root's end tag, and anything before it, is unfinished text.
        let end: Int = try #require(text.range(of: "</materialx>")).lowerBound.utf16Offset(in: text)
        // SWIFT: `stride(from:to:by:)` counts from 0 up to (not including)
        // `end` in steps of 7, like `for (i = 0; i < end; i += 7)`.
        for offset in stride(from: 0, to: end, by: 7) {
            let prefix = String(text.utf16.prefix(offset))!
            let check: MXTextCheck = document.check(text: prefix)
            #expect(!check.canApply, "applicable at \(offset): \(prefix.suffix(40))")
            #expect(throws: MXError.self) {
                try document.replaceContents(withText: prefix)
            }
        }
        #expect(document.difference(from: before) == nil)
    }

    @Test("Unreadable text says where: the line and column of the first malformed tag")
    func whereUnreadable() throws {
        let document = try document()
        let text = """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <constant name="c" type="float">
                <input name="value" type="float" value="1" >
              </constant>
            </materialx>
            """
        guard case .unreadable(let problem) = document.check(text: text) else {
            Issue.record("readable")
            return
        }
        #expect(!problem.message.isEmpty)
        // The end tag that doesn't match `<input ...>`.
        #expect(problem.line == 5, "\(problem)")
        #expect(problem.column != nil)
        #expect(problem.message.contains("mismatch"), "\(problem)")

        // Well-formed, but not a MaterialX document: unreadable, nowhere in particular.
        let missingInclude: String = MXNodeGraphEditTests.xml.replacingOccurrences(
            of: "</materialx>", with: #"<xi:include href="nowhere.mtlx" /></materialx>"#)
        guard case .unreadable(let missing) = document.check(text: missingInclude) else {
            Issue.record("a missing include read")
            return
        }
        #expect(missing.line == nil, "\(missing)")
    }

    @Test("Text between tags (a `>` typed twice) is unreadable, and says where")
    func strayText() throws {
        let document = try document()
        let text: String = try document.xmlString()
        let before: MXDocument = document.copy()
        // After the root's start tag, and inside a node: MaterialX would
        // make an element without a category of the first, and drop the second.
        let root: String = text.replacingOccurrences(of: #"version="1.39">"#, with: #"version="1.39">>"#)
        let node: String = text.replacingOccurrences(of: "</image>", with: "x</image>")
        for stray in [root, node] {
            #expect(stray != text)
            guard case .unreadable(let problem) = document.check(text: stray) else {
                Issue.record("readable: \(stray)")
                continue
            }
            #expect(problem.message.contains("Text between tags"), "\(problem)")
            #expect(problem.line != nil)
            #expect(throws: MXError.self) {
                try document.replaceContents(withText: stray)
            }
        }
        #expect(document.difference(from: before) == nil)
        // Layout and comments are fine.
        #expect(document.check(text: text.replacingOccurrences(of: "\n", with: "\n\n  <!-- note -->\n")).canApply)
    }

    @Test("Readable text with problems can be applied, and says which line the first is on")
    func readableWithIssues() throws {
        let document = try document()
        let text: String = try document.xmlString()
            .replacingOccurrences(of: #"nodename="dirt""#, with: #"nodename="nothing""#)
        guard case .issues(let count, let first) = document.check(text: text) else {
            Issue.record("no issues found in \(text)")
            return
        }
        #expect(count >= 1)
        let line: Int = try #require(first.line)
        let lines: [Substring] = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[line - 1].contains("<"), "\(first): \(lines[line - 1])")
        #expect(document.check(text: text).canApply)
        try document.replaceContents(withText: text)
        #expect(!document.issues().isEmpty)
    }

    @Test("Text of a document with includes: they are found next to its file, and stay included")
    func includes() throws {
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "MXXMLEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "lib"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <image name="shared_tex" type="color3">
                <input name="file" type="filename" value="wood.png" />
              </image>
            </materialx>
            """.write(to: folder.appending(path: "lib/shared.mtlx"), atomically: true, encoding: .utf8)
        try """
            <?xml version="1.0"?>
            <materialx version="1.39" xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="lib/shared.mtlx" />
              <image name="own_tex" type="float">
                <input name="file" type="filename" value="rough.png" />
              </image>
            </materialx>
            """.write(to: folder.appending(path: "main.mtlx"), atomically: true, encoding: .utf8)

        let document = try MXDocument.read(from: folder.appending(path: "main.mtlx"))
        document.setDataLibrary(try MXLibrary.bundled.get())
        let preview: String = try document.previewXMLString()
        let text: String = try document.xmlString().replacingOccurrences(of: "rough.png", with: "smooth.png")
        try document.replaceContents(withText: text)
        #expect(document.isIncluded("shared_tex"))
        #expect(!document.isIncluded("own_tex"))
        #expect(try document.xmlString() == text)
        // Texture paths resolve against the same folders as before.
        #expect(try document.previewXMLString() == preview.replacingOccurrences(of: "rough.png", with: "smooth.png"))
    }
}
