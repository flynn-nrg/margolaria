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

/// A list of strings, such as element names. Swift can't name a C++
/// template instantiation itself, only an alias for one.
using StringVector = std::vector<std::string>;

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

/// A document's preview text with a material showing one element on its
/// own (Document::writeSoloPreview).
struct SoloPreview {
    /// The preview XML, with the added material.
    std::string xml;
    /// The material to show: the added one, or the element itself.
    std::string materialName;
    /// The type of what is shown: "float", "color3", "surfaceshader", ...
    std::string outputType;
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
    /// The colour space the value would be in without the port's own
    /// `colorspace`: the owner's, or an ancestor's. Empty means the
    /// document's working space. What "Default" means in the inspector's
    /// colour space menu.
    std::string inheritedColorSpace;
    /// `unit` and `unittype` ("meter", "distance"), for distance and angle inputs.
    std::string unit;
    std::string unitType;
    /// `xpos`/`ypos`: where a nodegraph's own input or output is drawn
    /// inside the graph, as MaterialX's Graph Editor writes them (and the
    /// canvas, since the fix after M4a). Unset for most.
    bool hasPosition = false;
    float xpos = 0;
    float ypos = 0;
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
    /// For a nodegraph: true if it implements a nodedef defined in this
    /// document (not the libraries, not an included file). Its inputs,
    /// defaults and metadata are then the nodedef's, and edited here (M4c1).
    bool isLocalDefinition = false;
    /// The nodedef's `version` ("1.0"), if it has one.
    std::string nodeDefVersion;
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

/// The working space of the document or of a nodegraph: the colour space
/// its untagged colours are in.
struct WorkingSpaceInfo {
    /// Its own `colorspace`; empty if it has none.
    std::string own;
    /// What it would be in without one: for a nodegraph, its parent's
    /// active space; for the document, always empty (MaterialX's default,
    /// lin_rec709).
    std::string inherited;
};

/// A colour that is in a working space because nothing between it and the
/// document or nodegraph tags it with another: a color3 or color4 value,
/// or the file of an image node whose output is a colour.
struct ColorUse {
    /// The node or nodegraph whose input it is.
    std::string ownerPath;
    std::string inputName;
    /// "color3", "color4" or "filename".
    std::string type;
    /// The value: numbers, or the file name.
    std::string value;
};

/// A backdrop (M4d): a frame drawn behind some of a graph's elements, to
/// group and annotate them. MaterialX's `<backdrop>`: layout only, ignored
/// by shader generation and renderers.
struct BackdropInfo {
    std::string name;
    /// Path from the document root, such as "NG_copper/grain_notes".
    std::string path;
    /// The elements it frames (`contains`), by name: nodes, nodegraphs,
    /// and a nodegraph's own inputs and outputs, all siblings of it.
    StringVector contains;
    /// Its `note`: text shown in it. Empty without one.
    std::string note;
    /// True if it came from an `xi:include`d file (read-only).
    bool isIncluded = false;
    /// `xpos`/`ypos`, its top-left corner, in the units nodes' positions
    /// are in. Unset when another tool wrote it without one.
    bool hasPosition = false;
    float xpos = 0;
    float ypos = 0;
    /// `width`/`height`, in the same units. Unset when another tool wrote
    /// it without them: the canvas then fits it around what it contains.
    bool hasSize = false;
    float width = 0;
    float height = 0;
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
    /// Its backdrops (M4d), in file order.
    std::vector<BackdropInfo> backdrops;
};

/// One problem found by validation, attached to the element it is about.
struct Issue {
    /// Path of the element, or "" for the document itself.
    std::string elementPath;
    /// MaterialX's message, without the XML of the element it quotes.
    std::string message;
};

/// One input or output of a nodedef, for the node library (M2e).
struct NodeDefPort {
    std::string name;
    /// The MaterialX type: "float", "color3", ...
    std::string type;
    /// `uniform="true"`: takes a value, not a node's output.
    bool isUniform = false;
};

/// One node definition, as the node library lists it (M2e): enough to
/// group, search and describe it, and to tell its type variants apart.
struct NodeDefSummary {
    /// The nodedef's name: "ND_multiply_color3FA".
    std::string name;
    /// The category of the nodes it defines: "multiply".
    std::string node;
    /// The output type: "color3", or "multioutput" for several outputs.
    std::string type;
    /// `nodegroup`: "math", "texture2d", "pbr", ... Empty when not set.
    std::string nodeGroup;
    /// `doc`: what the node does. Often empty.
    std::string doc;
    /// True for a nodedef in the document itself (or a file it includes),
    /// rather than the data libraries.
    bool isFromDocument = false;
    std::vector<NodeDefPort> inputs;
    std::vector<NodeDefPort> outputs;
};

/// What a new node definition is called and how it is described (M4c1).
struct NodeDefSpec {
    /// The node's category, which nodes of it are written as: "my_tiles".
    std::string node;
    /// The nodedef's name: "ND_my_tiles_color3".
    std::string name;
    /// `nodegroup`: "texture2d", "pbr", ... Empty for none.
    std::string nodeGroup;
    /// `version`, such as "1.0"; empty for none.
    std::string version;
    /// `doc`: what the node does.
    std::string doc;
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

