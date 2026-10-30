// DisplayPass.swift
//
// The last step of every viewport frame and every swatch: draws a rendered
// frame into the screen's texture (or the swatch's image), doing two
// things on the way. Moved here from ViewportKit in M3c, when the swatches
// started using it too.
//
//  1. Anti-aliasing by supersampling (M1c). Storm renders the frame at twice
//     the width and height, and each screen pixel is the average of the
//     2 × 2 frame pixels it covers.
//  2. The view transform (M3b). Storm's frame holds scene-linear light
//     (lin_rec709), encoded with the sRGB curve (MGStormRenderer.h says
//     why it can't hand it over linear). The pass decodes it exactly, and
//     OpenColorIO's display/view transform (ACES 2.0 by default) turns the
//     light into what the display shows. The transform is Metal code
//     written by OCIO (ColorKit's GPUShader), compiled here together with
//     our own shaders.
//
// The four frame pixels are decoded first and then averaged: averaging
// light is correct, averaging sRGB-encoded values darkens edges slightly.
// Without a transform, the pass works as before M3b: the screen pixel
// samples the frame at its centre with bilinear filtering (at exactly 2×,
// the shared corner of four frame pixels, so their average), and the
// frame's sRGB values go to the screen as they are.
//
// Swatches (M3c) are different in two ways, chosen with `Encoding`: their
// frames hold linear light as it is, and they are transparent around the
// sphere, with colours premultiplied by alpha (the edge pixels, partly
// covered, are a mix of sphere and nothing). The pass divides by alpha
// before the transform, which works on colours, not on coverage, and
// multiplies again after.
//
// Why not Storm's own MSAA: UsdImagingGLEngine has no option for it, and
// setting the HDX_MSAA_SAMPLE_COUNT environment variable made no difference
// to the colour output it returns (tried in M1c). Supersampling needs no
// cooperation from Hydra, and also smooths texture and shading detail.
//
// Why not OpenUSD's OCIO support (HdxColorCorrectionTask): SwiftUsd builds
// OpenUSD without OpenColorIO.
//
// Introduces (SWIFT): compiling Metal shaders from a source string at run
// time, `MTLRenderPipelineDescriptor`, `MTLSamplerDescriptor`, a multi-line
// string literal holding code (all M1c, as Downsampler.swift);
// `enumerated()`, `joined(separator:)`, passing `&variable` to a C pointer
// parameter (M3b).

import ColorKit
import Metal

/// Draws a frame into a texture of the same size or half of it, with
/// bilinear filtering, through an optional OCIO view transform.
public final class DisplayPass {
    /// How much larger than the screen Storm renders, in each direction.
    public static let factor: Int = 2

    /// How the frames' pixels are encoded.
    public enum Encoding: Sendable {
        /// Storm's: linear light encoded with the sRGB curve, unclamped,
        /// opaque (see MGStormRenderer.h).
        case stormSRGB
        /// Linear light as it is, with colours premultiplied by alpha:
        /// the swatches'.
        case linearPremultiplied
    }

    private let pipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState
    /// The view transform's lookup tables, in the order its function takes
    /// them; bound at texture indices 1, 2, ...
    private let lookupTables: [any MTLTexture]

    /// The vertex shader, and the start of the fragment shader's file: a
    /// triangle covering the whole target (three vertices, positions
    /// computed from the vertex number, no buffers).
    ///
    /// SWIFT: A multi-line string literal starts and ends with `"""`. The
    /// indentation of the closing `"""` is removed from every line.
    private static let vertexSource: String = """
        #include <metal_stdlib>
        using namespace metal;

        struct Varyings {
            float4 position [[position]];
            float2 uv;
        };

        // Vertices 0, 1, 2 at (0,0), (2,0), (0,2) in "p" space: one triangle
        // big enough to cover the [0,1] square, clipped to the screen.
        vertex Varyings fullScreenTriangle(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            Varyings out;
            out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
            // Texture coordinates have y down; clip space has y up.
            out.uv = float2(p.x, 1.0 - p.y);
            return out;
        }

        """

