// MXBridge.cpp
//
// Implementation of the Swift-facing C++ API declared in include/MXBridge.h.
// This is the only file in Margolaria that includes MaterialX headers.
//
// The MaterialX headers come from SwiftUsd: they ship in its public include
// directory (Sources/_OpenUSD_SwiftBindingHelpers/include), which SwiftPM adds
// to our include path because MXBridge depends on the OpenUSD product.

#include "MXBridge.h"

#include <MaterialXCore/Document.h>
#include <MaterialXCore/Util.h>
#include <MaterialXFormat/File.h>
#include <MaterialXFormat/Util.h>
#include <MaterialXFormat/XmlIo.h>
#include <MaterialXGenMsl/MslShaderGenerator.h>
#include <MaterialXGenShader/DefaultColorManagementSystem.h>
#include <MaterialXGenShader/GenContext.h>
#include <MaterialXGenShader/Shader.h>
#include <MaterialXGenShader/ShaderStage.h>

#include <exception>
#include <set>
#include <sstream>

namespace mx = MaterialX;

namespace mxbridge {

// --- Private implementation structs ----------------------------------------
//
// These complete the `struct Impl;` forward declarations in the header. Only
// this file knows they hold MaterialX objects.

struct Library::Impl {
    mx::DocumentPtr definitions; // Every library file, merged into one document.
    int fileCount = 0;
    // The folder containing `libraries`. Shader generation reads the node
    // implementations (libraries/stdlib/genmsl/*.metal, ...) from here.
    std::string librariesRoot;
};

struct Document::Impl {
    mx::DocumentPtr document;
};

// --- Library ---------------------------------------------------------------

Library::Library() = default;

Library Library::loadStandard(const std::string& librariesRoot, std::string& errorMessage) {
    // Everything that can throw sits inside the try block. See the header:
    // no exception may escape into Swift.
    try {
        auto impl = std::make_shared<Impl>();
        impl->definitions = mx::createDocument();

        // loadLibraries() looks for the named folders ("libraries") on the
        // search path and reads every .mtlx file found under them.
        mx::FileSearchPath searchPath(librariesRoot);
        mx::StringSet loadedFiles =
            mx::loadLibraries({ "libraries" }, searchPath, impl->definitions);

        // An empty result is not an exception in MaterialX, but for us it
        // means the path was wrong, so report it as an error.
        if (loadedFiles.empty()) {
            errorMessage = "No MaterialX library files found under " + librariesRoot + "/libraries";
            return Library();
        }

        impl->fileCount = static_cast<int>(loadedFiles.size());
        impl->librariesRoot = librariesRoot;

        Library library;
        library._impl = impl;
        return library;
    } catch (const std::exception& e) {
        errorMessage = e.what();
        return Library();
    }
}

bool Library::isLoaded() const {
    return _impl != nullptr;
}

int Library::fileCount() const {
    return _impl ? _impl->fileCount : 0;
}

int Library::nodeDefinitionCount() const {
    return _impl ? static_cast<int>(_impl->definitions->getNodeDefs().size()) : 0;
}

// --- Document --------------------------------------------------------------

namespace {

/// How documents are read. Comments are kept, as <!-- --> "comment"
/// elements in the document, so writing it back keeps them; by default
/// MaterialX drops them. The graph and element lists skip these elements.
mx::XmlReadOptions ReadOptions() {
    mx::XmlReadOptions options;
    options.readComments = true;
    return options;
}

} // namespace

Document::Document() = default;

Document Document::readFromXmlString(const std::string& xml, std::string& errorMessage) {
    try {
        auto impl = std::make_shared<Impl>();
        impl->document = mx::createDocument();

        // Parses the XML into the document. This also upgrades older files
        // (for example v1.38) to the current version in memory. Throws
        // mx::ExceptionParseError on malformed XML.
        const mx::XmlReadOptions options = ReadOptions();
        mx::readFromXmlString(impl->document, xml, mx::FileSearchPath(), &options);

        Document document;
        document._impl = impl;
        return document;
    } catch (const std::exception& e) {
        errorMessage = e.what();
        return Document();
    }
}

Document Document::readFromXmlStringInFolder(const std::string& xml, const std::string& searchFolder,
                                             std::string& errorMessage) {
    try {
        auto impl = std::make_shared<Impl>();
        impl->document = mx::createDocument();
        const mx::XmlReadOptions options = ReadOptions();
        mx::readFromXmlString(impl->document, xml, mx::FileSearchPath(searchFolder), &options);
        Document document;
        document._impl = impl;
        return document;
    } catch (const std::exception& e) {
        errorMessage = e.what();
        return Document();
    }
}

Document Document::readFromFile(const std::string& path, std::string& errorMessage) {
    try {
        auto impl = std::make_shared<Impl>();
        impl->document = mx::createDocument();

        // xi:include hrefs are looked up on the search path. Put the file's
        // own folder on it, so includes relative to the file are found.
        // Reading from a file also records the file's path as the
        // document's source URI, which included elements override with their
        // own file's path (see PortInfo::sourceUri).
        mx::FilePath filePath(path);
        mx::FileSearchPath searchPath(filePath.getParentPath());
        const mx::XmlReadOptions options = ReadOptions();
        mx::readFromXmlFile(impl->document, filePath, searchPath, &options);

        Document document;
        document._impl = impl;
        return document;
    } catch (const std::exception& e) {
        errorMessage = e.what();
        return Document();
    }
}

bool Document::isLoaded() const {
    return _impl != nullptr;
}

std::string Document::writeToXmlString() const {
    if (!_impl) {
        return {};
    }
    try {
        return mx::writeToXmlString(_impl->document);
    } catch (const std::exception&) {
        // Writing a document that parsed fine is not expected to fail. If it
        // ever does, an empty string is safer than letting the exception
        // reach Swift. MXKit treats "" as a failed write.
        return {};
    }
}

void Document::setDataLibrary(const Library& library) {
    if (_impl && library._impl) {
        _impl->document->setDataLibrary(library._impl->definitions);
    }
}

bool Document::validate(std::string& message) const {
    if (!_impl) {
        message = "No document loaded";
        return false;
    }
    try {
        return _impl->document->validate(&message);
    } catch (const std::exception& e) {
        message = e.what();
        return false;
    }
}

namespace {

/// The lines of `element`'s validation message: one per problem, for the
/// element and everything below it. Empty when they are all valid.
std::vector<std::string> ValidationLines(const mx::ElementPtr& element) {
    std::string message;
    // Element::validate is virtual, so this runs the Node, NodeGraph or
    // Document version as appropriate. It is recursive: it validates the
    // children too and appends their messages after the element's own.
    element->validate(&message);
    std::vector<std::string> lines;
    std::stringstream stream(message);
    std::string line;
    while (std::getline(stream, line)) {
        if (!line.empty()) {
            lines.push_back(line);
        }
    }
    return lines;
}

/// MaterialX writes each problem as "<message>: <the element's XML tag>".
/// We report the element by path instead, so drop the quoted tag.
std::string StripQuotedElement(const std::string& line) {
    const size_t quote = line.rfind(": <");
    return quote == std::string::npos ? line : line.substr(0, quote);
}

/// Adds the problems of `element` and its descendants to `issues`, each
/// attached to the element it is about, parents before children. Returns
/// all the subtree's lines (for the caller's own bookkeeping).
///
/// MaterialX only reports problems for a whole subtree. To find which
/// element a line belongs to, validate each child's subtree too: the lines
/// that none of the children reported are the element's own. Valid subtrees
/// are skipped entirely, so a valid document is validated only once.
std::vector<std::string> CollectIssues(const mx::ElementPtr& element, std::vector<Issue>& issues) {
    std::vector<std::string> all = ValidationLines(element);
    if (all.empty()) {
        return all;
    }

    // Where this element's own issues go: before its children's.
    const size_t insertAt = issues.size();

    // A multiset, not a set: two identical elements with the same problem
    // produce two identical lines, and both must be accounted for.
    std::multiset<std::string> fromChildren;
    for (const mx::ElementPtr& child : element->getChildren()) {
        for (std::string& line : CollectIssues(child, issues)) {
            fromChildren.insert(std::move(line));
        }
    }

    std::vector<Issue> own;
    for (const std::string& line : all) {
        auto found = fromChildren.find(line);
        if (found != fromChildren.end()) {
            fromChildren.erase(found); // Erases one copy only.
        } else {
            own.push_back(Issue{ element->getNamePath(), StripQuotedElement(line) });
        }
    }
    issues.insert(issues.begin() + static_cast<std::ptrdiff_t>(insertAt), own.begin(), own.end());
    return all;
}

} // namespace

std::vector<Issue> Document::validationIssues() const {
    std::vector<Issue> issues;
    if (!_impl) {
        return issues;
    }
    try {
        CollectIssues(_impl->document, issues);
    } catch (const std::exception& e) {
        issues.push_back(Issue{ "", std::string("Validation failed: ") + e.what() });
    }
    return issues;
}

std::vector<ElementSummary> Document::topLevelElements() const {
    std::vector<ElementSummary> result;
    if (!_impl) {
        return result;
    }
    for (const mx::ElementPtr& element : _impl->document->getChildren()) {
        // Comments kept for writing back are not elements to show.
        if (element->isA<mx::CommentElement>()) {
            continue;
        }
        ElementSummary summary;
        summary.name = element->getName();
        summary.category = element->getCategory();
        // Not every element is typed (a <look> isn't), so read the raw
        // attribute instead of casting to mx::TypedElement.
        summary.type = element->getAttribute(mx::TypedElement::TYPE_ATTRIBUTE);
        summary.childCount = static_cast<int>(element->getChildren().size());
        summary.path = element->getNamePath();
        result.push_back(std::move(summary));
    }
    return result;
}

namespace {

/// The summary of `element`, with its full path.
ElementSummary Summarize(const mx::ElementPtr& element) {
    ElementSummary summary;
    summary.name = element->getName();
    summary.category = element->getCategory();
    summary.type = element->getAttribute(mx::TypedElement::TYPE_ATTRIBUTE);
    summary.childCount = static_cast<int>(element->getChildren().size());
    summary.path = element->getNamePath();
    return summary;
}

} // namespace

std::vector<ElementSummary> Document::shadeableElements() const {
    std::vector<ElementSummary> result;
    if (!_impl) {
        return result;
    }
    for (const mx::ElementPtr& element : _impl->document->getChildren()) {
        if (element->isA<mx::Node>()) {
            // Top-level nodes, including surface shaders and materials.
            result.push_back(Summarize(element));
        } else if (mx::NodeGraphPtr graph = element->asA<mx::NodeGraph>()) {
            // A nodegraph's own nodes and outputs, in file order.
            for (const mx::ElementPtr& child : graph->getChildren()) {
                if (child->isA<mx::Node>() || child->isA<mx::Output>()) {
                    result.push_back(Summarize(child));
                }
            }
        }
    }
    return result;
}

namespace {

/// The `xpos`/`ypos` attributes, if both are present and numeric.
void ReadPosition(const mx::ElementPtr& element, NodeInfo& info) {
    const std::string x = element->getAttribute("xpos");
    const std::string y = element->getAttribute("ypos");
    if (x.empty() || y.empty()) {
        return;
    }
    try {
        info.xpos = std::stof(x);
        info.ypos = std::stof(y);
        info.hasPosition = true;
    } catch (const std::exception&) {
        // Not numbers: treat the node as unpositioned.
    }
}

/// The absolute path of the file `element` was read from, or "" if the
/// document wasn't read from a file.
///
/// MaterialX records the source of included elements as the xi:include href,
/// as written: usually relative to the file that included it. So a relative
/// source URI is resolved against the source of the element above it, which
/// handles includes inside includes too.
std::string ResolvedSourceUri(const mx::ElementPtr& element) {
    // The nearest element, from this one upwards, that records a source.
    mx::ElementPtr owner = element;
    while (owner && !owner->hasSourceUri()) {
        owner = owner->getParent();
    }
    if (!owner) {
        return {};
    }
    mx::FilePath uri(owner->getSourceUri());
    mx::ElementPtr parent = owner->getParent();
    if (uri.isAbsolute() || !parent) {
        return uri.asString();
    }
    const std::string base = ResolvedSourceUri(parent);
    if (base.empty()) {
        return uri.asString();
    }
    return (mx::FilePath(base).getParentPath() / uri).getNormalized().asString();
}

/// True if `element` came from an `xi:include`d file: it, or an ancestor
/// below the document, records a source file other than the document's.
bool IsIncluded(const mx::ElementPtr& element) {
    const mx::DocumentPtr document = element->getDocument();
    for (mx::ElementPtr e = element; e && e != document; e = e->getParent()) {
        if (e->hasSourceUri() && e->getSourceUri() != document->getSourceUri()) {
            return true;
        }
    }
    return false;
}

/// Splits a comma-separated list ("OPAQUE, MASK, BLEND"), trimming spaces.
std::vector<std::string> SplitList(const std::string& list) {
    std::vector<std::string> items;
    for (const std::string& item : mx::splitString(list, ",")) {
        items.push_back(mx::trimSpaces(item));
    }
    return items;
}

/// Copies the inspector's metadata attributes of `element` (an input, in a
/// nodedef or a document) into `info`, for each field `info` doesn't
/// already have. Called with the document's input first, then the
/// nodedef's, so the document's attributes win.
void MergeUIMetadata(const mx::ElementPtr& element, PortInfo& info) {
    // Fills `field` from attribute `name` if it is still empty.
    auto fill = [&](std::string& field, const char* name) {
        if (field.empty()) {
            field = element->getAttribute(name);
        }
    };
    fill(info.uiName, "uiname");
    fill(info.uiMin, "uimin");
    fill(info.uiMax, "uimax");
    fill(info.uiSoftMin, "uisoftmin");
    fill(info.uiSoftMax, "uisoftmax");
    fill(info.uiStep, "uistep");
    fill(info.doc, "doc");
    fill(info.defaultGeomProp, "defaultgeomprop");
    fill(info.unit, "unit");
    fill(info.unitType, "unittype");
    if (info.uiFolder.empty()) {
        info.uiFolder = element->getAttribute("uifolder");
    }
    // The names and their values go together: take both from one element.
    if (info.enumNames.empty() && element->hasAttribute("enum")) {
        info.enumNames = SplitList(element->getAttribute("enum"));
        info.enumValues = element->hasAttribute("enumvalues") ? SplitList(element->getAttribute("enumvalues"))
                                                             : std::vector<std::string>();
    }
    info.isAdvanced = info.isAdvanced || element->getAttribute("uiadvanced") == "true";
}

/// An input or output element that exists in the document.
PortInfo DescribePort(const mx::PortElementPtr& port) {
    PortInfo info;
    info.name = port->getName();
    info.type = port->getType();
    info.value = port->getValueString();
    info.isAuthored = true;
    info.nodeName = port->getNodeName();
    info.nodeGraphName = port->getNodeGraphString();
    info.outputName = port->getOutputString();
    // Only inputs can refer to their graph's interface.
    if (mx::InputPtr input = port->asA<mx::Input>()) {
        info.interfaceName = input->getInterfaceName();
    }
    info.colorSpace = port->getColorSpace();
    if (info.type == mx::FILENAME_TYPE_STRING) {
        // Applies `fileprefix` from this element or any ancestor.
        info.resolvedFilename = port->getResolvedValueString();
    }
    info.sourceUri = ResolvedSourceUri(port);
    info.isUniform = port->getIsUniform();
    // Searches the port, then its ancestors, up to the document.
    info.activeColorSpace = port->getActiveColorSpace();
    MergeUIMetadata(port, info);
    return info;
}

/// An input that only exists in the nodedef: the node uses its default.
PortInfo DescribeDefaultInput(const mx::InputPtr& definition) {
    PortInfo info;
    info.name = definition->getName();
    info.type = definition->getType();
    info.value = definition->getValueString();
    info.isAuthored = false;
    info.isUniform = definition->getIsUniform();
    return info;
}

/// The colour space of a nodedef-only input on `element`: the nodedef's
/// own for that input, if it says, or the one `element` is in.
std::string DefaultColorSpace(const mx::InputPtr& definition, const mx::ElementPtr& element) {
    if (!definition->getColorSpace().empty()) {
        return definition->getColorSpace();
    }
    return element->getActiveColorSpace();
}

/// The inputs of `element` (a node or nodegraph) merged with those of its
/// nodedef, if it has one: nodedef order first, then extra authored inputs.
std::vector<PortInfo> MergeInputs(const mx::InterfaceElementPtr& element, const mx::NodeDefPtr& nodeDef) {
    std::vector<PortInfo> inputs;
    std::set<std::string> listed;
    if (nodeDef) {
        // getActiveInputs includes inputs inherited from parent nodedefs.
        for (const mx::InputPtr& definition : nodeDef->getActiveInputs()) {
            PortInfo info;
            if (mx::InputPtr authored = element->getInput(definition->getName())) {
                info = DescribePort(authored);
            } else {
                info = DescribeDefaultInput(definition);
                info.activeColorSpace = DefaultColorSpace(definition, element);
            }
            info.defaultValue = definition->getValueString();
            // The document's input may override the nodedef's metadata
            // (DescribePort read it already); the nodedef fills the rest.
            MergeUIMetadata(definition, info);
            info.isUniform = info.isUniform || definition->getIsUniform();
            listed.insert(info.name);
            inputs.push_back(std::move(info));
        }
    }
    for (const mx::InputPtr& authored : element->getInputs()) {
        if (listed.count(authored->getName()) == 0) {
            inputs.push_back(DescribePort(authored));
        }
    }
    return inputs;
}

NodeInfo DescribeNode(const mx::NodePtr& node) {
    NodeInfo info;
    info.name = node->getName();
    info.category = node->getCategory();
    info.type = node->getType();
    info.path = node->getNamePath();
    info.isIncluded = IsIncluded(node);
    ReadPosition(node, info);

    // Finds the nodedef by category, type and input types, in the document
    // and in its data library (Document::setDataLibrary).
    mx::NodeDefPtr nodeDef = node->getNodeDef();
    if (nodeDef) {
        info.nodeDefName = nodeDef->getName();
        info.nodeGroup = nodeDef->getNodeGroup();
        info.doc = nodeDef->getDocString();
    }
    info.inputs = MergeInputs(node, nodeDef);

    if (nodeDef) {
        for (const mx::OutputPtr& output : nodeDef->getActiveOutputs()) {
            PortInfo port;
            port.name = output->getName();
            port.type = output->getType();
            info.outputs.push_back(std::move(port));
        }
    } else if (info.type != mx::MULTI_OUTPUT_TYPE_STRING) {
        // Unknown node: assume the usual single output.
        PortInfo port;
        port.name = "out";
        port.type = info.type;
        info.outputs.push_back(std::move(port));
    }
    return info;
}

NodeInfo DescribeNodeGraph(const mx::NodeGraphPtr& graph) {
    NodeInfo info;
    info.name = graph->getName();
    info.category = graph->getCategory(); // "nodegraph"
    info.path = graph->getNamePath();
    info.isNodeGraph = true;
    info.isIncluded = IsIncluded(graph);
    ReadPosition(graph, info);

    // A nodegraph that implements a nodedef (a "functional" graph) takes its
    // interface from the nodedef.
    mx::NodeDefPtr nodeDef = graph->getNodeDef();
    if (nodeDef) {
        info.nodeDefName = nodeDef->getName();
        info.nodeGroup = nodeDef->getNodeGroup();
        info.doc = nodeDef->getDocString();
    } else {
        info.doc = graph->getDocString();
    }
    info.inputs = MergeInputs(graph, nodeDef);

    std::vector<mx::OutputPtr> outputs = graph->getOutputs();
    for (const mx::OutputPtr& output : outputs) {
        info.outputs.push_back(DescribePort(output));
    }
    info.type = outputs.size() == 1 ? outputs.front()->getType() : mx::MULTI_OUTPUT_TYPE_STRING;
    return info;
}

} // namespace

std::string Document::writeForPreview() const {
    if (!_impl) {
        return {};
    }
    try {
        // A copy, so the document itself keeps its relative paths.
        mx::DocumentPtr preview = _impl->document->copy();
        preview->setSourceUri(_impl->document->getSourceUri());

        for (const mx::ElementPtr& element : preview->traverseTree()) {
            mx::ValueElementPtr value = element->asA<mx::ValueElement>();
            if (!value || value->getType() != mx::FILENAME_TYPE_STRING || !value->hasValueString()) {
                continue;
            }
            // Applies `fileprefix` from this element or any ancestor.
            mx::FilePath file(value->getResolvedValueString());
            const std::string source = ResolvedSourceUri(value);
            if (!file.isEmpty() && !file.isAbsolute() && !source.empty()) {
                file = (mx::FilePath(source).getParentPath() / file).getNormalized();
            }
            value->setValueString(file.asString());
        }
        // The prefixes are applied now; leaving them would apply them twice.
        for (const mx::ElementPtr& element : preview->traverseTree()) {
            element->removeAttribute(mx::Element::FILE_PREFIX_ATTRIBUTE);
        }
        preview->removeAttribute(mx::Element::FILE_PREFIX_ATTRIBUTE);

        mx::XmlWriteOptions options;
        // Write included elements in place, not as references to their files.
        options.writeXIncludeEnable = false;
        return mx::writeToXmlString(preview, &options);
    } catch (const std::exception&) {
        return {};
    }
}

bool Document::graph(const std::string& path, GraphInfo& graph, std::string& errorMessage) const {
    if (!_impl) {
        errorMessage = "No document loaded";
        return false;
    }
    try {
        // The document itself is a graph (mx::Document derives from
        // mx::GraphElement), holding the top-level nodes and nodegraphs.
        mx::ElementPtr scope = _impl->document;
        if (!path.empty()) {
            scope = _impl->document->getDescendant(path);
            if (!scope || !scope->isA<mx::NodeGraph>()) {
                errorMessage = "No nodegraph at path " + path;
                return false;
            }
        }

        graph = GraphInfo();
        graph.path = path;
        for (const mx::ElementPtr& child : scope->getChildren()) {
            if (mx::NodePtr node = child->asA<mx::Node>()) {
                graph.nodes.push_back(DescribeNode(node));
            } else if (mx::NodeGraphPtr nodeGraph = child->asA<mx::NodeGraph>()) {
                graph.nodes.push_back(DescribeNodeGraph(nodeGraph));
            } else if (mx::OutputPtr output = child->asA<mx::Output>()) {
                graph.outputs.push_back(DescribePort(output));
            } else if (mx::InputPtr input = child->asA<mx::Input>()) {
                // Only nodegraphs have inputs as direct children.
                graph.interfaceInputs.push_back(DescribePort(input));
            }
            // Everything else (nodedefs, looks, backdrops, ...) is not part
            // of the graph view.
        }

        // A functional nodegraph declares its interface in its nodedef, not
        // as <input> children; use the merged list from DescribeNodeGraph.
        if (mx::NodeGraphPtr nodeGraph = scope->asA<mx::NodeGraph>()) {
            if (nodeGraph->getNodeDef()) {
                graph.interfaceInputs = DescribeNodeGraph(nodeGraph).inputs;
            }
        }
        return true;
    } catch (const std::exception& e) {
        errorMessage = e.what();
        return false;
    }
}

std::vector<ElementSummary> Document::nodeGraphs() const {
    std::vector<ElementSummary> result;
    if (!_impl) {
        return result;
    }
    // traverseTree visits every element depth-first, in file order.
    for (const mx::ElementPtr& element : _impl->document->traverseTree()) {
        if (element->isA<mx::NodeGraph>()) {
            result.push_back(Summarize(element));
        }
    }
    return result;
}

namespace {

/// The inputs or outputs of a nodedef, for NodeDefSummary.
template <typename Port>
std::vector<NodeDefPort> DescribeNodeDefPorts(const std::vector<std::shared_ptr<Port>>& ports) {
    std::vector<NodeDefPort> result;
    for (const auto& port : ports) {
        NodeDefPort info;
        info.name = port->getName();
        info.type = port->getType();
        info.isUniform = port->getIsUniform();
        result.push_back(std::move(info));
    }
    return result;
}

} // namespace

std::vector<NodeDefSummary> Document::nodeDefinitions() const {
    std::vector<NodeDefSummary> result;
    if (!_impl) {
        return result;
    }
    std::set<std::string> seen;
    auto add = [&](const std::vector<mx::NodeDefPtr>& nodeDefs) {
        for (const mx::NodeDefPtr& nodeDef : nodeDefs) {
            // An older version kept for old files (ND_UsdUVTexture 2.2 next
            // to ND_UsdUVTexture_23): new nodes use the default version.
            if (nodeDef->hasVersionString() && !nodeDef->getDefaultVersion()) {
                continue;
            }
            if (!seen.insert(nodeDef->getName()).second) {
                continue;
            }
            NodeDefSummary info;
            info.name = nodeDef->getName();
            info.node = nodeDef->getNodeString();
            info.type = nodeDef->getType();
            info.nodeGroup = nodeDef->getNodeGroup();
            info.doc = nodeDef->getDocString();
            // getNodeDefs() on a document with a data library lists the
            // library's too; their own document tells them apart.
            info.isFromDocument = nodeDef->getDocument() == _impl->document;
            // The active ports include inherited ones (`inherit="..."`).
            info.inputs = DescribeNodeDefPorts(nodeDef->getActiveInputs());
            info.outputs = DescribeNodeDefPorts(nodeDef->getActiveOutputs());
            result.push_back(std::move(info));
        }
    };
    add(_impl->document->getNodeDefs());
    if (mx::ConstDocumentPtr library = _impl->document->getDataLibrary()) {
        add(library->getNodeDefs());
    }
    return result;
}

Document Document::copy() const {
    Document result;
    if (_impl) {
        auto impl = std::make_shared<Impl>();
        // Document::copy copies every element and the data library. The
        // source file paths (which xi:include and textures depend on) are
        // copied with the elements; the test MXEditTests checks it.
        impl->document = _impl->document->copy();
        impl->document->setSourceUri(_impl->document->getSourceUri());
        result._impl = impl;
    }
    return result;
}

bool Document::isEquivalent(const Document& other, std::string& message) const {
    if (!_impl || !other._impl) {
        message = "No document loaded";
        return false;
    }
    try {
        mx::ElementEquivalenceOptions options;
        return _impl->document->isEquivalent(other._impl->document, options, &message);
    } catch (const std::exception& e) {
        message = e.what();
        return false;
    }
}

bool Document::isIncluded(const std::string& path) const {
    if (!_impl) {
        return false;
    }
    mx::ElementPtr element = _impl->document->getDescendant(path);
    return element && IsIncluded(element);
}

// --- Edits -------------------------------------------------------------------

namespace {

/// Thrown by the helpers below to refuse an edit; the edit functions catch
/// it (with every other exception) and report its message.
struct Refusal : std::runtime_error {
    using std::runtime_error::runtime_error;
};

/// The element at `path`, which must exist and not come from an include.
mx::ElementPtr EditableElement(const mx::DocumentPtr& document, const std::string& path) {
    mx::ElementPtr element = document->getDescendant(path);
    if (!element) {
        throw Refusal("No element at " + path);
    }
    if (IsIncluded(element)) {
        throw Refusal(path + " comes from an included file and can't be changed here");
    }
    return element;
}

/// The input `inputName` of the node or nodegraph `element`, or `element`
/// itself if it is an <output>. With `create`, an input the node doesn't set
/// yet is added from its nodedef.
mx::PortElementPtr Port(const mx::ElementPtr& element, const std::string& inputName, bool create) {
    if (mx::OutputPtr output = element->asA<mx::Output>()) {
        return output;
    }
    mx::InterfaceElementPtr owner = element->asA<mx::InterfaceElement>();
    if (!owner) {
        throw Refusal(element->getNamePath() + " has no inputs");
    }
    mx::InputPtr input = owner->getInput(inputName);
    if (!input && create) {
        if (mx::NodePtr node = element->asA<mx::Node>()) {
            input = node->addInputFromNodeDef(inputName);
        } else if (mx::NodeGraphPtr graph = element->asA<mx::NodeGraph>()) {
            // A nodegraph that implements a nodedef takes its inputs and
            // their defaults from the nodedef; they are changed there (M4).
            if (mx::NodeDefPtr nodeDef = graph->getNodeDef()) {
                throw Refusal("The inputs of " + graph->getName() + " are defined by " + nodeDef->getName() +
                              " and are changed there");
            }
        }
    }
    if (!input) {
        throw Refusal(element->getNamePath() + " has no input " + inputName);
    }
    return input;
}

/// Removes the attributes that connect a port to something.
void ClearConnection(const mx::PortElementPtr& port) {
    port->removeAttribute(mx::PortElement::NODE_NAME_ATTRIBUTE);
    port->removeAttribute(mx::PortElement::NODE_GRAPH_ATTRIBUTE);
    port->removeAttribute(mx::PortElement::OUTPUT_ATTRIBUTE);
    port->removeAttribute(mx::ValueElement::INTERFACE_NAME_ATTRIBUTE);
}

/// Removes a node's input, so the node uses its nodedef's default.
///
/// Unless that would change which nodedef MaterialX matches the node to:
/// variants of a node are told apart by their inputs' types
/// (`ND_multiply_vector3FA` takes a float `in2`, `ND_multiply_vector3` a
/// vector3), and a `separate3`'s outputs are named after its input's type.
/// Without the input, `getNodeDef()` may pick another variant, and the
/// node's other inputs and outputs would change meaning. Then the input is
/// put back where it was, with the nodedef's default as its value.
void RemoveInput(const mx::NodePtr& node, const mx::InputPtr& input) {
    const mx::NodeDefPtr before = node->getNodeDef();
    const std::string name = input->getName();
    const int index = node->getChildIndex(name);
    node->removeChild(name);
    if (!before || node->getNodeDef() == before) {
        return;
    }
    // `input` still holds the removed element (shared_ptr), so its
    // attributes can be copied back, then the value reset.
    mx::InputPtr restored = node->addInput(name, input->getType());
    restored->copyContentFrom(input);
    node->setChildIndex(name, index);
    mx::InputPtr definition = before->getActiveInput(name);
    if (definition && definition->hasValueString()) {
        restored->setValueString(definition->getValueString());
    }
}

/// Disconnects `port`; a node's input left with no value is removed, so
/// the node goes back to its default (see RemoveInput). A nodegraph's own
/// inputs are its interface, so they stay, even without a value.
void Disconnect(const mx::PortElementPtr& port) {
    ClearConnection(port);
    mx::NodePtr node = port->getParent()->asA<mx::Node>();
    mx::InputPtr input = port->asA<mx::Input>();
    if (node && input && !input->hasValueString()) {
        RemoveInput(node, input);
    }
}

/// True if `port` is declared `uniform`, on itself or on its nodedef. A
/// uniform input takes a value, or a nodegraph's input; never a node's
/// output (MaterialX specification, "Inputs").
bool IsUniform(const mx::PortElementPtr& port) {
    mx::InputPtr input = port->asA<mx::Input>();
    if (!input) {
        return false;
    }
    if (input->getIsUniform()) {
        return true;
    }
    mx::NodePtr node = input->getParent()->asA<mx::Node>();
    mx::NodeDefPtr nodeDef = node ? node->getNodeDef() : nullptr;
    mx::InputPtr definition = nodeDef ? nodeDef->getActiveInput(input->getName()) : nullptr;
    return definition && definition->getIsUniform();
}

/// The names of the nodes and nodegraphs `name` reads from, in `graph`.
std::vector<std::string> UpstreamNames(const mx::ElementPtr& graph, const std::string& name) {
    std::vector<std::string> names;
    mx::InterfaceElementPtr element = graph->getChild(name) ? graph->getChild(name)->asA<mx::InterfaceElement>() : nullptr;
    if (!element) {
        return names;
    }
    for (const mx::InputPtr& input : element->getInputs()) {
        if (!input->getNodeName().empty()) {
            names.push_back(input->getNodeName());
        } else if (!input->getNodeGraphString().empty()) {
            names.push_back(input->getNodeGraphString());
        }
    }
    return names;
}

/// True if `to` is `from` or upstream of it: connecting `to` to read from
/// `from` would then close a loop.
bool Reaches(const mx::ElementPtr& graph, const std::string& from, const std::string& to) {
    std::vector<std::string> pending{ from };
    std::set<std::string> seen;
    while (!pending.empty()) {
        std::string name = pending.back();
        pending.pop_back();
        if (name == to) {
            return true;
        }
        if (!seen.insert(name).second) {
            continue;
        }
        for (std::string& upstream : UpstreamNames(graph, name)) {
            pending.push_back(std::move(upstream));
        }
    }
    return false;
}

/// The nodedef called `name`: the document's own, or the data library's.
mx::NodeDefPtr FindNodeDef(const mx::DocumentPtr& document, const std::string& name) {
    mx::NodeDefPtr nodeDef = document->getNodeDef(name);
    if (!nodeDef && document->getDataLibrary()) {
        nodeDef = document->getDataLibrary()->getNodeDef(name);
    }
    if (!nodeDef) {
        throw Refusal("No nodedef " + name);
    }
    return nodeDef;
}

/// Every port in `graph` that can refer to a sibling by name: its <output>
/// elements, and the inputs of its nodes and nodegraphs.
std::vector<mx::PortElementPtr> SiblingPorts(const mx::ElementPtr& graph) {
    std::vector<mx::PortElementPtr> ports;
    for (const mx::ElementPtr& sibling : graph->getChildren()) {
        if (mx::PortElementPtr port = sibling->asA<mx::PortElement>()) {
            ports.push_back(port);
        } else if (mx::InterfaceElementPtr owner = sibling->asA<mx::InterfaceElement>()) {
            for (const mx::InputPtr& input : owner->getInputs()) {
                ports.push_back(input);
            }
        }
    }
    return ports;
}

/// Runs an edit on `document`, turning any exception into `false` and a
/// message. Every edit function below is one call to this, with the edit
/// as a lambda.
template <typename Edit>
bool Perform(const mx::DocumentPtr& document, std::string& errorMessage, Edit edit) {
    if (!document) {
        errorMessage = "No document loaded";
        return false;
    }
    try {
        edit(document);
        return true;
    } catch (const std::exception& e) {
        errorMessage = e.what();
        return false;
    }
}

} // namespace

bool Document::setInputValue(const std::string& elementPath, const std::string& inputName,
                             const std::string& value, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::PortElementPtr port = Port(EditableElement(document, elementPath), inputName, true);
        // Check the text means something for this type before storing it.
        if (!mx::Value::createValueFromStrings(value, port->getType())) {
            throw Refusal("\"" + value + "\" is not a valid " + port->getType());
        }
        ClearConnection(port);
        port->setValueString(value);
    });
}

