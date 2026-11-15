// MXXMLText.swift
//
// Working with a document's XML as text, for the XML panel: where the tag
// names, attribute names, values and comments are (to colour them), and
// where a given element is (to highlight the node selected on the canvas),
// which element a position is in (to select it on the canvas, M7b), and
// where the blank lines between elements are (to keep them on save, M7d).
//
// This reads the text MaterialX writes (MXDocument.xmlString), which is
// regular: one element per tag, attributes in double quotes, no CDATA. It is
// a highlighter, not an XML parser; MaterialX does the real parsing.
//
// It scans the text's bytes (M4e: it runs on every key typed in the XML
// tab). Until M4e it used regular expressions, kept in MXXMLTextTests as
// the reference the scanning must agree with.
//
// Introduces (SWIFT): `Range<String.Index>`, `String.utf8` and its
// indices, `UInt8(ascii:)`, `elementsEqual`, `popLast()`, `compactMap`;
// `utf8.distance(from:to:)` (M7b); `String(decoding:as:)`, `reversed()`,
// `repeatElement` (M7d).

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

    /// Every tag name, attribute name, attribute value and comment in `xml`,
    /// in order.
    public static func tokens(in xml: String) -> [Token] {
        let text = Bytes(xml)
        var tokens: [Token] = []
        for tag in text.tags() {
            if tag.isComment {
                tokens.append(Token(kind: .comment, range: text.range(tag.start..<tag.end)))
                continue
            }
            if let name = text.tagName(in: tag) {
                tokens.append(Token(kind: .tagName, range: text.range(name)))
            }
            for (name, value) in text.attributes(in: tag) {
                tokens.append(Token(kind: .attributeName, range: text.range(name)))
                tokens.append(Token(kind: .attributeValue, range: text.range(value)))
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
        // SWIFT: `Array(part.utf8)` copies a string's UTF-8 bytes into an
        // array, here to compare with the names' bytes in the text.
        let target: [[UInt8]] = path.split(separator: "/").map { Array($0.utf8) }
        guard !target.isEmpty else {
            return nil
        }
        let text = Bytes(xml)
        // The names of the open elements around the current position; nil
        // for elements without a name.
        var open: [[UInt8]?] = []
        // Where the matching element's start tag began, and how many
        // elements were open outside it.
        var start: Int? = nil
        var startDepth: Int = 0

        for tag in text.tags() {
            if tag.isComment || text.byte(at: tag.start + 1) == Bytes.question {
                continue
            }
            if text.byte(at: tag.start + 1) == Bytes.slash {
                // An end tag closes the innermost open element.
                // SWIFT: `popLast()` removes and returns the last element,
                // or nil if the array is empty (unlike `removeLast()`, which
                // would crash).
                _ = open.popLast()
                if let begin = start, open.count == startDepth {
                    return text.range(begin..<tag.end)
                }
                continue
            }
            let name: [UInt8]? = text.nameAttribute(in: tag).map { Array(text.bytes[$0]) }
            let selfClosing: Bool = tag.end - tag.start >= 2 && text.byte(at: tag.end - 2) == Bytes.slash
            open.append(name)
            // SWIFT: `compactMap` is `map` that drops the nils: the names of
            // the named open elements, outermost first.
            if start == nil, name != nil, open.compactMap({ $0 }) == target {
                if selfClosing {
                    return text.range(tag.start..<tag.end)
                }
                start = tag.start
                startDepth = open.count - 1
            }
            if selfClosing {
                _ = open.popLast()
            }
        }
        return nil
    }

    /// The path of the innermost named element around `position` in `xml`
    /// (M7b): the caret in the XML tab, inside a node's tags or between
    /// them, gives that node's path, or its input's ("SR/base_color").
    /// Nil outside every named element, as between top-level elements. The
    /// reverse of ``range(ofElementAt:in:)``.
    public static func elementPath(at position: String.Index, in xml: String) -> String? {
        let text = Bytes(xml)
        // SWIFT: `utf8.distance(from:to:)` counts the UTF-8 bytes between
        // two indices: the position as a byte offset.
        let offset: Int = xml.utf8.distance(from: xml.startIndex, to: position)
        var open: [[UInt8]?] = []
        for tag in text.tags() {
            // Past the position: the elements open now are around it.
            if tag.start >= offset {
                break
            }
            if tag.isComment || text.byte(at: tag.start + 1) == Bytes.question {
                continue
            }
            if text.byte(at: tag.start + 1) == Bytes.slash {
                // In an end tag, its element is still around the position.
                if offset < tag.end {
                    break
                }
                _ = open.popLast()
                continue
            }
            open.append(text.nameAttribute(in: tag).map { Array(text.bytes[$0]) })
            let selfClosing: Bool = tag.end - tag.start >= 2 && text.byte(at: tag.end - 2) == Bytes.slash
            if selfClosing && offset >= tag.end {
                _ = open.popLast()
            }
        }
        let names: [String] = open.compactMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
        return names.isEmpty ? nil : names.joined(separator: "/")
    }

    // MARK: Blank lines (M7d)

    /// The blank lines between `xml`'s elements, by the tag after them:
    /// how many there are before each, keyed by an *anchor*. A named
    /// element's anchor is its path ("NG_BishopBlack"); its end tag's is
    /// "end " and the path ("end NG_BishopBlack"); a comment's, or an
    /// unnamed element's, is the whole tag ("<!-- Bishop Black -->",
    /// "</materialx>").
    ///
    /// MaterialX's parser drops the whitespace between elements, so
    /// MXDocument notes these when it reads a file and puts the blank lines
    /// back when it writes (``insertingBlankLines(_:in:)``). Anchors
    /// rather than line numbers, so the blank lines stay with their
    /// elements through edits: a node moved keeps its blank line, a node
    /// renamed loses it.
    public static func blankLines(in xml: String) -> [String: Int] {
        let text = Bytes(xml)
        var blankLines: [String: Int] = [:]
        text.forEachTag { anchor, gap in
            // Two line ends make one blank line.
            let blank: Int = text.newlines(in: gap) - 1
            if blank > 0 {
                blankLines[anchor] = blank
            }
        }
        return blankLines
    }

    /// `xml` with ``blankLines(in:)``'s `blankLines` put back: before each
    /// tag they name that starts a line, as MaterialX writes every tag.
    public static func insertingBlankLines(_ blankLines: [String: Int], in xml: String) -> String {
        guard !blankLines.isEmpty else {
            return xml
        }
        let text = Bytes(xml)
        // Where each blank line goes, just after the tag before, and how many.
        var insertions: [(offset: Int, count: Int)] = []
        text.forEachTag { anchor, gap in
            if let count = blankLines[anchor], text.newlines(in: gap) == 1 {
                insertions.append((gap.lowerBound, count))
            }
        }
        var bytes: [UInt8] = text.bytes
        // SWIFT: `reversed()` walks the insertions from the last: inserting
        // there doesn't move the earlier ones' offsets.
        for insertion in insertions.reversed() {
            bytes.insert(contentsOf: repeatElement(Bytes.newline, count: insertion.count), at: insertion.offset)
        }
        // SWIFT: `String(decoding:as:)` makes a String from UTF-8 bytes
        // (any invalid ones would become "�"; these came from a String).
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A tag in the text, by byte offsets: from its `<` to just after its
    /// `>`. A comment is one tag, from `<!--` to `-->`.
    struct Tag {
        let start: Int
        let end: Int
        let isComment: Bool
    }

    /// The text's UTF-8 bytes, and the scanning the XML panel needs.
    ///
    /// Scanning bytes rather than Characters is many times faster: these
    /// run on every key typed in the XML tab, over up to tens of kilobytes.
    /// What it finds is what these regular expressions would (the tests
    /// check it, keeping them as the reference):
    ///   tag or comment   `<!--[\s\S]*?-->|<[^>]*>`
    ///   tag name         `^<[/?]?([\w:.-]+)`
    ///   attribute        `([\w:.-]+)\s*=\s*("[^"]*")`
    ///   name attribute   `\sname\s*=\s*"([^"]*)"`
    /// The markup is all ASCII, so a byte offset never falls inside a
    /// character, and every range found is one of `xml`'s String ranges.
    ///
    /// SWIFT: `UInt8(ascii: "<")` is the byte of an ASCII character, checked
    /// at compile time, like C's `'<'`.
    struct Bytes {
        static let less = UInt8(ascii: "<")
        static let greater = UInt8(ascii: ">")
        static let slash = UInt8(ascii: "/")
        static let question = UInt8(ascii: "?")
        static let equals = UInt8(ascii: "=")
        static let quote = UInt8(ascii: "\"")
        static let newline = UInt8(ascii: "\n")
        static let commentStart: [UInt8] = Array("<!--".utf8)
        static let commentEnd: [UInt8] = Array("-->".utf8)
        static let name: [UInt8] = Array("name".utf8)

        /// The string the bytes are from, for its indices.
        let string: String
        let bytes: [UInt8]

        init(_ string: String) {
            self.string = string
            self.bytes = Array(string.utf8)
        }

        /// The byte at `offset`, or nil past the end.
        func byte(at offset: Int) -> UInt8? {
            offset < bytes.count ? bytes[offset] : nil
        }

        /// The String range of a byte range.
        ///
        /// SWIFT: For a native Swift string (stored as UTF-8), moving a
        /// `utf8` index by an offset takes constant time.
        func range(_ offsets: Range<Int>) -> Range<String.Index> {
            let utf8: String.UTF8View = string.utf8
            let lower: String.Index = utf8.index(utf8.startIndex, offsetBy: offsets.lowerBound)
            let upper: String.Index = utf8.index(lower, offsetBy: offsets.count)
            return lower..<upper
        }

        /// True for the bytes of a name: `\w` (letters, digits, `_`, and
        /// anything not ASCII), `:`, `.` and `-`.
        static func isNameByte(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: ":"),
                 UInt8(ascii: "."), UInt8(ascii: "-"), 0x80...:
                return true
            default:
                return false
            }
        }

        /// True for `\s`: space, tab, newline, carriage return, vertical
        /// tab and form feed.
        static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || (0x09...0x0D).contains(byte)
        }

        /// True if `sequence` is at `offset`.
        func matches(_ sequence: [UInt8], at offset: Int) -> Bool {
            guard offset >= 0, offset + sequence.count <= bytes.count else {
                return false
            }
            // SWIFT: `elementsEqual` compares two sequences element by
            // element; here the slice of `bytes` and `sequence`.
            return bytes[offset..<offset + sequence.count].elementsEqual(sequence)
        }

        /// The first offset of `byte` in `start..<end`, or nil.
        func first(_ byte: UInt8, from start: Int, to end: Int) -> Int? {
            start < end ? bytes[start..<end].firstIndex(of: byte) : nil
        }

        /// The offset after whitespace from `offset`, up to `end`.
        func skippingSpace(from offset: Int, to end: Int) -> Int {
            var offset = offset
            while offset < end, Bytes.isSpace(bytes[offset]) {
                offset += 1
            }
            return offset
        }

        /// The tags and comments in the text, in order.
        func tags() -> [Tag] {
            var tags: [Tag] = []
            var offset: Int = 0
            while offset < bytes.count {
                guard bytes[offset] == Bytes.less else {
                    offset += 1
                    continue
                }
                // A comment ends at the first `-->` after `<!--`; one that
                // doesn't end runs to the next `>` instead (still a
                // comment, as the regular expression read it).
                let isComment: Bool = matches(Bytes.commentStart, at: offset)
                if isComment {
                    var close: Int = offset + Bytes.commentStart.count
                    while close + Bytes.commentEnd.count <= bytes.count, !matches(Bytes.commentEnd, at: close) {
                        close += 1
                    }
                    if matches(Bytes.commentEnd, at: close) {
                        tags.append(Tag(start: offset, end: close + Bytes.commentEnd.count, isComment: true))
                        offset = close + Bytes.commentEnd.count
                        continue
                    }
                }
                // No `>` left: no more tags (nor comments, which end in one).
                guard let close = first(Bytes.greater, from: offset + 1, to: bytes.count) else {
                    break
                }
                tags.append(Tag(start: offset, end: close + 1, isComment: isComment))
                offset = close + 1
            }
            return tags
        }

        /// Calls `body` for each tag and comment but the `<?xml ?>`
        /// declaration, in order, with its anchor (see
        /// ``MXXMLText/blankLines(in:)``) and the gap before it: from the
        /// end of the tag before (or the start of the text) to its `<`.
        func forEachTag(_ body: (_ anchor: String, _ gap: Range<Int>) -> Void) {
            // The open elements' names; nil for those without one.
            var open: [[UInt8]?] = []
            var previousEnd: Int = 0
            /// The path of the open elements, as names joined by "/".
            func path() -> String {
                open.compactMap { $0 }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
            }
            for tag in tags() {
                // SWIFT: `defer` in a loop's body runs at the end of each
                // pass, `continue` included.
                defer {
                    previousEnd = tag.end
                }
                let gap: Range<Int> = previousEnd..<tag.start
                if tag.isComment {
                    body(text(of: tag), gap)
                    continue
                }
                if byte(at: tag.start + 1) == Bytes.question {
                    continue
                }
                if byte(at: tag.start + 1) == Bytes.slash {
                    // An end tag: its element is the innermost open one.
                    let named: Bool = open.last.map { $0 != nil } ?? false
                    body(named ? "end " + path() : text(of: tag), gap)
                    _ = open.popLast()
                    continue
                }
                let name: [UInt8]? = nameAttribute(in: tag).map { Array(bytes[$0]) }
                open.append(name)
                body(name == nil ? text(of: tag) : path(), gap)
                let selfClosing: Bool = tag.end - tag.start >= 2 && byte(at: tag.end - 2) == Bytes.slash
                if selfClosing {
                    _ = open.popLast()
                }
            }
        }

        /// The whole of `tag`, as a String.
        func text(of tag: Tag) -> String {
            String(decoding: bytes[tag.start..<tag.end], as: UTF8.self)
        }

        /// How many line ends there are in `range`.
        func newlines(in range: Range<Int>) -> Int {
            bytes[range].reduce(0) { count, byte in byte == Bytes.newline ? count + 1 : count }
        }

        /// The tag's name: `name` in `<name`, `</name`, `<?name`.
        func tagName(in tag: Tag) -> Range<Int>? {
            var start: Int = tag.start + 1
            if let byte = byte(at: start), byte == Bytes.slash || byte == Bytes.question {
                start += 1
            }
            var end: Int = start
            while end < tag.end, Bytes.isNameByte(bytes[end]) {
                end += 1
            }
            return end > start ? start..<end : nil
        }

        /// The tag's `name="value"` pairs: each name, and its value with
        /// the quotes.
        func attributes(in tag: Tag) -> [(name: Range<Int>, value: Range<Int>)] {
            var pairs: [(name: Range<Int>, value: Range<Int>)] = []
            var offset: Int = tag.start
            while offset < tag.end {
                guard Bytes.isNameByte(bytes[offset]) else {
                    offset += 1
                    continue
                }
                // A name, then `=` and a quoted value, with or without
                // spaces between. Anything else: not an attribute, and
                // neither is any part of this name, so skip all of it.
                var end: Int = offset
                while end < tag.end, Bytes.isNameByte(bytes[end]) {
                    end += 1
                }
                var value: Int = skippingSpace(from: end, to: tag.end)
                if value < tag.end, bytes[value] == Bytes.equals {
                    value = skippingSpace(from: value + 1, to: tag.end)
                    if value < tag.end, bytes[value] == Bytes.quote,
                       let close = first(Bytes.quote, from: value + 1, to: tag.end) {
                        pairs.append((name: offset..<end, value: value..<close + 1))
                        offset = close + 1
                        continue
                    }
                }
                offset = end
            }
            return pairs
        }

        /// The value of the tag's first ` name="..."`, without the quotes.
        func nameAttribute(in tag: Tag) -> Range<Int>? {
            for offset in tag.start..<tag.end where Bytes.isSpace(bytes[offset]) {
                guard matches(Bytes.name, at: offset + 1) else {
                    continue
                }
                var value: Int = skippingSpace(from: offset + 1 + Bytes.name.count, to: tag.end)
                guard value < tag.end, bytes[value] == Bytes.equals else {
                    continue
                }
                value = skippingSpace(from: value + 1, to: tag.end)
                guard value < tag.end, bytes[value] == Bytes.quote,
                      let close = first(Bytes.quote, from: value + 1, to: tag.end) else {
                    continue
                }
                return value + 1..<close
            }
            return nil
        }
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