    /// Compiles the shaders for drawing frames encoded as `encoding` into
    /// textures of `pixelFormat`, and creates the transform's lookup
    /// tables. With no transform, Storm's pixels are copied as they are
    /// (encoded as sRGB, by Storm), and linear ones are encoded with the
    /// sRGB curve.
    ///
    /// - Throws: Metal's error if compilation fails, or
    ///   ``DisplayPassError`` if a lookup table can't be created.
    public init(device: any MTLDevice, pixelFormat: MTLPixelFormat, encoding: Encoding = .stormSRGB,
                transform: GPUShader? = nil) throws {
        let fragment: String
        // SWIFT: `if let` binds the optional for the first branch only.
        if let transform {
            fragment = Self.fragmentSource(transform, encoding: encoding)
        } else {
            fragment = encoding == .stormSRGB ? Self.plainFragmentSource : Self.linearFragmentSource
        }
        let source: String = Self.vertexSource + fragment
        // SWIFT: `makeLibrary(source:options:)` runs the Metal compiler
        // inside the app. It is allowed under the Hardened Runtime; Storm
        // compiles its own shaders the same way.
        let library: any MTLLibrary = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullScreenTriangle")
        descriptor.fragmentFunction = library.makeFunction(name: "display")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw DisplayPassError.metal("Could not create the sampler")
        }
        self.sampler = sampler

