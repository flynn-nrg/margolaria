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
#include <MaterialXFormat/File.h>
#include <MaterialXFormat/Util.h>
#include <MaterialXFormat/XmlIo.h>
#include <MaterialXGenMsl/MslShaderGenerator.h>
#include <MaterialXGenShader/DefaultColorManagementSystem.h>
#include <MaterialXGenShader/GenContext.h>
#include <MaterialXGenShader/Shader.h>
#include <MaterialXGenShader/ShaderStage.h>

#include <exception>
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

Document::Document() = default;

Document Document::readFromXmlString(const std::string& xml, std::string& errorMessage) {
    try {
        auto impl = std::make_shared<Impl>();
        impl->document = mx::createDocument();

        // Parses the XML into the document. This also upgrades older files
        // (for example v1.38) to the current version in memory. Throws
        // mx::ExceptionParseError on malformed XML.
        mx::readFromXmlString(impl->document, xml);

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

std::vector<ElementSummary> Document::topLevelElements() const {
    std::vector<ElementSummary> result;
    if (!_impl) {
        return result;
    }
    for (const mx::ElementPtr& element : _impl->document->getChildren()) {
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
