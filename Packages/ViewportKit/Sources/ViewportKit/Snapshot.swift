// Snapshot.swift
//
// Renders a still image with MGStormRenderer, offscreen. Used by the tests to
// check a render without opening a window, and a starting point for the
// thumbnails in M3.
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
    /// Returns nil if Storm produced no image.
    ///
    /// SWIFT: `public` makes the method visible outside the ViewportKit
    /// module. The default access level, `internal`, is visible only inside
    /// the module, like a symbol that isn't exported from a C library.
    public func snapshot(width: Int, height: Int, maxPasses: Int = 20) -> CGImage? {
        // SWIFT: `var` because it changes in the loop. `MTLTexture?` is an
        // optional: either a texture or nil. Objective-C's `nullable id<MTLTexture>`
        // arrives in Swift as `(any MTLTexture)?`.
        var texture: (any MTLTexture)? = nil
        var passes: Int = 0
        // SWIFT: `repeat { } while` is C's `do { } while`.
        repeat {
            texture = render(withWidth: width, height: height)
            passes += 1
        } while !isConverged && passes < maxPasses

        // SWIFT: `guard let` unwraps an optional or leaves the function. After
        // this line, `texture` is a plain non-optional texture.
        guard let texture else {
            return nil
        }

        // Core Image reads the texture on Storm's own queue, so it waits for
        // Storm's commands to finish before reading.
        let context: CIContext = CIContext(mtlCommandQueue: commandQueue)
        // Storm's colour correction already encoded the pixels as sRGB, so
        // tell Core Image that is the colour space they are in.
        let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        // SWIFT: `[.colorSpace: sRGB]` is a dictionary literal, and
        // `.colorSpace` is short for `CIImageOption.colorSpace`.
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: sRGB]) else {
            return nil
        }
        // Metal textures store the top row first; Core Image puts its origin
        // at the bottom left. Flip vertically so the snapshot is upright.
        let upright: CIImage = image.oriented(.downMirrored)
        return context.createCGImage(upright, from: upright.extent, format: .RGBA8, colorSpace: sRGB)
    }
}
