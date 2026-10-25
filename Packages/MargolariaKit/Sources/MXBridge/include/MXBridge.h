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

/// One input or output of a node, nodegraph or nodedef, as the graph view
/// needs it. Connection fields hold the MaterialX attributes as written in
/// the file; empty means "not set".
struct PortInfo {
    /// The port's name: "base_color", "out", ...
    std::string name;
    /// The MaterialX type: "float", "color3", "surfaceshader", ...
    std::string type;
    /// The value as written in the file ("0.8, 0.8, 0.8"). For an input the
    /// document doesn't set, the nodedef's default. Empty for outputs.
    std::string value;
    /// True when the element exists in the document; false for an input that
    /// only exists in the nodedef (the node uses the default).
    bool isAuthored = false;
    /// `nodename`: connected to the output of this node (same graph).
    std::string nodeName;
    /// `nodegraph`: connected to an output of this nodegraph (same graph).
    std::string nodeGraphName;
    /// `output`: which output of the node or nodegraph above; on its own, a
    /// top-level <output> element.
    std::string outputName;
    /// `interfacename`: inside a nodegraph, connected to the graph's input.
    std::string interfaceName;
    /// `colorspace` on this port, if any ("srgb_texture", ...).
    std::string colorSpace;
    /// For "filename" inputs: the value with any `fileprefix` applied. Still
    /// relative to `sourceUri`'s folder unless absolute.
    std::string resolvedFilename;
    /// Absolute path of the file this element was read from: differs from
    /// the document's file for elements brought in with xi:include. Empty
    /// for nodedef-only inputs and documents read from a string.
    std::string sourceUri;
    /// The nodedef's `uifolder`, for grouping inputs ("Specular", ...).
    std::string uiFolder;
    /// `uniform="true"`: can't be connected, only set.
    bool isUniform = false;

    // The inspector's metadata (M2b). It comes from the nodedef's input,
    // overridden by attributes on the document's own input (a nodegraph's
    // interface inputs carry their own). Empty when not set; values are in
    // MaterialX's text form for the port's type ("0, 0, 0" for a color3).

    /// The nodedef's default value, whether or not the document sets the
    /// input. Empty for inputs without a nodedef, or without a default.
    std::string defaultValue;
    /// `uiname`: the label to show instead of the name ("Base Color").
    std::string uiName;
    /// `uimin`/`uimax`: the hard limits of the value.
    std::string uiMin;
    std::string uiMax;
    /// `uisoftmin`/`uisoftmax`: the slider's usual range, inside the limits.
    std::string uiSoftMin;
    std::string uiSoftMax;
    /// `uistep`: the slider's increment.
    std::string uiStep;
    /// `enum`: the names of the allowed values, such as {"OPAQUE", "MASK"}.
    std::vector<std::string> enumNames;
    /// `enumvalues`: the value stored for each name, in the same order
    /// ({"0", "1"} for an integer). Empty when the names are the values.
    std::vector<std::string> enumValues;
    /// `doc`: a sentence describing the input.
    std::string doc;
    /// `uiadvanced="true"`: an input most users can leave alone.
    bool isAdvanced = false;
    /// `defaultgeomprop`: an unconnected input reads this geometric
    /// property ("UV0", "Nworld", ...) instead of a value.
    std::string defaultGeomProp;
    /// The colour space the value is in: the port's own `colorspace`, or
    /// the nearest ancestor's, or the nodedef's. Empty means the document's
    /// working space, usually lin_rec709.
    std::string activeColorSpace;
    /// `unit` and `unittype` ("meter", "distance"), for distance and angle inputs.
    std::string unit;
    std::string unitType;
};

/// One node in a graph, or one nodegraph shown as a node in its parent graph.
struct NodeInfo {
    std::string name;
    /// The node's category ("open_pbr_surface", "image", ...), or "nodegraph".
    std::string category;
    /// The output type ("color3", "surfaceshader", "multioutput", ...).
    std::string type;
    /// Path from the document root, such as "NG_copper/grain".
    std::string path;
    /// The nodedef this node resolves to, such as "ND_image_color3"; for a
    /// nodegraph, the nodedef it implements, if any. Empty when there is none
    /// or it isn't found. Needs Document::setDataLibrary first.
    std::string nodeDefName;
    /// The nodedef's `nodegroup`: "pbr", "texture2d", "math", ... Empty
    /// without a nodedef. The canvas colours node headers by it.
    std::string nodeGroup;
    /// The nodedef's `doc` attribute: what the node does. Empty without one.
    std::string doc;
    bool isNodeGraph = false;
    /// True for an element that came from an `xi:include`d file. Such
    /// elements are read-only: saving writes the include back as a
    /// reference, so changes to them would be lost.
    bool isIncluded = false;
    /// `xpos`/`ypos`, as written by MaterialX's Graph Editor. Most files
    /// don't have them; the app lays those out itself.
    bool hasPosition = false;
    float xpos = 0;
    float ypos = 0;
    /// Every input: the nodedef's, in nodedef order, with the document's
    /// values and connections; then any the document sets that the nodedef
    /// doesn't have (an error, but shown). For a nodegraph, its interface inputs.
    std::vector<PortInfo> inputs;
    /// The outputs: from the nodedef, or a nodegraph's <output> elements.
    std::vector<PortInfo> outputs;
};

