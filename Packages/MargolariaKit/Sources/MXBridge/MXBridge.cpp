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
#include <MaterialXCore/Material.h>
#include <MaterialXCore/Util.h>
#include <MaterialXFormat/File.h>
#include <MaterialXFormat/Util.h>
#include <MaterialXFormat/XmlIo.h>
#include <MaterialXGenGlsl/GlslShaderGenerator.h>
#include <MaterialXGenMsl/MslShaderGenerator.h>
#include <MaterialXGenOsl/Nodes/OsoNode.h>
#include <MaterialXGenOsl/OslNetworkShaderGenerator.h>
#include <MaterialXGenOsl/OslShaderGenerator.h>
#include <MaterialXGenShader/DefaultColorManagementSystem.h>
#include <MaterialXGenShader/GenContext.h>
#include <MaterialXGenShader/Shader.h>
#include <MaterialXGenShader/ShaderStage.h>

#include <ImageIO/ImageIO.h>
#include <dlfcn.h>

#include <algorithm>
#include <cmath>
#include <exception>
#include <map>
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
    // The folder containing `genoslnetwork`, the library compiled for OSL
    // networks (M5d); empty if it wasn't found.
    std::string networkRoot;
    // What generated shaders' colour management reads (M5d): `definitions`
    // with Margolaria's transforms to ACEScg added, which MaterialX lacks
    // (margolarialib/margolaria_cmlib.mtlx). A copy, so the node library
    // that documents and the UI see is MaterialX's alone.
    mx::DocumentPtr colorTransforms;
};

struct Document::Impl {
    mx::DocumentPtr document;
};

// --- Library ---------------------------------------------------------------

namespace {

/// The MaterialXGenOsl framework's Resources folder, which holds
/// `genoslnetwork`: MaterialX's library compiled for OSL networks, and the
/// implementations pointing at it; and `margolarialib`, Margolaria's colour
/// transforms (scripts/build-materialx-genosl.sh). Found from where the
/// framework's code was loaded, so it works in the app and in tests alike.
/// Empty if not found.
std::string FrameworkResources() {
    // dladdr: which loaded binary holds this address. Anything defined in
    // the framework's own code will do, such as the generator's TARGET
    // string; not create(), which the header defines inline, so its code
    // is compiled into MXBridge.
    Dl_info info;
    if (!dladdr(static_cast<const void*>(&mx::OslNetworkShaderGenerator::TARGET), &info) || !info.dli_fname) {
        return {};
    }
    // .../MaterialXGenOsl.framework/Versions/A/MaterialXGenOsl
    const mx::FilePath resources = mx::FilePath(info.dli_fname).getParentPath() / "Resources";
    return resources.exists() ? resources.asString() : std::string();
}

} // namespace

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

        // The implementations for OSL networks (target genoslnetwork),
        // beside the standard ones. Not counted in fileCount: they
        // aren't MaterialX's own library files.
        const mx::FilePath resources(FrameworkResources());
        const mx::FilePath networkImpls = resources / "genoslnetwork" / "genoslnetwork_impl.mtlx";
        if (!resources.isEmpty() && networkImpls.exists()) {
            impl->networkRoot = resources.asString();
            mx::DocumentPtr network = mx::createDocument();
            mx::readFromXmlFile(network, networkImpls);
            impl->definitions->importLibrary(network);
        }
        impl->colorTransforms = impl->definitions->copy();
        const mx::FilePath transforms = resources / "margolarialib" / "margolaria_cmlib.mtlx";
        if (!resources.isEmpty() && transforms.exists()) {
            mx::DocumentPtr own = mx::createDocument();
            mx::readFromXmlFile(own, transforms);
            impl->colorTransforms->importLibrary(own);
        }

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
template <typename Info>
void ReadPosition(const mx::ElementPtr& element, Info& info) {
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

/// The nodedef `graph` implements, if it is defined in the graph's own
/// document (not the data libraries, not an included file): one whose
/// inputs, defaults and metadata are edited here (M4c1). Null otherwise.
mx::NodeDefPtr LocalNodeDef(const mx::NodeGraphPtr& graph) {
    mx::NodeDefPtr nodeDef = graph->hasNodeDefString() ? graph->getNodeDef() : nullptr;
    if (!nodeDef || nodeDef->getDocument() != graph->getDocument() || IsIncluded(nodeDef)) {
        return nullptr;
    }
    return nodeDef;
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
    info.inheritedColorSpace = port->getParent()->getActiveColorSpace();
    MergeUIMetadata(port, info);
    ReadPosition(port, info);
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
                info.inheritedColorSpace = info.activeColorSpace;
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
    info.isLocalDefinition = LocalNodeDef(graph) != nullptr;
    if (nodeDef) {
        info.nodeDefName = nodeDef->getName();
        info.nodeGroup = nodeDef->getNodeGroup();
        info.doc = nodeDef->getDocString();
        info.nodeDefVersion = nodeDef->getVersionString();
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

BackdropInfo DescribeBackdrop(const mx::BackdropPtr& backdrop) {
    BackdropInfo info;
    info.name = backdrop->getName();
    info.path = backdrop->getNamePath();
    info.isIncluded = IsIncluded(backdrop);
    info.note = backdrop->getAttribute("note");
    ReadPosition(backdrop, info);
    if (backdrop->hasContainsString()) {
        for (const std::string& name : SplitList(backdrop->getContainsString())) {
            if (!name.empty()) {
                info.contains.push_back(name);
            }
        }
    }
    // Both, and positive, or neither: the canvas fits it to its contents.
    try {
        if (backdrop->hasWidth() && backdrop->hasHeight() && backdrop->getWidth() > 0 && backdrop->getHeight() > 0) {
            info.width = backdrop->getWidth();
            info.height = backdrop->getHeight();
            info.hasSize = true;
        }
    } catch (const std::exception&) {
        // Not numbers: as if unset.
    }
    return info;
}

/// The file a filename input or value refers to: its value with
/// `fileprefix` (from it or any ancestor) applied, made absolute against
/// the folder of the file it was read from. Relative still if the
/// document wasn't read from a file.
std::string AbsoluteFilename(const mx::ValueElementPtr& value) {
    mx::FilePath file(value->getResolvedValueString());
    const std::string source = ResolvedSourceUri(value);
    if (!file.isEmpty() && !file.isAbsolute() && !source.empty()) {
        file = (mx::FilePath(source).getParentPath() / file).getNormalized();
    }
    return file.asString();
}

} // namespace

namespace {

/// Defined with the M4a edits below.
void UngroupForStorm(const mx::DocumentPtr& preview, bool expandEveryDefinition = false);
/// Defined with the M4c1 edits below.
void ExpandInstance(const mx::NodePtr& node, const mx::NodeGraphPtr& implementation, const mx::NodeDefPtr& nodeDef);
/// Defined with UngroupForStorm below.
std::vector<std::pair<mx::NodeDefPtr, mx::NodeGraphPtr>> ExpandDefinitions(const mx::DocumentPtr& preview, bool every);

} // namespace

namespace {

/// True if `port` reads from a node or nodegraph (as ReadsSibling, which
/// comes later in this file).
bool ReadsSiblingPort(const mx::PortElementPtr& port) {
    return !port->getNodeName().empty() || !port->getNodeGraphString().empty();
}

/// A copy of `document` for a renderer reading it from memory: absolute
/// file paths, `fileprefix` applied (see writeForPreview). It keeps the
/// document's data library, so nodedefs can still be looked up.
mx::DocumentPtr PreviewCopy(const mx::DocumentPtr& document) {
    // A copy, so the document itself keeps its relative paths.
    mx::DocumentPtr preview = document->copy();
    preview->setSourceUri(document->getSourceUri());
    if (mx::ConstDocumentPtr library = document->getDataLibrary()) {
        preview->setDataLibrary(library);
    }

    for (const mx::ElementPtr& element : preview->traverseTree()) {
        mx::ValueElementPtr value = element->asA<mx::ValueElement>();
        if (!value || value->getType() != mx::FILENAME_TYPE_STRING || !value->hasValueString()) {
            continue;
        }
        value->setValueString(AbsoluteFilename(value));
    }
    // The prefixes are applied now; leaving them would apply them twice.
    for (const mx::ElementPtr& element : preview->traverseTree()) {
        element->removeAttribute(mx::Element::FILE_PREFIX_ATTRIBUTE);
    }
    preview->removeAttribute(mx::Element::FILE_PREFIX_ATTRIBUTE);

    // Storm ignores the colour space of a file that a node reads through
    // its nodegraph's input (`interfacename`), on either input (M4b,
    // PLAN.md §8.2): the texture came out unconverted. So such inputs
    // take the file and its space themselves, which means the same.
    for (const mx::ElementPtr& element : preview->traverseTree()) {
        mx::InputPtr input = element->asA<mx::Input>();
        if (!input || input->getType() != mx::FILENAME_TYPE_STRING || !input->hasInterfaceName() ||
            !input->getParent()->isA<mx::Node>()) {
            continue;
        }
        mx::NodeGraphPtr graph = input->getParent()->getParent()->asA<mx::NodeGraph>();
        mx::InputPtr interface = graph ? graph->getInput(input->getInterfaceName()) : nullptr;
        if (!interface || !interface->hasValueString() || ReadsSiblingPort(interface)) {
            continue;
        }
        const std::string colorSpace = interface->getActiveColorSpace();
        input->removeAttribute(mx::ValueElement::INTERFACE_NAME_ATTRIBUTE);
        input->setValueString(interface->getValueString());
        if (!colorSpace.empty() && !input->hasColorSpace()) {
            input->setColorSpace(colorSpace);
        }
    }

    // Storm ignores `colorspace` on <materialx> (UsdMtlx doesn't carry it
    // over; PLAN.md §8.2), though it honours it on nodes, nodegraphs and
    // inputs. So the document's working space moves down onto the
    // top-level elements that don't have their own: the same colours, in
    // a form Storm reads.
    const std::string workingSpace = preview->getColorSpace();
    if (!workingSpace.empty()) {
        for (const mx::ElementPtr& child : preview->getChildren()) {
            bool holdsColors = child->isA<mx::Node>() || child->isA<mx::NodeGraph>() || child->isA<mx::NodeDef>();
            if (holdsColors && !child->hasColorSpace()) {
                child->setColorSpace(workingSpace);
            }
        }
        preview->removeAttribute(mx::Element::COLOR_SPACE_ATTRIBUTE);
    }
    return preview;
}

/// Writes a preview copy with included elements in place, not as
/// references to their files.
std::string WritePreview(const mx::DocumentPtr& preview) {
    mx::XmlWriteOptions options;
    options.writeXIncludeEnable = false;
    return mx::writeToXmlString(preview, &options);
}

/// The conversions from a value type to color3, through the standard
/// library's `convert` nodes: one step for most, two for vector2 (there is
/// no vector2-to-color3), and through float for integers and booleans.
/// Empty for types with no conversion.
std::vector<std::string> ConversionsToColor3(const std::string& type) {
    if (type == "color3") {
        return {};
    }
    if (type == "vector2") {
        return {"vector3", "color3"};
    }
    if (type == "integer" || type == "boolean") {
        return {"float", "color3"};
    }
    if (type == "float" || type == "color4" || type == "vector3" || type == "vector4") {
        return {"color3"};
    }
    return {"?"};
}

} // namespace

std::string Document::writeForPreview() const {
    if (!_impl) {
        return {};
    }
    try {
        return WritePreview(PreviewCopy(_impl->document));
    } catch (const std::exception&) {
        return {};
    }
}

std::string Document::writeForViewport() const {
    if (!_impl) {
        return {};
    }
    try {
        mx::DocumentPtr preview = PreviewCopy(_impl->document);
        UngroupForStorm(preview);
        return WritePreview(preview);
    } catch (const std::exception&) {
        return {};
    }
}

namespace {

/// True if the image file at `path` has one channel of colour (grey, with
/// or without alpha), as ImageIO reads it. False if it can't be read.
bool IsGreyscaleImage(const std::string& path) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8*>(path.c_str()),
                                                           static_cast<CFIndex>(path.size()), false);
    if (!url) {
        return false;
    }
    CGImageSourceRef source = CGImageSourceCreateWithURL(url, nullptr);
    CFRelease(url);
    if (!source) {
        return false;
    }
    bool greyscale = false;
    if (CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr)) {
        const void* model = CFDictionaryGetValue(properties, kCGImagePropertyColorModel);
        greyscale = model && CFEqual(model, kCGImagePropertyColorModelGray);
        CFRelease(properties);
    }
    CFRelease(source);
    return greyscale;
}

/// The value of `input`, or of the nodegraph input it reads through
/// `interfacename`; "" if neither has one.
std::string ValueThroughInterface(const mx::InputPtr& input) {
    if (input->hasInterfaceName()) {
        mx::NodeGraphPtr graph = input->getParent()->getParent()->asA<mx::NodeGraph>();
        mx::InputPtr interface = graph ? graph->getInput(input->getInterfaceName()) : nullptr;
        return interface && !ReadsSiblingPort(interface) ? interface->getValueString() : "";
    }
    return ReadsSiblingPort(input) ? "" : input->getValueString();
}

/// The first number of a vector or colour value ("0.5, 0.2, 0.1": "0.5").
std::string FirstComponent(const std::string& value) {
    const std::string first = value.substr(0, value.find(','));
    const size_t start = first.find_first_not_of(' ');
    const size_t end = first.find_last_not_of(' ');
    return start == std::string::npos ? "0" : first.substr(start, end - start + 1);
}

