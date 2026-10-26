// DocumentWiring.swift
//
// Turns the canvas's wiring requests (WireConnection, InputSlot; see
// GraphWiring.swift) into MXKit edits on the document a DocumentGraph was
// built from (M2d). The canvas names nodes by index and outputs by row;
// MaterialX names them by element name, and connects each kind of element
// with a different edit:
//
//   source \ target        node input                <output>
//   node or nodegraph      connect(input:on:to:)     connect(input: "", ...)
//   the graph's input      connect(...toInterface:)  (refused by MaterialX)
//
// A node added at the end of a wire dropped on empty canvas (M2e) isn't
// on the canvas yet, so it is named by path: `connect(newNode:...)`.
//
// Kept here rather than in the app so the corpus tests can rewire every
// example the way the canvas does.
//
// Introduces (SWIFT): nothing new.

import Foundation
import MXKit

extension DocumentGraph {
    /// The element name of canvas node `node`: the last part of its path.
    public func elementName(of node: Int) -> String {
        let path: String = elementPaths[node]
        guard let slash = path.lastIndex(of: "/") else {
            return path
        }
        return String(path[path.index(after: slash)...])
    }

    /// Makes `connection` in `document`: disconnects the input it was moved
    /// from, if any, then connects. Throws MXError.editRefused if MaterialX
    /// refuses (the canvas only offers what should work).
    public func connect(_ connection: WireConnection, in document: MXDocument) throws {
        if let movedFrom = connection.movedFrom {
            try disconnect([movedFrom], in: document)
        }
        let target: String = elementPaths[connection.input.node]
        // An <output> element is its own port: its "input" is "".
        let input: String = kinds[connection.input.node] == .output ? "" : connection.input.name
        let source: Int = connection.output.node
        switch kinds[source] {
        case .interfaceInput:
            try document.connect(input: input, on: target, toInterface: elementName(of: source))
        case .node:
            let outputs: [GraphPort] = model.nodes[source].outputs
            // Name the output only when there is a choice, as MaterialX's
            // own files do.
            let output: String? = outputs.count > 1 ? outputs[connection.output.index].name : nil
            try document.connect(input: input, on: target, to: elementName(of: source), output: output)
        case .output:
            // <output>s have no outputs on the canvas; nothing starts there.
            throw MXError.editRefused("\(elementName(of: source)) is an output; wires go into it, not out of it")
        }
    }

    /// Connects the node just added at `path` to `wire`, the wire dropped
    /// on empty canvas that asked for it (M2e). `port` is the new node's
    /// input (for a wire from an output) or output (for a wire into an
    /// input) that takes it; `outputCount` is how many outputs the new
    /// node has, as an output is named only when there is a choice.
    public func connect(newNode path: String, port: String, outputCount: Int, to wire: DanglingWire,
                        in document: MXDocument) throws {
        switch wire {
        case .fromOutput(let output, _):
            let source: Int = output.node
            switch kinds[source] {
            case .interfaceInput:
                try document.connect(input: port, on: path, toInterface: elementName(of: source))
            case .node:
                let outputs: [GraphPort] = model.nodes[source].outputs
                let name: String? = outputs.count > 1 ? outputs[output.index].name : nil
                try document.connect(input: port, on: path, to: elementName(of: source), output: name)
            case .output:
                throw MXError.editRefused("\(elementName(of: source)) is an output; wires go into it, not out of it")
            }
        case .intoInput(let slot, _):
            let input: String = kinds[slot.node] == .output ? "" : slot.name
            // SWIFT: `split(separator:).last` is the last part of the path,
            // the new node's name; `String(...)` copies the Substring.
            let name = String(path.split(separator: "/").last ?? Substring(path))
            try document.connect(input: input, on: elementPaths[slot.node], to: name,
                                 output: outputCount > 1 ? port : nil)
        }
    }

    /// Disconnects each of `inputs` in `document`.
    public func disconnect(_ inputs: [InputSlot], in document: MXDocument) throws {
        for slot in inputs {
            let input: String = kinds[slot.node] == .output ? "" : slot.name
            try document.disconnect(input: input, on: elementPaths[slot.node])
        }
    }

    /// The Edit menu's name for undoing `connection`, such as "Connect
    /// scale to offset.in2".
    public func undoName(for connection: WireConnection) -> String {
        let source: String = elementName(of: connection.output.node)
        let target: String = describe(connection.input)
        return connection.movedFrom == nil ? "Connect \(source) to \(target)" : "Move Connection to \(target)"
    }

    /// The Edit menu's name for undoing a disconnection.
    public func undoName(forDisconnecting inputs: [InputSlot]) -> String {
        inputs.count == 1 ? "Disconnect \(describe(inputs[0]))" : "Disconnect \(inputs.count) Inputs"
    }

    /// "offset.in2" for a node's input; just "out" for an <output>.
    private func describe(_ slot: InputSlot) -> String {
        kinds[slot.node] == .output ? elementName(of: slot.node) : "\(elementName(of: slot.node)).\(slot.name)"
    }
}
