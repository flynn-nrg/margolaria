// DisplayPassTests.swift
//
// The view transform and the studio image (M3b; moved from ViewportKit's
// tests in M3c, with DisplayPass and StudioEnvironment). The view
// transform decodes Storm's sRGB and runs OCIO's Metal code on the GPU
// (DisplayPass); these tests encode known colours as Storm does, run them
// through it, and compare with OCIO's CPU processor, for every display and
// view offered. Swatches' frames (linear, premultiplied) are checked too.
// The studio renders are in ViewportKit's StudioRenderTests.
//
// Introduces (SWIFT): `[T](repeating:count:)`, `withUnsafeMutableBytes`
// (reading a GPU texture back into an array).

import ColorKit
import CoreGraphics
import Foundation
import Metal
import simd
import Testing
// SWIFT: `@testable` also imports the module's `internal` declarations
// (StudioEnvironment's soft boxes), for tests only. It works because
// SwiftPM builds for testing with that enabled; release builds don't.
@testable import PreviewKit

@Suite("Display pass and studio image", .serialized)
struct DisplayPassTests {
    /// Scene-linear test colours: black, darks, 18% grey, white, beyond
    /// white (highlights), saturated primaries.
    static let colours: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(0.002, 0.01, 0.05), SIMD3(0.18, 0.18, 0.18), SIMD3(1, 1, 1),
        SIMD3(4, 3, 2), SIMD3(16, 16, 16), SIMD3(0.8, 0.05, 0.05), SIMD3(0.05, 0.8, 0.05),
        SIMD3(0.05, 0.05, 0.8), SIMD3(0.9, 0.6, 0.1),
    ]

    /// `linear` encoded as Storm encodes its output: Hydra's FloatToSRGB
    /// (hdx/shaders/colorCorrection.glslfx), unclamped.
    static func stormSRGB(_ linear: Float) -> Float {
        linear < 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    /// Runs `encoded` (frame pixels, as Storm writes them) through a
    /// DisplayPass for `transform`, on the GPU, in 32-bit float textures,
    /// and returns what comes out.
    func gpuConvert(_ encoded: [SIMD3<Float>], with transform: ViewTransform) throws -> [SIMD3<Float>] {
        try gpuConvert(encoded.map { SIMD4($0, 1) }, encoding: .stormSRGB, with: transform).map {
            SIMD3($0.x, $0.y, $0.z)
        }
    }

    /// Runs RGBA frame pixels encoded as `encoding` through a DisplayPass,
    /// and returns the RGBA that comes out.
    func gpuConvert(_ encoded: [SIMD4<Float>], encoding: DisplayPass.Encoding,
                    with transform: ViewTransform) throws -> [SIMD4<Float>] {
        let colours = encoded
        let device: any MTLDevice = try #require(MTLCreateSystemDefaultDevice())
        let queue: any MTLCommandQueue = try #require(device.makeCommandQueue())
        let pass = try DisplayPass(device: device, pixelFormat: .rgba32Float, encoding: encoding,
                                   transform: transform.shader())

        // One row of texels, one per colour; same size in and out, so each
        // output pixel samples exactly one input texel.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: colours.count,
                                                                  height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        let input: any MTLTexture = try #require(device.makeTexture(descriptor: descriptor))
        let output: any MTLTexture = try #require(device.makeTexture(descriptor: descriptor))
        let texels: [Float] = colours.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        texels.withUnsafeBytes { bytes in
            input.replace(region: MTLRegionMake2D(0, 0, colours.count, 1), mipmapLevel: 0,
                          withBytes: bytes.baseAddress!, bytesPerRow: colours.count * 16)
        }

        let commandBuffer: any MTLCommandBuffer = try #require(queue.makeCommandBuffer())
        pass.encode(from: input, to: output, in: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // SWIFT: `[Float](repeating:count:)` makes an array of n copies;
        // `withUnsafeMutableBytes` lends a writable pointer to its storage.
        var result = [Float](repeating: 0, count: colours.count * 4)
        result.withUnsafeMutableBytes { bytes in
            output.getBytes(bytes.baseAddress!, bytesPerRow: colours.count * 16,
                            from: MTLRegionMake2D(0, 0, colours.count, 1), mipmapLevel: 0)
        }
        return (0..<colours.count).map {
            SIMD4(result[$0 * 4], result[$0 * 4 + 1], result[$0 * 4 + 2], result[$0 * 4 + 3])
        }
    }

    @Test("The GPU view transform gives what OCIO's CPU processor gives, for every display and view offered")
    func gpuMatchesCPU() throws {
        let config: ColorConfiguration = try ColorConfiguration.studio.get()
        #expect(ViewTransform.displays == ["sRGB - Display", "Display P3 - Display"])
        for display in ViewTransform.displays {
            for view in ViewTransform.views(for: display) {
                let transform = ViewTransform(display: display, view: view)
                // SWIFT: `.map(f)` on a SIMD3 isn't available, so encode
                // each component by hand.
                let encoded: [SIMD3<Float>] = Self.colours.map {
                    SIMD3(Self.stormSRGB($0.x), Self.stormSRGB($0.y), Self.stormSRGB($0.z))
                }
                let gpu: [SIMD3<Float>] = try gpuConvert(encoded, with: transform)
                let cpu: ColorConverter = try config.converter(from: ViewTransform.sceneSpace,
                                                               display: display, view: view)
                for (colour, fromGPU) in zip(Self.colours, gpu) {
                    let expected = SIMD3<Float>(cpu.convert(SIMD3<Double>(colour)))
                    // The GPU's pow, exp and log are a few ulps less exact
                    // than the CPU's; 2e-4 is far below what a display shows
                    // (1/255 = 4e-3).
                    let difference: Float = simd_reduce_max(simd_abs(fromGPU - expected))
                    #expect(difference < 2e-4, "\(display), \(view): \(colour) gave \(fromGPU), CPU \(expected)")
                }
            }
        }
    }

    @Test("A negative component, which Storm's encoding turns into NaN, is shown as 0")
    func negativeComponents() throws {
        let transform = ViewTransform(display: "sRGB - Display", view: "Un-tone-mapped")
        let gpu: [SIMD3<Float>] = try gpuConvert([SIMD3(.nan, Self.stormSRGB(0.5), 0)], with: transform)
        let expected: SIMD3<Double> = try ColorConfiguration.studio.get()
            .converter(from: "lin_rec709", display: transform.display, view: transform.view)
            .convert(SIMD3(0, 0.5, 0))
        #expect(simd_reduce_max(simd_abs(gpu[0] - SIMD3<Float>(expected))) < 2e-4, "\(gpu[0])")
    }

    @Test("Swatch frames, linear and premultiplied, are transformed as colours and keep their alpha")
    func premultipliedFrames() throws {
        let transform = ViewTransform(display: "sRGB - Display", view: "ACES 2.0 - SDR 100 nits (Rec.709)")
        let colour = SIMD3<Float>(0.8, 0.4, 0.1)
        // Opaque, a quarter covered (premultiplied: the colour times 0.25),
        // and empty.
        let frame: [SIMD4<Float>] = [SIMD4(colour, 1), SIMD4(colour * 0.25, 0.25), SIMD4(0, 0, 0, 0)]
        let gpu: [SIMD4<Float>] = try gpuConvert(frame, encoding: .linearPremultiplied, with: transform)
        let expected = SIMD3<Float>(try ColorConfiguration.studio.get()
            .converter(from: ViewTransform.sceneSpace, display: transform.display, view: transform.view)
            .convert(SIMD3<Double>(colour)))
        // SWIFT: `SIMD4(x, w)` builds a 4-vector from a 3-vector and a scalar.
        #expect(simd_reduce_max(simd_abs(gpu[0] - SIMD4(expected, 1))) < 2e-4, "\(gpu[0])")
        // The partly covered pixel is the same colour, a quarter as opaque:
        // the transform saw the colour, not the colour times coverage.
        #expect(simd_reduce_max(simd_abs(gpu[1] - SIMD4(expected * 0.25, 0.25))) < 2e-4, "\(gpu[1])")
        #expect(gpu[2] == SIMD4(0, 0, 0, 0))
    }

    @Test("Supersampled frames are averaged as light, not as encoded values")
    func averagesLight() throws {
        let device: any MTLDevice = try #require(MTLCreateSystemDefaultDevice())
        let queue: any MTLCommandQueue = try #require(device.makeCommandQueue())
        let transform = ViewTransform(display: "sRGB - Display", view: "Un-tone-mapped")
        let pass = try DisplayPass(device: device, pixelFormat: .rgba32Float, transform: transform.shader())
        // A 2 × 2 frame, half black and half white, drawn into one pixel.
        let frame = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 2, height: 2,
                                                             mipmapped: false)
        frame.usage = .shaderRead
        let input: any MTLTexture = try #require(device.makeTexture(descriptor: frame))
        let texels: [Float] = [0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1]
        texels.withUnsafeBytes { bytes in
            input.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: bytes.baseAddress!,
                          bytesPerRow: 32)
        }
        let pixel = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1,
                                                             mipmapped: false)
        pixel.usage = .renderTarget
        pixel.storageMode = .shared
        let output: any MTLTexture = try #require(device.makeTexture(descriptor: pixel))
        let commandBuffer: any MTLCommandBuffer = try #require(queue.makeCommandBuffer())
        pass.encode(from: input, to: output, in: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var result = [Float](repeating: 0, count: 4)
        result.withUnsafeMutableBytes { bytes in
            output.getBytes(bytes.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        }
        // Half the light is 0.5 linear, which the sRGB curve shows as 0.735,
        // not 0.5 (the average of the encoded values).
        #expect(abs(result[0] - Self.stormSRGB(0.5)) < 1e-4, "\(result)")
    }

    @Test("The default view transform is ACES 2.0 on the sRGB display")
    func standard() {
        #expect(ViewTransform.standard
            == ViewTransform(display: "sRGB - Display", view: "ACES 2.0 - SDR 100 nits (Rec.709)"))
        #expect(ViewTransform.standard?.isAvailable == true)
        #expect(!ViewTransform(display: "Rec.2100-PQ - Display", view: "Raw").isAvailable)
    }

    @Test("The studio image is a valid Radiance file, all grey, with soft boxes brighter than the walls")
    func studioImage() throws {
        let url: URL = try #require(StudioEnvironment.fileURL)
        let data = try Data(contentsOf: url)
        let header = "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 512 +X 1024\n"
        #expect(data.starts(with: Data(header.utf8)))
        #expect(data.count == header.utf8.count + 1024 * 512 * 4)
        // Every texel has R = G = B: the light adds no colour.
        let texels: Data = data.dropFirst(header.utf8.count)
        // SWIFT: `stride` over byte offsets, 4 bytes per texel.
        let grey: Bool = stride(from: texels.startIndex, to: texels.endIndex, by: 4).allSatisfy { index in
            texels[index] == texels[index + 1] && texels[index + 1] == texels[index + 2]
        }
        #expect(grey)
        // The key light's centre is many times brighter than a wall.
        let key: Float = StudioEnvironment.radiance(towards: StudioEnvironment.softBoxes[0].centre)
        // To the left of the default camera, level with the sphere: no
        // soft box there.
        let wall: Float = StudioEnvironment.radiance(towards: simd_normalize(SIMD3(-0.87, 0.05, 0.5)))
        #expect(key > 20 * wall, "key \(key), wall \(wall)")
        // RGBE round trip of one value: within its 8-bit mantissa.
        let encoded: [UInt8] = StudioEnvironment.rgbe(6, 6, 6)
        let decoded: Float = Float(encoded[0]) / 256 * Float(sign: .plus, exponent: Int(encoded[3]) - 128,
                                                              significand: 1)
        #expect(abs(decoded - 6) < 6.0 / 128, "\(encoded) → \(decoded)")
    }
}