/// Rewrites, in an export copy, the image nodes that read greyscale files
/// as colours, to read them as a float and convert that to a colour: the
/// same numbers (MaterialX copies one channel into all three either way),
/// which Reality Composer Pro reads right. Read as a colour, it puts the
/// grey in red alone (spike M5a, finding 7).
///
/// MaterialX converts a file's colour space only for colour outputs, so a
/// float image would skip it: the conversion from the file's space to the
/// working space (`workingSpace`, lin_rec709 if empty) follows the
/// `convert` explicitly, as the standard library's transform node
/// expanded into its implementation, plain maths every reader knows.
///
///   before:  image (color3, srgb_texture) ──▶ readers
///   after:   image (float) ─▶ convert ─▶ srgb_texture_to_lin_rec709's nodes ─▶ readers
///
/// The image node keeps its place under a new name; the last node takes
/// its name, so whatever read it reads the colour. Images in a space with
/// no transform to the working space are left as they are.
void ReadGreyscaleImagesAsFloats(const mx::DocumentPtr& preview, std::string workingSpace) {
    if (workingSpace.empty()) {
        workingSpace = "lin_rec709";
    }
    static const std::set<std::string> imageNodes = {"image", "tiledimage", "hextiledimage", "triplanarprojection"};
    // Collected first: the rewrite adds nodes to the tree being walked.
    std::vector<mx::NodePtr> nodes;
    for (const mx::ElementPtr& element : preview->traverseTree()) {
        mx::NodePtr node = element->asA<mx::Node>();
        if (node && node->getType() == "color3" && imageNodes.count(node->getCategory())) {
            nodes.push_back(node);
        }
    }
    for (const mx::NodePtr& node : nodes) {
        // Every file it reads (triplanarprojection has three) greyscale,
        // and in the same colour space.
        bool greyscale = false;
        std::vector<mx::InputPtr> files;
        for (const mx::InputPtr& input : node->getInputs()) {
            if (input->getType() == mx::FILENAME_TYPE_STRING) {
                files.push_back(input);
                greyscale = IsGreyscaleImage(ValueThroughInterface(input)) &&
                            input->getActiveColorSpace() == files.front()->getActiveColorSpace();
                if (!greyscale) {
                    break;
                }
            }
        }
        if (!greyscale) {
            continue;
        }
        // The transform from the files' space, if there is one to make.
        const std::string fileSpace = files.front()->getActiveColorSpace();
        mx::NodeDefPtr transformDef;
        if (!fileSpace.empty() && fileSpace != workingSpace) {
            transformDef = preview->getNodeDef("ND_" + fileSpace + "_to_" + workingSpace + "_color3");
            if (!transformDef) {
                continue;
            }
        }
        // The same kind of node, giving a float.
        mx::NodeDefPtr floatDef;
        for (const mx::NodeDefPtr& nodeDef : preview->getMatchingNodeDefs(node->getCategory())) {
            if (nodeDef->getType() == "float") {
                floatDef = nodeDef;
                break;
            }
        }
        if (!floatDef) {
            continue;
        }
        // Inputs whose type differs in the float version (`default`, a
        // colour there) take their first number; connected ones can't.
        bool convertible = true;
        for (const mx::InputPtr& input : node->getInputs()) {
            mx::InputPtr wanted = floatDef->getActiveInput(input->getName());
            if (wanted && wanted->getType() != input->getType() &&
                (ReadsSiblingPort(input) || input->hasInterfaceName() || wanted->getType() != "float")) {
                convertible = false;
            }
        }
        if (!convertible) {
            continue;
        }
        for (const mx::InputPtr& input : node->getInputs()) {
            mx::InputPtr wanted = floatDef->getActiveInput(input->getName());
            if (wanted && wanted->getType() != input->getType()) {
                const std::string value = FirstComponent(input->getValueString());
                input->setType(wanted->getType());
                input->setValueString(value);
            }
        }
        mx::GraphElementPtr parent = node->getParent()->asA<mx::GraphElement>();
        const std::string name = node->getName();
        node->setName(parent->createValidChildName(name + "_float"));
        node->setType("float");
        node->removeAttribute(mx::InterfaceElement::NODE_DEF_ATTRIBUTE);
        // Read as raw numbers: the transform below does what the space did.
        for (const mx::InputPtr& file : files) {
            file->removeAttribute(mx::Element::COLOR_SPACE_ATTRIBUTE);
        }
        mx::NodePtr convert = parent->addNode("convert", transformDef ? parent->createValidChildName(name + "_color") : name,
                                              "color3");
        convert->addInput("in", "float")->setNodeName(node->getName());
        if (transformDef) {
            mx::NodePtr transform = parent->addNode(transformDef->getNodeString(), name, "color3");
            transform->addInput("in", "color3")->setNodeName(convert->getName());
            mx::InterfaceElementPtr implementation = transformDef->getImplementation();
            if (mx::NodeGraphPtr graph = implementation ? implementation->asA<mx::NodeGraph>() : nullptr) {
                ExpandInstance(transform, graph, transformDef);
            }
        }
    }
}

/// Moves `input` to `node` as its input `name`: value, connection or
/// interface alike. A node's input leaves it; a definition's (a default)
/// is copied.
void MoveInput(const mx::InputPtr& input, const mx::NodePtr& node, const std::string& name) {
    node->addInput(name, input->getType())->copyContentFrom(input);
    if (mx::NodePtr owner = input->getParent()->asA<mx::Node>()) {
        owner->removeInput(input->getName());
    }
}

/// Rewrites, in an export copy, every `mix` weighted by a colour or vector
/// (`ND_mix_color3_color3` and its kind) as the sum it computes:
///
///   before:  mix(fg, bg, mix)
///   after:   add(bg, multiply(subtract(fg, bg), mix))
///
/// RealityKit doesn't compile such a mix: Quick Look draws cyan stripes,
/// Reality Composer Pro white. The standard library's colour-space
/// transforms use one, so every image whose space export does by hand
/// (ReadGreyscaleImagesAsFloats) has one. A mix weighted by a float is
/// left as it is. The `add` keeps the mix's name, so its readers don't
/// change.
void SpellOutWeightedMixes(const mx::DocumentPtr& preview) {
    // Collected first: the rewrite adds nodes to the tree being walked.
    std::vector<mx::NodePtr> mixes;
    for (const mx::ElementPtr& element : preview->traverseTree()) {
        mx::NodePtr node = element->asA<mx::Node>();
        mx::NodeDefPtr nodeDef = node && node->getCategory() == "mix" ? node->getNodeDef() : nullptr;
        mx::InputPtr weight = nodeDef ? nodeDef->getActiveInput("mix") : nullptr;
        if (weight && weight->getType() != "float" && weight->getType() == node->getType()) {
            mixes.push_back(node);
        }
    }
    for (const mx::NodePtr& node : mixes) {
        mx::NodeDefPtr nodeDef = node->getNodeDef();
        mx::GraphElementPtr parent = node->getParent()->asA<mx::GraphElement>();
        const std::string name = node->getName();
        const std::string type = node->getType();
        // The node's own input, or the definition's default for it.
        auto input = [&](const std::string& port) {
            mx::InputPtr own = node->getInput(port);
            return own ? own : nodeDef->getActiveInput(port);
        };
        mx::NodePtr difference = parent->addNode("subtract", parent->createValidChildName(name + "_difference"), type);
        MoveInput(input("fg"), difference, "in1");
        // bg is read twice: copied here, moved below.
        difference->addInput("in2", type)->copyContentFrom(input("bg"));
        mx::NodePtr weighted = parent->addNode("multiply", parent->createValidChildName(name + "_weighted"), type);
        weighted->addInput("in1", type)->setNodeName(difference->getName());
        MoveInput(input("mix"), weighted, "in2");
        MoveInput(input("bg"), node, "in1");
        node->addInput("in2", type)->setNodeName(weighted->getName());
        node->setCategory("add");
        node->removeAttribute(mx::InterfaceElement::NODE_DEF_ATTRIBUTE);
    }
}

/// An export copy: the preview copy with every definition expanded (see
/// writeForUSD).
mx::DocumentPtr ExportCopy(const mx::DocumentPtr& document) {
    mx::DocumentPtr preview = PreviewCopy(document);
    UngroupForStorm(preview, true);
    return preview;
}

} // namespace

std::string Document::writeForUSDZ() const {
    if (!_impl) {
        return {};
    }
    try {
        mx::DocumentPtr preview = ExportCopy(_impl->document);
        ReadGreyscaleImagesAsFloats(preview, _impl->document->getColorSpace());
        SpellOutWeightedMixes(preview);
        return WritePreview(preview);
    } catch (const std::exception&) {
        return {};
    }
}

StringVector Document::quickLookIssues() const {
    StringVector issues;
    if (!_impl) {
        return issues;
    }
    // What RealityKit draws from its MaterialX graph (spike M5a); for any
    // other surface it draws a plain grey material (Quick Look) or magenta
    // (Reality Composer Pro).
    static const std::set<std::string> drawn = {"standard_surface", "open_pbr_surface", "UsdPreviewSurface"};
    try {
        mx::DocumentPtr preview = ExportCopy(_impl->document);
        for (const mx::NodePtr& material : preview->getMaterialNodes()) {
            for (const mx::NodePtr& shader : mx::getShaderNodes(material)) {
                if (!drawn.count(shader->getCategory())) {
                    issues.push_back(material->getName() + " uses " + shader->getCategory() +
                                     ", which Quick Look and Reality Composer Pro don't draw");
                }
            }
        }
    } catch (const std::exception&) {
    }
    return issues;
}

std::string Document::writeForUSD() const {
    if (!_impl) {
        return {};
    }
    try {
        return WritePreview(ExportCopy(_impl->document));
    } catch (const std::exception&) {
        return {};
    }
}

