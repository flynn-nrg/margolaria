// MXDocumentTemplate.swift
//
// What File > New starts from (M2e): a material ready to edit (a shader
// feeding a surfacematerial, so the viewport shows it straight away), or
// an empty document.
//
// Introduces (SWIFT): nothing new.

import Foundation

/// A starting point for a new document.
public enum MXDocumentTemplate: String, CaseIterable, Identifiable, Sendable {
    /// `open_pbr_surface` feeding a `surfacematerial`.
    case openPBR
    /// `standard_surface` feeding a `surfacematerial`.
    case standardSurface
    /// Nothing at all.
    case empty

    public var id: String { rawValue }

    /// The name shown for it.
    public var title: String {
        switch self {
        case .openPBR:
            return "OpenPBR Material"
        case .standardSurface:
            return "Standard Surface Material"
        case .empty:
            return "Empty Document"
        }
    }

    /// A sentence saying what it is.
    public var summary: String {
        switch self {
        case .openPBR:
            return "An OpenPBR Surface shader in a material: the current Academy Software Foundation standard."
        case .standardSurface:
            return "An Autodesk Standard Surface shader in a material, as many existing assets use."
        case .empty:
            return "No nodes. Add them from the Library, or with Tab on the canvas."
        }
    }

    /// The document's XML.
    ///
    /// SWIFT: A multi-line raw string, `#"""..."""#`: the indentation of
    /// the closing delimiter is removed from every line.
    public var xml: String {
        switch self {
        case .openPBR:
            return Self.material(shader: "open_pbr_surface")
        case .standardSurface:
            return Self.material(shader: "standard_surface")
        case .empty:
            return #"""
                <?xml version="1.0"?>
                <materialx version="1.39" />
                """#
        }
    }

    /// A `shader` node feeding a material, side by side (in the Graph
    /// Editor's units, as DocumentGraph saves positions).
    private static func material(shader: String) -> String {
        #"""
        <?xml version="1.0"?>
        <materialx version="1.39">
          <\#(shader) name="shader" type="surfaceshader" xpos="0" ypos="0" />
          <surfacematerial name="material" type="material" xpos="1.5" ypos="0">
            <input name="surfaceshader" type="surfaceshader" nodename="shader" />
          </surfacematerial>
        </materialx>
        """#
    }

    /// The template as a document.
    public func makeDocument() throws -> MXDocument {
        try MXDocument(xml: xml)
    }
}
