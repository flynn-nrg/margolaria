// SwatchEnvironment.swift
//
// The environment that lights swatches: one HDR image in two forms, as
// MaterialX's surface shaders expect them (u_envRadiance and u_envIrradiance):
//
//   radiance    the full latitude-longitude image with a mip chain; shaders
//               sample blurrier mips for rougher reflections.
//   irradiance  a tiny, heavily blurred copy, standing in for the diffuse
//               lighting. A proper one would be a cosine convolution; a blur
//               is close enough for a swatch (M3 can do better).
//
// The image is OpenUSD's default dome light texture (StinsonBeach.hdr), the
// one the Storm viewport uses, so swatches and viewport see the same light.
//
// Introduces (SWIFT): `static let` caching in a type, Core Image filters.

import CoreImage
import Foundation
import Metal

/// The radiance and irradiance textures, created once per device.
struct SwatchEnvironment {
    /// Lat-long radiance, RGBA16Float, mipmapped.
    let radiance: any MTLTexture
    /// Small blurred lat-long irradiance, RGBA16Float.
    let irradiance: any MTLTexture

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

    /// Loads `imageURL` (any format ImageIO reads, including Radiance .hdr)
    /// and builds both textures on `queue`'s device.
    init(imageURL: URL, queue: any MTLCommandQueue) throws {
        let device: any MTLDevice = queue.device

        // Keep the pixel values linear and unclamped: they are light
        // intensities, many of them far above 1.0.
        let linear: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let loaded = CIImage(contentsOf: imageURL, options: [.colorSpace: linear]) else {
            throw PreviewError.resourceNotFound(imageURL.path)
        }
        // Core Image's origin is bottom-left, Metal's is top-left. Flip, so
        // row 0 of the texture is the top of the image (the sky), as the
        // shaders' lat-long lookup expects.
        let image: CIImage = loaded.oriented(.downMirrored)

        let context = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: linear])

        radiance = try Self.render(image, width: Int(image.extent.width), height: Int(image.extent.height),
                                   mipmapped: true, context: context, queue: queue, device: device)

        // Irradiance: shrink to 32 × 16, then blur. `clampedToExtent` repeats
        // the edge pixels outwards so the blur doesn't darken the borders.
        let small: CIImage = image.transformed(by: CGAffineTransform(scaleX: 32 / image.extent.width,
                                                                      y: 16 / image.extent.height))
        let blurred: CIImage = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 4)
            .cropped(to: small.extent)
        irradiance = try Self.render(blurred, width: 32, height: 16,
                                     mipmapped: false, context: context, queue: queue, device: device)
    }

    /// Renders a Core Image image into a new RGBA16Float texture.
    private static func render(_ image: CIImage, width: Int, height: Int, mipmapped: Bool,
                               context: CIContext, queue: any MTLCommandQueue,
                               device: any MTLDevice) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: mipmapped)
        // Core Image writes with a compute shader, so the texture needs
        // shaderWrite as well as shaderRead.
        descriptor.usage = [.shaderRead, .shaderWrite]
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
        return texture
    }
}