bool Document::writeSoloPreview(const std::string& elementPath, SoloPreview& solo,
                                std::string& errorMessage) const {
    if (!_impl) {
        errorMessage = "No document loaded";
        return false;
    }
    try {
        mx::DocumentPtr preview = PreviewCopy(_impl->document);
        mx::ElementPtr target = preview->getDescendant(elementPath);
        if (!target) {
            errorMessage = "No element at path " + elementPath;
            return false;
        }
        mx::ElementPtr parent = target->getParent();
        const bool topLevel = parent && parent->isA<mx::Document>();

        // What is shown, as a node and which of its outputs, and the
        // nodegraph it is in (null at the top level). Every case comes down
        // to this: a nodegraph shown as a node, or an <output>, is shown
        // through the node its output is connected to.
        mx::NodePtr source;
        std::string sourceOutput;
        mx::NodeGraphPtr owner;
        std::string type;

        auto showOutput = [&](const mx::OutputPtr& output, const mx::NodeGraphPtr& graph) {
            source = output->getConnectedNode();
            sourceOutput = output->getOutputString();
            owner = graph;
            type = output->getType();
        };

        if (mx::NodePtr node = target->asA<mx::Node>()) {
            source = node;
            type = node->getType();
            // A multi-output node shows its first output, as its swatch does.
            if (type == mx::MULTI_OUTPUT_TYPE_STRING) {
                mx::NodeDefPtr nodeDef = node->getNodeDef();
                std::vector<mx::OutputPtr> outputs = nodeDef ? nodeDef->getActiveOutputs() : std::vector<mx::OutputPtr>{};
                if (outputs.empty()) {
                    errorMessage = node->getName() + " has no outputs to show";
                    return false;
                }
                sourceOutput = outputs.front()->getName();
                type = outputs.front()->getType();
            }
            if (topLevel && type == mx::MATERIAL_TYPE_STRING) {
                // A material is shown as it is.
                solo.materialName = node->getName();
                solo.outputType = type;
                UngroupForStorm(preview);
                solo.xml = WritePreview(preview);
                return true;
            }
            if (!topLevel) {
                owner = parent->asA<mx::NodeGraph>();
            }
        } else if (mx::NodeGraphPtr graph = target->asA<mx::NodeGraph>(); graph && topLevel) {
            // A nodegraph shown as a node: its first output.
            std::vector<mx::OutputPtr> outputs = graph->getOutputs();
            if (outputs.empty()) {
                errorMessage = graph->getName() + " has no outputs to show";
                return false;
            }
            showOutput(outputs.front(), graph);
        } else if (mx::OutputPtr output = target->asA<mx::Output>(); output && parent && parent->isA<mx::NodeGraph>()) {
            showOutput(output, parent->asA<mx::NodeGraph>());
        } else {
            errorMessage = elementPath + " can't be shown on its own";
            return false;
        }
        if (!source) {
            errorMessage = elementPath + " isn't connected to a node";
            return false;
        }
        if (owner && !(owner->getParent() && owner->getParent()->isA<mx::Document>())) {
            errorMessage = "Only nodes at the top level or in a top-level nodegraph can be shown";
            return false;
        }

        // The chain from the shown node to the material is built in two
        // parts, because of how UsdMtlx (OpenUSD's MaterialX reader, which
        // Storm uses) translates documents:
        //
        //  - Conversions of a value to color3 go next to the shown node,
        //    inside its nodegraph if it is in one: a top-level `convert`
        //    reading a nodegraph's output came out black.
        //  - Shader nodes (the surface, a BSDF's `surface`) go at the top
        //    level, reading the nodegraph through a new output: shader
        //    nodes inside a nodegraph lost their connections.
        //
        // `last` and `lastOutput` are the end of the chain so far.
        mx::NodePtr last = source;
        std::string lastOutput = sourceOutput;
        // Connects `port` (an input, or a nodegraph's output: both are
        // port elements) to the end of the chain, from the same scope.
        auto feed = [&](const mx::PortElementPtr& port) {
            port->setNodeName(last->getName());
            if (!lastOutput.empty()) {
                port->setOutputString(lastOutput);
            }
        };

        // 1. Conversions, next to the shown node.
        std::string shownType = type;
        if (type != mx::SURFACE_SHADER_TYPE_STRING && type != "BSDF") {
            std::vector<std::string> steps = ConversionsToColor3(type);
            if (!steps.empty() && steps.front() == "?") {
                errorMessage = "A " + type + " output can't be shown on the sphere";
                return false;
            }
            mx::GraphElementPtr scope = owner ? mx::GraphElementPtr(owner) : mx::GraphElementPtr(preview);
            std::string from = type;
            for (const std::string& to : steps) {
                mx::NodePtr convert = scope->addNode("convert", scope->createValidChildName("margolaria_solo_convert"), to);
                feed(convert->addInput("in", from));
                last = convert;
                lastOutput.clear();
                from = to;
            }
            shownType = "color3";
        }

        // Connects a top-level input to the end of the chain: directly, or
        // through a new output of the nodegraph the chain ends in.
        auto feedFromTop = [&](const mx::InputPtr& input) {
            if (!owner) {
                feed(input);
                return;
            }
            mx::OutputPtr exit = owner->addOutput(owner->createValidChildName("margolaria_solo_out"), shownType);
            feed(exit);
            input->setNodeGraphString(owner->getName());
            input->setOutputString(exit->getName());
        };

        // 2. The surface shader, at the top level.
        mx::NodePtr material = preview->addNode("surfacematerial", preview->createValidChildName("margolaria_solo"),
                                                mx::MATERIAL_TYPE_STRING);
        mx::InputPtr shaderInput = material->addInput("surfaceshader", mx::SURFACE_SHADER_TYPE_STRING);
        if (shownType == mx::SURFACE_SHADER_TYPE_STRING) {
            feedFromTop(shaderInput);
        } else if (shownType == "BSDF") {
            // A BSDF on its own lights the sphere through MaterialX's
            // `surface` node, as a shader would.
            mx::NodePtr surface = preview->addNode("surface", preview->createValidChildName("margolaria_solo_surface"),
                                                   mx::SURFACE_SHADER_TYPE_STRING);
            feedFromTop(surface->addInput("bsdf", "BSDF"));
            shaderInput->setNodeName(surface->getName());
        } else {
            // Values are shown unlit, as their swatches are: the colour is
            // the value, whatever the light. As the emission of a
            // standard_surface with no base and no specular, which adds
            // nothing else, rather than MaterialX's surface_unlit: Storm
            // (OpenUSD 26.08) can't compile surface_unlit, whose code uses
            // environment uniforms Storm only declares for lit surfaces,
            // and falls back to a grey sphere.
            mx::NodePtr surface = preview->addNode("standard_surface",
                                                   preview->createValidChildName("margolaria_solo_surface"),
                                                   mx::SURFACE_SHADER_TYPE_STRING);
            surface->setInputValue("base", 0.0f);
            surface->setInputValue("specular", 0.0f);
            surface->setInputValue("emission", 1.0f);
            feedFromTop(surface->addInput("emission_color", "color3"));
            shaderInput->setNodeName(surface->getName());
        }

        solo.materialName = material->getName();
        solo.outputType = type;
        UngroupForStorm(preview);
        solo.xml = WritePreview(preview);
        return true;
    } catch (const std::exception& e) {
        errorMessage = e.what();
        return false;
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
            } else if (mx::BackdropPtr backdrop = child->asA<mx::Backdrop>()) {
                graph.backdrops.push_back(DescribeBackdrop(backdrop));
            }
            // Everything else (nodedefs, looks, ...) is not part of the
            // graph view.
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

Document Document::readText(const std::string& xml, std::string& errorMessage) const {
    if (!_impl) {
        errorMessage = "No document loaded";
        return Document();
    }
    try {
        auto impl = std::make_shared<Impl>();
        impl->document = mx::createDocument();
        // The file's folder, as readFromFile searches it. A document that
        // didn't come from a file has no source, and no folder to search.
        const std::string source = _impl->document->getSourceUri();
        mx::FileSearchPath searchPath;
        if (!source.empty()) {
            searchPath.append(mx::FilePath(source).getParentPath());
        }
        const mx::XmlReadOptions options = ReadOptions();
        mx::readFromXmlString(impl->document, xml, searchPath, &options);
        impl->document->setSourceUri(source);
        if (mx::ConstDocumentPtr library = _impl->document->getDataLibrary()) {
            impl->document->setDataLibrary(library);
        }
        Document document;
        document._impl = impl;
        return document;
    } catch (const std::exception& e) {
        errorMessage = e.what();
        return Document();
    }
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
            // their defaults from the nodedef. One in this document is
            // changed there (M4c1); others can't be changed here.
            if (mx::NodeDefPtr nodeDef = LocalNodeDef(graph)) {
                input = nodeDef->getInput(inputName);
            } else if (mx::NodeDefPtr nodeDef = graph->getNodeDef()) {
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

/// The type of what comes out of `source` (a node or nodegraph) through
/// its output `outputName`, or its only output for "".
std::string SourceOutputType(const mx::ElementPtr& source, const std::string& outputName) {
    if (mx::NodeGraphPtr nodeGraph = source->asA<mx::NodeGraph>()) {
        std::vector<mx::OutputPtr> outputs = nodeGraph->getOutputs();
        mx::OutputPtr output = outputName.empty() ? (outputs.size() == 1 ? outputs.front() : nullptr)
                                                  : nodeGraph->getOutput(outputName);
        if (!output) {
            throw Refusal("Say which output of " + source->getName() + " to use");
        }
        return output->getType();
    }
    mx::NodePtr node = source->asA<mx::Node>();
    if (!node) {
        throw Refusal(source->getName() + " is not a node or nodegraph");
    }
    if (outputName.empty() && node->getType() != mx::MULTI_OUTPUT_TYPE_STRING) {
        return node->getType();
    }
    mx::NodeDefPtr nodeDef = node->getNodeDef();
    mx::OutputPtr output = nodeDef ? nodeDef->getActiveOutput(outputName) : nullptr;
    if (!output) {
        throw Refusal(source->getName() + " has no output " + outputName);
    }
    return output->getType();
}

/// A position or size as written in the file, with three decimals: a
/// thousandth of a node is far below a pixel, and shorter numbers keep
/// the file tidy.
std::string FormatUnits(float value) {
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
}

/// Sets `xpos`/`ypos` on `element` (see FormatUnits).
void SetPosition(const mx::ElementPtr& element, float x, float y) {
    element->setAttribute(mx::Element::XPOS_ATTRIBUTE, FormatUnits(x));
    element->setAttribute(mx::Element::YPOS_ATTRIBUTE, FormatUnits(y));
}

// --- Keeping backdrops current (M4d) ----------------------------------------
//
// A backdrop names what it contains; MaterialX's validation rejects a name
// that isn't a sibling. So every edit ends with KeepBackdropsCurrent, and
// the edits that rename or regroup elements update the names themselves.

/// The names a backdrop contains, in order.
std::vector<std::string> Contents(const mx::BackdropPtr& backdrop) {
    std::vector<std::string> names;
    for (const std::string& name : SplitList(backdrop->getContainsString())) {
        if (!name.empty()) {
            names.push_back(name);
        }
    }
    return names;
}

/// Sets what a backdrop contains; nothing removes the attribute.
void SetContents(const mx::BackdropPtr& backdrop, const std::vector<std::string>& names) {
    if (names.empty()) {
        backdrop->removeAttribute(mx::Backdrop::CONTAINS_ATTRIBUTE);
    } else {
        backdrop->setContainsString(mx::joinStrings(names, ","));
    }
}

/// The backdrops in `graph` that can be changed (not included).
std::vector<mx::BackdropPtr> EditableBackdrops(const mx::ElementPtr& graph) {
    std::vector<mx::BackdropPtr> backdrops;
    for (const mx::ElementPtr& child : graph->getChildren()) {
        if (mx::BackdropPtr backdrop = child->asA<mx::Backdrop>(); backdrop && !IsIncluded(backdrop)) {
            backdrops.push_back(backdrop);
        }
    }
    return backdrops;
}

/// Drops, from every backdrop in the document, the names of elements that
/// aren't beside it any more (removed, or moved into a nodegraph).
void KeepBackdropsCurrent(const mx::DocumentPtr& document) {
    for (const mx::ElementPtr& element : document->traverseTree()) {
        mx::BackdropPtr backdrop = element->asA<mx::Backdrop>();
        if (!backdrop || IsIncluded(backdrop) || !backdrop->hasContainsString()) {
            continue;
        }
        const std::vector<std::string> names = Contents(backdrop);
        std::vector<std::string> kept;
        for (const std::string& name : names) {
            if (backdrop->getParent()->getChildOfType<mx::TypedElement>(name)) {
                kept.push_back(name);
            }
        }
        if (kept != names) {
            SetContents(backdrop, kept);
        }
    }
}

/// In the backdrops of `graph`, the element `oldName` is now `newName`.
void RenameInBackdrops(const mx::ElementPtr& graph, const std::string& oldName, const std::string& newName) {
    for (const mx::BackdropPtr& backdrop : EditableBackdrops(graph)) {
        std::vector<std::string> names = Contents(backdrop);
        if (std::find(names.begin(), names.end(), oldName) != names.end()) {
            std::replace(names.begin(), names.end(), oldName, newName);
            SetContents(backdrop, names);
        }
    }
}

/// The backdrops of `graph` that contain any of `names`.
std::vector<mx::BackdropPtr> BackdropsContaining(const mx::ElementPtr& graph, const std::set<std::string>& names) {
    std::vector<mx::BackdropPtr> found;
    for (const mx::BackdropPtr& backdrop : EditableBackdrops(graph)) {
        for (const std::string& name : Contents(backdrop)) {
            if (names.count(name)) {
                found.push_back(backdrop);
                break;
            }
        }
    }
    return found;
}

/// Adds `names` to each of `backdrops`, after what they contain.
void AddToBackdrops(const std::vector<mx::BackdropPtr>& backdrops, const std::vector<std::string>& names) {
    for (const mx::BackdropPtr& backdrop : backdrops) {
        std::vector<std::string> contents = Contents(backdrop);
        for (const std::string& name : names) {
            if (std::find(contents.begin(), contents.end(), name) == contents.end()) {
                contents.push_back(name);
            }
        }
        SetContents(backdrop, contents);
    }
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
        KeepBackdropsCurrent(document);
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

bool Document::setInputColorSpace(const std::string& elementPath, const std::string& inputName,
                                  const std::string& colorSpace, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::PortElementPtr port = Port(EditableElement(document, elementPath), inputName, true);
        if (!port->isA<mx::Input>()) {
            throw Refusal("Only inputs have a colour space");
        }
        if (colorSpace.empty()) {
            port->removeAttribute(mx::Element::COLOR_SPACE_ATTRIBUTE);
        } else {
            port->setColorSpace(colorSpace);
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

        const std::string sourceType = SourceOutputType(source, sourceOutput);

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
        // A definition's implementation goes with its definition (M4c1).
        if (mx::NodeGraphPtr graph = element->asA<mx::NodeGraph>(); graph && graph->hasNodeDefString()) {
            throw Refusal(graph->getName() + " implements " + graph->getNodeDefString() +
                          ": delete the definition instead");
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
        RenameInBackdrops(graph, oldName, newName);
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
        SetPosition(EditableElement(document, path), x, y);
    });
}

// --- Backdrops (M4d) ----------------------------------------------------------

namespace {

// Defined with the M4a edits below.
mx::GraphElementPtr EditableGraph(const mx::DocumentPtr& document, const std::string& path);

/// The backdrop at `path`, which may be edited.
mx::BackdropPtr EditableBackdrop(const mx::DocumentPtr& document, const std::string& path) {
    mx::BackdropPtr backdrop = EditableElement(document, path)->asA<mx::Backdrop>();
    if (!backdrop) {
        throw Refusal(path + " is not a backdrop");
    }
    return backdrop;
}

/// Refuses names in `contains` that aren't elements of `graph` a backdrop
/// can frame (MaterialX: typed elements, so not other backdrops).
void RequireFramable(const mx::ElementPtr& graph, const StringVector& contains) {
    for (const std::string& name : contains) {
        if (!graph->getChildOfType<mx::TypedElement>(name)) {
            throw Refusal("There is no node called " + name + " here to put in a backdrop");
        }
    }
}

/// Sets `width`/`height` on `backdrop` (see FormatUnits).
void SetSize(const mx::BackdropPtr& backdrop, float width, float height) {
    if (!(width > 0 && height > 0)) {
        throw Refusal("A backdrop needs a width and a height");
    }
    backdrop->setAttribute(mx::Backdrop::WIDTH_ATTRIBUTE, FormatUnits(width));
    backdrop->setAttribute(mx::Backdrop::HEIGHT_ATTRIBUTE, FormatUnits(height));
}

} // namespace

bool Document::addBackdrop(const std::string& parentPath, const StringVector& contains, const std::string& nameHint,
                           float x, float y, float width, float height, std::string& newPath,
                           std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::GraphElementPtr parent = EditableGraph(document, parentPath);
        RequireFramable(parent, contains);
        mx::BackdropPtr backdrop =
            parent->addBackdrop(parent->createValidChildName(nameHint.empty() ? "backdrop" : mx::createValidName(nameHint)));
        SetContents(backdrop, contains);
        SetPosition(backdrop, x, y);
        SetSize(backdrop, width, height);
        newPath = backdrop->getNamePath();
    });
}

bool Document::setBackdropFrame(const std::string& path, float x, float y, float width, float height,
                                std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::BackdropPtr backdrop = EditableBackdrop(document, path);
        SetSize(backdrop, width, height);
        SetPosition(backdrop, x, y);
    });
}

bool Document::setBackdropContents(const std::string& path, const StringVector& contains, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::BackdropPtr backdrop = EditableBackdrop(document, path);
        RequireFramable(backdrop->getParent(), contains);
        SetContents(backdrop, contains);
    });
}