bool Document::resetInput(const std::string& elementPath, const std::string& inputName, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::ElementPtr element = EditableElement(document, elementPath);
        mx::PortElementPtr port = Port(element, inputName, false);
        mx::NodePtr node = element->asA<mx::Node>();
        mx::InputPtr input = port->asA<mx::Input>();
        if (node && input) {
            RemoveInput(node, input);
        } else {
            element->removeChild(port->getName());
        }
    });
}

bool Document::connectInput(const std::string& targetPath, const std::string& inputName,
                            const std::string& sourceName, const std::string& sourceOutput,
                            std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::ElementPtr target = EditableElement(document, targetPath);
        // An <output>'s graph is its parent; a node's input's graph is the
        // node's parent.
        mx::ElementPtr graph = target->getParent();
        mx::ElementPtr source = graph->getChild(sourceName);
        if (!source || !(source->isA<mx::Node>() || source->isA<mx::NodeGraph>())) {
            throw Refusal("No node or nodegraph " + sourceName + " next to " + targetPath);
        }

        // The type that comes out of the source.
        std::string sourceType;
        if (mx::NodeGraphPtr nodeGraph = source->asA<mx::NodeGraph>()) {
            std::vector<mx::OutputPtr> outputs = nodeGraph->getOutputs();
            mx::OutputPtr output = sourceOutput.empty() ? (outputs.size() == 1 ? outputs.front() : nullptr)
                                                        : nodeGraph->getOutput(sourceOutput);
            if (!output) {
                throw Refusal("Say which output of " + sourceName + " to use");
            }
            sourceType = output->getType();
        } else {
            mx::NodePtr node = source->asA<mx::Node>();
            sourceType = node->getType();
            if (!sourceOutput.empty() || sourceType == mx::MULTI_OUTPUT_TYPE_STRING) {
                mx::NodeDefPtr nodeDef = node->getNodeDef();
                mx::OutputPtr output = nodeDef ? nodeDef->getActiveOutput(sourceOutput) : nullptr;
                if (!output) {
                    throw Refusal(sourceName + " has no output " + sourceOutput);
                }
                sourceType = output->getType();
            }
        }

        mx::PortElementPtr port = Port(target, inputName, true);
        if (port->getType() != sourceType) {
            throw Refusal("Can't connect " + sourceType + " to " + port->getType());
        }
        if (IsUniform(port)) {
            throw Refusal(inputName + " is uniform: it takes a value or one of the graph's inputs, not a node's output");
        }
        // A node can't read from itself or from anything downstream of it.
        if (!target->isA<mx::Output>() && Reaches(graph, sourceName, target->getName())) {
            throw Refusal("Connecting " + sourceName + " to " + target->getName() + " would make a loop");
        }

        ClearConnection(port);
        port->removeAttribute(mx::ValueElement::VALUE_ATTRIBUTE);
        if (source->isA<mx::NodeGraph>()) {
            port->setNodeGraphString(sourceName);
        } else {
            port->setNodeName(sourceName);
        }
        if (!sourceOutput.empty()) {
            port->setOutputString(sourceOutput);
        }
    });
}

