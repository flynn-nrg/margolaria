// ColorBridge.h
//
// The C++ API that Swift sees for colour management (M3a; displays, views
// and GPU shaders since M3b). ColorKit (Swift) imports this header; nothing
// else in Margolaria talks to OpenColorIO.
//
// The same rules as MXBridge.h, for the same reasons:
//
//  1. No OpenColorIO headers. Its types live behind private `Impl` structs,
//     defined only in ColorBridge.cpp.
//  2. No exceptions cross into Swift. OCIO reports errors by throwing
//     OCIO::Exception; every function here catches it and reports it
//     through an `errorMessage` out-parameter instead.
//  3. Only simple types in signatures: std::string, std::vector, plain
//     structs, bool.
//
// Config and Processor are cheap-to-copy handles around a std::shared_ptr.
// Both are safe to use from several threads at once: OCIO's configs and
// processors are immutable once made (OCIO's documentation, "Thread
// safety"), and we never change them.

#pragma once

#include <memory>
#include <string>
#include <vector>

namespace colorbridge {

/// A list of floats. Swift can't name a C++ template instance such as
/// `std::vector<float>` itself, only through a typedef like this one, which
/// it imports as `colorbridge.FloatVector`.
using FloatVector = std::vector<float>;

/// A list of strings, as `FloatVector` is for floats.
using StringVector = std::vector<std::string>;

/// OpenColorIO's version, such as "2.5.2".
std::string ocioVersion();

/// One colour space of a config, as the UI lists it.
struct ColorSpaceInfo {
    /// The config's name for it, such as "ACEScg" or "sRGB Encoded Rec.709 (sRGB)".
    std::string name;
    /// Other names that find it: MaterialX's names ("acescg", "srgb_texture",
    /// "lin_rec709") are aliases in OCIO's ACES configs.
    std::vector<std::string> aliases;
    /// The config's grouping, such as "ACES" or "Utility", with levels
    /// separated by "/".
    std::string family;
    /// A sentence or two from the config.
    std::string description;
    /// "scene-linear", "sdr-video", "log", ... Empty when the config doesn't say.
    std::string encoding;
    /// True for data spaces ("Raw"): values that aren't colours (normals,
    /// roughness), which conversions leave alone.
    bool isData = false;
    /// True for display spaces (what a monitor shows), false for scene
    /// spaces (what materials and textures hold).
    bool isDisplay = false;
};

/// A lookup table that a GPU shader samples, as OCIO describes it. The
/// shader declares it as a texture (`textureName`) and a sampler
/// (`samplerName`); whoever runs the shader creates both from these values.
struct ShaderTexture {
    /// The texture's name in the shader text, such as "ocio_lut1d_0".
    std::string textureName;
    /// The name of the sampler the shader samples it with.
    std::string samplerName;
    /// Size in texels. `depth` is 0 for a 2D texture, the size of the cube
    /// for a 3D one (then width, height and depth are equal).
    unsigned width = 0;
    unsigned height = 0;
    unsigned depth = 0;
    /// 1 (red only) or 3 (RGB) floats per texel.
    unsigned channels = 0;
    /// True to sample with linear filtering, false for nearest.
    bool linearFilter = false;
    /// The texels, row by row (and slice by slice), `channels` floats each.
    FloatVector values;
};

/// The textures of a GPU shader.
using ShaderTextureVector = std::vector<ShaderTexture>;

/// A colour transform as GPU shader code, in the Metal Shading Language.
///
/// The code defines a function, `functionName`, that takes each texture
/// and its sampler, in the order of `textures`, then the pixel:
///
///     float4 OCIOMain(texture2d<float> t0, sampler s0, ..., float4 inPixel)
struct GPUShader {
    /// True when this holds a shader.
    bool isLoaded = false;
    /// MSL source: helper functions and `functionName`, no entry points.
    std::string source;
    /// The function to call, "OCIOMain".
    std::string functionName;
    /// The lookup tables the function samples.
    ShaderTextureVector textures;
};

/// Converts colours from one colour space to another, on the CPU, without
/// OCIO's lossy approximations (exact to float precision).
class Processor {
public:
    /// An empty handle. isLoaded() returns false.
    Processor();

    /// True when this handle converts something.
    bool isLoaded() const;

    /// True when the conversion changes nothing (the same space, or two
    /// names for it).
    bool isNoOp() const;

    /// Converts packed RGB triples (r, g, b, r, g, b, ...); a trailing
    /// partial triple is returned unchanged. Returns `rgb` as it is if this
    /// handle is empty.
    FloatVector applyRGB(const FloatVector& rgb) const;

private:
    friend class Config;
    struct Impl;
    std::shared_ptr<Impl> _impl;
};

/// An OCIO config: the colour spaces, displays and views a project uses.
class Config {
public:
    /// An empty handle with no config. isLoaded() returns false.
    Config();

    /// One of the configs built into OCIO, such as
    /// "ocio://studio-config-latest". On failure, returns an empty Config
    /// and sets `errorMessage`.
    static Config builtin(const std::string& uri, std::string& errorMessage);

    /// True when this handle holds a config.
    bool isLoaded() const;

    /// The config's name, such as "studio-config-v4.0.0_aces-v2.0_ocio-v2.5".
    std::string name() const;

    /// Every colour space, scene and display ones, in the config's order.
    std::vector<ColorSpaceInfo> colorSpaces() const;

    /// The config's name for a colour space given by name or alias
    /// (case-insensitively, as OCIO looks names up). Empty if unknown.
    std::string canonicalName(const std::string& nameOrAlias) const;

    /// A processor from one colour space to another, each given by name or
    /// alias. On failure (an unknown name), returns an empty Processor and
    /// sets `errorMessage`.
    Processor processor(const std::string& from, const std::string& to, std::string& errorMessage) const;

    // --- Displays and views (M3b) ------------------------------------------
    //
    // A *display* is a kind of monitor ("sRGB - Display"); a *view* is a way
    // of showing scene-linear light on it ("ACES 2.0 - SDR 100 nits
    // (Rec.709)" tone-maps, "Un-tone-mapped" only encodes). Together they
    // are a "view transform", applied to rendered images just before they
    // reach the screen.

    /// The active displays, in the config's order. The first is the default.
    StringVector displays() const;

    /// The views of `display`, in the config's order. Empty for an unknown
    /// display.
    StringVector views(const std::string& display) const;

    /// The view `display` shows unless told otherwise. Empty for an unknown
    /// display.
    std::string defaultView(const std::string& display) const;

    /// A CPU processor from the colour space `from` to `display` through
    /// `view`. On failure, returns an empty Processor and sets `errorMessage`.
    Processor displayProcessor(const std::string& from, const std::string& display, const std::string& view,
                               std::string& errorMessage) const;

    /// The same transform as displayProcessor, as a Metal shader. On
    /// failure, returns a GPUShader whose isLoaded is false and sets
    /// `errorMessage`.
    GPUShader displayShader(const std::string& from, const std::string& display, const std::string& view,
                            std::string& errorMessage) const;

private:
    struct Impl;
    std::shared_ptr<Impl> _impl;
};

} // namespace colorbridge