bool Document::setBackdropNote(const std::string& path, const std::string& note, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::BackdropPtr backdrop = EditableBackdrop(document, path);
        if (note.empty()) {
            backdrop->removeAttribute("note");
        } else {
            backdrop->setAttribute("note", note);
        }
    });
}

bool Document::removeBackdrop(const std::string& path, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::BackdropPtr backdrop = EditableBackdrop(document, path);
        backdrop->getParent()->removeChild(backdrop->getName());
    });
}

// --- Nodegraphs, outputs, copy and paste (M4a) -----------------------------

namespace {

/// The graph at `path`: the document for "", or a nodegraph that may be
/// edited.
mx::GraphElementPtr EditableGraph(const mx::DocumentPtr& document, const std::string& path) {
    mx::ElementPtr element = path.empty() ? mx::ElementPtr(document) : EditableElement(document, path);
    mx::GraphElementPtr graph = element->asA<mx::GraphElement>();
    if (!graph || !(graph->isA<mx::Document>() || graph->isA<mx::NodeGraph>())) {
        throw Refusal(path + " is not a nodegraph");
    }
    return graph;
}

/// Refuses to put a nodegraph inside `graph` unless it is the document.
/// MaterialX 1.39.5 can't connect to a nodegraph inside another: its
/// validation finds no output for the connection ("No output found for
/// port connection", "Invalid port connection"; PLAN.md §8.2).
void RequireTopLevel(const mx::GraphElementPtr& graph) {
    if (!graph->isA<mx::Document>()) {
        throw Refusal("Nodegraphs can only be at the top level of the document: MaterialX can't connect "
                      "to a nodegraph inside another");
    }
}

/// The node or nodegraph `name` in `graph`, which must not be a material:
/// materials stay at the top level of a document.
mx::ElementPtr MovableNode(const mx::GraphElementPtr& graph, const std::string& name) {
    mx::ElementPtr element = graph->getChild(name);
    if (!element || !(element->isA<mx::Node>() || element->isA<mx::NodeGraph>())) {
        throw Refusal("No node or nodegraph " + name + " in " + (graph->isA<mx::Document>() ? "the document" : graph->getName()));
    }
    if (IsIncluded(element)) {
        throw Refusal(name + " comes from an included file and can't be changed here");
    }
    return element;
}

/// True for nodes that output a material: they must stay at the top level.
bool IsMaterial(const mx::ElementPtr& element) {
    mx::NodePtr node = element->asA<mx::Node>();
    return node && node->getType() == mx::MATERIAL_TYPE_STRING;
}

/// A copy of `element` (a node or nodegraph) added to `graph` as `name`:
/// same attributes and children. The original is left where it is.
mx::ElementPtr CopyNode(const mx::ElementPtr& element, const mx::GraphElementPtr& graph, const std::string& name) {
    mx::ElementPtr copy;
    if (mx::NodePtr node = element->asA<mx::Node>()) {
        copy = graph->addNode(node->getCategory(), name, node->getType());
    } else {
        copy = graph->addChildOfCategory(mx::NodeGraph::CATEGORY, name);
    }
    copy->copyContentFrom(element);
    return copy;
}

/// Copies the attributes that say where a port's value comes from
/// (`nodename`, `nodegraph`, `output`, `interfacename`) from `from` to `to`.
void CopyConnection(const mx::PortElementPtr& from, const mx::PortElementPtr& to) {
    ClearConnection(to);
    for (const std::string& attribute : {mx::PortElement::NODE_NAME_ATTRIBUTE, mx::PortElement::NODE_GRAPH_ATTRIBUTE,
                                         mx::PortElement::OUTPUT_ATTRIBUTE, mx::ValueElement::INTERFACE_NAME_ATTRIBUTE}) {
        if (from->hasAttribute(attribute)) {
            to->setAttribute(attribute, from->getAttribute(attribute));
        }
    }
}

/// True if `port` reads from a node or nodegraph (not a graph's input).
bool ReadsSibling(const mx::PortElementPtr& port) {
    return !port->getNodeName().empty() || !port->getNodeGraphString().empty();
}

/// The name of the node or nodegraph `port` reads from, or "".
std::string SiblingName(const mx::PortElementPtr& port) {
    return !port->getNodeName().empty() ? port->getNodeName() : port->getNodeGraphString();
}

/// Renames what the inputs of `elements` read from, following `names`
/// (old name → new name), for elements that were copied or moved together.
void RenameReferences(const std::vector<mx::ElementPtr>& elements, const std::map<std::string, std::string>& names) {
    for (const mx::ElementPtr& element : elements) {
        for (const mx::InputPtr& input : element->asA<mx::InterfaceElement>()->getInputs()) {
            auto found = names.find(SiblingName(input));
            if (!ReadsSibling(input) || found == names.end()) {
                continue;
            }
            if (!input->getNodeName().empty()) {
                input->setNodeName(found->second);
            } else {
                input->setNodeGraphString(found->second);
            }
        }
    }
}

/// The average `xpos`/`ypos` of the elements that have one; false if none has.
bool AveragePosition(const std::vector<mx::ElementPtr>& elements, float& x, float& y) {
    int count = 0;
    x = 0;
    y = 0;
    for (const mx::ElementPtr& element : elements) {
        if (element->hasAttribute(mx::Element::XPOS_ATTRIBUTE) && element->hasAttribute(mx::Element::YPOS_ATTRIBUTE)) {
            x += std::stof(element->getAttribute(mx::Element::XPOS_ATTRIBUTE));
            y += std::stof(element->getAttribute(mx::Element::YPOS_ATTRIBUTE));
            count += 1;
        }
    }
    if (count == 0) {
        return false;
    }
    x /= count;
    y /= count;
    return true;
}

/// MaterialX's name for a working space, with "" meaning its default.
std::string SpaceName(const std::string& colorSpace) {
    return colorSpace.empty() ? std::string("lin_rec709") : colorSpace;
}

/// Gives `elements` (just put in a graph whose working space is
/// `newSpace`) the space their colours were in, `oldSpace`, unless they
/// set their own: the colours stay the same.
void KeepColorSpace(const std::vector<mx::ElementPtr>& elements, const std::string& oldSpace, const std::string& newSpace) {
    if (SpaceName(oldSpace) == SpaceName(newSpace)) {
        return;
    }
    for (const mx::ElementPtr& element : elements) {
        if (!element->hasColorSpace()) {
            element->setColorSpace(SpaceName(oldSpace));
        }
    }
}

/// The nodegraph at `path`, whose outputs may be edited: not one that
/// implements a nodedef, whose outputs are the nodedef's.
mx::NodeGraphPtr GraphWithOwnOutputs(const mx::DocumentPtr& document, const std::string& path) {
    mx::NodeGraphPtr graph = path.empty() ? nullptr : EditableElement(document, path)->asA<mx::NodeGraph>();
    if (!graph) {
        throw Refusal("Only nodegraphs have outputs that can be changed");
    }
    if (graph->hasNodeDefString()) {
        throw Refusal("The outputs of " + graph->getName() + " are defined by " + graph->getNodeDefString() +
                      " and are changed there");
    }
    return graph;
}

/// The ports next to `graph` that read its output `outputName`: by name,
/// or without naming one if it is the graph's only output.
std::vector<mx::PortElementPtr> PortsReading(const mx::NodeGraphPtr& graph, const std::string& outputName) {
    std::vector<mx::PortElementPtr> ports;
    const bool only = graph->getOutputs().size() == 1;
    for (const mx::PortElementPtr& port : SiblingPorts(graph->getParent())) {
        if (port->getNodeGraphString() != graph->getName()) {
            continue;
        }
        if (port->getOutputString() == outputName || (only && port->getOutputString().empty())) {
            ports.push_back(port);
        }
    }
    return ports;
}

} // namespace

bool Document::collapseIntoNodeGraph(const std::string& parentPath, const StringVector& names,
                                     const std::string& nameHint, std::string& newPath, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::GraphElementPtr parent = EditableGraph(document, parentPath);
        RequireTopLevel(parent);
        if (names.empty()) {
            throw Refusal("Select the nodes to put in a nodegraph");
        }
        // The selection, in file order, so the nodegraph keeps it.
        std::set<std::string> selected(names.begin(), names.end());
        std::vector<mx::ElementPtr> elements;
        for (const std::string& name : selected) {
            mx::ElementPtr element = MovableNode(parent, name);
            if (IsMaterial(element)) {
                throw Refusal(name + " is a material: materials stay at the top level of the document");
            }
            if (element->isA<mx::NodeGraph>()) {
                throw Refusal(name + " is a nodegraph: MaterialX can't connect to a nodegraph inside another");
            }
        }
        for (const mx::ElementPtr& child : parent->getChildren()) {
            if (selected.count(child->getName())) {
                elements.push_back(child);
            }
        }
        const int index = parent->getChildIndex(elements.front()->getName());
        // The backdrops that framed some of the nodes frame the graph.
        const std::vector<mx::BackdropPtr> framing = BackdropsContaining(parent, selected);

        // Outside ports reading the selection, before anything moves.
        std::vector<mx::PortElementPtr> outbound;
        for (const mx::PortElementPtr& port : SiblingPorts(parent)) {
            const bool inside = selected.count(port->getParent()->getName()) && !port->isA<mx::Output>();
            if (!inside && ReadsSibling(port) && selected.count(SiblingName(port))) {
                outbound.push_back(port);
            }
        }

        mx::NodeGraphPtr graph = parent->addChildOfCategory(mx::NodeGraph::CATEGORY,
                                                            parent->createValidChildName(nameHint.empty() ? "NG_group" : nameHint))
                                     ->asA<mx::NodeGraph>();
        float x = 0, y = 0;
        if (AveragePosition(elements, x, y)) {
            SetPosition(graph, x, y);
        }
        std::vector<mx::ElementPtr> moved;
        for (const mx::ElementPtr& element : elements) {
            const std::string name = element->getName();
            moved.push_back(CopyNode(element, graph, name));
            parent->removeChild(name);
        }
        parent->setChildIndex(graph->getName(), index);
        AddToBackdrops(framing, {graph->getName()});

        // Inbound: each input reading something outside reads one of the
        // graph's own inputs instead, one per thing read, which reads it.
        std::map<std::string, std::string> interfaceFor;
        for (const mx::ElementPtr& element : moved) {
            for (const mx::InputPtr& input : element->asA<mx::InterfaceElement>()->getInputs()) {
                std::string key;
                if (ReadsSibling(input) && !selected.count(SiblingName(input))) {
                    key = "node:" + SiblingName(input) + "." + input->getOutputString();
                } else if (input->hasInterfaceName()) {
                    key = "interface:" + input->getInterfaceName();
                } else {
                    continue;
                }
                auto found = interfaceFor.find(key);
                if (found == interfaceFor.end()) {
                    mx::InputPtr interface = graph->addInput(graph->createValidChildName(input->getName()), input->getType());
                    CopyConnection(input, interface);
                    found = interfaceFor.emplace(key, interface->getName()).first;
                }
                ClearConnection(input);
                input->setInterfaceName(found->second);
            }
        }

        // Outbound: each output of the selection read outside becomes an
        // output of the graph, which the readers read instead.
        std::map<std::string, std::string> outputFor;
        for (const mx::PortElementPtr& port : outbound) {
            outputFor.emplace(SiblingName(port) + "." + port->getOutputString(), "");
        }
        for (const mx::PortElementPtr& port : outbound) {
            std::string& outputName = outputFor[SiblingName(port) + "." + port->getOutputString()];
            if (outputName.empty()) {
                const std::string source = SiblingName(port);
                const std::string sourceOutput = port->getOutputString();
                const std::string hint = outputFor.size() == 1 ? std::string("out")
                                                               : source + "_" + (sourceOutput.empty() ? "out" : sourceOutput);
                mx::OutputPtr output = graph->addOutput(graph->createValidChildName(hint),
                                                        SourceOutputType(graph->getChild(source), sourceOutput));
                CopyConnection(port, output);
                outputName = output->getName();
            }
            ClearConnection(port);
            port->setNodeGraphString(graph->getName());
            port->setOutputString(outputName);
        }
        newPath = graph->getNamePath();
    });
}

