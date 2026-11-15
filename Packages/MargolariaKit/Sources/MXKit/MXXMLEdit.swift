// MXXMLEdit.swift
//
// Editing a document as text (M4e, PLAN.md §8.5): the XML tab checks what
// is typed (`check(text:)`), and Apply replaces the document with it
// (`replaceContents(withText:)`), as one edit the app can undo like any
// other.
//
// The text is read as the document's own file would be: `xi:include`s are
// found next to the file, and its elements keep the file as their source,
// so included elements stay included (written back as includes) and
// relative texture paths resolve the same way. Text MaterialX can't read
// is never applied: most text is unreadable while it is being typed.
//
// Introduces (SWIFT): `XMLParser` and a delegate (Foundation's
// event-driven XML parser, libxml2 underneath), `Array.min(by:)`, `reduce` over a Substring's
// characters.

import Foundation
import MXBridge

/// A problem in the XML tab's text, and where it is.
public struct MXTextProblem: Hashable, Sendable {
    /// What is wrong, in one line.
    public let message: String
    /// The line it is on, from 1; nil if the text doesn't say where.
    public let line: Int?
    /// The column on that line, from 1; nil if only the line is known.
    public let column: Int?

    public init(message: String, line: Int?, column: Int? = nil) {
        self.message = message
        self.line = line
        self.column = column
    }
}

/// What the XML tab's text would make of the document.
///
/// SWIFT: An enum whose cases carry values (*associated values*), like a
/// tagged union in C: `.unreadable(problem)` holds a problem, `.valid`
/// nothing. A `switch` unpacks them with `case .issues(let count, let first)`.
public enum MXTextCheck: Hashable, Sendable {
    /// MaterialX can't read it (malformed XML, a missing include, not a
    /// `<materialx>` document). It can't be applied.
    case unreadable(MXTextProblem)
    /// It reads, but validation or Margolaria's checks found `count`
    /// problems; `first` is the one earliest in the text. It can be
    /// applied, as a canvas edit leaving the same problems could be made.
    case issues(count: Int, first: MXTextProblem)
    /// It reads and validates.
    case valid

    /// The check of a document's own text, `text`, from the document's
    /// `issues`, without reading the text again: valid, or the issue
    /// earliest in the text.
    public init(issues: [MXIssue], in text: String) {
        guard !issues.isEmpty else {
            self = .valid
            return
        }
        // Each issue's line: where its element starts in the text.
        let problems: [MXTextProblem] = issues.map { issue in
            var line: Int? = nil
            if let range = MXXMLText.range(ofElementAt: issue.elementPath, in: text) {
                line = MXDocument.line(of: range.lowerBound, in: text)
            }
            return MXTextProblem(message: issue.message, line: line)
        }
        // The earliest in the text; issues without a line (about the
        // document as a whole) after those with one.
        //
        // SWIFT: `min(by:)` takes an "is less than" closure, and returns
        // nil only for an empty array (not this one, so `!` is safe).
        // `Int.max` stands in for a missing line, so those sort last.
        let first: MXTextProblem = problems.min(by: { ($0.line ?? Int.max) < ($1.line ?? Int.max) })!
        // SWIFT: An enum's initializer gives a value by assigning `self`.
        self = .issues(count: issues.count, first: first)
    }

    /// True if Apply may replace the document with the text.
    public var canApply: Bool {
        if case .unreadable = self {
            return false
        }
        return true
    }
}

extension MXDocument {
    /// Reads `text` as this document's own XML (see the file's header):
    /// a new document with this one's file, includes and data library.
    /// This document doesn't change.
    ///
    /// - Throws: ``MXError/parseFailed(_:)`` with MaterialX's message.
    public func readText(_ text: String) throws -> MXDocument {
        // Malformed, or with text between tags, which MaterialX would turn
        // into elements without a category, or drop.
        if let problem = Self.malformation(in: text) {
            throw MXError.parseFailed(problem.message)
        }
        var errorMessage = std.string()
        let document = handle.readText(std.string(text), &errorMessage)
        guard document.isLoaded() else {
            throw MXError.parseFailed(errorMessage.swiftString)
        }
        let result = MXDocument(handle: document, fileURL: fileURL, fileVersion: fileVersion)
        result.hasDataLibrary = hasDataLibrary
        // The blank lines typed in the XML tab are kept too.
        result.blankLines = MXXMLText.blankLines(in: text)
        return result
    }