    /// Parses `xml` as this document's own text (the XML tab, M4e): its
    /// `xi:include`s found next to this document's file, that file recorded
    /// as its source (so included elements and relative texture paths
    /// resolve as they do here), and this document's data library. On
    /// failure, returns an empty Document and sets `errorMessage`.
    Document readText(const std::string& xml, std::string& errorMessage) const;

    /// Compares two documents element by element, ignoring formatting
    /// (MaterialX's Element::isEquivalent). On a difference, returns false
    /// and describes the first one in `message`.
    bool isEquivalent(const Document& other, std::string& message) const;

    /// Serialises the document back to MaterialX XML. Returns "" if not loaded.
    std::string writeToXmlString() const;

    /// The document as XML for a renderer that reads it from memory (the
    /// viewport, M2c): self-contained, so it doesn't depend on where it is
    /// read from. Included files are written inline rather than as
    /// `xi:include`, and every filename is made absolute, with `fileprefix`
    /// applied, against the folder of the file the element came from.
    /// Returns "" if not loaded.
    std::string writeForPreview() const;

    /// The same, for Storm (the viewport): nodegraphs that Storm would
    /// draw wrong are ungrouped (their inputs read nodes, or nodes other
    /// than shaders read them, or they hold a shader; PLAN.md §8.2). The
    /// materials compute the same, but nodes inside those graphs have
    /// other paths, so swatches use writeForPreview().
    std::string writeForViewport() const;

    /// writeForViewport's text, with a material added that shows the element at
    /// `elementPath` on its own (solo preview, M3d): a value through
    /// `convert` nodes into the emission of an otherwise black surface, a BSDF in a `surface`, a
    /// surface shader as it is, each in a new surfacematerial; a material
    /// itself. A node inside a nodegraph is reached through a new output
    /// of the graph. The document itself is not changed.
    bool writeSoloPreview(const std::string& elementPath, SoloPreview& solo, std::string& errorMessage) const;

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

    /// Every nodedef a node can be added from: the document's own, then
    /// the data library's, each name once. Superseded versions (a
    /// `version` that isn't the `isdefaultversion` one) are left out.
    std::vector<NodeDefSummary> nodeDefinitions() const;

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
    /// default again (and any connection goes with it). If removing it
    /// would change which nodedef the node matches (type variants such as
    /// `ND_multiply_vector3FA`), the input stays, set to the default.
    bool resetInput(const std::string& elementPath, const std::string& inputName, std::string& errorMessage);

    /// Sets the `colorspace` of an input of the node or nodegraph at
    /// `elementPath`; "" removes it, so the input is in its owner's space
    /// again. The value is left as it is: converting it, if wanted, is a
    /// separate setInputValue. An input the document doesn't set yet is
    /// added, with the nodedef's default value.
    bool setInputColorSpace(const std::string& elementPath, const std::string& inputName,
                            const std::string& colorSpace, std::string& errorMessage);

    /// Connects an input to the output of a node or nodegraph in the same
    /// graph, called `sourceName`. `sourceOutput` names the output when the
    /// source has several; "" for the only one. `targetPath` may also be
    /// an <output> element, with `inputName` "". The types must match, the
    /// connection must not create a cycle, and a `uniform` input can't be
    /// connected to a node.
    bool connectInput(const std::string& targetPath, const std::string& inputName,
                      const std::string& sourceName, const std::string& sourceOutput,
                      std::string& errorMessage);