namespace {

/// Ungroups `graph` (see Document::ungroupNodeGraph), which must not
/// implement a nodedef, and sets `newPaths` to the paths of its nodes.
void Ungroup(const mx::NodeGraphPtr& graph, StringVector& newPaths) {
    mx::GraphElementPtr parent = graph->getParent()->asA<mx::GraphElement>();
    const int index = parent->getChildIndex(graph->getName());
    // Outside ports reading the graph, before it is renamed.
    std::vector<mx::PortElementPtr> outbound;
    for (const mx::PortElementPtr& port : SiblingPorts(parent)) {
        if (port->getNodeGraphString() == graph->getName()) {
            outbound.push_back(port);
        }
    }
    // Out of the way, so the nodes inside can take its name.
    graph->setName(parent->createValidChildName("margolaria_ungrouped"));

    std::vector<mx::ElementPtr> inner;
    for (const mx::ElementPtr& child : graph->getChildren()) {
        if (child->isA<mx::Node>() || child->isA<mx::NodeGraph>()) {
            inner.push_back(child);
        }
    }
    // Back where the graph is: offset by how far the graph was moved
    // since its nodes were last placed around it.
    float offsetX = 0, offsetY = 0, innerX = 0, innerY = 0;
    if (graph->hasAttribute(mx::Element::XPOS_ATTRIBUTE) && AveragePosition(inner, innerX, innerY)) {
        offsetX = std::stof(graph->getAttribute(mx::Element::XPOS_ATTRIBUTE)) - innerX;
        offsetY = std::stof(graph->getAttribute(mx::Element::YPOS_ATTRIBUTE)) - innerY;
    }
    const bool offset = std::abs(offsetX) >= 0.001f || std::abs(offsetY) >= 0.001f;

    std::map<std::string, std::string> names;
    std::vector<mx::ElementPtr> moved;
    for (const mx::ElementPtr& element : inner) {
        mx::ElementPtr copy = CopyNode(element, parent, parent->createValidChildName(element->getName()));
        names[element->getName()] = copy->getName();
        if (offset && copy->hasAttribute(mx::Element::XPOS_ATTRIBUTE) && copy->hasAttribute(mx::Element::YPOS_ATTRIBUTE)) {
            SetPosition(copy, std::stof(copy->getAttribute(mx::Element::XPOS_ATTRIBUTE)) + offsetX,
                        std::stof(copy->getAttribute(mx::Element::YPOS_ATTRIBUTE)) + offsetY);
        }
        moved.push_back(copy);
    }
    RenameReferences(moved, names);
    // What the graph gave its nodes: its working space and file prefix.
    KeepColorSpace(moved, graph->getActiveColorSpace(), parent->getActiveColorSpace());
    if (graph->hasFilePrefix()) {
        for (const mx::ElementPtr& element : moved) {
            if (!element->hasFilePrefix()) {
                element->setFilePrefix(graph->getActiveFilePrefix());
            }
        }
    }

    // Inputs reading the graph's inputs read what those read, or take
    // their values.
    for (const mx::ElementPtr& element : moved) {
        for (const mx::InputPtr& input : element->asA<mx::InterfaceElement>()->getInputs()) {
            if (!input->hasInterfaceName()) {
                continue;
            }
            mx::InputPtr interface = graph->getInput(input->getInterfaceName());
            if (interface && (ReadsSibling(interface) || interface->hasInterfaceName())) {
                CopyConnection(interface, input);
            } else if (interface && interface->hasValueString()) {
                ClearConnection(input);
                input->setValueString(interface->getValueString());
                if (interface->hasColorSpace() && !input->hasColorSpace()) {
                    input->setColorSpace(interface->getColorSpace());
                }
            } else {
                Disconnect(input);
            }
        }
    }

    // Ports reading the graph's outputs read what those read.
    const std::vector<mx::OutputPtr> outputs = graph->getOutputs();
    for (const mx::PortElementPtr& port : outbound) {
        mx::OutputPtr output = port->getOutputString().empty() ? (outputs.size() == 1 ? outputs.front() : nullptr)
                                                               : graph->getOutput(port->getOutputString());
        if (output && ReadsSibling(output)) {
            CopyConnection(output, port);
            const std::string source = names.count(SiblingName(output)) ? names[SiblingName(output)] : SiblingName(output);
            if (!port->getNodeName().empty()) {
                port->setNodeName(source);
            } else {
                port->setNodeGraphString(source);
            }
        } else if (output && output->hasValueString()) {
            ClearConnection(port);
            port->setValueString(output->getValueString());
        } else {
            Disconnect(port);
        }
    }

    parent->removeChild(graph->getName());
    newPaths.clear();
    for (size_t i = 0; i < moved.size(); ++i) {
        parent->setChildIndex(moved[i]->getName(), index + static_cast<int>(i));
        newPaths.push_back(moved[i]->getNamePath());
    }
}

/// The types of shader and material nodes.
bool IsShaderType(const std::string& type) {
    return type == mx::SURFACE_SHADER_TYPE_STRING || type == mx::DISPLACEMENT_SHADER_TYPE_STRING ||
           type == mx::VOLUME_SHADER_TYPE_STRING || type == mx::LIGHT_SHADER_TYPE_STRING ||
           type == mx::MATERIAL_TYPE_STRING;
}

/// True if Storm (UsdMtlx, OpenUSD 26.08) would draw `graph` wrong
/// (PLAN.md §8.2): when one of its inputs reads a node or nodegraph, when
/// a node that isn't a shader or material reads one of its outputs, or
/// when it holds a shader node. MaterialX's own examples only use
/// nodegraphs whose inputs are values and whose outputs shaders read.
bool StormMisreads(const mx::NodeGraphPtr& graph) {
    if (graph->hasNodeDefString()) {
        return false;
    }
    for (const mx::InputPtr& input : graph->getInputs()) {
        if (ReadsSibling(input)) {
            return true;
        }
    }
    for (const mx::NodePtr& node : graph->getNodes()) {
        if (IsShaderType(node->getType())) {
            return true;
        }
    }
    for (const mx::PortElementPtr& port : SiblingPorts(graph->getParent())) {
        mx::NodePtr reader = port->getParent()->asA<mx::Node>();
        if (port->getNodeGraphString() == graph->getName() && reader && !IsShaderType(reader->getType())) {
            return true;
        }
    }
    return false;
}

std::vector<mx::NodePtr> InstancesOf(const mx::DocumentPtr& document, const mx::NodeDefPtr& nodeDef);

/// True if `graph` or anything in it reads a file.
bool ReadsFiles(const mx::ElementPtr& graph) {
    for (const mx::ElementPtr& element : graph->traverseTree()) {
        mx::InputPtr input = element->asA<mx::Input>();
        if (input && input->getType() == mx::FILENAME_TYPE_STRING) {
            return true;
        }
    }
    return false;
}

/// Replaces `node`, an instance of a nodedef implemented by `implementation`
/// (a nodegraph), with the implementation's nodes, set and connected as
/// the node was: a copy of the graph takes the node's place and name, with
/// the nodedef's inputs given the node's values or connections (or the
/// defaults), and is ungrouped.
void ExpandInstance(const mx::NodePtr& node, const mx::NodeGraphPtr& implementation, const mx::NodeDefPtr& nodeDef) {
    mx::GraphElementPtr parent = node->getParent()->asA<mx::GraphElement>();
    const std::string name = node->getName();
    node->setName(parent->createValidChildName("margolaria_expanded"));
    mx::NodeGraphPtr graph = parent->addChildOfCategory(mx::NodeGraph::CATEGORY, name)->asA<mx::NodeGraph>();
    graph->copyContentFrom(implementation);
    graph->removeAttribute(mx::InterfaceElement::NODE_DEF_ATTRIBUTE);
    for (const std::string& attribute : {mx::Element::XPOS_ATTRIBUTE, mx::Element::YPOS_ATTRIBUTE}) {
        graph->removeAttribute(attribute);
        if (node->hasAttribute(attribute)) {
            graph->setAttribute(attribute, node->getAttribute(attribute));
        }
    }
    if (node->hasColorSpace()) {
        graph->setColorSpace(node->getColorSpace());
    }
    for (const mx::InputPtr& definition : nodeDef->getActiveInputs()) {
        mx::InputPtr input = graph->addInput(definition->getName(), definition->getType());
        mx::InputPtr set = node->getInput(definition->getName());
        input->copyContentFrom(set ? set : definition);
    }
    // What read the node reads the graph's output of the same name.
    const std::vector<mx::OutputPtr> outputs = graph->getOutputs();
    for (const mx::PortElementPtr& port : SiblingPorts(parent)) {
        if (port->getNodeName() != name) {
            continue;
        }
        const std::string output = port->getOutputString();
        ClearConnection(port);
        port->setNodeGraphString(name);
        port->setOutputString(output.empty() && !outputs.empty() ? outputs.front()->getName() : output);
    }
    parent->removeChild(node->getName());
    StringVector paths;
    Ungroup(graph, paths);
}

/// Expands, in a copy of a document, the nodes of the definitions the
/// document makes and implements with a nodegraph: every one with
/// `every`, otherwise those whose implementation reads a file (what Storm
/// needs, see UngroupForStorm). Returns the definitions expanded, with
/// their implementations, which are left in place.
///
/// One pass is enough when definitions use each other: once a definition
/// is done, no node of it is left anywhere, implementations included, so
/// the implementations copied afterwards have none either.
std::vector<std::pair<mx::NodeDefPtr, mx::NodeGraphPtr>> ExpandDefinitions(const mx::DocumentPtr& preview, bool every) {
    std::vector<std::pair<mx::NodeDefPtr, mx::NodeGraphPtr>> expanded;
    // Over a copy of the children: getChildren() is the document's own
    // list, which this changes.
    const std::vector<mx::ElementPtr> children = preview->getChildren();
    for (const mx::ElementPtr& child : children) {
        mx::NodeGraphPtr implementation = child->asA<mx::NodeGraph>();
        mx::NodeDefPtr nodeDef = implementation && implementation->hasNodeDefString() ? implementation->getNodeDef()
                                                                                       : nullptr;
        if (!nodeDef || nodeDef->getDocument() != preview || !(every || ReadsFiles(implementation))) {
            continue;
        }
        for (const mx::NodePtr& instance : InstancesOf(preview, nodeDef)) {
            ExpandInstance(instance, implementation, nodeDef);
        }
        expanded.emplace_back(nodeDef, implementation);
    }
    return expanded;
}

/// Ungroups, in a preview copy, the nodegraphs Storm would draw wrong
/// (see StormMisreads), until none is left. Ungrouping keeps what the
/// document computes (MXNodeGraphEditTests, CollapseRenderTests), so this
/// is the same material in a shape Storm reads.
///
/// With `expandEveryDefinition` (USD export, M5b), every node whose
/// definition the document makes is expanded, not only those Storm needs,
/// and the definitions are then removed: a USD file has no use for them,
/// and UsdMtlx would record the `.mtlx` as where the nodes are defined,
/// a file the exported USD would depend on (spike M5a).
void UngroupForStorm(const mx::DocumentPtr& preview, bool expandEveryDefinition) {
    // Storm can't draw a node whose nodedef, defined in the document, is
    // implemented by a nodegraph reading a file (M4c1, PLAN.md §8.2): the
    // texture's uniform is left out of the shader, which doesn't compile.
    // Such nodes become the implementation's nodes.
    const auto expanded = ExpandDefinitions(preview, expandEveryDefinition);
    if (expandEveryDefinition) {
        for (const auto& [nodeDef, implementation] : expanded) {
            implementation->getParent()->removeChild(implementation->getName());
            nodeDef->getParent()->removeChild(nodeDef->getName());
        }
    }
    for (bool changed = true; changed;) {
        changed = false;
        // The document's own children: getNodeGraphs() would also list the
        // data library's, which every document shares and which must never
        // change.
        for (const mx::ElementPtr& child : preview->getChildren()) {
            mx::NodeGraphPtr graph = child->asA<mx::NodeGraph>();
            if (graph && StormMisreads(graph)) {
                StringVector paths;
                Ungroup(graph, paths);
                changed = true;
                break;
            }
        }
    }
}

} // namespace

bool Document::ungroupNodeGraph(const std::string& path, StringVector& newPaths, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::NodeGraphPtr graph = EditableElement(document, path)->asA<mx::NodeGraph>();
        if (!graph) {
            throw Refusal(path + " is not a nodegraph");
        }
        if (graph->hasNodeDefString()) {
            throw Refusal(graph->getName() + " implements " + graph->getNodeDefString() +
                          ": ungrouping it would leave the definition without an implementation");
        }
        // The backdrops that framed the graph frame its nodes.
        const std::vector<mx::BackdropPtr> framing = BackdropsContaining(graph->getParent(), {graph->getName()});
        Ungroup(graph, newPaths);
        std::vector<std::string> names;
        for (const std::string& newPath : newPaths) {
            names.push_back(newPath.substr(newPath.rfind('/') + 1));
        }
        AddToBackdrops(framing, names);
    });
}

bool Document::addNodeGraph(const std::string& parentPath, const std::string& nameHint, std::string& newPath,
                            std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::GraphElementPtr parent = EditableGraph(document, parentPath);
        RequireTopLevel(parent);
        const std::string name = parent->createValidChildName(nameHint.empty() ? "NG_graph" : nameHint);
        newPath = parent->addChildOfCategory(mx::NodeGraph::CATEGORY, name)->getNamePath();
    });
}

bool Document::addGraphOutput(const std::string& graphPath, const std::string& nameHint, const std::string& type,
                              std::string& newName, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::NodeGraphPtr graph = GraphWithOwnOutputs(document, graphPath);
        static const std::set<std::string> standardTypes = {
            "float", "integer", "boolean", "color3", "color4", "vector2", "vector3", "vector4",
            "matrix33", "matrix44", "string", "filename", "BSDF", "EDF", "VDF",
            "surfaceshader", "displacementshader", "volumeshader", "lightshader"};
        if (!standardTypes.count(type) && !document->getTypeDef(type)) {
            throw Refusal(type + " is not a MaterialX type");
        }
        // With a second output, readers of the first must say which they read.
        if (graph->getOutputs().size() == 1) {
            const std::string first = graph->getOutputs().front()->getName();
            for (const mx::PortElementPtr& port : PortsReading(graph, first)) {
                port->setOutputString(first);
            }
        }
        newName = graph->addOutput(graph->createValidChildName(nameHint.empty() ? "out" : nameHint), type)->getName();
    });
}

bool Document::renameGraphOutput(const std::string& graphPath, const std::string& outputName,
                                 const std::string& newName, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::NodeGraphPtr graph = GraphWithOwnOutputs(document, graphPath);
        mx::OutputPtr output = graph->getOutput(outputName);
        if (!output) {
            throw Refusal(graph->getName() + " has no output " + outputName);
        }
        if (newName == outputName) {
            return;
        }
        if (newName.empty() || mx::createValidName(newName) != newName) {
            throw Refusal("\"" + newName + "\" is not a valid MaterialX name (letters, digits and _ only)");
        }
        if (graph->getChild(newName)) {
            throw Refusal("There is already a " + newName + " in " + graph->getName());
        }
        for (const mx::PortElementPtr& port : PortsReading(graph, outputName)) {
            if (!port->getOutputString().empty()) {
                port->setOutputString(newName);
            }
        }
        output->setName(newName);
        RenameInBackdrops(graph, outputName, newName);
    });
}

