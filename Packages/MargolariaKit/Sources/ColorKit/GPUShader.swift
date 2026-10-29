// GPUShader.swift
//
// A colour transform as Metal shader code (M3b), made by
// ``ColorConfiguration/displayShader(from:display:view:)``: the viewport
// converts Storm's frames for the screen with it. ColorKit only describes
// the shader; ViewportKit compiles it and creates the textures, so ColorKit
// needs no Metal.
//
// Introduces (SWIFT): `Array(_:)` copying an imported C++ vector.

import ColorBridge
import CxxStdlib

/// Metal Shading Language code for a colour transform, and the lookup
/// tables it samples.
///
/// The code defines one function, ``functionName``, that takes each
/// texture and its sampler, in the order of ``textures``, then the pixel:
///
///     float4 OCIOMain(texture2d<float> t0, sampler s0, ..., float4 inPixel)
///
/// It has no entry points (`vertex`/`fragment` functions): the caller adds
/// its own, which calls the function.
public struct GPUShader: Sendable {
    /// The MSL source.
    public let source: String
    /// The function to call: "OCIOMain".
    public let functionName: String
    /// The lookup tables, in the order the function takes them.
    public let textures: [Texture]

    /// A lookup table the shader samples.
    ///
    /// SWIFT: A type declared inside another is a *nested type*, named
    /// `GPUShader.Texture` from outside, like a C++ nested struct. It only
    /// affects the name; it holds no reference to a GPUShader.
    public struct Texture: Sendable {
        /// Its parameter name in the source, such as "ocio_lut1d_0".
        public let name: String
        /// The name of its sampler parameter.
        public let samplerName: String
        /// Size in texels. ``depth`` is 0 for a 2D texture.
        public let width: Int
        public let height: Int
        public let depth: Int
        /// 1 (red only) or 3 (RGB) floats per texel.
        public let channels: Int
        /// Sample with linear filtering (true) or the nearest texel.
        public let linearFilter: Bool
        /// The texels, row by row (and slice by slice), ``channels`` floats each.
        public let values: [Float]

        /// True for a 3D texture (a cube), false for a 2D one.
        public var is3D: Bool { depth > 0 }
    }

    /// Copies the C++ description.
    init(_ shader: colorbridge.GPUShader) {
        source = shader.source.colorKitString
        functionName = shader.functionName.colorKitString
        // SWIFT: `shader.textures` is a C++ `std::vector`, which Swift
        // imports as a collection: `map` walks it like a Swift array.
        textures = shader.textures.map { texture in
            Texture(name: texture.textureName.colorKitString,
                    samplerName: texture.samplerName.colorKitString,
                    width: Int(texture.width), height: Int(texture.height), depth: Int(texture.depth),
                    channels: Int(texture.channels), linearFilter: texture.linearFilter,
                    // SWIFT: `Array(_:)` copies any sequence into a Swift
                    // array: here the C++ vector's floats. The copy is
                    // needed because the C++ vector dies with `shader`.
                    values: Array(texture.values))
        }
    }
}