    /// Inside a nodegraph, connects an input to one of the graph's own
    /// inputs (`interfacename`). Not an <output>: MaterialX allows
    /// `interfacename` only on inputs.
    bool connectInterface(const std::string& targetPath, const std::string& inputName,
                          const std::string& interfaceName, std::string& errorMessage);

    /// Removes an input's connection. If it is a node's input with no value
    /// of its own, the input is removed, so the node uses its default.
    bool disconnectInput(const std::string& targetPath, const std::string& inputName, std::string& errorMessage);

    /// Adds a node defined by the nodedef `nodeDefName` (such as
    /// "ND_multiply_float") to the graph at `parentPath` ("" for the
    /// document). The name is `nameHint`, made valid and unique. Sets
    /// `newPath` to the new node's path. The node records its nodedef
    /// (`nodedef="..."`), as MaterialX's addNodeInstance does.
    bool addNode(const std::string& parentPath, const std::string& nodeDefName, const std::string& nameHint,
                 std::string& newPath, std::string& errorMessage);

    /// Changes the node at `path` to another type variant of the same
    /// node, the nodedef `nodeDefName` ("ND_multiply_float" to
    /// "ND_multiply_color3"). Inputs the new nodedef has with the same
    /// type keep their values and connections; the others are removed.
    /// Connections from the node's outputs stay where the types still
    /// match, and are disconnected elsewhere. The node records the nodedef
    /// (`nodedef="..."`), so MaterialX doesn't match it to another variant.
    bool changeNodeDef(const std::string& path, const std::string& nodeDefName, std::string& errorMessage);

    /// Removes the node or nodegraph at `path`, and disconnects everything
    /// that was connected to it. Refused for a nodegraph implementing a
    /// nodedef (see removeNodeDefinition).
    bool removeNode(const std::string& path, std::string& errorMessage);

    /// Renames the node, nodegraph or backdrop at `path`, updating the
    /// connections, material assignments and backdrops that refer to it.
    /// Sets `newPath`.
    bool renameNode(const std::string& path, const std::string& newName,
                    std::string& newPath, std::string& errorMessage);

    /// Sets the `xpos`/`ypos` attributes of the element at `path`.
    bool setPosition(const std::string& path, float x, float y, std::string& errorMessage);

    // --- Backdrops (M4d) --------------------------------------------------------
    //
    // A backdrop's `contains` names siblings, so the edits that remove or
    // rename elements keep it up to date: every edit drops the names that
    // are gone, renames follow, collapsing puts the new nodegraph where its
    // nodes were, and ungrouping puts the nodes where their graph was.

    /// Adds a backdrop to the graph at `parentPath` ("" for the document),
    /// named `nameHint` ("backdrop" if empty, made unique), containing the
    /// elements `contains` (siblings of it), at `x`, `y` and `width` by
    /// `height`. Sets `newPath`.
    bool addBackdrop(const std::string& parentPath, const StringVector& contains, const std::string& nameHint,
                     float x, float y, float width, float height, std::string& newPath, std::string& errorMessage);

    /// Sets the position (`xpos`/`ypos`) and size (`width`/`height`) of
    /// the backdrop at `path`.
    bool setBackdropFrame(const std::string& path, float x, float y, float width, float height,
                          std::string& errorMessage);

    /// Sets what the backdrop at `path` contains: siblings of it, by name.
    /// An empty list removes the `contains` attribute.
    bool setBackdropContents(const std::string& path, const StringVector& contains, std::string& errorMessage);

    /// Sets the backdrop's `note`; "" removes it.
    bool setBackdropNote(const std::string& path, const std::string& note, std::string& errorMessage);

    /// Removes the backdrop at `path`. What it contains stays.
    bool removeBackdrop(const std::string& path, std::string& errorMessage);

    // --- Nodegraphs, outputs, copy and paste (M4a) --------------------------

    /// Moves the nodes called `names` at the top level of the document
    /// into a new nodegraph there,
    /// named `nameHint` (made unique), placed at their average position.
    /// Connections that cross the new graph's edge go through it: an input
    /// reading something left outside reads a new input of the graph
    /// (named after it, one per thing read), and what reads the moved
    /// nodes from outside reads a new output ("out", or `node_output` when
    /// there are several). Materials can't be moved: they stay at the top
    /// level. Nodegraphs can't be nested (`parentPath` must be "", and
    /// `names` can't include one): MaterialX 1.39.5 can't connect to a
    /// nodegraph inside another. Sets `newPath`.
    bool collapseIntoNodeGraph(const std::string& parentPath, const StringVector& names, const std::string& nameHint,
                               std::string& newPath, std::string& errorMessage);