bool Document::removeGraphOutput(const std::string& graphPath, const std::string& outputName, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::NodeGraphPtr graph = GraphWithOwnOutputs(document, graphPath);
        if (!graph->getOutput(outputName)) {
            throw Refusal(graph->getName() + " has no output " + outputName);
        }
        for (const mx::PortElementPtr& port : PortsReading(graph, outputName)) {
            Disconnect(port);
        }
        graph->removeOutput(outputName);
    });
}

// --- A nodegraph's interface (M4b) ------------------------------------------

namespace {

/// The metadata of an interface input that the inspector edits, and that
/// promoting copies from the node's input or its nodedef.
const std::vector<std::string>& InterfaceMetadata() {
    static const std::vector<std::string> names = {
        "uiname", "uifolder", "uimin", "uimax", "uisoftmin", "uisoftmax", "uistep",
        "enum", "enumvalues", "doc", "uiadvanced", "unit", "unittype", "defaultgeomprop"};
    return names;
}

/// True for metadata whose value is a value of the input's type.
bool IsValueMetadata(const std::string& name) {
    return name == "uimin" || name == "uimax" || name == "uisoftmin" || name == "uisoftmax" || name == "uistep";
}

/// The nodegraph at `path`, and the element that holds its inputs: the
/// graph itself, or the nodedef it implements when that is defined in
/// this document (M4c1). Refused for a graph implementing a nodedef from
/// the libraries or an included file.
struct GraphInterface {
    mx::NodeGraphPtr graph;
    mx::InterfaceElementPtr owner;
    /// The local nodedef, or null.
    mx::NodeDefPtr nodeDef;
};

GraphInterface InterfaceOf(const mx::DocumentPtr& document, const std::string& path) {
    mx::NodeGraphPtr graph = path.empty() ? nullptr : EditableElement(document, path)->asA<mx::NodeGraph>();
    if (!graph) {
        throw Refusal("Only nodegraphs have inputs of their own");
    }
    if (mx::NodeDefPtr nodeDef = LocalNodeDef(graph)) {
        return {graph, nodeDef, nodeDef};
    }
    if (graph->hasNodeDefString()) {
        throw Refusal("The inputs of " + graph->getName() + " are defined by " + graph->getNodeDefString() +
                      ", in the libraries or an included file");
    }
    return {graph, graph, nullptr};
}

/// The nodes of `document` that are instances of `nodeDef`.
std::vector<mx::NodePtr> InstancesOf(const mx::DocumentPtr& document, const mx::NodeDefPtr& nodeDef) {
    std::vector<mx::NodePtr> nodes;
    for (const mx::ElementPtr& element : document->traverseTree()) {
        mx::NodePtr node = element->asA<mx::Node>();
        if (node && node->getCategory() == nodeDef->getNodeString() && node->getNodeDef() == nodeDef) {
            nodes.push_back(node);
        }
    }
    return nodes;
}

/// A value of `type` to start a new input with: zero, false, an identity
/// matrix, or "" for strings and files. Throws for types an input can't have.
std::string StartingValue(const std::string& type) {
    static const std::map<std::string, std::string> values = {
        {"float", "0"}, {"integer", "0"}, {"boolean", "false"},
        {"color3", "0, 0, 0"}, {"color4", "0, 0, 0, 1"},
        {"vector2", "0, 0"}, {"vector3", "0, 0, 0"}, {"vector4", "0, 0, 0, 0"},
        {"matrix33", "1, 0, 0, 0, 1, 0, 0, 0, 1"},
        {"matrix44", "1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1"},
        {"string", ""}, {"filename", ""}};
    auto found = values.find(type);
    if (found == values.end()) {
        throw Refusal("A nodegraph's input can't be a " + type);
    }
    return found->second;
}

/// Checks that `name` can be a new name for a child of `graph`.
void RequireNewName(const mx::ElementPtr& graph, const std::string& name) {
    if (name.empty() || mx::createValidName(name) != name) {
        throw Refusal("\"" + name + "\" is not a valid MaterialX name (letters, digits and _ only)");
    }
    if (graph->getChild(name)) {
        throw Refusal("There is already a " + name + " in " + graph->getName());
    }
}

/// The inputs of the nodes in `graph` that read its input `name`.
std::vector<mx::InputPtr> InputsReading(const mx::NodeGraphPtr& graph, const std::string& name);

/// A name for a new input of `target`, from `hint`: unique among the
/// owner's children, and the graph's when the owner is its nodedef (so
/// the canvas's node for it doesn't share a name with a node).
std::string UniqueInterfaceName(const GraphInterface& target, const std::string& hint) {
    std::string name = target.owner->createValidChildName(hint);
    for (int i = 2; target.nodeDef && (target.graph->getChild(name) || target.owner->getChild(name)); ++i) {
        name = mx::createValidName(hint) + std::to_string(i);
    }
    return name;
}

std::vector<mx::InputPtr> InputsReading(const mx::NodeGraphPtr& graph, const std::string& name) {
    std::vector<mx::InputPtr> inputs;
    for (const mx::NodePtr& node : graph->getNodes()) {
        for (const mx::InputPtr& input : node->getInputs()) {
            if (input->getInterfaceName() == name) {
                inputs.push_back(input);
            }
        }
    }
    return inputs;
}

} // namespace

bool Document::promoteInput(const std::string& elementPath, const std::string& inputName, const std::string& nameHint,
                            std::string& newName, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::NodePtr node = EditableElement(document, elementPath)->asA<mx::Node>();
        if (!node) {
            throw Refusal("Only a node's inputs can become its nodegraph's");
        }
        mx::NodeGraphPtr parent = node->getParent()->asA<mx::NodeGraph>();
        if (!parent) {
            throw Refusal(node->getName() + " isn't in a nodegraph");
        }
        GraphInterface target = InterfaceOf(document, parent->getNamePath());
        mx::NodeGraphPtr graph = target.graph;
        mx::NodeDefPtr nodeDef = node->getNodeDef();
        mx::InputPtr definition = nodeDef ? nodeDef->getActiveInput(inputName) : nullptr;
        mx::InputPtr input = node->getInput(inputName);
        if (!input && !definition) {
            throw Refusal(node->getName() + " has no input " + inputName);
        }
        if (input && (ReadsSibling(input) || input->hasInterfaceName())) {
            throw Refusal(inputName + " is connected: only an input with a value can become the graph's");
        }
        const std::string type = input ? input->getType() : definition->getType();

        mx::InputPtr interface = target.owner->addInput(UniqueInterfaceName(target, nameHint.empty() ? inputName : nameHint),
                                                        type);
        // Its value: the input's own, or the nodedef's default.
        if (input && input->hasValueString()) {
            interface->setValueString(input->getValueString());
        } else if (definition && definition->hasValueString()) {
            interface->setValueString(definition->getValueString());
        }
        // The space the value is in, if the graph's differs.
        std::string colorSpace;
        if (input && input->hasColorSpace()) {
            colorSpace = input->getColorSpace();
        } else if (node->hasColorSpace()) {
            colorSpace = node->getColorSpace();
        } else if (definition && definition->hasColorSpace()) {
            colorSpace = definition->getColorSpace();
        }
        if (!colorSpace.empty() && SpaceName(colorSpace) != SpaceName(graph->getActiveColorSpace())) {
            interface->setColorSpace(colorSpace);
        }
        // How the inspector shows it: the input's metadata, else the nodedef's.
        for (const std::string& name : InterfaceMetadata()) {
            if (input && input->hasAttribute(name)) {
                interface->setAttribute(name, input->getAttribute(name));
            } else if (definition && definition->hasAttribute(name)) {
                interface->setAttribute(name, definition->getAttribute(name));
            }
        }
        if ((input && IsUniform(input)) || (definition && definition->getIsUniform())) {
            interface->setIsUniform(true);
        }

        if (!input) {
            input = node->addInputFromNodeDef(inputName);
        }
        ClearConnection(input);
        input->removeAttribute(mx::ValueElement::VALUE_ATTRIBUTE);
        input->removeAttribute(mx::Element::COLOR_SPACE_ATTRIBUTE);
        input->setInterfaceName(interface->getName());
        newName = interface->getName();
    });
}

bool Document::addGraphInput(const std::string& graphPath, const std::string& nameHint, const std::string& type,
                             std::string& newName, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        GraphInterface target = InterfaceOf(document, graphPath);
        const std::string value = StartingValue(type);
        mx::InputPtr input = target.owner->addInput(UniqueInterfaceName(target, nameHint.empty() ? "in" : nameHint), type);
        if (!value.empty()) {
            input->setValueString(value);
        }
        newName = input->getName();
    });
}

bool Document::renameGraphInput(const std::string& graphPath, const std::string& inputName, const std::string& newName,
                                std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        GraphInterface target = InterfaceOf(document, graphPath);
        mx::InputPtr input = target.owner->getInput(inputName);
        if (!input) {
            throw Refusal(target.graph->getName() + " has no input " + inputName);
        }
        if (newName == inputName) {
            return;
        }
        RequireNewName(target.owner, newName);
        if (target.nodeDef) {
            RequireNewName(target.graph, newName);
        }
        for (const mx::InputPtr& reader : InputsReading(target.graph, inputName)) {
            reader->setInterfaceName(newName);
        }
        // A graph's: what is connected to it from outside is written on the
        // input itself, so nothing outside changes. A nodedef's: its
        // instances set the input by name.
        if (target.nodeDef) {
            for (const mx::NodePtr& instance : InstancesOf(document, target.nodeDef)) {
                if (mx::InputPtr set = instance->getInput(inputName)) {
                    set->setName(newName);
                }
            }
        }
        input->setName(newName);
        RenameInBackdrops(target.graph, inputName, newName);
    });
}

bool Document::removeGraphInput(const std::string& graphPath, const std::string& inputName, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        GraphInterface target = InterfaceOf(document, graphPath);
        mx::InputPtr input = target.owner->getInput(inputName);
        if (!input) {
            throw Refusal(target.graph->getName() + " has no input " + inputName);
        }
        // The nodes that read it keep its value, as ungrouping does.
        for (const mx::InputPtr& reader : InputsReading(target.graph, inputName)) {
            if (input->hasValueString()) {
                ClearConnection(reader);
                reader->setValueString(input->getValueString());
                if (input->hasColorSpace() && !reader->hasColorSpace()) {
                    reader->setColorSpace(input->getColorSpace());
                }
            } else {
                Disconnect(reader);
            }
        }
        // Instances of a nodedef lose what they set it to.
        if (target.nodeDef) {
            for (const mx::NodePtr& instance : InstancesOf(document, target.nodeDef)) {
                instance->removeInput(inputName);
            }
        }
        target.owner->removeInput(inputName);
    });
}

bool Document::setInputMetadata(const std::string& graphPath, const std::string& inputName, const std::string& attribute,
                                const std::string& value, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        GraphInterface target = InterfaceOf(document, graphPath);
        mx::InputPtr input = target.owner->getInput(inputName);
        if (!input) {
            throw Refusal(target.graph->getName() + " has no input " + inputName);
        }
        const std::vector<std::string>& names = InterfaceMetadata();
        if (std::find(names.begin(), names.end(), attribute) == names.end()) {
            throw Refusal(attribute + " is not metadata the inspector edits");
        }
        if (value.empty()) {
            input->removeAttribute(attribute);
            if (attribute == "enum") {
                input->removeAttribute("enumvalues");
            }
            return;
        }
        if (IsValueMetadata(attribute) && !mx::Value::createValueFromStrings(value, input->getType())) {
            throw Refusal("\"" + value + "\" is not a valid " + input->getType());
        }
        input->setAttribute(attribute, value);
    });
}

// --- Node definitions (M4c1) --------------------------------------------------

