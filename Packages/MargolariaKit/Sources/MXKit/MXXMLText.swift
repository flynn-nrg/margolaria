// MXXMLText.swift
//
// Working with a document's XML as text, for the XML panel: where the tag
// names, attribute names, values and comments are (to colour them), and
// where a given element is (to highlight the node selected on the canvas).
//
// This reads the text MaterialX writes (MXDocument.xmlString), which is
// regular: one element per tag, attributes in double quotes, no CDATA. It is
// a highlighter, not an XML parser; MaterialX does the real parsing.
//
// Introduces (SWIFT): regex literals (`#/.../#`), `firstMatch`/`matches`,
// `Range<String.Index>`, substrings sharing their parent's indices,
// `popLast()`, `compactMap`.

import Foundation

/// Text-level views of MaterialX XML.
public enum MXXMLText {
    /// What a highlighted piece of XML is.
    public enum TokenKind: Sendable {
        /// An element's tag name: `open_pbr_surface`, `nodegraph`, `xi:include`.
        case tagName
        /// An attribute's name: `name`, `type`, `nodename`.
        case attributeName
        /// An attribute's value, quotes included.
        case attributeValue
        /// A whole `<!-- ... -->` comment.
        case comment
    }

    /// One highlighted piece of the text.
    public struct Token: Sendable {
        public let kind: TokenKind
        /// Where it is in the string it came from.
        ///
        /// SWIFT: String positions are `String.Index` values, not integers,
        /// because characters have different sizes in UTF-8. A
        /// `Range<String.Index>` only makes sense for the string it came
        /// from. AppKit wants `NSRange` (UTF-16 offsets); convert with
        /// `NSRange(range, in: string)`.
        public let range: Range<String.Index>
    }

    // SWIFT: A *regex literal*, written between slashes, is checked by the
    // compiler like any other code: a typo in it is a compile error, not a
    // run-time one. `#/.../#` (with hashes) allows "/" inside. The `(...)`
    // groups become fields of each match's output tuple: `.1`, `.2`, ...
    //
    // SWIFT: These are computed properties (`static var ... { }`), built
    // on each use, rather than `static let`s. `Regex` isn't `Sendable`, so
    // Swift 6 rejects a shared constant of it (as for CTFont, see
    // LayerGraphView.swift). The compiler has already parsed the literal,
    // so building one is cheap.

    /// A comment, or any other tag from `<` to `>`.
    private static var tagOrComment: Regex<Substring> { #/<!--[\s\S]*?-->|<[^>]*>/# }
    /// The name at the start of a tag: `<name`, `</name`, `<?name`.
    private static var tagName: Regex<(Substring, Substring)> { #/^<[/?]?([\w:.-]+)/# }
    /// `name="value"` inside a tag.
    private static var attribute: Regex<(Substring, Substring, Substring)> { #/([\w:.-]+)\s*=\s*("[^"]*")/# }
    /// The `name` attribute inside a tag.
    private static var nameAttribute: Regex<(Substring, Substring)> { #/\sname\s*=\s*"([^"]*)"/# }

    /// Every tag name, attribute name, attribute value and comment in `xml`,
    /// in order.
    public static func tokens(in xml: String) -> [Token] {
        var tokens: [Token] = []
        // SWIFT: `matches(of:)` returns every non-overlapping match. Each
        // match's `.range` is a range in `xml`; `.0` is the matched text.
        for match in xml.matches(of: tagOrComment) {
            let tag: Substring = match.0
            if tag.hasPrefix("<!--") {
                tokens.append(Token(kind: .comment, range: match.range))
                continue
            }
            // SWIFT: A Substring shares its parent's storage *and indices*,
            // so ranges found inside `tag` are valid ranges in `xml` too.
            if let name = tag.firstMatch(of: tagName) {
                tokens.append(Token(kind: .tagName, range: name.1.startIndex..<name.1.endIndex))
            }
            for pair in tag.matches(of: attribute) {
                tokens.append(Token(kind: .attributeName, range: pair.1.startIndex..<pair.1.endIndex))
                tokens.append(Token(kind: .attributeValue, range: pair.2.startIndex..<pair.2.endIndex))
            }
        }
        return tokens
    }

    /// Where the element at `path` (such as "NG_copper/grain") is in `xml`:
    /// from its start tag to the end of its end tag. Nil if it isn't there.
    ///
    /// The path is the element names from the root, as MaterialX builds it;
    /// elements without a `name` (the root `<materialx>`) don't count.
    public static func range(ofElementAt path: String, in xml: String) -> Range<String.Index>? {
        let target: [Substring] = path.split(separator: "/")
        guard !target.isEmpty else {
            return nil
        }
        // The names of the open elements around the current position; nil
        // for elements without a name.
        var open: [Substring?] = []
        // Where the matching element's start tag began, and how many
        // elements were open outside it.
        var start: String.Index? = nil
        var startDepth: Int = 0

        for match in xml.matches(of: tagOrComment) {
            let tag: Substring = match.0
            if tag.hasPrefix("<!--") || tag.hasPrefix("<?") {
                continue
            }
            if tag.hasPrefix("</") {
                // An end tag closes the innermost open element.
                // SWIFT: `popLast()` removes and returns the last element,
                // or nil if the array is empty (unlike `removeLast()`, which
                // would crash).
                _ = open.popLast()
                if let begin = start, open.count == startDepth {
                    return begin..<match.range.upperBound
                }
                continue
            }
            let name: Substring? = tag.firstMatch(of: nameAttribute).map { $0.1 }
            let selfClosing: Bool = tag.hasSuffix("/>")
            open.append(name)
            // SWIFT: `compactMap` is `map` that drops the nils: the names of
            // the named open elements, outermost first.
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

extension MXDocument {
    /// Where the canvas shows the element at `path`: the graph level (""
    /// for the document, or a nodegraph's path) and the node on that level
    /// to select. An input's or output's issue selects its node; a
    /// nodegraph's issue selects the nodegraph in its parent level. For ""
    /// (the document itself), there is no node.
    ///
    /// SWIFT: A tuple with labels as the return type, so callers write
    /// `location.graphPath` and `location.nodePath`.
    public func canvasLocation(of path: String) -> (graphPath: String, nodePath: String?) {
        let parts: [String] = path.split(separator: "/").map { String($0) }
        guard !parts.isEmpty else {
            return ("", nil)
        }
        // SWIFT: `Set(...)` of the nodegraph paths, for quick lookups.
        let graphPaths: Set<String> = Set(nodeGraphs.map(\.path))
        // The deepest nodegraph that contains the element (not the element
        // itself, if it is one).
        var depth: Int = parts.count - 1
        while depth > 0 {
            let prefix: String = parts[0..<depth].joined(separator: "/")
            if graphPaths.contains(prefix) {
                return (prefix, prefix + "/" + parts[depth])
            }
            depth -= 1
        }
        return ("", parts[0])
    }
}
