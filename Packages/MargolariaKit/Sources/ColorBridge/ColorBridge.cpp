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

    /// Wraps an OCIO processor's CPU half in our handle. May throw.
    ///
    /// A member of Config::Impl because only Config may build a Processor
    /// (it is Processor's friend, and its member classes share that).
    static Processor makeProcessor(const OCIO::ConstProcessorRcPtr& processor) {
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
    }
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
        return Impl::makeProcessor(_impl->config->getProcessor(from.c_str(), to.c_str()));
    } catch (const std::exception& error) {
        errorMessage = error.what();
        return Processor();
    }
}

// --- Displays and views ----------------------------------------------------

StringVector Config::displays() const {
    StringVector result;
    if (!_impl) {
        return result;
    }
    for (int index = 0; index < _impl->config->getNumDisplays(); ++index) {
        result.emplace_back(_impl->config->getDisplay(index));
    }
    return result;
}

StringVector Config::views(const std::string& display) const {
    StringVector result;
    if (!_impl) {
        return result;
    }
    // An unknown display has no views (getNumViews returns 0).
    const int count = _impl->config->getNumViews(display.c_str());
    for (int index = 0; index < count; ++index) {
        result.emplace_back(_impl->config->getView(display.c_str(), index));
    }
    return result;
}

std::string Config::defaultView(const std::string& display) const {
    if (!_impl || views(display).empty()) {
        return "";
    }
    const char* view = _impl->config->getDefaultView(display.c_str());
    return view ? view : "";
}

namespace {

/// A processor from `from` to `display` through `view`. May throw.
OCIO::ConstProcessorRcPtr DisplayViewProcessor(const OCIO::ConstConfigRcPtr& config, const std::string& from,
                                               const std::string& display, const std::string& view) {
    OCIO::DisplayViewTransformRcPtr transform = OCIO::DisplayViewTransform::Create();
    transform->setSrc(from.c_str());
    transform->setDisplay(display.c_str());
    transform->setView(view.c_str());
    return config->getProcessor(transform);
}

} // namespace

Processor Config::displayProcessor(const std::string& from, const std::string& display, const std::string& view,
                                   std::string& errorMessage) const {
    if (!_impl) {
        errorMessage = "No colour config";
        return Processor();
    }
    try {
        return Impl::makeProcessor(DisplayViewProcessor(_impl->config, from, display, view));
    } catch (const std::exception& error) {
        errorMessage = error.what();
        return Processor();
    }
}

GPUShader Config::displayShader(const std::string& from, const std::string& display, const std::string& view,
                                std::string& errorMessage) const {
    if (!_impl) {
        errorMessage = "No colour config";
        return GPUShader();
    }
    try {
        OCIO::ConstProcessorRcPtr processor = DisplayViewProcessor(_impl->config, from, display, view);
        // Lossless, as for the CPU: the shader then computes exactly what
        // the CPU processor does, which the tests check.
        OCIO::ConstGPUProcessorRcPtr gpu = processor->getOptimizedGPUProcessor(OCIO::OPTIMIZATION_LOSSLESS);

        // Ask for Metal source. OCIO writes the shader into this
        // description, along with the lookup tables it samples.
        OCIO::GpuShaderDescRcPtr description = OCIO::GpuShaderDesc::CreateShaderDesc();
        description->setLanguage(OCIO::GPU_LANGUAGE_MSL_2_0);
        description->setFunctionName("OCIOMain");
        description->setResourcePrefix("ocio");
        // Metal has 1D textures, but they can't be filtered linearly; OCIO
        // then uses one-row 2D textures instead.
        description->setAllowTexture1D(false);
        gpu->extractGpuShaderInfo(description);

        // Uniforms come from "dynamic properties" (exposure, gamma, ...
        // adjustable without a new shader). A display/view transform from a
        // config has none, and the caller has no way to set them.
        if (description->getNumUniforms() > 0) {
            errorMessage = "The view transform needs uniforms, which aren't supported";
            return GPUShader();
        }

        GPUShader shader;
        shader.source = description->getShaderText();
        shader.functionName = description->getFunctionName();

        // 1D lookup tables, as one-row 2D textures (or several rows, for a
        // table too long for one).
        for (unsigned index = 0; index < description->getNumTextures(); ++index) {
            const char* textureName = nullptr;
            const char* samplerName = nullptr;
            unsigned width = 0, height = 0;
            OCIO::GpuShaderDesc::TextureType channel = OCIO::GpuShaderDesc::TEXTURE_RGB_CHANNEL;
            OCIO::GpuShaderDesc::TextureDimensions dimensions = OCIO::GpuShaderDesc::TEXTURE_2D;
            OCIO::Interpolation interpolation = OCIO::INTERP_LINEAR;
            description->getTexture(index, textureName, samplerName, width, height, channel, dimensions,
                                    interpolation);
            const float* values = nullptr;
            description->getTextureValues(index, values);

            ShaderTexture texture;
            texture.textureName = textureName;
            texture.samplerName = samplerName;
            texture.width = width;
            texture.height = height;
            texture.channels = channel == OCIO::GpuShaderDesc::TEXTURE_RED_CHANNEL ? 1 : 3;
            texture.linearFilter = interpolation != OCIO::INTERP_NEAREST;
            texture.values.assign(values, values + size_t(width) * height * texture.channels);
            shader.textures.push_back(texture);
        }

        // 3D lookup tables: cubes of RGB values, red varying fastest.
        for (unsigned index = 0; index < description->getNum3DTextures(); ++index) {
            const char* textureName = nullptr;
            const char* samplerName = nullptr;
            unsigned edge = 0;
            OCIO::Interpolation interpolation = OCIO::INTERP_LINEAR;
            description->get3DTexture(index, textureName, samplerName, edge, interpolation);
            const float* values = nullptr;
            description->get3DTextureValues(index, values);

            ShaderTexture texture;
            texture.textureName = textureName;
            texture.samplerName = samplerName;
            texture.width = texture.height = texture.depth = edge;
            texture.channels = 3;
            texture.linearFilter = interpolation != OCIO::INTERP_NEAREST;
            texture.values.assign(values, values + size_t(edge) * edge * edge * 3);
            shader.textures.push_back(texture);
        }

        shader.isLoaded = true;
        return shader;
    } catch (const std::exception& error) {
        errorMessage = error.what();
        return GPUShader();
    }
}

} // namespace colorbridge