bool Document::makeNodeDefinition(const std::string& graphPath, const NodeDefSpec& spec, std::string& nodeDefName,
                                  std::string& instancePath, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::NodeGraphPtr graph = EditableElement(document, graphPath)->asA<mx::NodeGraph>();
        if (!graph || !graph->getParent()->isA<mx::Document>()) {
            throw Refusal("Only a nodegraph at the top level of the document can become a node definition");
        }
        if (graph->hasNodeDefString()) {
            throw Refusal(graph->getName() + " already implements " + graph->getNodeDefString());
        }
        const std::vector<mx::OutputPtr> outputs = graph->getOutputs();
        if (outputs.empty()) {
            throw Refusal(graph->getName() + " has no outputs: a node made from it would give nothing");
        }
        for (const std::string& name : {spec.node, spec.name}) {
            if (name.empty() || mx::createValidName(name) != name) {
                throw Refusal("\"" + name + "\" is not a valid MaterialX name (letters, digits and _ only)");
            }
        }
        if (document->getChild(spec.name) || (document->getDataLibrary() && document->getDataLibrary()->getNodeDef(spec.name))) {
            throw Refusal("There is already a " + spec.name);
        }
        // A standard node's name would make nodes of it ambiguous.
        if (mx::ConstDocumentPtr library = document->getDataLibrary()) {
            if (!library->getMatchingNodeDefs(spec.node).empty()) {
                throw Refusal(spec.node + " is a standard MaterialX node; choose another name");
            }
        }
        for (const mx::NodeDefPtr& existing : document->getMatchingNodeDefs(spec.node)) {
            if (existing->getDocument() == document && existing->getActiveOutputs().size() == outputs.size()) {
                // Variants of one node must differ in their types; MaterialX
                // matches nodes to nodedefs by them.
                bool same = true;
                for (size_t i = 0; i < outputs.size(); ++i) {
                    same = same && existing->getActiveOutputs()[i]->getType() == outputs[i]->getType();
                }
                if (same) {
                    throw Refusal(existing->getName() + " already defines " + spec.node + " with these outputs");
                }
            }
        }

        // The nodedef: the graph's inputs and outputs, its values as defaults.
        mx::NodeDefPtr nodeDef = document->addNodeDef(spec.name, "", spec.node);
        if (!spec.nodeGroup.empty()) {
            nodeDef->setNodeGroup(spec.nodeGroup);
        }
        if (!spec.version.empty()) {
            nodeDef->setVersionString(spec.version);
            nodeDef->setDefaultVersion(true);
        }
        if (!spec.doc.empty()) {
            nodeDef->setDocString(spec.doc);
        } else if (!graph->getDocString().empty()) {
            nodeDef->setDocString(graph->getDocString());
        }
        for (const mx::InputPtr& input : graph->getInputs()) {
            mx::InputPtr definition = nodeDef->addInput(input->getName(), input->getType());
            definition->copyContentFrom(input);
            // Connections and positions belong to the graph's use, not its
            // definition.
            ClearConnection(definition);
            definition->removeAttribute(mx::Element::XPOS_ATTRIBUTE);
            definition->removeAttribute(mx::Element::YPOS_ATTRIBUTE);
        }
        for (const mx::OutputPtr& output : outputs) {
            nodeDef->addOutput(output->getName(), output->getType());
        }
        // Before the graph, as MaterialX's libraries write them.
        document->setChildIndex(nodeDef->getName(), document->getChildIndex(graph->getName()));

        // Uses of the graph become a node of the new kind, under the
        // graph's name, which the graph gives up.
        const std::string useName = graph->getName();
        std::vector<mx::PortElementPtr> readers;
        for (const mx::PortElementPtr& port : SiblingPorts(document)) {
            if (port->getNodeGraphString() == useName) {
                readers.push_back(port);
            }
        }
        // (getInputs() returns a new vector each time: one copy, for both ends.)
        const std::vector<mx::InputPtr> inputs = graph->getInputs();
        const bool used = !readers.empty() ||
            std::any_of(inputs.begin(), inputs.end(), [](const mx::InputPtr& input) { return ReadsSibling(input); });
        graph->setName(document->createValidChildName("NG_" + spec.node));
        instancePath.clear();
        if (used) {
            const std::string type = outputs.size() == 1 ? outputs.front()->getType() : mx::MULTI_OUTPUT_TYPE_STRING;
            mx::NodePtr instance = document->addNode(spec.node, useName, type);
            instance->setNodeDefString(nodeDef->getName());
            for (const std::string& attribute : {mx::Element::XPOS_ATTRIBUTE, mx::Element::YPOS_ATTRIBUTE,
                                                 mx::Element::COLOR_SPACE_ATTRIBUTE}) {
                if (graph->hasAttribute(attribute)) {
                    instance->setAttribute(attribute, graph->getAttribute(attribute));
                }
            }
            // What the graph's inputs read from outside, the node's read.
            for (const mx::InputPtr& input : graph->getInputs()) {
                if (ReadsSibling(input)) {
                    mx::InputPtr set = instance->addInput(input->getName(), input->getType());
                    CopyConnection(input, set);
                }
            }
            for (const mx::PortElementPtr& port : readers) {
                const std::string output = port->getOutputString();
                ClearConnection(port);
                port->setNodeName(useName);
                // MaterialX names the output only for a node with several.
                if (outputs.size() > 1) {
                    port->setOutputString(output.empty() ? outputs.front()->getName() : output);
                }
            }
            document->setChildIndex(useName, document->getChildIndex(graph->getName()) + 1);
            instancePath = instance->getNamePath();
        }

        // The graph implements the nodedef: its interface is the nodedef's.
        for (const mx::InputPtr& input : graph->getInputs()) {
            graph->removeInput(input->getName());
        }
        graph->removeAttribute(mx::Element::DOC_ATTRIBUTE);
        graph->setNodeDefString(nodeDef->getName());
        nodeDefName = nodeDef->getName();
    });
}

bool Document::removeNodeDefinition(const std::string& graphPath, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::NodeGraphPtr graph = EditableElement(document, graphPath)->asA<mx::NodeGraph>();
        mx::NodeDefPtr nodeDef = graph ? LocalNodeDef(graph) : nullptr;
        if (!nodeDef) {
            throw Refusal(graphPath + " doesn't implement a node definition in this document");
        }
        const size_t count = InstancesOf(document, nodeDef).size();
        if (count > 0) {
            throw Refusal(std::to_string(count) + (count == 1 ? " node uses " : " nodes use ") + nodeDef->getNodeString() +
                          ": delete " + (count == 1 ? "it" : "them") + " first");
        }
        document->removeChild(graph->getName());
        document->removeChild(nodeDef->getName());
    });
}

bool Document::setNodeDefAttribute(const std::string& graphPath, const std::string& attribute, const std::string& value,
                                   std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::NodeGraphPtr graph = EditableElement(document, graphPath)->asA<mx::NodeGraph>();
        mx::NodeDefPtr nodeDef = graph ? LocalNodeDef(graph) : nullptr;
        if (!nodeDef) {
            throw Refusal(graphPath + " doesn't implement a node definition in this document");
        }
        if (attribute != "nodegroup" && attribute != "doc" && attribute != "version") {
            throw Refusal(attribute + " is not a node definition attribute the inspector edits");
        }
        if (value.empty()) {
            nodeDef->removeAttribute(attribute);
            if (attribute == "version") {
                nodeDef->removeAttribute(mx::InterfaceElement::DEFAULT_VERSION_ATTRIBUTE);
            }
            return;
        }
        nodeDef->setAttribute(attribute, value);
        if (attribute == "version") {
            nodeDef->setDefaultVersion(true);
        }
    });
}

// --- Libraries (M4c2) ---------------------------------------------------------

bool Document::writeNodeDefinition(const std::string& graphPath, std::string& xml, std::string& errorMessage) const {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::ElementPtr element = document->getDescendant(graphPath);
        mx::NodeGraphPtr graph = element ? element->asA<mx::NodeGraph>() : nullptr;
        mx::NodeDefPtr nodeDef = graph ? LocalNodeDef(graph) : nullptr;
        if (!nodeDef) {
            throw Refusal(graphPath + " doesn't implement a node definition in this document");
        }
        // Nodes of other definitions made here would be missing from the file.
        for (const mx::ElementPtr& inner : graph->traverseTree()) {
            mx::NodePtr node = inner->asA<mx::Node>();
            mx::NodeDefPtr used = node ? node->getNodeDef() : nullptr;
            if (used && used != nodeDef && used->getDocument() == document) {
                throw Refusal(nodeDef->getNodeString() + " uses " + used->getNodeString() +
                              ", defined in this document: save that to a library first, and use it from there");
            }
        }
        mx::DocumentPtr library = mx::createDocument();
        // The space untagged colours are in, if not the default.
        if (!graph->getActiveColorSpace().empty()) {
            library->setColorSpace(graph->getActiveColorSpace());
        }
        for (const mx::ElementPtr& source : {mx::ElementPtr(nodeDef), mx::ElementPtr(graph)}) {
            mx::ElementPtr copy = library->addChildOfCategory(source->getCategory(), source->getName());
            copy->copyContentFrom(source);
            copy->removeAttribute(mx::Element::XPOS_ATTRIBUTE);
            copy->removeAttribute(mx::Element::YPOS_ATTRIBUTE);
            // Files by absolute path: the library may be anywhere.
            for (const mx::ElementPtr& descendant : copy->traverseTree()) {
                mx::ValueElementPtr value = descendant->asA<mx::ValueElement>();
                if (value && value->getType() == mx::FILENAME_TYPE_STRING && value->hasValueString()) {
                    mx::ElementPtr original = document->getDescendant(descendant->getNamePath());
                    if (mx::ValueElementPtr from = original ? original->asA<mx::ValueElement>() : nullptr) {
                        value->setValueString(AbsoluteFilename(from));
                    }
                }
            }
            for (const mx::ElementPtr& descendant : copy->traverseTree()) {
                descendant->removeAttribute(mx::Element::FILE_PREFIX_ATTRIBUTE);
            }
        }
        mx::XmlWriteOptions options;
        options.writeXIncludeEnable = false;
        xml = mx::writeToXmlString(library, &options);
    });
}

bool Document::includeLibrary(const std::string& filePath, const std::string& href, StringVector& nodeDefNames,
                              std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::DocumentPtr library = mx::createDocument();
        mx::FilePath path(filePath);
        const mx::XmlReadOptions options = ReadOptions();
        mx::readFromXmlFile(library, path, mx::FileSearchPath(path.getParentPath()), &options);

        // Already included (under this name, or found by the same path):
        // nothing to add. Another element with one of its names: refused.
        std::vector<mx::ElementPtr> added;
        nodeDefNames.clear();
        for (const mx::ElementPtr& child : library->getChildren()) {
            if (mx::ElementPtr existing = document->getChild(child->getName())) {
                if (IsIncluded(existing) && existing->getCategory() == child->getCategory()) {
                    if (child->isA<mx::NodeDef>()) {
                        nodeDefNames.push_back(child->getName());
                    }
                    continue;
                }
                throw Refusal("This document already has a " + child->getName() + ": rename it to use " +
                              path.getBaseName());
            }
        }
        for (const mx::ElementPtr& child : library->getChildren()) {
            if (document->getChild(child->getName())) {
                continue;
            }
            mx::ElementPtr copy = document->addChildOfCategory(child->getCategory(), child->getName());
            copy->copyContentFrom(child);
            // Written back as `<xi:include href="...">` when saving (M2a).
            copy->setSourceUri(href);
            for (const mx::ElementPtr& descendant : copy->traverseTree()) {
                if (descendant != copy) {
                    descendant->setSourceUri("");
                }
            }
            if (child->isA<mx::NodeDef>()) {
                nodeDefNames.push_back(child->getName());
            }
            added.push_back(copy);
        }
        // Included elements first, where MaterialX's own files put them.
        for (size_t i = 0; i < added.size(); ++i) {
            document->setChildIndex(added[i]->getName(), static_cast<int>(i));
        }
    });
}

bool Document::copyNodes(const std::string& parentPath, const StringVector& names, bool keepsInterface,
                         std::string& xml, std::string& errorMessage) const {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::ElementPtr scope = parentPath.empty() ? mx::ElementPtr(document) : document->getDescendant(parentPath);
        mx::GraphElementPtr parent = scope ? scope->asA<mx::GraphElement>() : nullptr;
        if (!parent) {
            throw Refusal("No nodegraph at " + parentPath);
        }
        std::set<std::string> selected(names.begin(), names.end());
        mx::DocumentPtr copy = mx::createDocument();
        if (mx::ConstDocumentPtr library = document->getDataLibrary()) {
            copy->setDataLibrary(library);
        }
        // The space their colours are in, so pasting can keep them.
        if (!parent->getActiveColorSpace().empty()) {
            copy->setColorSpace(parent->getActiveColorSpace());
        }
        std::vector<mx::ElementPtr> copied;
        for (const mx::ElementPtr& child : parent->getChildren()) {
            if (!selected.count(child->getName())) {
                continue;
            }
            if (!(child->isA<mx::Node>() || child->isA<mx::NodeGraph>())) {
                throw Refusal("No node or nodegraph " + child->getName());
            }
            copied.push_back(CopyNode(child, copy, child->getName()));
        }
        if (copied.empty()) {
            throw Refusal("Nothing to copy");
        }
        for (const mx::ElementPtr& element : copied) {
            // Files by absolute path, so they are found wherever the copy goes.
            for (const mx::ElementPtr& descendant : element->traverseTree()) {
                mx::ValueElementPtr value = descendant->asA<mx::ValueElement>();
                if (value && value->getType() == mx::FILENAME_TYPE_STRING && value->hasValueString()) {
                    mx::ElementPtr original = parent->getDescendant(descendant->getNamePath(copy));
                    if (mx::ValueElementPtr source = original ? original->asA<mx::ValueElement>() : nullptr) {
                        value->setValueString(AbsoluteFilename(source));
                    }
                }
            }
            for (const mx::ElementPtr& descendant : element->traverseTree()) {
                descendant->removeAttribute(mx::Element::FILE_PREFIX_ATTRIBUTE);
            }
            // Connections to what stays behind are dropped.
            for (const mx::InputPtr& input : element->asA<mx::InterfaceElement>()->getInputs()) {
                const bool toSelection = ReadsSibling(input) && selected.count(SiblingName(input));
                const bool toInterface = keepsInterface && input->hasInterfaceName();
                if ((ReadsSibling(input) || input->hasInterfaceName()) && !toSelection && !toInterface) {
                    Disconnect(input);
                }
            }
        }
        mx::XmlWriteOptions options;
        options.writeXIncludeEnable = false;
        xml = mx::writeToXmlString(copy, &options);
    });
}

