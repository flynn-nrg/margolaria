// MXXMLTextTests.swift
//
// Tests for the XML panel's helpers: syntax tokens, finding an element's
// text and the element at a position (M7b), and where the canvas shows an
// issue's element. MXXMLText scans
// bytes (since M4e); `Reference` below is how it worked before, with
// regular expressions, and the scanning must find the same, in every
// example and in text cut off part-way, as typing leaves it.
//
// Introduces (SWIFT): regex literals (`#/.../#`), `firstMatch`/`matches`,
// substrings sharing their parent's indices.

import Foundation
import Testing
@testable import MXKit

@Suite("MXXMLText")
struct MXXMLTextTests {
    /// The copper fixture as MaterialX writes it.
    func copperXML() throws -> String {
        try MXDocument.read(from: Fixtures.url("brushed_copper.mtlx")).xmlString()
    }

    @Test("Tokens: tag names, attributes, values and comments")
    func tokens() {
        let xml = #"<materialx version="1.39"><!-- note --><image name="tex" type="color3" /></materialx>"#
        // SWIFT: `xml[token.range]` reads the substring a range covers.
        let found: [(MXXMLText.TokenKind, String)] = MXXMLText.tokens(in: xml).map { ($0.kind, String(xml[$0.range])) }
        let expected: [(MXXMLText.TokenKind, String)] = [
            (.tagName, "materialx"), (.attributeName, "version"), (.attributeValue, "\"1.39\""),
            (.comment, "<!-- note -->"),
            (.tagName, "image"), (.attributeName, "name"), (.attributeValue, "\"tex\""),
            (.attributeName, "type"), (.attributeValue, "\"color3\""),
            (.tagName, "materialx"),
        ]
        #expect(found.map(\.1) == expected.map(\.1))
        #expect(found.map(\.0) == expected.map(\.0))
    }

    @Test("Finds elements by path, nested and self-closing")
    func elementRanges() throws {
        let xml: String = try copperXML()
        let graph = try #require(MXXMLText.range(ofElementAt: "NG_copper", in: xml))
        #expect(xml[graph].hasPrefix("<nodegraph name=\"NG_copper\""))
        #expect(xml[graph].hasSuffix("</nodegraph>"))

        let grain = try #require(MXXMLText.range(ofElementAt: "NG_copper/grain", in: xml))
        #expect(xml[grain].hasPrefix("<noise3d name=\"grain\""))
        #expect(xml[grain].hasSuffix("</noise3d>"))

        let input = try #require(MXXMLText.range(ofElementAt: "SR_copper/base_color", in: xml))
        #expect(xml[input].hasPrefix("<input name=\"base_color\""))
        #expect(xml[input].hasSuffix("/>"))

        // `grain` exists, but not at the top level.
        #expect(MXXMLText.range(ofElementAt: "grain", in: xml) == nil)
        #expect(MXXMLText.range(ofElementAt: "", in: xml) == nil)
    }

    @Test("Finds the element around a position, the reverse of finding its text (M7b)")
    func elementPaths() throws {
        let xml: String = try copperXML()
        let document = try MXDocument.read(from: Fixtures.url("brushed_copper.mtlx"))
        // Every element on a canvas level, and every input written there.
        var paths: [String] = []
        for level in ["", "NG_copper"] {
            for node in try document.graph(at: level).nodes {
                paths.append(node.path)
                paths += node.inputs.filter(\.isAuthored).map { node.path + "/" + $0.name }
            }
        }
        #expect(paths.count >= 10, "\(paths)")
        for path in paths {
            let range = try #require(MXXMLText.range(ofElementAt: path, in: xml), "\(path)")
            // Just inside its start tag, and in its end tag (or the end
            // of a self-closing one).
            #expect(MXXMLText.elementPath(at: xml.index(after: range.lowerBound), in: xml) == path)
            #expect(MXXMLText.elementPath(at: xml.index(before: range.upperBound), in: xml) == path)
        }

        // Between a node's inputs: the node.
        let grain = try #require(MXXMLText.range(ofElementAt: "NG_copper/grain", in: xml))
        let firstInput = try #require(xml[grain].range(of: "<input"))
        #expect(MXXMLText.elementPath(at: xml.index(before: firstInput.lowerBound), in: xml) == "NG_copper/grain")
        // Just after it: the nodegraph around it.
        #expect(MXXMLText.elementPath(at: grain.upperBound, in: xml) == "NG_copper")
        // Before every element, in a comment, and at the end: none.
        #expect(MXXMLText.elementPath(at: xml.startIndex, in: xml) == nil)
        let comment = try #require(xml.range(of: "<!-- Test fixture"))
        #expect(MXXMLText.elementPath(at: xml.index(after: comment.lowerBound), in: xml) == nil)
        #expect(MXXMLText.elementPath(at: xml.endIndex, in: xml) == nil)
    }

