// SwatchPlan.swift
//
// Which canvas nodes get a swatch, and when a swatch must be drawn again
// (M3c). PLAN.md §8.3: re-render "only downstream of an edit".
//
// Edits reach the canvas as a whole new document (MaterialXDocument bumps
// its revision; the canvas is rebuilt), not as "input X of node Y
// changed". So instead of tracking edits, every node gets a *fingerprint*:
// a hash of everything its swatch depends on. That is the node itself (its
// category, type, nodedef and inputs, but not its position), and the
// fingerprints of the nodes its inputs are connected to, so the
// fingerprint covers the whole graph upstream of the node. A node whose
// fingerprint is unchanged looks the same as before: its swatch is kept.
// After a value edit, exactly the edited node and those downstream of it
// get new fingerprints. The same works for undo, redo, reverting the file
// and any other change, whatever caused it.
//
// What a fingerprint can't see, and how it's covered:
//
//  - A nodegraph shown as a node at the document level depends on the nodes
//    inside it: its fingerprint includes its inner graph's, recursively.
//  - A node whose nodedef the document defines itself (a custom node, such
//    as simple_hair in the examples) depends on that definition's
//    implementation, elsewhere in the document: its fingerprint includes
//    the hash of the whole document text, so it is drawn again after any
//    edit. Rare, and always right.
//  - File textures changing on disk aren't noticed until the document is
//    opened again.
//
// Introduces (SWIFT): `Hasher`, Swift's hash function, used directly.

import Foundation
import MXKit

/// One swatch to draw: which canvas node it belongs to, what to shade, and
/// the node's fingerprint.
public struct SwatchRequest: Hashable, Sendable {
    /// The canvas node's element path: what the swatch is stored under.
    public let nodePath: String
    /// The element whose shader shows the node: the node itself, or for a
    /// nodegraph shown as a node, its first output.
    public let shaderPath: String
    /// A hash of everything the swatch depends on (see the file comment).
    public let fingerprint: Int
    /// True for data (a float or a vector, not a colour): shown through
    /// the display's Raw view, not tone-mapped (M3d, SwatchPlan.showsData).
    public let showsData: Bool

    public init(nodePath: String, shaderPath: String, fingerprint: Int, showsData: Bool = false) {
        self.nodePath = nodePath
        self.shaderPath = shaderPath
        self.fingerprint = fingerprint
        self.showsData = showsData
    }
}

/// Decides which nodes get swatches, and fingerprints them.
public enum SwatchPlan {
    /// The output types a swatch can show: values (drawn as colours on the
    /// sphere: a float as grey, a vector as RGB), shaders and materials.
    /// Not strings, filenames, integers, booleans, matrices or closures
    /// other than BSDFs, for which MaterialX's MSL has nothing to draw.
    static let previewableTypes: Set<String> = [
        "float", "color3", "color4", "vector2", "vector3", "vector4",
        "BSDF", "surfaceshader", "material",
    ]

    /// The types shown as data rather than light (M3d): their values are
    /// numbers (a roughness, a mask, a normal, a position), and tone
    /// mapping them, as the view transform does to light, would show a
    /// roughness of 0.5 as something else. Colours, shaders and materials
    /// are light and keep the view transform.
    public static func showsData(_ type: String) -> Bool {
        ["float", "vector2", "vector3", "vector4"].contains(type)
    }

    /// The type of what `node`'s swatch shows: its output's, or for a
    /// nodegraph or a multi-output node, its first output's.
    public static func shownType(of node: MXNode) -> String {
        if node.isNodeGraph || node.type == "multioutput" {
            return node.outputs.first?.type ?? ""
        }
        return node.type
    }

    /// The element whose shader shows `node`'s swatch, or nil if the node
    /// gets no swatch.
    ///
    /// A node with several outputs (`multioutput`, such as separate3) is
    /// shaded as a whole: MaterialX shows its first output. A nodegraph
    /// shown as a node is shaded through its first output, an element of
    /// its own ("NG_marble1/out").
    public static func shaderPath(for node: MXNode) -> String? {
        if node.isNodeGraph {
            // SWIFT: `first.map { }` builds the path only if there is a
            // first output.
            return previewableTypes.contains(shownType(of: node)) ? node.outputs.first.map { node.path + "/" + $0.name } : nil
        }
        return previewableTypes.contains(shownType(of: node)) ? node.path : nil
    }