bool Document::connectInterface(const std::string& targetPath, const std::string& inputName,
                                const std::string& interfaceName, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::ElementPtr target = EditableElement(document, targetPath);
        mx::NodeGraphPtr graph = target->getParent()->asA<mx::NodeGraph>();
        mx::InputPtr interface = graph ? graph->getInput(interfaceName) : nullptr;
        // A nodegraph that implements a nodedef has no inputs of its own:
        // its interface is the nodedef's inputs.
        if (!interface && graph && graph->getNodeDef()) {
            interface = graph->getNodeDef()->getActiveInput(interfaceName);
        }
        if (!interface) {
            throw Refusal("The graph around " + targetPath + " has no input " + interfaceName);
        }
        mx::PortElementPtr port = Port(target, inputName, true);
        mx::InputPtr input = port->asA<mx::Input>();
        if (!input) {
            // MaterialX's validation: "Only input and token elements
            // support interface names". An <output> can't pass one through.
            throw Refusal("Only inputs can use the graph's inputs");
        }
        if (input->getType() != interface->getType()) {
            throw Refusal("Can't connect " + interface->getType() + " to " + input->getType());
        }
        ClearConnection(input);
        input->removeAttribute(mx::ValueElement::VALUE_ATTRIBUTE);
        input->setInterfaceName(interfaceName);
    });
}

