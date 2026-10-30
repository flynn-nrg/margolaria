// SwatchEnvironment.swift
//
// The environment that lights swatches: one HDR image in two forms, as
// MaterialX's surface shaders expect them (u_envRadiance and u_envIrradiance):
//
//   radiance    the full latitude-longitude image with a mip chain; shaders
//               sample blurrier mips for rougher reflections.
//   irradiance  a small latitude-longitude map of the diffuse light: for
//               each direction, the light arriving from the whole
//               hemisphere around it, weighted by the cosine of its angle
//               (and divided by π, so a white diffuse surface shows the
//               map's value). Since M3c a real cosine convolution, computed
//               on the CPU; until then a blur (M0c), which made diffuse
//               shading flatter than the viewport's.
//
// The image is the viewport's (M3c): the studio by default
// (StudioEnvironment), or OpenUSD's outdoor StinsonBeach.hdr, so a node's
// swatch and the viewport see the same light.
//
// Orientation. MaterialX's shaders look a direction up in a lat-long image
// with their own convention (mx_latlong_projection: the first texture row
// is straight up, the middle column is -Z), and Storm with another (the
// first row stored in the file is straight down, the first column -Z;
// StudioEnvironment.direction). `matrix`, which shaders apply to every
// direction before the lookup (u_envMatrix), converts one into the other.
//
// Introduces (SWIFT): `static let` caching in a type, Core Image filters
// (M0c); `Float16` (M3c).

import CoreImage
import Foundation
import Metal
import simd

/// The radiance and irradiance textures, created once per environment.
struct SwatchEnvironment {
    /// Lat-long radiance, RGBA16Float, mipmapped.
    let radiance: any MTLTexture
    /// Small lat-long irradiance (divided by π), RGBA16Float.
    let irradiance: any MTLTexture
    /// The image both were made from.
    let imageURL: URL

    /// What the shaders apply to a direction before looking it up
    /// (u_envMatrix), so that the image lights the swatch as Storm's dome
    /// light shows it in the viewport.
    ///
    /// The textures hold the image's rows in the order they are stored, so
    /// the first row (Storm's straight down) is where MaterialX looks for
    /// straight up: y is negated. Along a row, Storm's -Z is the first
    /// column and MaterialX's the middle one: half a turn around Y, which
    /// negates x and z. Negating all three maps each direction to its
    /// opposite. (A reflection, not a rotation, but a direction lookup
    /// doesn't care.) Checked by rendering a mirror sphere both ways
    /// (ViewportKit's SwatchAgreementTests).
    static let matrix: simd_float4x4 = simd_float4x4(diagonal: SIMD4(-1, -1, -1, 1))

