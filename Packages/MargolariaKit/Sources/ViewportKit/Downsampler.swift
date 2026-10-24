// Downsampler.swift
//
// Anti-aliasing for the viewport by supersampling: Storm renders the frame
// at twice the width and height, and this draws it into the screen's
// texture at the real size. Each screen pixel samples the big frame at its
// centre with bilinear filtering; at exactly 2× that point is the shared
// corner of four frame pixels, so the result is their average.
//
// Why not Storm's own MSAA: UsdImagingGLEngine has no option for it, and
// setting the HDX_MSAA_SAMPLE_COUNT environment variable made no difference
// to the colour output it returns (tried in M1c). Supersampling needs no
// cooperation from Hydra, and also smooths texture and shading detail.
//
// Introduces (SWIFT): compiling Metal shaders from a source string at run
// time, `MTLRenderPipelineDescriptor`, `MTLSamplerDescriptor`, a multi-line
// string literal holding code.

import Metal

/// Draws a texture into another, smaller one, with bilinear filtering.
final class Downsampler {
    /// How much larger than the screen Storm renders, in each direction.
    static let factor: Int = 2

    private let pipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState

    /// The two shaders: a triangle covering the whole target (three
    /// vertices, positions computed from the vertex number, no buffers), and
    /// a fragment shader that samples the source texture.
    ///
    /// SWIFT: A multi-line string literal starts and ends with `"""`. The
    /// indentation of the closing `"""` is removed from every line.
    private static let source: String = """
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

        fragment half4 downsample(Varyings in [[stage_in]],
                                  texture2d<half> source [[texture(0)]],
                                  sampler bilinear [[sampler(0)]]) {
            return source.sample(bilinear, in.uv);
        }
        """

    /// Compiles the shaders for drawing into textures of `pixelFormat`.
    ///
    /// - Throws: Metal's error if compilation fails (not expected: the
    ///   source is fixed).
    init(device: any MTLDevice, pixelFormat: MTLPixelFormat) throws {
        // SWIFT: `makeLibrary(source:options:)` runs the Metal compiler
        // inside the app. It is allowed under the Hardened Runtime; Storm
        // compiles its own shaders the same way.
        let library: any MTLLibrary = try device.makeLibrary(source: Self.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullScreenTriangle")
        descriptor.fragmentFunction = library.makeFunction(name: "downsample")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MTLDeviceError.samplerCreationFailed
        }
        self.sampler = sampler
    }

    /// Encodes drawing `source` over the whole of `destination`.
    func encode(from source: any MTLTexture, to destination: any MTLTexture, in commandBuffer: any MTLCommandBuffer) {
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
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}

/// Errors the Metal API reports as nil rather than by throwing.
enum MTLDeviceError: Error {
    case samplerCreationFailed
}