bool Document::disconnectInput(const std::string& targetPath, const std::string& inputName, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        Disconnect(Port(EditableElement(document, targetPath), inputName, false));
    });
}

bool Document::addNode(const std::string& parentPath, const std::string& nodeDefName, const std::string& nameHint,
                       std::string& newPath, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::ElementPtr parent = parentPath.empty() ? mx::ElementPtr(document) : EditableElement(document, parentPath);
        mx::GraphElementPtr graph = parent->asA<mx::GraphElement>();
        if (!graph) {
            throw Refusal(parentPath + " is not a graph");
        }
        mx::NodeDefPtr nodeDef = FindNodeDef(document, nodeDefName);
        const std::string name = graph->createValidChildName(nameHint.empty() ? nodeDef->getNodeString() : nameHint);
        mx::NodePtr node = graph->addNodeInstance(nodeDef, name);
        newPath = node->getNamePath();
    });
}

bool Document::changeNodeDef(const std::string& path, const std::string& nodeDefName, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::NodePtr node = EditableElement(document, path)->asA<mx::Node>();
        if (!node) {
            throw Refusal(path + " is not a node");
        }
        mx::NodeDefPtr nodeDef = FindNodeDef(document, nodeDefName);
        if (nodeDef->getNodeString() != node->getCategory()) {
            throw Refusal(nodeDefName + " defines " + nodeDef->getNodeString() + " nodes, not " +
                          node->getCategory());
        }
        // Inputs: keep those the new variant has with the same type.
        for (const mx::InputPtr& input : node->getInputs()) {
            mx::InputPtr definition = nodeDef->getActiveInput(input->getName());
            if (!definition || definition->getType() != input->getType()) {
                node->removeInput(input->getName());
            }
        }
        node->setType(nodeDef->getType());
        node->setNodeDefString(nodeDef->getName());

        // Connections from the node's outputs: each must still find an
        // output of its own type.
        const std::vector<mx::OutputPtr> outputs = nodeDef->getActiveOutputs();
        for (const mx::PortElementPtr& port : SiblingPorts(node->getParent())) {
            if (port->getNodeName() != node->getName()) {
                continue;
            }
            const std::string outputName = port->getOutputString();
            mx::OutputPtr output;
            if (!outputName.empty()) {
                output = nodeDef->getActiveOutput(outputName);
            } else if (outputs.size() == 1) {
                output = outputs[0];
            }
            if (!output || output->getType() != port->getType()) {
                Disconnect(port);
            }
        }
    });
}

