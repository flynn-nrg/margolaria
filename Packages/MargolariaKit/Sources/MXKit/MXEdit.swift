// MXEdit.swift
//
// Changing a document: the edits the editor (M2) and later Python (M6)
// make, and the copies undo keeps (PLAN.md §8.1).
//
// Every edit names elements by path, checks that the change makes sense
// (types match, no loops, valid names, not an included element), and
// either makes it or throws MXError.editRefused with the reason, leaving
// the document as it was.
//
// Undo doesn't need anything from these methods: the app keeps a copy of
// the whole document before each edit (`copy()`) and puts it back to undo
// (`restore(from:)`). MaterialX documents are small, and that is correct
// for any edit, or any number of them.
//
// Introduces (SWIFT): an `extension` in its own file adding to a class
// from another file, `@discardableResult` on a throwing method, tuples as
// return values for several results, `CGPoint` arithmetic.

import CoreGraphics
import Foundation
import MXBridge

extension MXDocument {
    /// Parses MaterialX XML text, finding `xi:include`d files in `folder`.
    /// Used to read back what was just written, as saving would.
    ///
    /// SWIFT: A `static func` that builds an instance: an extension can't
    /// add a designated `init` to a class from another file.
    public static func parse(xml: String, includesFrom folder: URL) throws -> MXDocument {
        var errorMessage = std.string()
        let document = mxbridge.Document.readFromXmlStringInFolder(std.string(xml),
                                                                    std.string(folder.path(percentEncoded: false)),
                                                                    &errorMessage)
        guard document.isLoaded() else {
            throw MXError.parseFailed(errorMessage.swiftString)
        }
        return MXDocument(handle: document, fileURL: nil, fileVersion: nil)
    }

    // MARK: Copies, for undo

    /// An independent copy of the document: same contents, file and data
    /// library, sharing nothing with this one. Editing either doesn't affect
    /// the other.
    public func copy() -> MXDocument {
        let copy = MXDocument(handle: handle.copy(), fileURL: fileURL, fileVersion: fileVersion)
        copy.hasDataLibrary = hasDataLibrary
        return copy
    }

    /// Replaces this document's contents with a copy of `snapshot`'s,
    /// keeping this object. Views that hold on to the MXDocument keep
    /// working; undo and redo use this.
    public func restore(from snapshot: MXDocument) {
        handle = snapshot.handle.copy()
    }

    /// Compares with `other` element by element, ignoring formatting.
    /// Returns nil when they are equivalent, or a description of the first
    /// difference.
    ///
    /// SWIFT: Returning an optional message, rather than a Bool and a
    /// message, makes "equivalent" impossible to misread: nil means no
    /// difference.
    public func difference(from other: MXDocument) -> String? {
        var message = std.string()
        if handle.isEquivalent(other.handle, &message) {
            return nil
        }
        let text: String = message.swiftString
        return text.isEmpty ? "The documents differ" : text
    }

    /// True if the element at `path` came from an `xi:include`d file, and so
    /// can't be edited.
    public func isIncluded(_ path: String) -> Bool {
        handle.isIncluded(std.string(path))
    }

    // MARK: Edits

    /// Sets an input's value (MaterialX text, such as "0.8, 0.2, 0.1"),
    /// disconnecting it if it was connected. `path` is the node or
    /// nodegraph.
    public func setValue(_ value: String, ofInput input: String, on path: String) throws {
        try perform { error in
            handle.setInputValue(std.string(path), std.string(input), std.string(value), &error)
        }
    }

    /// Removes an input from the document, so the node uses its nodedef's
    /// default again.
    public func resetInput(_ input: String, on path: String) throws {
        try perform { error in
            handle.resetInput(std.string(path), std.string(input), &error)
        }
    }

    /// Connects input `input` of the node at `target` to the node or
    /// nodegraph `source` in the same graph (its output `output`, if it has
    /// several). For an `<output>` element, `input` is "".
    public func connect(input: String, on target: String, to source: String, output: String? = nil) throws {
        try perform { error in
            handle.connectInput(std.string(target), std.string(input), std.string(source), std.string(output ?? ""), &error)
        }
    }

    /// Connects an input inside a nodegraph to one of the graph's own inputs.
    public func connect(input: String, on target: String, toInterface interface: String) throws {
        try perform { error in
            handle.connectInterface(std.string(target), std.string(input), std.string(interface), &error)
        }
    }

    /// Disconnects an input (or an `<output>`, with `input` "").
    public func disconnect(input: String, on target: String) throws {
        try perform { error in
            handle.disconnectInput(std.string(target), std.string(input), &error)
        }
    }

    /// Adds a node defined by `nodeDef` (such as "ND_multiply_float") to the
    /// graph at `parent` ("" for the document). Returns the new node's path.
    ///
    /// SWIFT: `@discardableResult`: callers that don't need the path can
    /// ignore it without a warning.
    @discardableResult
    public func addNode(nodeDef: String, in parent: String = "", named name: String = "") throws -> String {
        var newPath = std.string()
        try perform { error in
            handle.addNode(std.string(parent), std.string(nodeDef), std.string(name), &newPath, &error)
        }
        return newPath.swiftString
    }

    /// Removes a node or nodegraph, disconnecting everything that used it.
    public func removeNode(at path: String) throws {
        try perform { error in
            handle.removeNode(std.string(path), &error)
        }
    }

    /// Renames a node or nodegraph, updating what refers to it. Returns its
    /// new path.
    @discardableResult
    public func renameNode(at path: String, to name: String) throws -> String {
        var newPath = std.string()
        try perform { error in
            handle.renameNode(std.string(path), std.string(name), &newPath, &error)
        }
        return newPath.swiftString
    }

    /// Sets an element's `xpos`/`ypos` attributes, in MaterialX's units (one
    /// unit is one node of MaterialX's Graph Editor; see GraphBuilder for
    /// the conversion to canvas points).
    public func setPosition(_ position: CGPoint, of path: String) throws {
        try perform { error in
            handle.setPosition(std.string(path), Float(position.x), Float(position.y), &error)
        }
    }

    // MARK: Private

    /// Runs one bridge edit, and turns a refusal into a thrown error.
    ///
    /// SWIFT: The closure gets the error message as an `inout` parameter,
    /// so each edit above is one line: call the bridge, passing `&error`,
    /// and return its Bool.
    private func perform(_ edit: (inout std.string) -> Bool) throws {
        var error = std.string()
        guard edit(&error) else {
            throw MXError.editRefused(error.swiftString)
        }
    }
}
