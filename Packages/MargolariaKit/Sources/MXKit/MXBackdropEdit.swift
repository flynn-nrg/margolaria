// MXBackdropEdit.swift
//
// The edits of M4d (PLAN.md §8.5): backdrops, MaterialX's frames drawn
// behind a group of nodes, with a note. A backdrop names what it contains
// (`contains`), so moving it on the canvas moves them; deleting it leaves
// them where they are.
//
// Positions and sizes are in MaterialX's units, as nodes' `xpos`/`ypos`
// are (one unit is a node of MaterialX's Graph Editor; GraphBuilder
// converts to canvas points). The specification doesn't give units for
// `width` and `height`; using the positions' units keeps a backdrop
// around its nodes whatever editor reads it.
//
// The bridge keeps `contains` current through the other edits: removing a
// node drops it, renaming renames it, collapsing nodes into a nodegraph
// puts the graph in their backdrop, ungrouping puts the nodes back in it.
//
// Introduces (SWIFT): `CGRect`'s `origin` and `size` as separate values.

import CoreGraphics
import Foundation
import MXBridge

extension MXDocument {
    /// Adds a backdrop to the graph at `parent` ("" for the document),
    /// framing the elements `contains` (by name, in that graph), at
    /// `frame` in MaterialX units. Named `name` ("backdrop" if empty),
    /// made unique. Returns its path.
    @discardableResult
    public func addBackdrop(containing contains: [String], in parent: String = "", frame: CGRect,
                            named name: String = "") throws -> String {
        var newPath = std.string()
        try perform { error in
            handle.addBackdrop(std.string(parent), Self.stringVector(contains), std.string(name),
                               Float(frame.minX), Float(frame.minY), Float(frame.width), Float(frame.height),
                               &newPath, &error)
        }
        return newPath.swiftString
    }

    /// Moves and resizes the backdrop at `path`: its top-left corner and
    /// size, in MaterialX units. What it contains doesn't move with it:
    /// the canvas moves those, as nodes.
    ///
    /// SWIFT: A `CGRect` is an `origin` (`CGPoint`) and a `size`
    /// (`CGSize`); `minX`/`minY` read the origin, normalised so they are
    /// the smallest corner even for a negative size.
    public func setFrame(_ frame: CGRect, ofBackdrop path: String) throws {
        try perform { error in
            handle.setBackdropFrame(std.string(path), Float(frame.minX), Float(frame.minY),
                                    Float(frame.width), Float(frame.height), &error)
        }
    }

    /// Sets what the backdrop at `path` contains: elements of its graph,
    /// by name. Empty for nothing.
    public func setContents(_ contains: [String], ofBackdrop path: String) throws {
        try perform { error in
            handle.setBackdropContents(std.string(path), Self.stringVector(contains), &error)
        }
    }

    /// Sets the backdrop's note; "" removes it.
    public func setNote(_ note: String, ofBackdrop path: String) throws {
        try perform { error in
            handle.setBackdropNote(std.string(path), std.string(note), &error)
        }
    }

    /// Removes the backdrop at `path`, leaving what it contains.
    public func removeBackdrop(at path: String) throws {
        try perform { error in
            handle.removeBackdrop(std.string(path), &error)
        }
    }
}
