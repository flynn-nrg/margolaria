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

#include <exception>

namespace mx = MaterialX;

namespace mxbridge {

// --- Private implementation structs ----------------------------------------
//
// These complete the `struct Impl;` forward declarations in the header. Only
// this file knows they hold MaterialX objects.

struct Library::Impl {
    mx::DocumentPtr definitions; // Every library file, merged into one document.
    int fileCount = 0;
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
        result.push_back(std::move(summary));
    }
    return result;
}

std::string Document::documentVersion() const {
    return _impl ? _impl->document->getVersionString() : std::string();
}

// --- Free functions ----------------------------------------------------------

std::string materialXVersion() {
    return mx::getVersionString();
}

} // namespace mxbridge
