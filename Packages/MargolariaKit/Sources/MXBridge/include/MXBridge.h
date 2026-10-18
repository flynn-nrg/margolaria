// MXBridge.h
//
// The C++ API that Swift sees. MXKit (Swift) imports this header; nothing
// else in Margolaria talks to MaterialX directly.
//
// Rules for this header, so it imports cleanly into Swift:
//
//  1. No MaterialX headers. The MaterialX types live behind a private `Impl`
//     struct (the "pimpl" idiom), defined only in MXBridge.cpp. Swift therefore
//     never has to parse MaterialX's templates, and changes to MaterialX don't
//     ripple into Swift.
//  2. No exceptions cross into Swift. Swift cannot catch C++ exceptions; one
//     that escapes into Swift terminates the app. Every function that might
//     throw catches the exception and reports it through an `errorMessage`
//     out-parameter instead.
//  3. Only simple types in signatures: std::string, std::vector, plain structs,
//     bool and int. Swift imports these well (std::string becomes `std.string`,
//     std::vector becomes a Swift collection you can loop over).
//
// The classes below are cheap-to-copy handles: copying one copies a
// std::shared_ptr, so two copies refer to the same MaterialX object. Swift
// imports C++ classes as Swift *value* types (structs), which would make that
// sharing surprising. MXKit hides it by storing each handle inside a Swift
// `class`, which has reference semantics on purpose (see MXDocument.swift).

#pragma once

#include <memory>
#include <string>
#include <vector>

namespace mxbridge {

/// A short description of one element in a document, for listing in the UI.
/// All fields are empty strings when the attribute doesn't apply.
struct ElementSummary {
    /// The element's `name` attribute, unique among its siblings.
    std::string name;
    /// The element's XML tag: "surfacematerial", "nodegraph", "open_pbr_surface", ...
    std::string category;
    /// The `type` attribute ("material", "surfaceshader", "color3", ...).
    /// Empty for untyped elements such as <look>.
    std::string type;
    /// Number of direct child elements (inputs, outputs, nodes inside a nodegraph, ...).
    int childCount = 0;
    /// The element's path from the document root, such as "NG_copper/grain".
    /// Equal to `name` for top-level elements.
    std::string path;
};

/// One uniform (shader parameter) of a generated shader, with its default value.
struct ShaderUniform {
    /// The variable name in the generated source, such as "noise3d_amplitude"
    /// or "u_worldMatrix".
    std::string name;
    /// The MaterialX type name: "float", "color3", "vector3", "matrix44",
    /// "integer", "boolean", "filename", ...
    std::string type;
    /// The default value as numbers, in order (3 for a color3, 16 for a
    /// matrix44, 1 for a float, integer or boolean). Empty when the uniform
    /// has no default, such as the transform matrices the renderer must set.
    std::vector<float> value;
    /// The default value for string-like types ("filename", "string").
    std::string stringValue;
};

/// A shader generated for one element, in the Metal Shading Language.
struct GeneratedShader {
    /// Complete MSL source for the vertex stage (entry point "VertexMain").
    std::string vertexSource;
    /// Complete MSL source for the fragment stage (entry point "FragmentMain").
    std::string pixelSource;
    /// The type of the output being shaded: "color3", "float",
    /// "surfaceshader", ... Surface shaders need lights; plain values don't.
    std::string outputType;
    /// Every uniform of both stages, with default values where known.
    std::vector<ShaderUniform> uniforms;
};

/// The MaterialX standard data libraries: stdlib, pbrlib, bxdf and the rest.
/// These hold the node definitions (nodedefs) that documents refer to. They
/// are loaded once and shared by every open document.
class Library {
public:
    /// An empty library with nothing loaded. isLoaded() returns false.
    Library();

    /// Loads every .mtlx file under `librariesRoot`/libraries.
    /// `librariesRoot` is the folder that *contains* the `libraries` folder.
    /// On failure, returns an empty Library and sets `errorMessage`.
    static Library loadStandard(const std::string& librariesRoot, std::string& errorMessage);

    /// True when a library has been loaded.
    bool isLoaded() const;

    /// How many .mtlx files were loaded.
    int fileCount() const;

    /// How many <nodedef> elements the libraries contain.
    int nodeDefinitionCount() const;

private:
    // Document::setDataLibrary needs to reach the MaterialX object inside.
    friend class Document;

    // Defined in MXBridge.cpp. Holds the mx::DocumentPtr with the definitions.
    struct Impl;
    std::shared_ptr<Impl> _impl;
};

/// One MaterialX document, typically the contents of one .mtlx file.
class Document {
public:
    /// An empty handle with no document. isLoaded() returns false.
    Document();

    /// Parses MaterialX XML. On failure, returns an empty Document and sets
    /// `errorMessage` (for example, to the XML parser's message).
    static Document readFromXmlString(const std::string& xml, std::string& errorMessage);

    /// True when this handle refers to a document.
    bool isLoaded() const;

    /// Serialises the document back to MaterialX XML. Returns "" if not loaded.
    std::string writeToXmlString() const;

    /// Makes the standard libraries' nodedefs visible to this document, so
    /// validation and nodedef lookups work. The library is referenced, not
    /// copied into the document, so it is not written out when saving.
    void setDataLibrary(const Library& library);

    /// Runs MaterialX's own validation. Returns true if the document is valid;
    /// otherwise returns false and `message` holds one line per problem.
    bool validate(std::string& message) const;

    /// The direct children of the root <materialx> element, in file order.
    std::vector<ElementSummary> topLevelElements() const;

    /// Every element a shader can be generated for, in file order: top-level
    /// nodes and materials, and the nodes and outputs inside nodegraphs.
    std::vector<ElementSummary> shadeableElements() const;

    /// The `version` attribute of the root element, such as "1.39".
    std::string documentVersion() const;

    /// Generates a Metal shader for the element at `elementPath`: a node, a
    /// node's output or a material, for example "NG_copper/grain" or
    /// "M_BrushedCopper". The library provides the node implementations and
    /// must be the one set with setDataLibrary().
    /// Returns false and sets `errorMessage` if generation fails.
    bool generateMsl(const std::string& elementPath, const Library& library,
                     GeneratedShader& shader, std::string& errorMessage) const;

private:
    struct Impl;
    std::shared_ptr<Impl> _impl;
};

/// Version of the MaterialX library we are linked against, such as "1.39.5".
std::string materialXVersion();

} // namespace mxbridge