/// One level of a document's graph: the document root, or one nodegraph.
struct GraphInfo {
    /// "" for the document root; otherwise the nodegraph's path.
    std::string path;
    /// The nodes in this graph, in file order. Nodegraphs are included as
    /// nodes (with `isNodeGraph`).
    std::vector<NodeInfo> nodes;
    /// A nodegraph's interface inputs (empty at the document root).
    std::vector<PortInfo> interfaceInputs;
    /// The <output> elements directly in this graph, with their connections.
    std::vector<PortInfo> outputs;
};

/// One problem found by validation, attached to the element it is about.
struct Issue {
    /// Path of the element, or "" for the document itself.
    std::string elementPath;
    /// MaterialX's message, without the XML of the element it quotes.
    std::string message;
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

    /// Reads a .mtlx file, following any xi:include elements relative to the
    /// file's folder. On failure, returns an empty Document and sets
    /// `errorMessage`.
    static Document readFromFile(const std::string& path, std::string& errorMessage);

    /// Parses MaterialX XML, finding `xi:include`d files in `searchFolder`.
    /// On failure, returns an empty Document and sets `errorMessage`.
    static Document readFromXmlStringInFolder(const std::string& xml, const std::string& searchFolder,
                                              std::string& errorMessage);

    /// True when this handle refers to a document.
    bool isLoaded() const;

    /// An independent copy: same contents, data library and file
    /// locations, sharing nothing with this one. Undo keeps these.
    Document copy() const;

    /// Compares two documents element by element, ignoring formatting
    /// (MaterialX's Element::isEquivalent). On a difference, returns false
    /// and describes the first one in `message`.
    bool isEquivalent(const Document& other, std::string& message) const;

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

    /// Like validate(), but with each problem attached to the element it is
    /// about. Empty when the document is valid.
    std::vector<Issue> validationIssues() const;

    /// One level of the graph: the document root for "", or the nodegraph at
    /// `path`. Returns false and sets `errorMessage` if there is no nodegraph
    /// at that path.
    bool graph(const std::string& path, GraphInfo& graph, std::string& errorMessage) const;

    /// Every nodegraph in the document, in file order, at any depth.
    std::vector<ElementSummary> nodeGraphs() const;

    /// True if the element at `path` came from an `xi:include`d file (see
    /// NodeInfo::isIncluded). False for paths that don't exist.
    bool isIncluded(const std::string& path) const;

    // --- Edits -------------------------------------------------------------
    //
    // Every edit names the element by path. Each returns false and sets
    // `errorMessage` when it is refused (an included element, a type
    // mismatch, a cycle, an invalid name, a path that doesn't exist); the
    // document is then unchanged. Undo is the caller's business (MXKit keeps
    // copies, see copy()).

    /// Sets an input of the node or nodegraph at `elementPath` to `value`
    /// (MaterialX's text form, such as "0.8, 0.2, 0.1"), disconnecting it if
    /// it was connected. An input the document doesn't set yet is added,
    /// with its type from the nodedef.
    bool setInputValue(const std::string& elementPath, const std::string& inputName,
                       const std::string& value, std::string& errorMessage);

    /// Removes an input from the document, so the node uses its nodedef's
    /// default again (and any connection goes with it).
    bool resetInput(const std::string& elementPath, const std::string& inputName, std::string& errorMessage);

    /// Connects an input to the output of a node or nodegraph in the same
    /// graph, called `sourceName`. `sourceOutput` names the output when the
    /// source has several; "" for the only one. `targetPath` may also be
    /// an <output> element, with `inputName` "". The types must match, and
    /// the connection must not create a cycle.
    bool connectInput(const std::string& targetPath, const std::string& inputName,
                      const std::string& sourceName, const std::string& sourceOutput,
                      std::string& errorMessage);

    /// Inside a nodegraph, connects an input to one of the graph's own
    /// inputs (`interfacename`).
    bool connectInterface(const std::string& targetPath, const std::string& inputName,
                          const std::string& interfaceName, std::string& errorMessage);

    /// Removes an input's connection. If it has no value of its own, the
    /// input is removed, so the node uses its default.
    bool disconnectInput(const std::string& targetPath, const std::string& inputName, std::string& errorMessage);

    /// Adds a node defined by the nodedef `nodeDefName` (such as
    /// "ND_multiply_float") to the graph at `parentPath` ("" for the
    /// document). The name is `nameHint`, made valid and unique. Sets
    /// `newPath` to the new node's path.
    bool addNode(const std::string& parentPath, const std::string& nodeDefName, const std::string& nameHint,
                 std::string& newPath, std::string& errorMessage);

    /// Removes the node or nodegraph at `path`, and disconnects everything
    /// that was connected to it.
    bool removeNode(const std::string& path, std::string& errorMessage);

    /// Renames the node or nodegraph at `path`, updating the connections
    /// and material assignments that refer to it. Sets `newPath`.
    bool renameNode(const std::string& path, const std::string& newName,
                    std::string& newPath, std::string& errorMessage);

    /// Sets the `xpos`/`ypos` attributes of the element at `path`.
    bool setPosition(const std::string& path, float x, float y, std::string& errorMessage);

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