    /// A swatch request for every node of `graph` that gets a swatch.
    ///
    /// - Parameters:
    ///   - graph: the level shown on the canvas.
    ///   - document: the document it comes from, to look inside nodegraphs.
    ///   - documentText: the document's XML (any form; only its hash is
    ///     used), for nodes with the document's own nodedefs.
    ///   - customNodeDefs: the names of the nodedefs the document defines.
    public static func requests(for graph: MXGraph, in document: MXDocument, documentText: String,
                                customNodeDefs: Set<String>) -> [SwatchRequest] {
        var fingerprints = Fingerprints(document: document, documentHash: documentText.hashValue,
                                        customNodeDefs: customNodeDefs)
        let byNode: [String: Int] = fingerprints.of(graph)
        // SWIFT: `compactMap` is `map` that drops the nils: nodes without
        // a swatch.
        return graph.nodes.compactMap { node in
            guard let shaderPath = shaderPath(for: node), let fingerprint = byNode[node.name] else {
                return nil
            }
            return SwatchRequest(nodePath: node.path, shaderPath: shaderPath, fingerprint: fingerprint,
                                 showsData: showsData(shownType(of: node)))
        }
    }

    /// The fingerprinting of one document.
    struct Fingerprints {
        let document: MXDocument
        let documentHash: Int
        let customNodeDefs: Set<String>
        /// Inner graphs' fingerprints, by nodegraph path, so a nodegraph used
        /// twice is read once.
        var innerGraphs: [String: Int] = [:]

        /// Every node's fingerprint in `graph`, by name.
        ///
        /// SWIFT: `mutating` because it fills `innerGraphs`.
        mutating func of(_ graph: MXGraph) -> [String: Int] {
            // The graph's own inputs (inside a nodegraph): their values.
            var interface: [String: Int] = [:]
            for input in graph.interfaceInputs {
                var hasher = Hasher()
                hasher.combine(input)
                interface[input.name] = hasher.finalize()
            }

            var result: [String: Int] = [:]
            // Names being fingerprinted, to stop at a cycle (which MaterialX
            // forbids, but a file could contain).
            var visiting: Set<String> = []

            // SWIFT: A nested function can call itself, and can read and
            // change the variables of the function around it (`result`,
            // `visiting`): it *captures* them. It can't capture `self`
            // mutably while being stored, so it takes `self` as an
            // `inout` parameter instead.
            func fingerprint(of name: String, _ fingerprints: inout Fingerprints) -> Int {
                if let known = result[name] {
                    return known
                }
                guard let node = graph.node(named: name), !visiting.contains(name) else {
                    // Not a node of this level, or a cycle: only the name.
                    return name.hashValue
                }
                visiting.insert(name)
                var hasher = Hasher()
                // The node itself, without its position: moving a node
                // doesn't change its swatch.
                hasher.combine(node.name)
                hasher.combine(node.category)
                hasher.combine(node.type)
                hasher.combine(node.nodeDefName)
                hasher.combine(node.inputs)
                hasher.combine(node.outputs)
                // What its inputs are connected to.
                for input in node.inputs {
                    switch input.connection {
                    case .node(let source, _)?, .nodeGraph(let source, _)?:
                        hasher.combine(fingerprint(of: source, &fingerprints))
                    case .interface(let source)?:
                        hasher.combine(interface[source])
                    case .output(let source)?:
                        hasher.combine(source)
                    case nil:
                        break
                    }
                }
                if node.isNodeGraph {
                    hasher.combine(fingerprints.innerGraph(at: node.path))
                }
                if let nodeDef = node.nodeDefName, fingerprints.customNodeDefs.contains(nodeDef) {
                    hasher.combine(fingerprints.documentHash)
                }
                visiting.remove(name)
                let value: Int = hasher.finalize()
                result[name] = value
                return value
            }

            for node in graph.nodes {
                _ = fingerprint(of: node.name, &self)
            }
            return result
        }

        /// The fingerprint of the nodegraph at `path`: of all its nodes and
        /// outputs.
        mutating func innerGraph(at path: String) -> Int {
            if let known = innerGraphs[path] {
                return known
            }
            // Mark it first, so a nodegraph containing itself stops here.
            innerGraphs[path] = path.hashValue
            guard let inner = try? document.graph(at: path) else {
                return path.hashValue
            }
            let nodes: [String: Int] = of(inner)
            var hasher = Hasher()
            // SWIFT: Sorted, because a dictionary's order isn't defined, and
            // the same graph must always give the same hash.
            for name in nodes.keys.sorted() {
                hasher.combine(name)
                hasher.combine(nodes[name])
            }
            hasher.combine(inner.outputs)
            let value: Int = hasher.finalize()
            innerGraphs[path] = value
            return value
        }
    }
}
