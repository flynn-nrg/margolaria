// MXInspectable.swift
//
// What the inspector (M2b) can show: the element selected on the canvas,
// found by its path. The canvas shows three kinds of things, and the
// inspector treats each differently: nodes (and nodegraphs) with all their
// inputs, a nodegraph's own inputs (one value each), and `<output>`
// elements (only a connection).
//
// Introduces (SWIFT): an enum whose cases carry different structs, a
// computed property that `switch`es over `self`.

import Foundation

/// One element the inspector can show, read from the document.
///
/// SWIFT: Each case carries what that kind of element needs, so the
/// inspector's `switch` gets exactly the right data in each branch.
public enum MXInspectable: Hashable, Sendable {
    /// A node, or a nodegraph shown as a node.
    case node(MXNode)
    /// One of a nodegraph's own inputs. Its value is edited like a node's
    /// input, on the nodegraph at `graphPath`.
    case graphInput(MXPort, graphPath: String)
    /// An `<output>` element of the document or of the nodegraph at
    /// `graphPath` ("" for the document).
    case graphOutput(MXPort, graphPath: String)

    /// The element's name.
    public var name: String {
        switch self {
        case .node(let node):
            return node.name
        case .graphInput(let port, _), .graphOutput(let port, _):
            return port.name
        }
    }
}

extension MXDocument {
    /// The node, nodegraph, nodegraph input or output at `path`, such as
    /// "NG_copper/grain"; nil if there is none.
    ///
    /// This reads the whole graph level the element is in, which is quick
    /// for MaterialX's document sizes; the inspector calls it after each
    /// change.
    public func inspectable(at path: String) throws -> MXInspectable? {
        // "NG/scale" is "scale" in the graph "NG"; "SR" is "SR" at the top.
        let graphPath: String
        let name: String
        if let slash = path.lastIndex(of: "/") {
            graphPath = String(path[..<slash])
            // SWIFT: `index(after:)`: String indices step one character at a
            // time, so "the character after the slash" is asked for, not
            // computed with `+ 1`.
            name = String(path[path.index(after: slash)...])
        } else {
            graphPath = ""
            name = path
        }

        let graph: MXGraph = try graph(at: graphPath)
        if let node = graph.node(named: name) {
            return .node(node)
        }
        // Names are unique among siblings, so at most one of these matches.
        if let input = graph.interfaceInputs.first(where: { $0.name == name }) {
            return .graphInput(input, graphPath: graphPath)
        }
        if let output = graph.outputs.first(where: { $0.name == name }) {
            return .graphOutput(output, graphPath: graphPath)
        }
        return nil
    }
}