bool Document::pasteNodes(const std::string& parentPath, const std::string& xml, StringVector& newPaths,
                          std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::GraphElementPtr parent = EditableGraph(document, parentPath);
        mx::DocumentPtr pasted = mx::createDocument();
        mx::readFromXmlString(pasted, xml, mx::FileSearchPath(), nullptr);

        std::vector<mx::ElementPtr> sources;
        for (const mx::ElementPtr& child : pasted->getChildren()) {
            if (child->isA<mx::Node>() || child->isA<mx::NodeGraph>()) {
                if (IsMaterial(child) && !parent->isA<mx::Document>()) {
                    throw Refusal(child->getName() + " is a material: materials go at the top level of the document");
                }
                if (child->isA<mx::NodeGraph>()) {
                    RequireTopLevel(parent);
                }
                sources.push_back(child);
            }
        }
        if (sources.empty()) {
            throw Refusal("There are no MaterialX nodes to paste");
        }
        std::map<std::string, std::string> names;
        std::vector<mx::ElementPtr> added;
        for (const mx::ElementPtr& source : sources) {
            mx::ElementPtr copy = CopyNode(source, parent, parent->createValidChildName(source->getName()));
            // Not from any file of this document's: as if typed in.
            copy->setSourceUri(document->getSourceUri());
            names[source->getName()] = copy->getName();
            added.push_back(copy);
        }
        RenameReferences(added, names);
        KeepColorSpace(added, pasted->getColorSpace(), parent->getActiveColorSpace());

        // Connections that mean nothing here: to nodes that weren't pasted,
        // or to graph inputs this graph doesn't have.
        mx::NodeGraphPtr graph = parent->asA<mx::NodeGraph>();
        std::set<std::string> newNames;
        for (const auto& [oldName, newName] : names) {
            newNames.insert(newName);
        }
        for (const mx::ElementPtr& element : added) {
            for (const mx::InputPtr& input : element->asA<mx::InterfaceElement>()->getInputs()) {
                bool dangling = false;
                if (ReadsSibling(input)) {
                    // References to pasted nodes have their new names by now.
                    dangling = !newNames.count(SiblingName(input));
                } else if (input->hasInterfaceName()) {
                    mx::InputPtr interface = graph ? graph->getInput(input->getInterfaceName()) : nullptr;
                    if (!interface && graph && graph->getNodeDef()) {
                        interface = graph->getNodeDef()->getActiveInput(input->getInterfaceName());
                    }
                    dangling = !interface || interface->getType() != input->getType();
                }
                if (dangling) {
                    Disconnect(input);
                }
            }
        }
        newPaths.clear();
        for (const mx::ElementPtr& element : added) {
            newPaths.push_back(element->getNamePath());
        }
    });
}

std::string Document::documentVersion() const {
    return _impl ? _impl->document->getVersionString() : std::string();
}

namespace {

/// Adds the colours of `owner`'s inputs that have no `colorspace`: colour
/// values, and the file of an image node with a colour output.
void AddColorUses(const mx::InterfaceElementPtr& owner, std::vector<ColorUse>& uses) {
    const std::string ownerType = owner->getType();
    const bool colorImage = owner->isA<mx::Node>() && (ownerType == "color3" || ownerType == "color4");
    for (const mx::InputPtr& input : owner->getInputs()) {
        if (input->hasColorSpace() || !input->hasValueString() || input->getValueString().empty()) {
            continue;
        }
        const std::string type = input->getType();
        if (type == "color3" || type == "color4" || (type == mx::FILENAME_TYPE_STRING && colorImage)) {
            uses.push_back({owner->getNamePath(), input->getName(), type, input->getValueString()});
        }
    }
}

/// Adds the colours in the working space of `graph` (the document or a
/// nodegraph), going down into nodegraphs that don't set their own.
void CollectColorUses(const mx::ElementPtr& graph, std::vector<ColorUse>& uses) {
    for (const mx::ElementPtr& child : graph->getChildren()) {
        if (child->hasColorSpace() || IsIncluded(child)) {
            continue;
        }
        if (mx::NodePtr node = child->asA<mx::Node>()) {
            AddColorUses(node, uses);
        } else if (mx::NodeGraphPtr nodeGraph = child->asA<mx::NodeGraph>()) {
            if (nodeGraph->hasNodeDefString()) {
                continue;
            }
            AddColorUses(nodeGraph, uses);
            CollectColorUses(nodeGraph, uses);
        }
    }
}

/// The document (`path` "") or the nodegraph at `path`, or nullptr.
mx::ElementPtr WorkingSpaceOwner(const mx::DocumentPtr& document, const std::string& path) {
    if (path.empty()) {
        return document;
    }
    mx::ElementPtr element = document->getDescendant(path);
    return element && element->isA<mx::NodeGraph>() ? element : nullptr;
}

} // namespace

WorkingSpaceInfo Document::workingSpace(const std::string& path) const {
    WorkingSpaceInfo info;
    mx::ElementPtr owner = _impl ? WorkingSpaceOwner(_impl->document, path) : nullptr;
    if (!owner) {
        return info;
    }
    info.own = owner->getColorSpace();
    if (mx::ElementPtr parent = owner->getParent()) {
        info.inherited = parent->getActiveColorSpace();
    }
    return info;
}

std::vector<ColorUse> Document::colorsInWorkingSpace(const std::string& path) const {
    std::vector<ColorUse> uses;
    mx::ElementPtr owner = _impl ? WorkingSpaceOwner(_impl->document, path) : nullptr;
    if (!owner) {
        return uses;
    }
    if (mx::NodeGraphPtr nodeGraph = owner->asA<mx::NodeGraph>()) {
        if (nodeGraph->hasNodeDefString() || IsIncluded(nodeGraph)) {
            return uses;
        }
        AddColorUses(nodeGraph, uses);
    }
    CollectColorUses(owner, uses);
    return uses;
}

bool Document::setWorkingSpace(const std::string& path, const std::string& colorSpace, std::string& errorMessage) {
    return Perform(_impl ? _impl->document : nullptr, errorMessage, [&](const mx::DocumentPtr& document) {
        mx::ElementPtr owner = path.empty() ? mx::ElementPtr(document) : EditableElement(document, path);
        if (!owner->isA<mx::Document>() && !owner->isA<mx::NodeGraph>()) {
            throw Refusal("Only the document and nodegraphs have a working space");
        }
        if (colorSpace.empty()) {
            owner->removeAttribute(mx::Element::COLOR_SPACE_ATTRIBUTE);
        } else {
            owner->setColorSpace(colorSpace);
        }
    });
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

namespace {

/// The element at `path` in a copy of `document` with the nodes of the
/// definitions it makes expanded (ExpandDefinitions), for the OSL network
/// generator: its shaders are MaterialX's library compiled to .oso files,
/// and a definition made in the document has none (simple_hair's shader,
/// or one made with M4's Make Definition). The expansion turns each such
/// node into its implementation's nodes, which are all in the library.
///
/// For a node other than a material, a `dot` node reading it is returned
/// instead (for a closure, which has no dot, a `mix` weighing it fully,
/// which passes it through), for two reasons. A node of such a definition would vanish in
/// the expansion; the dot takes its place. And MaterialX 1.39.5's network
/// generator leaves out the values of the node it starts from: they
/// become the shader's own parameters, which it doesn't write, so the
/// group would use the defaults. Read by the dot, the node is upstream,
/// and its values are written like any other node's. (A material's values
/// are its shaders' connections, which it writes.)
///
/// `copy` receives the copy: MaterialX elements hold their document only
/// weakly, so the caller must keep it alive while using the element.
mx::ElementPtr ExpandedForNetwork(const mx::DocumentPtr& document, const std::string& path, mx::DocumentPtr& copy) {
    copy = document->copy();
    copy->setSourceUri(document->getSourceUri());
    if (mx::ConstDocumentPtr library = document->getDataLibrary()) {
        copy->setDataLibrary(library);
    }
    std::string target = path;
    mx::NodePtr node = copy->getDescendant(path)->asA<mx::Node>();
    if (node && node->getType() != mx::MATERIAL_TYPE_STRING && !node->isMultiOutputType()) {
        mx::GraphElementPtr parent = node->getParent()->asA<mx::GraphElement>();
        const std::string type = node->getType();
        const std::string name = parent->createValidChildName(node->getName() + "_shown");
        mx::NodePtr shown;
        if (copy->getNodeDef("ND_dot_" + type)) {
            shown = parent->addNode("dot", name, type);
            shown->addInput("in", type)->setNodeName(node->getName());
        } else if (copy->getNodeDef("ND_mix_" + mx::createValidName(mx::replaceSubstrings(type, {{"BSDF", "bsdf"},
                                                                                                 {"EDF", "edf"},
                                                                                                 {"VDF", "vdf"}})))) {
            shown = parent->addNode("mix", name, type);
            shown->addInput("fg", type)->setNodeName(node->getName());
            shown->addInput("mix", "float")->setValue(1.0f);
        }
        if (shown) {
            target = shown->getNamePath();
        }
    }
    ExpandDefinitions(copy, true);
    mx::ElementPtr element = copy->getDescendant(target);
    if (!element) {
        throw mx::Exception("Can't make an OSL network of " + path + ": it is expanded away");
    }
    return element;
}

/// Quotes the unquoted string values in an OSL shader group
/// (`param string file /a/b c.png ;` becomes `param string file "/a/b c.png" ;`).
/// MaterialX 1.39.5's network generator writes filenames bare, so OSL
/// would read a path with a space as two words; other strings it quotes.
std::string QuoteStringParams(const std::string& group) {
    static const std::string prefix = "param string ";
    static const std::string suffix = " ;";
    std::stringstream in(group);
    std::string result;
    std::string line;
    while (std::getline(in, line)) {
        const size_t nameEnd = line.find(' ', prefix.size());
        if (line.rfind(prefix, 0) == 0 && nameEnd != std::string::npos && line.size() >= nameEnd + 1 + suffix.size() &&
            line.compare(line.size() - suffix.size(), suffix.size(), suffix) == 0 && line[nameEnd + 1] != '"') {
            const std::string value = line.substr(nameEnd + 1, line.size() - suffix.size() - nameEnd - 1);
            std::string quoted = "\"";
            for (char c : value) {
                if (c == '"' || c == '\\') {
                    quoted += '\\';
                }
                quoted += c;
            }
            line = line.substr(0, nameEnd + 1) + quoted + "\"" + suffix;
        }
        result += line + "\n";
    }
    return result;
}

} // namespace

bool Document::generateCode(const std::string& elementPath, const Library& library, ShaderLanguage language,
                            const std::string& colorSpace, ShaderCode& code, std::string& errorMessage) const {
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
        // The shader is named after the element, whatever is generated.
        const std::string shaderName = element->getName();
        mx::DocumentPtr expanded;
        if (language == ShaderLanguage::oslNetwork) {
            element = ExpandedForNetwork(_impl->document, elementPath, expanded);
        }

        mx::ShaderGeneratorPtr generator;
        switch (language) {
        case ShaderLanguage::msl:
            generator = mx::MslShaderGenerator::create();
            break;
        case ShaderLanguage::glsl:
            generator = mx::GlslShaderGenerator::create();
            break;
        case ShaderLanguage::osl:
            generator = mx::OslShaderGenerator::create();
            break;
        case ShaderLanguage::oslNetwork:
            if (library._impl->networkRoot.empty()) {
                errorMessage = "MaterialX's library compiled for OSL networks wasn't found "
                               "(scripts/build-materialx-genosl.sh makes it)";
                return false;
            }
            generator = mx::OslNetworkShaderGenerator::create();
            break;
        }

        // Colour management, as in generateMsl(), into `colorSpace` if
        // there are transforms to it (MaterialX's to lin_rec709, ours to
        // acescg), otherwise lin_rec709.
        mx::DocumentPtr transforms = library._impl->colorTransforms;
        const std::string target =
            transforms->getNodeDef("ND_lin_rec709_to_" + colorSpace + "_color3") ? colorSpace : "lin_rec709";
        mx::DefaultColorManagementSystemPtr colorManagement =
            mx::DefaultColorManagementSystem::create(generator->getTarget());
        colorManagement->loadLibrary(transforms);
        generator->setColorManagementSystem(colorManagement);

        mx::GenContext context(generator);
        context.registerSourceCodeSearchPath(mx::FilePath(library._impl->librariesRoot));
        context.getOptions().targetColorSpaceOverride = target;
        mx::TypedElementPtr typed = element->asA<mx::TypedElement>();
        if ((language == ShaderLanguage::osl || language == ShaderLanguage::oslNetwork) &&
            !(typed && typed->isMultiOutputType())) {
            // The shader (or the group) ends by assigning its result to Ci,
            // the closure a renderer reads, as MaterialX's own OSL render
            // tests do. Without it, a material's result is only an output
            // parameter, which renderers don't look at. Not for a node with
            // several outputs, which has no one result: MaterialX 1.39.5
            // crashes trying (gltf_colorimage, for one).
            context.getOptions().oslConnectCiWrapper = true;
        }
        if (language == ShaderLanguage::oslNetwork) {
            // Where the network's implementations (`file="genoslnetwork"`)
            // are found.
            context.registerSourceCodeSearchPath(mx::FilePath(library._impl->networkRoot));
        }

        mx::ShaderPtr generated = generator->generate(shaderName, element, context);
        if (!generated) {
            errorMessage = "Shader generation produced nothing for " + elementPath;
            return false;
        }

        code = ShaderCode();
        code.colorSpace = target;
        if (language == ShaderLanguage::msl || language == ShaderLanguage::glsl) {
            code.vertexSource = generated->getSourceCode(mx::Stage::VERTEX);
        }
        // OSL has only the pixel stage.
        code.pixelSource = generated->getSourceCode(mx::Stage::PIXEL);

        if (language == ShaderLanguage::oslNetwork) {
            code.pixelSource = QuoteStringParams(code.pixelSource);
            // The .oso files the group's `shader` lines name: every node's
            // implementation is an OsoNode, which knows its file.
            std::set<std::string> seen;
            for (const mx::ShaderNode* node : generated->getGraph().getNodes()) {
                const auto* oso = dynamic_cast<const mx::OsoNode*>(&node->getImplementation());
                if (!oso) {
                    continue;
                }
                const mx::FilePath folder = context.resolveSourceFile(oso->getOsoPath(), mx::FilePath());
                const std::string file = (folder / (oso->getOsoName() + ".oso")).asString();
                if (seen.insert(file).second) {
                    code.osoFiles.push_back(file);
                }
            }
        }
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