    /// Replaces the whole document with `text` (the XML tab's Apply). The
    /// app's `edit` keeps a copy first, as for any edit, so it undoes in
    /// one step. Text that can't be read changes nothing.
    ///
    /// - Throws: ``MXError/parseFailed(_:)`` with MaterialX's message.
    public func replaceContents(withText text: String) throws {
        restore(from: try readText(text))
    }

    /// What `text` would make of this document: unreadable (and where),
    /// readable with problems (and the first one's line), or valid. Reads
    /// and validates the whole text, so the XML tab calls it when typing
    /// pauses, not on every key.
    public func check(text: String) -> MXTextCheck {
        // Foundation's parser says where the XML is malformed, and how;
        // MaterialX says neither.
        if let malformation = Self.malformation(in: text) {
            return .unreadable(malformation)
        }
        let document: MXDocument
        do {
            document = try readText(text)
        } catch {
            // Well-formed: MaterialX refused it for a reason of its own (a
            // missing include).
            var message: String = error.localizedDescription
            if case MXError.parseFailed(let reason) = error {
                message = reason
            }
            return .unreadable(MXTextProblem(message: message, line: nil))
        }
        return MXTextCheck(issues: document.issues(), in: text)
    }

    /// The first place `text` isn't well-formed XML, by Foundation's
    /// parser, or has text between tags (MaterialX documents have none,
    /// only elements, attributes and comments): its message, line and
    /// column. Nil if there is neither.
    static func malformation(in text: String) -> MXTextProblem? {
        let parser = XMLParser(data: Data(text.utf8))
        let listener = ErrorListener()
        // SWIFT: `delegate` is a weak reference (as in Objective-C), so
        // `listener` must be kept alive by this local constant until
        // `parse()` returns.
        parser.delegate = listener
        if parser.parse() {
            return nil
        }
        return listener.first ?? MXTextProblem(message: "The XML is malformed", line: max(parser.lineNumber, 1))
    }

    /// The line `index` is on in `text`, from 1.
    ///
    /// SWIFT: `text[..<index]` is the text before `index` (a Substring, no
    /// copy); counting its newlines gives the line.
    static func line(of index: String.Index, in text: String) -> Int {
        text[..<index].reduce(1) { count, character in character.isNewline ? count + 1 : count }
    }
}

/// Keeps the first error `XMLParser` reports, or the first text between
/// tags, with where it was then: the parser stops soon after, but its own
/// line and column are wherever it had read to by then.
///
/// SWIFT: `XMLParser` is Foundation's event-driven (SAX-style) parser. It
/// calls a *delegate*, an object conforming to the `XMLParserDelegate`
/// protocol, for each tag and error; every method is optional, so this one
/// implements only the error. Objective-C protocols need an `NSObject`
/// subclass to conform.
private final class ErrorListener: NSObject, XMLParserDelegate {
    var first: MXTextProblem? = nil

    func parser(_ parser: XMLParser, parseErrorOccurred error: any Error) {
        guard first == nil else {
            return
        }
        // libxml2's message ends with a newline.
        let message: String = (error as NSError).userInfo["NSXMLParserErrorMessage"] as? String ?? error.localizedDescription
        first = MXTextProblem(message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                              line: max(parser.lineNumber, 1), column: max(parser.columnNumber, 1))
    }

    /// Text between tags (the parser reports it in pieces). Whitespace is
    /// only layout; anything else is a stray character, such as a `>`
    /// typed twice. The parser is stopped there.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard first == nil, !string.allSatisfy(\.isWhitespace) else {
            return
        }
        let shown: String = string.trimmingCharacters(in: .whitespacesAndNewlines)
        first = MXTextProblem(message: "Text between tags: “\(shown.prefix(20))” (MaterialX has only elements and attributes)",
                              line: max(parser.lineNumber, 1), column: max(parser.columnNumber, 1))
        parser.abortParsing()
    }
}