    /// The opposite: moves the nodes of the nodegraph at `path` into its
    /// parent (renamed where their names are taken), connects them to what
    /// the graph's inputs read or to their values, connects what read the
    /// graph's outputs to what those read, and removes the graph. Nodes
    /// keep the graph's working space and file prefix. Refused for a graph
    /// that implements a nodedef. Sets `newPaths` to the nodes' new paths.
    bool ungroupNodeGraph(const std::string& path, StringVector& newPaths, std::string& errorMessage);

    /// Adds an empty nodegraph to the document (`parentPath` must be "",
    /// see collapseIntoNodeGraph), named `nameHint` (made unique). Sets
    /// `newPath`.
    bool addNodeGraph(const std::string& parentPath, const std::string& nameHint, std::string& newPath,
                      std::string& errorMessage);

    /// Adds an `<output>` of `type` to the nodegraph at `graphPath`, named
    /// `nameHint` (made unique), connected to nothing. Sets `newName`.
    /// Ports reading the graph's only output without naming it are made to
    /// name it, since there are now two. Refused for a graph that
    /// implements a nodedef: its outputs are the nodedef's.
    bool addGraphOutput(const std::string& graphPath, const std::string& nameHint, const std::string& type,
                        std::string& newName, std::string& errorMessage);

    /// Renames the output `outputName` of the nodegraph at `graphPath`,
    /// and what reads it by name.
    bool renameGraphOutput(const std::string& graphPath, const std::string& outputName, const std::string& newName,
                           std::string& errorMessage);

    /// Removes the output `outputName` of the nodegraph at `graphPath`,
    /// disconnecting what read it.
    bool removeGraphOutput(const std::string& graphPath, const std::string& outputName, std::string& errorMessage);

    // --- A nodegraph's interface (M4b) ----------------------------------------
    //
    // A nodegraph's own inputs are what it shows as a node: values set
    // there, or connections from outside, reach the nodes inside that read
    // them (`interfacename`). Not for a nodegraph that implements a
    // nodedef: its inputs are the nodedef's (M4c1).

    /// Makes the input `inputName` of the node at `elementPath` (inside a
    /// nodegraph) one of the graph's inputs: a new graph input, named
    /// `nameHint` or after the input (made unique), takes its type, value
    /// (or the nodedef's default), colour space, `uniform` and metadata
    /// (uiname, uifolder, ranges, enum, doc, unit...: the input's, else the
    /// nodedef's), and the input reads it. Refused for a connected input.
    /// Sets `newName`.
    bool promoteInput(const std::string& elementPath, const std::string& inputName, const std::string& nameHint,
                      std::string& newName, std::string& errorMessage);

    /// Adds an input of `type` to the nodegraph at `graphPath`, named
    /// `nameHint` ("in" if empty, made unique), with zero for its value.
    /// Sets `newName`.
    bool addGraphInput(const std::string& graphPath, const std::string& nameHint, const std::string& type,
                       std::string& newName, std::string& errorMessage);

    /// Renames the input `inputName` of the nodegraph at `graphPath`, and
    /// the `interfacename` of the inputs inside that read it.
    bool renameGraphInput(const std::string& graphPath, const std::string& inputName, const std::string& newName,
                          std::string& errorMessage);

    /// Removes the input `inputName` of the nodegraph at `graphPath`. The
    /// inputs inside that read it take its value instead (or go back to
    /// their default if it has none).
    bool removeGraphInput(const std::string& graphPath, const std::string& inputName, std::string& errorMessage);

    /// Sets the metadata `attribute` of the input `inputName` of the
    /// nodegraph at `graphPath`: one of uiname, uifolder, uimin, uimax,
    /// uisoftmin, uisoftmax, uistep (values of the input's type), enum,
    /// enumvalues (comma-separated lists), doc, uiadvanced ("true"), unit,
    /// unittype, defaultgeomprop. "" removes it (and `enum` takes
    /// `enumvalues` with it).
    bool setInputMetadata(const std::string& graphPath, const std::string& inputName, const std::string& attribute,
                          const std::string& value, std::string& errorMessage);

