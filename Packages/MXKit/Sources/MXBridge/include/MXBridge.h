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

    /// The `version` attribute of the root element, such as "1.39".
    std::string documentVersion() const;

private:
    struct Impl;
    std::shared_ptr<Impl> _impl;
};

/// Version of the MaterialX library we are linked against, such as "1.39.5".
std::string materialXVersion();

} // namespace mxbridge
