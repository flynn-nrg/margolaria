// MXNodeGraphEdit.swift
//
// The edits of M4a (PLAN.md §8.5): putting nodes in a nodegraph and taking
// them out again, empty nodegraphs, a nodegraph's outputs, and copying
// nodes as MaterialX text for the pasteboard.
//
// Collapsing keeps what the graph computes: every connection that crosses
// the new graph's edge goes through one of its inputs (inbound) or
// outputs (outbound). Ungrouping undoes that. The bridge (MXBridge.cpp)
// does the work; like every edit, each throws MXError.editRefused and
// leaves the document unchanged when it can't be done.
//
// Introduces (SWIFT): building a C++ `std::vector` from Swift
// (`push_back`), `reduce(into:)`.

import Foundation
import MXBridge

extension MXDocument {
    /// Moves the nodes `names` of the graph at `parent` into a new
    /// nodegraph there, named `name` (made unique; "NG_group" if empty), at
    /// their average position. Returns the new nodegraph's path.
    ///
    /// Only at the top level of the document (`parent` ""), and only nodes:
    /// MaterialX 1.39.5 can't connect to a nodegraph inside another. Nor
    /// materials, which stay at the top level.
    @discardableResult
    public func collapse(_ names: [String], in parent: String = "", into name: String = "") throws -> String {
        var newPath = std.string()
        try perform { error in
            handle.collapseIntoNodeGraph(std.string(parent), Self.stringVector(names), std.string(name), &newPath, &error)
        }
        return newPath.swiftString
    }

    /// Moves the nodes of the nodegraph at `path` into its parent and
    /// removes the graph, keeping every connection that went through it.
    /// Returns the nodes' new paths (some may be renamed, if their names
    /// were taken). Refused for a nodegraph that implements a nodedef.
    @discardableResult
    public func ungroup(_ path: String) throws -> [String] {
        var newPaths = mxbridge.StringVector()
        try perform { error in
            handle.ungroupNodeGraph(std.string(path), &newPaths, &error)
        }
        return newPaths.map { $0.swiftString }
    }

    /// Adds an empty nodegraph to the document, named `name` (made unique;
    /// "NG_graph" if empty). Returns its path. `parent` must be "" (see
    /// ``collapse(_:in:into:)``).
    @discardableResult
    public func addNodeGraph(in parent: String = "", named name: String = "") throws -> String {
        var newPath = std.string()
        try perform { error in
            handle.addNodeGraph(std.string(parent), std.string(name), &newPath, &error)
        }
        return newPath.swiftString
    }

    /// Adds an output of `type` (such as "color3") to the nodegraph at
    /// `graph`, named `name` (made unique; "out" if empty), connected to
    /// nothing. Returns its name.
    @discardableResult
    public func addOutput(named name: String = "", type: String, to graph: String) throws -> String {
        var newName = std.string()
        try perform { error in
            handle.addGraphOutput(std.string(graph), std.string(name), std.string(type), &newName, &error)
        }
        return newName.swiftString
    }

    /// Renames the output `output` of the nodegraph at `graph`, and what
    /// reads it by name.
    public func renameOutput(_ output: String, of graph: String, to name: String) throws {
        try perform { error in
            handle.renameGraphOutput(std.string(graph), std.string(output), std.string(name), &error)
        }
    }

    /// Removes the output `output` of the nodegraph at `graph`,
    /// disconnecting what read it.
    public func removeOutput(_ output: String, of graph: String) throws {
        try perform { error in
            handle.removeGraphOutput(std.string(graph), std.string(output), &error)
        }
    }

    /// The nodes and nodegraphs `names` of the graph at `parent`, as a small
    /// MaterialX document for the pasteboard. Connections between them are
    /// kept; connections to anything else are dropped, except, with
    /// `keepingInterface`, to the graph's own inputs (for Duplicate, which
    /// pastes in the same graph). File names are made absolute.
    ///
    /// Not an edit: the document is unchanged.
    public func copyNodes(_ names: [String], in parent: String, keepingInterface: Bool = false) throws -> String {
        var xml = std.string()
        try perform { error in
            handle.copyNodes(std.string(parent), Self.stringVector(names), keepingInterface, &xml, &error)
        }
        return xml.swiftString
    }

    /// Adds the nodes and nodegraphs of the MaterialX text `xml` (from
    /// ``copyNodes(_:in:keepingInterface:)``, or another MaterialX tool) to
    /// the graph at `parent`, renamed where their names are taken. Returns
    /// their paths, in order. Connections to anything not pasted are
    /// dropped. Materials and nodegraphs are pasted only at the top level.
    @discardableResult
    public func paste(_ xml: String, into parent: String) throws -> [String] {
        var newPaths = mxbridge.StringVector()
        try perform { error in
            handle.pasteNodes(std.string(parent), std.string(xml), &newPaths, &error)
        }
        return newPaths.map { $0.swiftString }
    }

    /// A C++ vector of the strings, for the bridge.
    ///
    /// SWIFT: `reduce(into:)` starts from an empty value and lets the
    /// closure change it in place (`inout`) for each element: here,
    /// `push_back` as in C++. `StringVector` is the bridge's alias for
    /// `std::vector<std::string>`; Swift can't spell the template itself.
    private static func stringVector(_ strings: [String]) -> mxbridge.StringVector {
        strings.reduce(into: mxbridge.StringVector()) { vector, string in
            vector.push_back(std.string(string))
        }
    }
}
