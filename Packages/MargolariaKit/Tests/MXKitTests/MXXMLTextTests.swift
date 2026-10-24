// MXXMLTextTests.swift
//
// Tests for the XML panel's helpers: syntax tokens, finding an element's
// text, and where the canvas shows an issue's element.

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
}