    @Test("Blank lines between elements are kept through edits, undo and the XML tab (M7d)")
    func blankLines() throws {
        let xml: String = """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <!-- Constants -->
              <constant name="a" type="float" />

              <constant name="b" type="float" />


              <!-- More -->
              <nodegraph name="NG">

                <constant name="c" type="float" />

              </nodegraph>
            </materialx>

            """
        // Each by its path (an end tag's with "end "), or its whole tag for
        // a comment; two in a row count two.
        #expect(MXXMLText.blankLines(in: xml) == ["b": 1, "<!-- More -->": 2, "NG/c": 1, "end NG": 1])
        let document = try MXDocument(xml: xml)
        #expect(try document.xmlString() == xml)

        // A node removed takes its blank line with it; the others stay.
        let original: MXDocument = document.copy()
        try document.removeNode(at: "b")
        #expect(try document.xmlString() == xml.replacingOccurrences(of: "\n  <constant name=\"b\" type=\"float\" />\n", with: ""))
        // A node renamed loses its blank line.
        _ = try document.renameNode(at: "NG/c", to: "d")
        #expect(try !document.xmlString().contains("\n\n    <constant name=\"d\""))
        // Undo puts them back.
        document.restore(from: original)
        #expect(try document.xmlString() == xml)

        // Text applied in the XML tab brings its own.
        try document.replaceContents(withText: xml.replacingOccurrences(of: "\n\n\n  <!-- More -->", with: "\n  <!-- More -->"))
        #expect(MXXMLText.blankLines(in: try document.xmlString()) == ["b": 1, "NG/c": 1, "end NG": 1])
    }

    @Test("XML comments survive reading and writing, and aren't listed as elements")
    func commentsKept() throws {
        let document = try MXDocument.read(from: Fixtures.url("brushed_copper.mtlx"))
        #expect(try document.xmlString().contains("<!-- Test fixture for MXKitTests"))
        #expect(!document.topLevelElements.contains(where: { $0.category == "comment" }))
        #expect(try document.graph().nodes.count == 3)
    }

    @Test("Where the canvas shows an element")
    func canvasLocation() throws {
        let document = try MXDocument.read(from: Fixtures.url("brushed_copper.mtlx"))
        #expect(document.canvasLocation(of: "SR_copper") == ("", "SR_copper"))
        #expect(document.canvasLocation(of: "SR_copper/base_color") == ("", "SR_copper"))
        #expect(document.canvasLocation(of: "NG_copper") == ("", "NG_copper"))
        #expect(document.canvasLocation(of: "NG_copper/grain") == ("NG_copper", "NG_copper/grain"))
        #expect(document.canvasLocation(of: "NG_copper/grain/amplitude") == ("NG_copper", "NG_copper/grain"))
        #expect(document.canvasLocation(of: "") == ("", nil))
    }

    @Test("Scanning finds what the regular expressions did, in every example",
          .enabled(if: Corpus.isAvailable, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Corpus.files)
    func sameAsReference(_ file: String) throws {
        let document = try MXDocument.read(from: Corpus.examplesFolder.appending(path: file))
        let xml: String = try document.xmlString()
        Self.expectSameTokens(in: xml, file)
        // Every node of every level, and an input of each.
        var paths: [String] = document.topLevelElements.map(\.path)
        for level in [""] + document.nodeGraphs.map(\.path) {
            for node in try document.graph(at: level).nodes {
                paths.append(node.path)
                if let input = node.inputs.first {
                    paths.append(node.path + "/" + input.name)
                }
            }
        }
        for path in paths {
            #expect(MXXMLText.range(ofElementAt: path, in: xml) == Reference.range(ofElementAt: path, in: xml),
                    "\(file): \(path)")
        }
    }

    @Test("Scanning finds what the regular expressions did, in half-typed text")
    func sameAsReferenceWhileTyping() throws {
        let xml: String = try copperXML()
            // Text outside ASCII, in a comment and in a value.
            .replacingOccurrences(of: "</materialx>", with: #"<!-- Größe × 2 --><x name="é" note="a=b>" /></materialx>"#)
        // SWIFT: `stride(from:to:by:)` counts from 0 up to the end in steps of 5.
        for count in stride(from: 0, to: xml.count, by: 5) {
            let prefix = String(xml.prefix(count))
            Self.expectSameTokens(in: prefix, "prefix \(count)")
            for path in ["NG_copper", "NG_copper/grain", "SR_copper/base_color", "x"] {
                #expect(MXXMLText.range(ofElementAt: path, in: prefix) == Reference.range(ofElementAt: path, in: prefix),
                        "prefix \(count): \(path)")
            }
        }
        // Tags broken in other ways.
        for text in ["<a b=\"1>", "<a <b c=\"d\">", "<!-- <a> -->", "<!-- open <a name=\"x\">", "<a name =  \"y\"/>", "a=\"b\">"] {
            Self.expectSameTokens(in: text, text)
        }
    }