    /// Where StinsonBeach.hdr lives: inside the Usd_Plug framework that
    /// SwiftUsd ships, found by bundle identifier (see MXLibrary.swift for why
    /// identifiers and not folder names).
    static func defaultImageURL() throws -> URL {
        guard let bundle = Bundle(identifier: "com.pixar.Usd-Plug"),
              let resources = bundle.resourceURL
        else {
            throw PreviewError.resourceNotFound("the Usd_Plug framework (com.pixar.Usd-Plug)")
        }
        let url: URL = resources.appendingPathComponent("usd/hdx/Resources/textures/StinsonBeach.hdr")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PreviewError.resourceNotFound(url.path)
        }
        return url
    }

    /// The size of the irradiance map, and of the copy of the image it is
    /// computed from. Diffuse light changes slowly with direction, so a
    /// small map is enough; 32 × 16 output texels from 64 × 32 input ones
    /// is about a million multiplications, a millisecond or two.
    static let irradianceSize: (width: Int, height: Int) = (32, 16)
    static let convolutionSize: (width: Int, height: Int) = (64, 32)

    /// Loads `imageURL` (any format ImageIO reads, including Radiance .hdr)
    /// and builds both textures on `queue`'s device.
    init(imageURL: URL, queue: any MTLCommandQueue) throws {
        let device: any MTLDevice = queue.device
        self.imageURL = imageURL

        // Keep the pixel values linear and unclamped: they are light
        // intensities, many of them far above 1.0.
        let linear: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let loaded = CIImage(contentsOf: imageURL, options: [.colorSpace: linear]) else {
            throw PreviewError.resourceNotFound(imageURL.path)
        }
        // Core Image's origin is bottom-left, Metal's is top-left. Flip, so
        // texture row 0 is the image's first stored row.
        let image: CIImage = loaded.oriented(.downMirrored)

        let context = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: linear])

        radiance = try Self.render(image, width: Int(image.extent.width), height: Int(image.extent.height),
                                   mipmapped: true, readable: false, context: context, queue: queue,
                                   device: device)

        // A small copy, averaged down with Lanczos filtering so that small
        // bright spots (the sun, a soft box's edge) aren't missed, read back
        // to the CPU for the convolution.
        let (width, height) = Self.convolutionSize
        let small: CIImage = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: Double(height) / image.extent.height,
            kCIInputAspectRatioKey: (Double(width) / image.extent.width) / (Double(height) / image.extent.height),
        ])
        let smallTexture: any MTLTexture = try Self.render(small, width: width, height: height, mipmapped: false,
                                                           readable: true, context: context, queue: queue,
                                                           device: device)
        let texels: [SIMD4<Float>] = Self.read(smallTexture)
        irradiance = try Self.upload(Self.convolve(texels, width: width, height: height), device: device)
    }

    // MARK: Irradiance

    /// The direction a lat-long texel shows, in the shaders' convention
    /// (mx_latlong_projection, before `matrix`): row 0 is straight up, and
    /// along a row u = 0.25 is -X, 0.5 is -Z, 0.75 is +X.
    static func latLongDirection(column: Int, row: Int, width: Int, height: Int) -> SIMD3<Float> {
        let u: Float = (Float(column) + 0.5) / Float(width)
        let v: Float = (Float(row) + 0.5) / Float(height)
        // mx_latlong_projection inverted: v = 0.5 - asin(y) / π, and
        // u = atan2(x, -z) / 2π + 0.5.
        let latitude: Float = (0.5 - v) * .pi
        let longitude: Float = (u - 0.5) * 2 * .pi
        return SIMD3(cos(latitude) * sin(longitude), sin(latitude), -cos(latitude) * cos(longitude))
    }

    /// The irradiance map of a lat-long image: for each output direction N,
    /// (1/π) Σ L(ω) max(0, N·ω) dω over the image's texels.
    ///
    /// Both images are in the same convention, so `matrix` doesn't matter
    /// here: a reflection keeps angles between directions.
    static func convolve(_ texels: [SIMD4<Float>], width: Int, height: Int) -> [SIMD4<Float>] {
        // Each input texel's direction, and its radiance times its solid
        // angle (texels near the poles cover less of the sphere).
        var directions: [SIMD3<Float>] = []
        var weighted: [SIMD3<Float>] = []
        directions.reserveCapacity(width * height)
        weighted.reserveCapacity(width * height)
        let texelAngle: Float = (2 * .pi / Float(width)) * (.pi / Float(height))
        for row in 0..<height {
            let latitude: Float = (0.5 - (Float(row) + 0.5) / Float(height)) * .pi
            for column in 0..<width {
                let texel: SIMD4<Float> = texels[row * width + column]
                directions.append(latLongDirection(column: column, row: row, width: width, height: height))
                // SWIFT: `SIMD3(texel.x, texel.y, texel.z)` keeps RGB, and
                // drops alpha.
                weighted.append(SIMD3(texel.x, texel.y, texel.z) * (texelAngle * cos(latitude)))
            }
        }

        let (outWidth, outHeight) = irradianceSize
        var result: [SIMD4<Float>] = []
        result.reserveCapacity(outWidth * outHeight)
        for row in 0..<outHeight {
            for column in 0..<outWidth {
                let normal: SIMD3<Float> = latLongDirection(column: column, row: row,
                                                            width: outWidth, height: outHeight)
                var sum = SIMD3<Float>(repeating: 0)
                // SWIFT: `indices` is 0..<count; `zip` would work too.
                for index in directions.indices {
                    let cosine: Float = simd_dot(normal, directions[index])
                    if cosine > 0 {
                        sum += weighted[index] * cosine
                    }
                }
                result.append(SIMD4(sum / .pi, 1))
            }
        }
        return result
    }

    // MARK: Textures

    /// Renders a Core Image image into a new RGBA16Float texture
    /// (RGBA32Float if `readable`, to read back exactly).
    private static func render(_ image: CIImage, width: Int, height: Int, mipmapped: Bool, readable: Bool,
                               context: CIContext, queue: any MTLCommandQueue,
                               device: any MTLDevice) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: readable ? .rgba32Float : .rgba16Float, width: width, height: height,
            mipmapped: mipmapped)
        // Core Image writes with a compute shader, so the texture needs
        // shaderWrite as well as shaderRead.
        descriptor.usage = [.shaderRead, .shaderWrite]
        // Shared: the CPU can read it after the GPU has written it.
        descriptor.storageMode = readable ? .shared : .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer()
        else {
            throw PreviewError.metal("Could not create the environment texture")
        }
        context.render(image, to: texture, commandBuffer: commandBuffer,
                       bounds: image.extent,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        if mipmapped, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
        commandBuffer.commit()
        if readable {
            commandBuffer.waitUntilCompleted()
        }
        return texture
    }

    /// The texels of an RGBA32Float texture with shared storage, row by row.
    private static func read(_ texture: any MTLTexture) -> [SIMD4<Float>] {
        // SWIFT: `SIMD4<Float>` is 16 bytes, laid out as four floats, the
        // same as one RGBA32Float texel, so the array's storage can receive
        // the texture's bytes directly.
        var texels = [SIMD4<Float>](repeating: .zero, count: texture.width * texture.height)
        texels.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 16,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return texels
    }

    /// The irradiance map as an RGBA16Float texture (half floats are
    /// plenty for light that is averaged over a hemisphere).
    private static func upload(_ texels: [SIMD4<Float>], device: any MTLDevice) throws -> any MTLTexture {
        let (width, height) = irradianceSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PreviewError.metal("Could not create the irradiance texture")
        }
        // SWIFT: `Float16` is Swift's half-precision float, the same 16 bits
        // as Metal's `half`.
        let halves: [Float16] = texels.flatMap { [Float16($0.x), Float16($0.y), Float16($0.z), Float16($0.w)] }
        halves.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: width * 8)
        }
        return texture
    }
}