        // SWIFT: `try` inside `map`'s closure: if one table fails, the
        // error leaves `map` and then this initializer.
        lookupTables = try (transform?.textures ?? []).map { try Self.makeTexture($0, device: device) }
    }

    /// The fragment shader without a transform: sample and return.
    private static let plainFragmentSource: String = """
        fragment float4 display(Varyings in [[stage_in]],
                                texture2d<float> frame [[texture(0)]],
                                sampler bilinear [[sampler(0)]]) {
            return frame.sample(bilinear, in.uv);
        }
        """

    /// The fragment shader for linear frames without a transform: sample,
    /// and encode with the sRGB curve (clamped: the screen can't show
    /// more than white), keeping alpha.
    private static let linearFragmentSource: String = """
        fragment float4 display(Varyings in [[stage_in]],
                                texture2d<float> frame [[texture(0)]],
                                sampler bilinear [[sampler(0)]]) {
            float4 pixel = frame.sample(bilinear, in.uv);
            float3 light = pixel.a > 0.0 ? saturate(pixel.rgb / pixel.a) : float3(0.0);
            float3 encoded = select(1.055 * pow(light, 1.0 / 2.4) - 0.055, light * 12.92, light < 0.0031308);
            return float4(encoded * pixel.a, pixel.a);
        }
        """

    /// OCIO's code for `transform`, then a fragment shader that samples the
    /// frame, decodes it into linear light, and passes the light through
    /// OCIO's function.
    ///
    /// OCIO's function takes each lookup table and its sampler as
    /// arguments. The fragment shader receives the tables as textures 1,
    /// 2, ... and makes the samplers itself (`constexpr sampler`: a sampler
    /// written into the shader, so Swift needn't create them).
    private static func fragmentSource(_ transform: GPUShader, encoding: Encoding) -> String {
        // SWIFT: `enumerated()` pairs each element with its index, like
        // Go's `for i, t := range textures`.
        let parameters: [String] = transform.textures.enumerated().map { index, table in
            let type: String = table.is3D ? "texture3d<float>" : "texture2d<float>"
            return ",\n    \(type) \(table.name) [[texture(\(index + 1))]]"
        }
        let samplers: [String] = transform.textures.map { table in
            let filter: String = table.linearFilter ? "linear" : "nearest"
            return "    constexpr sampler \(table.samplerName)(filter::\(filter), address::clamp_to_edge);\n"
        }
        let arguments: [String] = transform.textures.map { "\($0.name), \($0.samplerName), " }

        // What reads one frame pixel as light, and what finishes the
        // transformed colour.
        let decode: String
        let finish: String
        switch encoding {
        case .stormSRGB:
            decode = "float4(linearFromStormSRGB(frame.read(corner + uint2(x, y)).rgb), 1.0)"
            // Alpha is 1: Storm's frame is opaque (it clears to an opaque
            // grey).
            finish = "return \(transform.functionName)(\(arguments.joined())float4(sum.rgb / count, 1.0));"
        case .linearPremultiplied:
            decode = "frame.read(corner + uint2(x, y))"
            // Divide by alpha, transform, multiply again. Fully
            // transparent pixels stay transparent black.
            finish = """
                float alpha = sum.a / count;
                    if (alpha <= 0.0) {
                        return float4(0.0);
                    }
                    float4 display = \(transform.functionName)(\(arguments.joined())float4(sum.rgb / sum.a, 1.0));
                    return float4(display.rgb * alpha, alpha);
                """
        }

        // SWIFT: `joined(separator:)` concatenates an array of strings,
        // like Go's strings.Join.
        return transform.source + """

            // The exact inverse of Hydra's sRGB encoding (FloatToSRGB in
            // hdx/shaders/colorCorrection.glslfx): unclamped, so highlights
            // above 1 come back. Hydra turns negative components into NaN
            // (the power of a negative number); they become 0.
            float3 linearFromStormSRGB(float3 encoded) {
                float3 decoded = select(pow((encoded + 0.055) / 1.055, 2.4), encoded / 12.92,
                                        encoded < 0.04045);
                return select(decoded, float3(0.0), isnan(decoded));
            }

            // `factor` frame pixels per screen pixel, across and down (1 or 2).
            fragment float4 display(Varyings in [[stage_in]],
                                    texture2d<float> frame [[texture(0)]],
                                    constant uint &factor [[buffer(0)]]\(parameters.joined())) {
            \(samplers.joined())
                // The frame pixels this screen pixel covers, decoded, summed.
                // OCIO is then given alpha 1: it treats alpha as a fourth
                // channel, not as coverage.
                uint2 corner = uint2(in.position.xy) * factor;
                float4 sum = float4(0.0);
                for (uint y = 0; y < factor; ++y) {
                    for (uint x = 0; x < factor; ++x) {
                        sum += \(decode);
                    }
                }
                float count = float(factor * factor);
                \(finish)
            }
            """
    }

    /// A Metal texture holding `table`: one channel as R32Float, three as
    /// RGBA32Float (Metal has no three-channel float format, so alpha is
    /// added, set to 1).
    private static func makeTexture(_ table: GPUShader.Texture, device: any MTLDevice) throws -> any MTLTexture {
        // Linear filtering of 32-bit floats needs an Apple GPU of the M1's
        // generation or later; every Mac that runs macOS 15 on Apple
        // silicon has one, but check rather than sample wrongly.
        if table.linearFilter && !device.supports32BitFloatFiltering {
            throw DisplayPassError.metal("This GPU can't filter 32-bit float textures")
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = table.is3D ? .type3D : .type2D
        descriptor.pixelFormat = table.channels == 1 ? .r32Float : .rgba32Float
        descriptor.width = table.width
        descriptor.height = table.height
        descriptor.depth = max(table.depth, 1)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw DisplayPassError.metal("Could not create the \(table.name) lookup table")
        }

        let texels: [Float]
        switch table.channels {
        case 1:
            texels = table.values
        case 3:
            // SWIFT: `stride(from:to:by:)` counts in steps, like
            // `for (i = 0; i < n; i += 3)`. `flatMap` joins the small
            // arrays the closure returns into one.
            texels = stride(from: 0, to: table.values.count, by: 3).flatMap { index in
                [table.values[index], table.values[index + 1], table.values[index + 2], 1]
            }
        default:
            throw DisplayPassError.metal("\(table.name) has \(table.channels) channels")
        }
        let texelSize: Int = (table.channels == 1 ? 1 : 4) * MemoryLayout<Float>.size
        // SWIFT: `withUnsafeBytes` lends a raw pointer to the array's
        // storage for the duration of the closure, as for a C API taking
        // `const void *`.
        texels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, table.width, table.height, max(table.depth, 1)),
                            mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                            bytesPerRow: table.width * texelSize,
                            bytesPerImage: table.width * table.height * texelSize)
        }
        return texture
    }

    /// Encodes drawing `source` over the whole of `destination`, which is
    /// the same size or half of it in each direction.
    public func encode(from source: any MTLTexture, to destination: any MTLTexture, in commandBuffer: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        // Every pixel is overwritten, so the old contents needn't be loaded.
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        // SWIFT: `var` because `setFragmentBytes` takes a pointer to it
        // (`&factor`), and Swift only lends pointers to variables. Metal
        // copies the bytes into the command buffer.
        var factor = UInt32(max(1, source.width / max(1, destination.width)))
        encoder.setFragmentBytes(&factor, length: MemoryLayout<UInt32>.size, index: 0)
        for (index, table) in lookupTables.enumerated() {
            encoder.setFragmentTexture(table, index: index + 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}

/// Errors the Metal API reports as nil rather than by throwing, and
/// lookup tables Metal can't hold.
public enum DisplayPassError: Error {
    case metal(String)
}