    /// Expects MXXMLText's tokens to be the reference's.
    static func expectSameTokens(in xml: String, _ label: String) {
        let found = MXXMLText.tokens(in: xml).map { "\($0.kind) \(xml[$0.range])" }
        let expected = Reference.tokens(in: xml).map { "\($0.kind) \(xml[$0.range])" }
        #expect(found == expected, "\(label)")
    }

    /// MXXMLText as it was until M4e, with regular expressions: slower, but
    /// short enough to see it is right.
    enum Reference {
        // SWIFT: A *regex literal*, written between slashes, is checked by
        // the compiler like any other code: a typo in it is a compile
        // error, not a run-time one. `#/.../#` (with hashes) allows "/"
        // inside. The `(...)` groups become fields of each match's output
        // tuple: `.1`, `.2`, ...
        //
        // SWIFT: These are computed properties (`static var ... { }`),
        // built on each use, rather than `static let`s. `Regex` isn't
        // `Sendable`, so Swift 6 rejects a shared constant of it (as for
        // CTFont, see LayerGraphView.swift). The compiler has already
        // parsed the literal, so building one is cheap.

        /// A comment, or any other tag from `<` to `>`.
        static var tagOrComment: Regex<Substring> { #/<!--[\s\S]*?-->|<[^>]*>/# }
        /// The name at the start of a tag: `<name`, `</name`, `<?name`.
        static var tagName: Regex<(Substring, Substring)> { #/^<[/?]?([\w:.-]+)/# }
        /// `name="value"` inside a tag.
        static var attribute: Regex<(Substring, Substring, Substring)> { #/([\w:.-]+)\s*=\s*("[^"]*")/# }
        /// The `name` attribute inside a tag.
        static var nameAttribute: Regex<(Substring, Substring)> { #/\sname\s*=\s*"([^"]*)"/# }

        static func tokens(in xml: String) -> [MXXMLText.Token] {
            var tokens: [MXXMLText.Token] = []
            // SWIFT: `matches(of:)` returns every non-overlapping match.
            // Each match's `.range` is a range in `xml`; `.0` is the
            // matched text.
            for match in xml.matches(of: tagOrComment) {
                let tag: Substring = match.0
                if tag.hasPrefix("<!--") {
                    tokens.append(MXXMLText.Token(kind: .comment, range: match.range))
                    continue
                }
                // SWIFT: A Substring shares its parent's storage *and
                // indices*, so ranges found inside `tag` are valid ranges
                // in `xml` too.
                if let name = tag.firstMatch(of: tagName) {
                    tokens.append(MXXMLText.Token(kind: .tagName, range: name.1.startIndex..<name.1.endIndex))
                }
                for pair in tag.matches(of: attribute) {
                    tokens.append(MXXMLText.Token(kind: .attributeName, range: pair.1.startIndex..<pair.1.endIndex))
                    tokens.append(MXXMLText.Token(kind: .attributeValue, range: pair.2.startIndex..<pair.2.endIndex))
                }
            }
            return tokens
        }

        static func range(ofElementAt path: String, in xml: String) -> Range<String.Index>? {
            let target: [Substring] = path.split(separator: "/")
            guard !target.isEmpty else {
                return nil
            }
            var open: [Substring?] = []
            var start: String.Index? = nil
            var startDepth: Int = 0
            for match in xml.matches(of: tagOrComment) {
                let tag: Substring = match.0
                if tag.hasPrefix("<!--") || tag.hasPrefix("<?") {
                    continue
                }
                if tag.hasPrefix("</") {
                    _ = open.popLast()
                    if let begin = start, open.count == startDepth {
                        return begin..<match.range.upperBound
                    }
                    continue
                }
                let name: Substring? = tag.firstMatch(of: nameAttribute).map { $0.1 }
                let selfClosing: Bool = tag.hasSuffix("/>")
                open.append(name)
                if start == nil, open.compactMap({ $0 }) == target, name != nil {
                    if selfClosing {
                        return match.range
                    }
                    start = match.range.lowerBound
                    startDepth = open.count - 1
                }
                if selfClosing {
                    _ = open.popLast()
                }
            }
            return nil
        }
    }
}