bool Document::removeNode(const std::string& path, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::ElementPtr element = EditableElement(document, path);
        if (!(element->isA<mx::Node>() || element->isA<mx::NodeGraph>())) {
            throw Refusal(path + " is not a node or nodegraph");
        }
        const std::string name = element->getName();
        mx::ElementPtr graph = element->getParent();
        // Disconnect everything in the same graph that reads from it.
        for (const mx::PortElementPtr& port : SiblingPorts(graph)) {
            if (port->getNodeName() == name || port->getNodeGraphString() == name) {
                Disconnect(port);
            }
        }
        graph->removeChild(name);
    });
}

bool Document::renameNode(const std::string& path, const std::string& newName,
                          std::string& newPath, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::ElementPtr element = EditableElement(document, path);
        const std::string oldName = element->getName();
        if (newName == oldName) {
            newPath = path;
            return;
        }
        if (newName.empty() || mx::createValidName(newName) != newName) {
            throw Refusal("\"" + newName + "\" is not a valid MaterialX name (letters, digits and _ only)");
        }
        mx::ElementPtr graph = element->getParent();
        if (graph->getChild(newName)) {
            throw Refusal("There is already a " + newName + " here");
        }
        element->setName(newName);
        // Connections in the same graph that refer to it by name.
        for (const mx::PortElementPtr& port : SiblingPorts(graph)) {
            if (port->getNodeName() == oldName) {
                port->setNodeName(newName);
            }
            if (port->getNodeGraphString() == oldName) {
                port->setNodeGraphString(newName);
            }
        }
        // Material assignments in looks refer to materials by name.
        if (graph == document) {
            for (const mx::ElementPtr& e : document->traverseTree()) {
                if (e->getCategory() == "materialassign" && e->getAttribute("material") == oldName) {
                    e->setAttribute("material", newName);
                }
            }
        }
        newPath = element->getNamePath();
    });
}

