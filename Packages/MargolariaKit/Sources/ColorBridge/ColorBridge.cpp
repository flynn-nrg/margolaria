// ColorBridge.cpp
//
// Implementation of the Swift-facing C++ API declared in include/ColorBridge.h.
// This is the only file in Margolaria that includes OpenColorIO headers.
//
// The headers and library come from Vendor/OpenColorIO/OpenColorIO.xcframework
// (scripts/build-ocio.sh). SwiftPM puts the framework on our search path, so
// `<OpenColorIO/OpenColorIO.h>` finds its Headers folder.

#include "ColorBridge.h"

#include <OpenColorIO/OpenColorIO.h>

#include <exception>

namespace OCIO = OCIO_NAMESPACE;

namespace colorbridge {

// --- Private implementation structs ----------------------------------------

struct Processor::Impl {
    // The CPU half of an OCIO processor, optimised for 32-bit float pixels.
    OCIO::ConstCPUProcessorRcPtr cpu;
    bool isNoOp = false;
};

struct Config::Impl {
    OCIO::ConstConfigRcPtr config;
};

std::string ocioVersion() {
    return OCIO::GetVersion();
}

// --- Processor -------------------------------------------------------------

Processor::Processor() = default;

bool Processor::isLoaded() const {
    return _impl != nullptr;
}

bool Processor::isNoOp() const {
    return _impl && _impl->isNoOp;
}

FloatVector Processor::applyRGB(const FloatVector& rgb) const {
    FloatVector result = rgb;
    const size_t pixelCount = result.size() / 3;
    if (!_impl || pixelCount == 0) {
        return result;
    }
    try {
        // A packed image of `pixelCount` pixels in one row, processed in place.
        OCIO::PackedImageDesc image(result.data(), static_cast<long>(pixelCount), 1, 3);
        _impl->cpu->apply(image);
    } catch (const std::exception&) {
        // apply() only throws for a malformed image description, which the
        // one above isn't; return the input unchanged rather than crash.
        return rgb;
    }
    return result;
}

// --- Config ----------------------------------------------------------------

Config::Config() = default;

Config Config::builtin(const std::string& uri, std::string& errorMessage) {
    // Everything that can throw sits inside the try block. See the header:
    // no exception may escape into Swift.
    try {
        auto impl = std::make_shared<Impl>();
        // CreateFromFile accepts "ocio://" URIs for the built-in configs.
        impl->config = OCIO::Config::CreateFromFile(uri.c_str());
        Config config;
        config._impl = impl;
        return config;
    } catch (const std::exception& error) {
        errorMessage = error.what();
        return Config();
    }
}

bool Config::isLoaded() const {
    return _impl != nullptr;
}

std::string Config::name() const {
    if (!_impl) {
        return "";
    }
    const char* name = _impl->config->getName();
    return name ? name : "";
}

std::vector<ColorSpaceInfo> Config::colorSpaces() const {
    std::vector<ColorSpaceInfo> result;
    if (!_impl) {
        return result;
    }
    const OCIO::ConstConfigRcPtr& config = _impl->config;
    // Active spaces only, of both kinds: inactive ones are hidden by the
    // config's author on purpose.
    const int count = config->getNumColorSpaces(OCIO::SEARCH_REFERENCE_SPACE_ALL, OCIO::COLORSPACE_ACTIVE);
    for (int index = 0; index < count; ++index) {
        const char* name =
            config->getColorSpaceNameByIndex(OCIO::SEARCH_REFERENCE_SPACE_ALL, OCIO::COLORSPACE_ACTIVE, index);
        OCIO::ConstColorSpaceRcPtr space = config->getColorSpace(name);
        if (!space) {
            continue;
        }
        ColorSpaceInfo info;
        info.name = space->getName();
        for (size_t alias = 0; alias < space->getNumAliases(); ++alias) {
            info.aliases.emplace_back(space->getAlias(alias));
        }
        info.family = space->getFamily();
        info.description = space->getDescription();
        info.encoding = space->getEncoding();
        info.isData = space->isData();
        info.isDisplay = space->getReferenceSpaceType() == OCIO::REFERENCE_SPACE_DISPLAY;
        result.push_back(info);
    }
    return result;
}

std::string Config::canonicalName(const std::string& nameOrAlias) const {
    if (!_impl) {
        return "";
    }
    // getCanonicalName resolves aliases and ignores case; "" if unknown.
    const char* name = _impl->config->getCanonicalName(nameOrAlias.c_str());
    return name ? name : "";
}

Processor Config::processor(const std::string& from, const std::string& to, std::string& errorMessage) const {
    if (!_impl) {
        errorMessage = "No colour config";
        return Processor();
    }
    try {
        // The config caches processors, so asking again for the same pair
        // is cheap.
        OCIO::ConstProcessorRcPtr processor = _impl->config->getProcessor(from.c_str(), to.c_str());
        auto impl = std::make_shared<Processor::Impl>();
        // Lossless optimisation, not OCIO's default: the default allows fast
        // approximations of pow, log and exp, off by about 2e-5 (white came
        // back as 1.000024). Pixels wouldn't show it, but the inspector
        // writes converted values into documents, where 1 must stay 1.
        impl->cpu = processor->getOptimizedCPUProcessor(OCIO::OPTIMIZATION_LOSSLESS);
        impl->isNoOp = processor->isNoOp();
        Processor result;
        result._impl = impl;
        return result;
    } catch (const std::exception& error) {
        errorMessage = error.what();
        return Processor();
    }
}

} // namespace colorbridge