    // --- Node definitions (M4c1) ----------------------------------------------

    /// Makes the top-level nodegraph at `graphPath` the implementation of a
    /// new nodedef described by `spec`, whose inputs and outputs are the
    /// graph's (the inputs' values as defaults, with their metadata).
    /// Where the graph was used (read, or its inputs connected), a node of
    /// the new kind takes its place and name; the graph is renamed
    /// "NG_<node>". Refused for a name that is taken or a standard node's,
    /// and for a graph without outputs. Sets `nodeDefName`, and
    /// `instancePath` to the new node's path ("" if the graph was unused).
    bool makeNodeDefinition(const std::string& graphPath, const NodeDefSpec& spec, std::string& nodeDefName,
                            std::string& instancePath, std::string& errorMessage);

    /// Removes the nodedef the nodegraph at `graphPath` implements (if it
    /// is in this document) and the graph. Refused while any node is of it.
    bool removeNodeDefinition(const std::string& graphPath, std::string& errorMessage);

    /// Sets `nodegroup`, `doc` or `version` (with `isdefaultversion`) of the
    /// nodedef the nodegraph at `graphPath` implements, if it is in this
    /// document; "" removes it.
    bool setNodeDefAttribute(const std::string& graphPath, const std::string& attribute, const std::string& value,
                             std::string& errorMessage);

    // --- Libraries (M4c2) -----------------------------------------------------

    /// The nodedef the nodegraph at `graphPath` implements (in this
    /// document) and the graph, as a MaterialX document of their own: what
    /// a library file holds. File names are made absolute. Refused if the
    /// graph uses nodes of another definition made in this document.
    bool writeNodeDefinition(const std::string& graphPath, std::string& xml, std::string& errorMessage) const;

    /// Adds the elements of the MaterialX file at `filePath` (a library) to
    /// the document as included from `href`: saving writes
    /// `<xi:include href="...">` rather than copies, and they are read-only
    /// here. `href` is relative to the document's file, or absolute. Does
    /// nothing for a file already included; refused if one of its names is
    /// taken by an element of the document. Sets `nodeDefNames` to the
    /// file's nodedefs.
    bool includeLibrary(const std::string& filePath, const std::string& href, StringVector& nodeDefNames,
                        std::string& errorMessage);

    /// The nodes and nodegraphs `names` of the graph at `parentPath`, as a
    /// small MaterialX document (`xml`), for the pasteboard: connections
    /// between them are kept, connections to anything else dropped
    /// (except, with `keepsInterface`, to the graph's own inputs, for
    /// pasting back in the same graph). File names are made absolute, and
    /// the document's `colorspace` is the space their colours were in.
    bool copyNodes(const std::string& parentPath, const StringVector& names, bool keepsInterface, std::string& xml,
                   std::string& errorMessage) const;

    /// Adds the nodes and nodegraphs of the MaterialX document `xml` (as
    /// copyNodes writes it, or from another tool) to the graph at
    /// `parentPath`, renamed where their names are taken. Connections to
    /// anything that wasn't pasted are dropped; colours keep their space.
    /// Nodegraphs are only pasted at the top level, materials too. Sets
    /// `newPaths` to their paths, in order.
    bool pasteNodes(const std::string& parentPath, const std::string& xml, StringVector& newPaths,
                    std::string& errorMessage);

    /// The `version` attribute of the root element, such as "1.39".
    std::string documentVersion() const;

    /// The working space of the document (`path` "") or of the nodegraph at
    /// `path`. Throws nothing: an unknown path gives empty strings.
    WorkingSpaceInfo workingSpace(const std::string& path) const;

    /// The colours in the working space of the document (`path` "") or of
    /// the nodegraph at `path`, which would change meaning if it changed:
    /// colour values and colour images without a `colorspace` of their own
    /// or on any element in between. Included elements, nodedefs and
    /// nodegraphs that implement a nodedef are left out: they aren't
    /// edited here.
    std::vector<ColorUse> colorsInWorkingSpace(const std::string& path) const;

    /// Sets the `colorspace` of the document (`path` "") or of the
    /// nodegraph at `path`; "" removes it. Values are left as they are.
    bool setWorkingSpace(const std::string& path, const std::string& colorSpace, std::string& errorMessage);

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