bool Document::setPosition(const std::string& path, float x, float y, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::ElementPtr element = EditableElement(document, path);
        // Three decimals: a thousandth of a node is far below a pixel, and
        // shorter numbers keep the file tidy.
        auto format = [](float value) {
            std::ostringstream stream;
            stream.setf(std::ios::fixed);
            stream.precision(3);
            stream << value;
            std::string text = stream.str();
            // "1.500" → "1.5", "2.000" → "2".
            text.erase(text.find_last_not_of('0') + 1);
            if (!text.empty() && text.back() == '.') {
                text.pop_back();
            }
            return text == "-0" ? std::string("0") : text;
        };
        element->setAttribute(mx::Element::XPOS_ATTRIBUTE, format(x));
        element->setAttribute(mx::Element::YPOS_ATTRIBUTE, format(y));
    });
}

std::string Document::documentVersion() const {
    return _impl ? _impl->document->getVersionString() : std::string();
}

namespace {

/// Splits a MaterialX value string ("0.95, 0.64, 0.54", "true", "2") into numbers.
std::vector<float> ParseNumbers(const std::string& type, const std::string& text) {
    std::vector<float> numbers;
    if (type == "boolean") {
        numbers.push_back(text == "true" ? 1.0f : 0.0f);
        return numbers;
    }
    std::stringstream stream(text);
    std::string item;
    while (std::getline(stream, item, ',')) {
        try {
            numbers.push_back(std::stof(item));
        } catch (const std::exception&) {
            return {}; // Not numeric (an enum string, for example).
        }
    }
    return numbers;
}

/// Appends the uniforms of every uniform block in `stage` to `uniforms`.
void CollectUniforms(const mx::ShaderStage& stage, std::vector<ShaderUniform>& uniforms) {
    for (const auto& [blockName, block] : stage.getUniformBlocks()) {
        for (size_t i = 0; i < block->size(); ++i) {
            const mx::ShaderPort* port = (*block)[i];
            ShaderUniform uniform;
            uniform.name = port->getVariable();
            uniform.type = port->getType().getName();
            if (mx::ValuePtr value = port->getValue()) {
                const std::string text = value->getValueString();
                if (uniform.type == "filename" || uniform.type == "string") {
                    uniform.stringValue = text;
                } else {
                    uniform.value = ParseNumbers(uniform.type, text);
                }
            }
            uniforms.push_back(std::move(uniform));
        }
    }
}

} // namespace

