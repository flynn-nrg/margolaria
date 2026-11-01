// MXInterfaceEdit.swift
//
// A nodegraph's interface (M4b, PLAN.md §8.5): its own inputs, which are
// what the graph shows as a node, and how the inspector presents them.
// Values set on them, or connections from outside, reach the nodes inside
// that read them (`interfacename`).
//
// Promoting an input of a node inside the graph makes it one of the
// graph's: a new graph input takes its type, value, colour space and
// metadata, and the node reads it. What the graph computes doesn't change.
// The metadata set here (label, folder, ranges, choices, help) is what a
// node definition made from the graph will show (M4c1).
//
// Not for a nodegraph that implements a nodedef: its inputs are the
// nodedef's. Every edit throws MXError.editRefused when it can't be done,
// leaving the document unchanged.
//
// Introduces (SWIFT): an enum whose cases have explicit raw values that
// differ from their names (`case uiName = "uiname"`).

import Foundation
import MXBridge

/// The metadata of a nodegraph's input that the inspector edits, by its
/// MaterialX attribute name.
///
/// SWIFT: A `String` raw value can differ from the case's name: here the
/// Swift name follows Swift's camelCase, the raw value is the attribute.
/// `CaseIterable` provides `allCases`, in declaration order.
public enum MXInputMetadata: String, CaseIterable, Sendable {
    /// The label shown instead of the name.
    case uiName = "uiname"
    /// The group the input is shown in.
    case uiFolder = "uifolder"
    /// The value's hard limits, values of the input's type.
    case uiMin = "uimin"
    case uiMax = "uimax"
    /// The slider's usual range, inside the limits.
    case uiSoftMin = "uisoftmin"
    case uiSoftMax = "uisoftmax"
    /// The slider's increment.
    case uiStep = "uistep"
    /// The names of the allowed values, comma-separated.
    case enumNames = "enum"
    /// The value stored for each name, in the same order.
    case enumValues = "enumvalues"
    /// A sentence describing the input.
    case doc = "doc"
    /// "true" for an input most users can leave alone.
    case uiAdvanced = "uiadvanced"

    /// A label for the inspector.
    public var title: String {
        switch self {
        case .uiName: "Label"
        case .uiFolder: "Folder"
        case .uiMin: "Minimum"
        case .uiMax: "Maximum"
        case .uiSoftMin: "Slider Minimum"
        case .uiSoftMax: "Slider Maximum"
        case .uiStep: "Step"
        case .enumNames: "Choices"
        case .enumValues: "Choice Values"
        case .doc: "Description"
        case .uiAdvanced: "Advanced"
        }
    }

    /// True for metadata whose value is a value of the input's type.
    public var isValue: Bool {
        switch self {
        case .uiMin, .uiMax, .uiSoftMin, .uiSoftMax, .uiStep: true
        default: false
        }
    }
}

extension MXDocument {
    /// Makes the input `input` of the node at `path` (inside a nodegraph)
    /// one of the graph's own inputs, named `name` (or after the input,
    /// made unique), with its type, value, colour space and metadata; the
    /// node then reads it. Returns the new input's name. Refused for a
    /// connected input, or a node that isn't in a nodegraph.
    @discardableResult
    public func promote(input: String, on path: String, as name: String = "") throws -> String {
        var newName = std.string()
        try perform { error in
            handle.promoteInput(std.string(path), std.string(input), std.string(name), &newName, &error)
        }
        return newName.swiftString
    }

    /// Adds an input of `type` to the nodegraph at `graph`, named `name`
    /// ("in" if empty, made unique), with zero as its value. Returns its
    /// name.
    @discardableResult
    public func addInput(named name: String = "", type: String, to graph: String) throws -> String {
        var newName = std.string()
        try perform { error in
            handle.addGraphInput(std.string(graph), std.string(name), std.string(type), &newName, &error)
        }
        return newName.swiftString
    }

    /// Renames the input `input` of the nodegraph at `graph`, and what
    /// reads it inside.
    public func renameInput(_ input: String, of graph: String, to name: String) throws {
        try perform { error in
            handle.renameGraphInput(std.string(graph), std.string(input), std.string(name), &error)
        }
    }

    /// Removes the input `input` of the nodegraph at `graph`. The nodes
    /// inside that read it take its value instead.
    public func removeInput(_ input: String, of graph: String) throws {
        try perform { error in
            handle.removeGraphInput(std.string(graph), std.string(input), &error)
        }
    }

    /// Sets the metadata `metadata` of the input `input` of the nodegraph
    /// at `graph`; nil (or "") removes it. Range values must be values of
    /// the input's type.
    public func setMetadata(_ metadata: MXInputMetadata, to value: String?, ofInput input: String,
                            on graph: String) throws {
        try perform { error in
            handle.setInputMetadata(std.string(graph), std.string(input), std.string(metadata.rawValue),
                                    std.string(value ?? ""), &error)
        }
    }
}
