// MXWorkingSpace.swift
//
// The working space of a document or nodegraph: the colour space its
// untagged colours are in (`colorspace` on <materialx> or <nodegraph>;
// lin_rec709 when nothing says). Changing it changes what every untagged
// colour value and colour image below it means, so a change can keep the
// colours as they look: values are converted to the new space, and images
// (whose numbers are in their files) are tagged with the old one.
//
// MXKit doesn't do colour management itself (that's ColorKit, with OCIO):
// the conversion is passed in as a function.
//
// Introduces (SWIFT): a function type as a parameter, with argument labels
// left out (`([Double], String, String) throws -> [Double]`).

import Foundation
import MXBridge

/// The working space of the document or of a nodegraph.
public struct MXWorkingSpace: Equatable, Sendable {
    /// Its own `colorspace`, or nil.
    public let own: String?
    /// The space it would be in without one: for a nodegraph, its parent's;
    /// nil means the document's default.
    public let inherited: String?

    /// MaterialX's working space for documents that don't name one.
    public static let documentDefault: String = "lin_rec709"

    /// The space in effect.
    public var active: String {
        own ?? inherited ?? Self.documentDefault
    }

    /// What it would be without its own `colorspace`.
    public var inheritedOrDefault: String {
        inherited ?? Self.documentDefault
    }
}

/// A colour that is in a working space: a color3 or color4 value, or the
/// file of an image node with a colour output.
public struct MXColorUse: Equatable, Sendable {
    /// The node or nodegraph whose input it is.
    public let ownerPath: String
    public let inputName: String
    /// "color3", "color4" or "filename".
    public let type: String
    /// The numbers, or the file name.
    public let value: String
    /// True for an input left at its nodedef's default (M7e): `value` is
    /// the default, and converting it sets the input.
    public var isDefault: Bool = false

    /// True for an image file, which can only be tagged.
    public var isFile: Bool {
        type == "filename"
    }
}

extension MXDocument {
    /// The working space of the document (`path` "") or of the nodegraph
    /// at `path`.
    public func workingSpace(of path: String) -> MXWorkingSpace {
        let info = handle.workingSpace(std.string(path))
        return MXWorkingSpace(own: info.own.swiftString.nonEmpty, inherited: info.inherited.swiftString.nonEmpty)
    }

    /// The colours that are in the working space of the document (`path`
    /// "") or of the nodegraph at `path`: without a `colorspace` of their
    /// own or on anything in between. Included elements, and nodegraphs
    /// implementing a nodedef, are left out.
    public func colorsInWorkingSpace(of path: String) -> [MXColorUse] {
        colorUses(of: path, defaults: false)
    }

    /// The colour inputs left at their nodedef's default in the working
    /// space of the document (`path` "") or of the nodegraph at `path`
    /// (M7e): their numbers are read in that space too, so a coloured
    /// default changes colour with it. Each has ``MXColorUse/isDefault``.
    public func defaultColorsInWorkingSpace(of path: String) -> [MXColorUse] {
        colorUses(of: path, defaults: true)
    }

    private func colorUses(of path: String, defaults: Bool) -> [MXColorUse] {
        handle.colorsInWorkingSpace(std.string(path), defaults).map { use in
            MXColorUse(ownerPath: use.ownerPath.swiftString, inputName: use.inputName.swiftString,
                       type: use.type.swiftString, value: use.value.swiftString, isDefault: defaults)
        }
    }

    /// What converting from the working space of `path` to `space` (nil:
    /// the one it would inherit) changes, to keep the colours' look: the
    /// colours set (``colorsInWorkingSpace(of:)``), and the defaults whose
    /// numbers the conversion changes (M7e). Greys are the same in every
    /// space, so most defaults (a surface's white specular colour) aren't
    /// listed. Empty when the space doesn't change.
    public func colorsToConvert(of path: String, to space: String?,
                                convert: ([Double], String, String) throws -> [Double]) throws -> [MXColorUse] {
        let before: MXWorkingSpace = workingSpace(of: path)
        let from: String = before.active
        let to: String = space ?? before.inheritedOrDefault
        guard from != to else {
            return []
        }
        var uses: [MXColorUse] = colorsInWorkingSpace(of: path)
        for use in defaultColorsInWorkingSpace(of: path) {
            guard let numbers = MXValueText.numbers(use.value) else {
                continue
            }
            let converted: [Double] = try convert(numbers, from, to)
            // SWIFT: `zip` pairs the numbers before and after; `contains`
            // asks whether any pair moved by more than the tolerance.
            if zip(numbers, converted).contains(where: { abs($0 - $1) > Self.unchangedTolerance }) {
                uses.append(use)
            }
        }
        return uses
    }

    /// How far a converted number may be from the original and still count
    /// as unchanged: a grey converted between spaces comes back off by
    /// rounding (0.79999995 for 0.8), and a default isn't set for that.
    static let unchangedTolerance: Double = 1e-4

    /// Sets the working space of the document (`path` "") or of the
    /// nodegraph at `path`; nil removes its `colorspace`, so it inherits.
    ///
    /// With `convert` (numbers, from space, to space → numbers), the
    /// colours keep their look: each value in ``colorsToConvert(of:to:convert:)``
    /// is converted to the new space (a default is set on its node,
    /// converted, M7e), and each image is tagged with the old one.
    /// Without, the numbers stay and mean colours in the new space.
    ///
    /// SWIFT: `convert` is an optional function. Its type,
    /// `([Double], String, String) throws -> [Double]`, has no argument
    /// labels: labels belong to declarations, not to function types.
    ///
    /// - Throws: ``MXError`` if an edit is refused, or what `convert`
    ///   throws. The document may then be half changed: callers undo by
    ///   restoring a copy, as MaterialXDocument's `edit` does.
    public func setWorkingSpace(_ space: String?, of path: String,
                                convert: (([Double], String, String) throws -> [Double])? = nil) throws {
        let before: MXWorkingSpace = workingSpace(of: path)
        let from: String = before.active
        let to: String = space ?? before.inheritedOrDefault
        if let convert, from != to {
            for use in try colorsToConvert(of: path, to: space, convert: convert) {
                if use.isFile {
                    try setColorSpace(from, ofInput: use.inputName, on: use.ownerPath)
                } else if let numbers = MXValueText.numbers(use.value) {
                    let converted: [Double] = try convert(numbers, from, to)
                    try setValue(MXValueText.text(converted, as: MXValueType(use.type)), ofInput: use.inputName,
                                 on: use.ownerPath)
                }
            }
        }
        try perform { error in
            handle.setWorkingSpace(std.string(path), std.string(space ?? ""), &error)
        }
    }
}