bool Document::generateMsl(const std::string& elementPath, const Library& library,
                           GeneratedShader& shader, std::string& errorMessage) const {
    if (!_impl || !library._impl) {
        errorMessage = "No document or library loaded";
        return false;
    }
    try {
        mx::ElementPtr element = _impl->document->getDescendant(elementPath);
        if (!element) {
            errorMessage = "No element at path " + elementPath;
            return false;
        }

        mx::ShaderGeneratorPtr generator = mx::MslShaderGenerator::create();

        // Colour management: converts colours and textures tagged with a
        // colour space (such as srgb_texture) to the working space, using the
        // conversion nodes defined in the standard library.
        mx::DefaultColorManagementSystemPtr colorManagement =
            mx::DefaultColorManagementSystem::create(generator->getTarget());
        colorManagement->loadLibrary(library._impl->definitions);
        generator->setColorManagementSystem(colorManagement);

        mx::GenContext context(generator);
        // Where the per-node MSL snippets live (libraries/stdlib/genmsl/...).
        context.registerSourceCodeSearchPath(mx::FilePath(library._impl->librariesRoot));
        // Shade in linear Rec.709, the documents' usual working space.
        context.getOptions().targetColorSpaceOverride = "lin_rec709";

        mx::ShaderPtr generated = generator->generate(element->getName(), element, context);
        if (!generated) {
            errorMessage = "Shader generation produced nothing for " + elementPath;
            return false;
        }

        shader.vertexSource = generated->getSourceCode(mx::Stage::VERTEX);
        shader.pixelSource = generated->getSourceCode(mx::Stage::PIXEL);

        // The shaded output's type: the element's own type for an output or
        // node, "material" for a material node.
        if (auto typed = element->asA<mx::TypedElement>()) {
            shader.outputType = typed->getType();
        }

        shader.uniforms.clear();
        CollectUniforms(generated->getStage(mx::Stage::VERTEX), shader.uniforms);
        CollectUniforms(generated->getStage(mx::Stage::PIXEL), shader.uniforms);
        return true;
    } catch (const std::exception& e) {
        errorMessage = e.what();
        return false;
    }
}

// --- Free functions ----------------------------------------------------------

std::string materialXVersion() {
    return mx::getVersionString();
}

} // namespace mxbridge
