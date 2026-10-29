// Snapshot.swift
//
// Renders a still image with MGStormRenderer, offscreen. Used by the tests to
// check a render without opening a window, and a starting point for the
// thumbnails in M3. Finished the same way as the viewport's frames, by
// DisplayPass: rendered at twice the size and scaled down, and converted
// for the screen by an OCIO view transform (M3b).
//
// Introduces (SWIFT): importing an Objective-C module, how Objective-C names
// and nullability appear in Swift, `extension`, `public`, `while` loops,
// Core Image interop with Metal.

import CoreImage
import Metal

// SWIFT: ViewportBridge is an Objective-C module (its header is in
// Sources/ViewportBridge/include). Swift imports Objective-C classes directly:
// `MGStormRenderer` becomes a Swift class, `-initWithMaterialXFile:error:`
// becomes `init(materialXFile:) throws`, and `nullable` return types become
// optionals. It is the same machinery as using AppKit from Swift.
//
// `@_exported` re-exports the module: anything that imports ViewportKit sees
// MGStormRenderer too, without a second import. The underscore marks it as
// officially unsupported, but it is widely used and stable in practice.
@_exported import ViewportBridge

// SWIFT: An `extension` adds methods to an existing type, here a class
// defined in Objective-C. It is the Swift equivalent of an Objective-C
// category. Extensions can't add stored properties, only methods and
// computed properties.
extension MGStormRenderer {
    /// Renders a still image, rendering repeatedly until Storm reports that
    /// background work (shader compilation, texture loading) is done.
    ///
    /// `viewTransform` converts Storm's light for the screen; the image is
    /// in that display's colour space. The default is the config's (ACES
    /// 2.0 on sRGB), as in the viewport. With nil, or without colour
    /// management, the image is Storm's own sRGB encoding.
    ///
    /// Returns nil if Storm produced no image.
    ///
    /// SWIFT: `public` makes the method visible outside the ViewportKit
    /// module. The default access level, `internal`, is visible only inside
    /// the module, like a symbol that isn't exported from a C library.
    public func snapshot(width: Int, height: Int, maxPasses: Int = 20,
                         viewTransform: ViewportViewTransform? = .standard) -> CGImage? {
        // SWIFT: `flatMap` on an optional runs the closure only when there
        // is a value; `try?` turns each failure into nil.
        let transformed: DisplayPass? = viewTransform.flatMap { transform in
            (try? transform.shader()).flatMap { try? DisplayPass(device: device, pixelFormat: .rgba16Float,
                                                                 transform: $0) }
        }
        guard let pass = transformed ?? (try? DisplayPass(device: device, pixelFormat: .rgba16Float)) else {
            return nil
        }

        // SWIFT: `var` because it changes in the loop. `MTLTexture?` is an
        // optional: either a texture or nil. Objective-C's `nullable id<MTLTexture>`
        // arrives in Swift as `(any MTLTexture)?`.
        var texture: (any MTLTexture)? = nil
        var passes: Int = 0
        let factor: Int = DisplayPass.factor
        // SWIFT: `repeat { } while` is C's `do { } while`.
        repeat {
            texture = render(withWidth: width * factor, height: height * factor)
            passes += 1
        } while !isConverged && passes < maxPasses

        // SWIFT: `guard let` unwraps an optional or leaves the function. After
        // this line, `big` is a plain non-optional texture.
        guard let big = texture, let small = finish(big, with: pass, width: width, height: height) else {
            return nil
        }

        // Core Image reads the texture on Storm's own queue, so it waits for
        // Storm's commands to finish before reading.
        let context: CIContext = CIContext(mtlCommandQueue: commandQueue)
        // The pixels are encoded for the transform's display (or as sRGB by
        // Storm), so tell Core Image that is the colour space they are in,
        // and keep it in the image.
        let space: CGColorSpace = (transformed != nil ? viewTransform?.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // SWIFT: `[.colorSpace: space]` is a dictionary literal, and
        // `.colorSpace` is short for `CIImageOption.colorSpace`.
        guard let image = CIImage(mtlTexture: small, options: [.colorSpace: space]) else {
            return nil
        }
        // Metal textures store the top row first; Core Image puts its origin
        // at the bottom left. Flip vertically so the snapshot is upright.
        let upright: CIImage = image.oriented(.downMirrored)
        return context.createCGImage(upright, from: upright.extent, format: .RGBA8, colorSpace: space)
    }

    /// `texture` scaled down to `width` × `height` and converted by `pass`,
    /// in a new texture. Nil if Metal can't do it.
    private func finish(_ texture: any MTLTexture, with pass: DisplayPass,
                        width: Int, height: Int) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat,
                                                                  width: width, height: height, mipmapped: false)
        // Drawn into by the pass, then read by Core Image.
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return nil
        }
        pass.encode(from: texture, to: target, in: commandBuffer)
        commandBuffer.commit()
        return target
    }
}
