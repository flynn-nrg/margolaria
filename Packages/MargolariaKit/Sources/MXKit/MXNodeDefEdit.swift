// MXNodeDefEdit.swift
//
// Node definitions made from nodegraphs (M4c1, PLAN.md §8.5). A nodegraph
// with inputs and outputs becomes the implementation of a new `<nodedef>`:
// a kind of node, listed in the Library like a standard one, whose
// instances compute what the graph does. Its inputs and outputs are the
// graph's; the graph's input values become its defaults, with their
// metadata (M4b), which is what the inspector shows for its nodes.
//
// The definition stays editable in its own document: the graph's inputs,
// defaults and metadata are then the nodedef's, and M4b's edits change
// them there (and in its instances, for a renamed or removed input). Since
// M7c its outputs too (M4a's edits, MXNodeGraphEdit.swift), and its node's
// name.
// Saving it to a library for other documents is M4c2.
//
// Introduces (SWIFT): a `static func` returning a suggested value of its
// own type, `lowercased()`, `hasPrefix`/`dropFirst` on a String.

import Foundation
import MXBridge

/// What a new node definition is called and how it is described.
public struct MXNodeDefSpec: Equatable, Sendable {
    /// The node's category, which its nodes are written as: "my_tiles".
    public var node: String
    /// The nodedef's name: "ND_my_tiles_color3".
    public var name: String
    /// `nodegroup`, such as "texture2d"; empty for none.
    public var nodeGroup: String
    /// `version`, such as "1.0"; empty for none.
    public var version: String
    /// What the node does.
    public var documentation: String

    public init(node: String, name: String, nodeGroup: String = "", version: String = "", documentation: String = "") {
        self.node = node
        self.name = name
        self.nodeGroup = nodeGroup
        self.version = version
        self.documentation = documentation
    }

    /// The nodedef name MaterialX's libraries would give `node` with
    /// `outputs`: "ND_<node>_<type>" for one output, "ND_<node>" for several.
    public static func nodeDefName(for node: String, outputs: [MXPort]) -> String {
        outputs.count == 1 ? "ND_\(node)_\(outputs[0].type)" : "ND_\(node)"
    }

    /// A first suggestion for `graph`: its name without "NG_", in lower
    /// case, as the node; the nodedef named from it; the graph's
    /// description.
    ///
    /// SWIFT: `dropFirst(3)` is the string without its first three
    /// characters (a Substring, turned back into a String).
    public static func suggested(for graph: MXNode) -> MXNodeDefSpec {
        var node: String = graph.name.hasPrefix("NG_") ? String(graph.name.dropFirst(3)) : graph.name
        node = node.lowercased()
        return MXNodeDefSpec(node: node, name: nodeDefName(for: node, outputs: graph.outputs),
                             documentation: graph.documentation ?? "")
    }
}

/// The nodedef attributes the inspector edits for a definition made here.
public enum MXNodeDefAttribute: String, Sendable {
    case nodeGroup = "nodegroup"
    case documentation = "doc"
    case version = "version"
}

extension MXDocument {
    /// Makes the top-level nodegraph at `graph` the implementation of a new
    /// nodedef described by `spec` (see MXNodeDefSpec). Where the graph was
    /// used, a node of the new kind takes its place and its name; the graph
    /// is renamed "NG_<node>". Returns the nodedef's name and the new
    /// node's path (nil if the graph wasn't used).
    @discardableResult
    public func makeNodeDefinition(from graph: String, as spec: MXNodeDefSpec) throws -> (nodeDef: String, instance: String?) {
        var bridgeSpec = mxbridge.NodeDefSpec()
        bridgeSpec.node = std.string(spec.node)
        bridgeSpec.name = std.string(spec.name)
        bridgeSpec.nodeGroup = std.string(spec.nodeGroup)
        bridgeSpec.version = std.string(spec.version)
        bridgeSpec.doc = std.string(spec.documentation)
        var nodeDef = std.string()
        var instance = std.string()
        try perform { error in
            handle.makeNodeDefinition(std.string(graph), bridgeSpec, &nodeDef, &instance, &error)
        }
        return (nodeDef.swiftString, instance.swiftString.nonEmpty)
    }

    /// Removes the definition the nodegraph at `graph` implements, and the
    /// graph. Refused while any node is of it.
    public func removeNodeDefinition(implementedBy graph: String) throws {
        try perform { error in
            handle.removeNodeDefinition(std.string(graph), &error)
        }
    }

    /// The path of the nodegraph implementing `nodeDef`, if it is in this
    /// document: made here, or included from a library file (M4c2), where
    /// it is read-only. What double-clicking a node of it opens. Nil for
    /// the data libraries' definitions.
    public func implementation(of nodeDef: String) -> String? {
        let nodes: [MXNode] = (try? graph(at: "").nodes) ?? []
        return nodes.first(where: { $0.isNodeGraph && $0.nodeDefName == nodeDef && ($0.isLocalDefinition || $0.isIncluded) })?
            .path
    }

    /// Renames the node of the definition the nodegraph at `graph`
    /// implements (M7c): its category, which every node of it is written
    /// as. The nodedef ("ND_<node>_<type>") and the graph ("NG_<node>")
    /// are renamed too where their names came from the old one. Refused
    /// for a name another definition uses. Returns the graph's path, which
    /// may have changed.
    @discardableResult
    public func renameNodeDefinition(implementedBy graph: String, to node: String) throws -> String {
        var newPath = std.string()
        try perform { error in
            handle.renameNodeDefinition(std.string(graph), std.string(node), &newPath, &error)
        }
        return newPath.swiftString
    }

    /// Sets an attribute of the nodedef the nodegraph at `graph` implements,
    /// if it is in this document; nil (or "") removes it.
    public func setNodeDef(_ attribute: MXNodeDefAttribute, to value: String?, of graph: String) throws {
        try perform { error in
            handle.setNodeDefAttribute(std.string(graph), std.string(attribute.rawValue), std.string(value ?? ""), &error)
        }
    }
}
