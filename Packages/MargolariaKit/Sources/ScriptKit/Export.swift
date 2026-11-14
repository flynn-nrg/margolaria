// Export.swift
//
// The exports scripts make (`margolaria.export_usd`, `export_usdz`,
// `export_shader`, M6b) and the command line's (`margolaria export`, M6e):
// the same calls as the app's File > Export as USD… and Export as USDZ…,
// and the Generated Shader tab's Export…, so each gives the same files.
//
// Introduces (SWIFT): nothing new.

import Foundation
import MXKit
import ViewportKit

/// Writes a document's exports.
enum Export {
    /// The shader languages, by the names scripts and the command line use.
    static let languages: [String: MXShaderLanguage] = ["msl": .msl, "glsl": .glsl, "osl": .osl,
                                                        "osl_network": .oslNetwork]

    /// The document's materials as USD, at `url` (.usda, .usdc or .usd).
    static func usd(_ document: MXDocument, to url: URL) throws {
        try MGUSDExporter.exportMaterials(fromMaterialXString: try document.usdXMLString(), to: url)
    }

    /// A USDZ package at `url`: `shape` with `material` (by name; the
    /// first if nil), the other materials, and every texture. A material
    /// the document doesn't have is an error, rather than the exporter's
    /// first: a name mistyped in a script or a pipeline would go unseen.
    static func usdz(_ document: MXDocument, to url: URL, material: String?, shape: ViewportShape) throws {
        let materials: [String] = document.topLevelElements.filter { $0.type == "material" }.map(\.name)
        if let material, !materials.contains(material) {
            throw ScriptError.noMaterial(material, materials)
        }
        try MGUSDExporter.exportPreview(fromMaterialXString: try document.usdzXMLString(), to: url,
                                        materialName: material, shape: shape.bridged)
    }

    /// The shader for the element at `path`, in `language` ("msl", "glsl",
    /// "osl" or "osl_network"), computing in `colorSpace`, written into
    /// `folder`; for "osl", compiled with `oslc` if given. Returns the
    /// files.
    static func shader(of path: String, in document: MXDocument, language: String, colorSpace: String,
                       to folder: URL, oslc: URL?) throws -> [URL] {
        guard let shaderLanguage = languages[language] else {
            throw ScriptError.unknownLanguage(language)
        }
        let library: MXLibrary = try MXLibrary.bundled.get()
        let code: MXShaderCode = try MXShaderExport.generate(shaderLanguage, for: path,
                                                             previewXML: try document.previewXMLString(),
                                                             colorSpace: colorSpace, library: library)
        return try MXShaderExport.write(code, named: MXShaderExport.fileName(for: path), to: folder, oslc: oslc,
                                        library: library)
    }
}
