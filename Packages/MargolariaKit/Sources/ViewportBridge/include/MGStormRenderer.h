// MGStormRenderer.h
//
// Renders a .mtlx material on a preview sphere with Hydra Storm on Metal.
// This is the only code in ViewportKit that touches OpenUSD; ViewportKit
// (Swift) imports this header and sees an ordinary Objective-C class.
//
// Why Objective-C++ rather than C++ (as in MXBridge): the result of a render
// is a Metal texture, `id<MTLTexture>`, which OpenUSD only exposes through
// HgiMetal's Objective-C++ API. An Objective-C class hands it to Swift as a
// normal `MTLTexture` without any C++ types crossing the boundary.
//
// The header follows the same rules as MXBridge.h:
//
//  1. No OpenUSD headers. The USD stage and the Hydra engine are private
//     instance variables, declared only in MGStormRenderer.mm.
//  2. No exceptions cross into Swift. The initializer reports failures
//     through NSError, which Swift turns into a `throws` initializer.
//  3. Only Foundation and Metal types in the interface.
//
// Spike M0b (docs/spikes/M0b-storm-viewport.md).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// The NSError domain used by MGStormRenderer.
extern NSErrorDomain const MGStormRendererErrorDomain;

/// A Hydra Storm renderer for one material on a preview sphere.
///
/// It owns an in-memory USD stage containing a sphere, two lights and a
/// reference to the .mtlx file. OpenUSD's UsdMtlx plugin translates the
/// MaterialX document into UsdShade prims; one of its materials is bound to
/// the sphere (the first, unless bindMaterialAtPath: picks another).
///
/// Not thread-safe: use one renderer from one thread (the main thread, in the
/// app).
@interface MGStormRenderer : NSObject

/// Builds the stage and the Storm engine for the given .mtlx file.
/// Returns nil and sets `error` if the file contains no material.
- (nullable instancetype)initWithMaterialXFile:(NSURL *)fileURL
                                         error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// The Metal device Storm renders with.
@property (nonatomic, readonly) id<MTLDevice> device;

/// Storm's command queue. Work encoded on this queue after a render (copying
/// the texture to the screen, reading it back) runs after Storm's own work.
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;

/// The USD path of the material bound to the sphere, for example
/// "/World/MaterialX/Materials/M_BrushedCopper". The first material in the
/// file, until bindMaterialAtPath: chooses another.
@property (nonatomic, readonly) NSString *boundMaterialPath;

/// The USD paths of every material in the file, in file order. The last
/// path component is the MaterialX material's name.
@property (nonatomic, readonly) NSArray<NSString *> *materialPaths;

/// Binds the material at `path` (one of materialPaths) to the sphere.
/// Returns NO, and changes nothing, if there is no material there.
- (BOOL)bindMaterialAtPath:(NSString *)path;

/// The name of the Hydra renderer in use ("GL" for Storm, whatever its backend).
@property (nonatomic, readonly) NSString *rendererName;

/// Orbit camera, looking at the origin. Angles in degrees.
@property (nonatomic) double azimuth;
/// Height above the equator, in degrees. Clamped to ±89.
@property (nonatomic) double elevation;
/// Distance from the origin, in scene units. The sphere has radius 1.
@property (nonatomic) double distance;

/// Renders one frame of `width` × `height` pixels.
///
/// Returns Storm's colour output: an RGBA16Float texture, already converted to
/// sRGB for display. The texture belongs to Storm and is reused by the next
/// call, so copy it before rendering again. Returns nil if Storm produced no
/// output.
- (nullable id<MTLTexture>)renderWithWidth:(NSInteger)width height:(NSInteger)height;

/// True once Storm has finished all background work (shader compilation,
/// texture loading) for the last frame. Until then, rendering again may
/// produce a different image.
@property (nonatomic, readonly, getter=isConverged) BOOL converged;

@end

NS_ASSUME_NONNULL_END
