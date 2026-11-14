// MGStormRenderer.h
//
// Renders a MaterialX material (from a .mtlx file, or from XML text) on a
// preview shape with Hydra Storm on Metal: a sphere, or since M7a another
// of MGPreviewShape.h's.
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
// Spike M0b (docs/spikes/M0b-storm-viewport.md). Since M5e, it can render
// with another Hydra renderer plugin instead of Storm (setRendererID:error:,
// Embree in SwiftUsd); the class keeps its name.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "MGPreviewShape.h"

NS_ASSUME_NONNULL_BEGIN

/// The NSError domain used by MGStormRenderer.
extern NSErrorDomain const MGStormRendererErrorDomain;

/// A Hydra Storm renderer for one material on a preview shape.
///
/// It owns an in-memory USD stage containing the shape (a mesh at
/// /World/Shape, a sphere until `shape` is set), two lights (a key
/// light and a dome light for the environment) and a
/// reference to the .mtlx file (or to MaterialX text, kept in a temporary file). OpenUSD's UsdMtlx plugin translates the
/// MaterialX document into UsdShade prims; one of its materials is bound to
/// the shape (the first, unless bindMaterialAtPath: picks another).
///
/// Not thread-safe: use one renderer from one thread (the main thread, in the
/// app).
@interface MGStormRenderer : NSObject

/// Builds the stage and the Storm engine for the given .mtlx file, or a
/// USD file exported by MGUSDExporter (its materials are under /MaterialX,
/// as UsdMtlx puts a .mtlx's; M5b's tests render those). Returns nil and
/// sets `error` if the file contains no material.
- (nullable instancetype)initWithMaterialXFile:(NSURL *)fileURL
                                         error:(NSError **)error NS_DESIGNATED_INITIALIZER;

/// Builds the stage and the Storm engine for a MaterialX document given as
/// XML text, such as a document being edited (M2c). The text must stand on
/// its own: no `xi:include`, absolute texture paths (MXKit's
/// `previewXMLString()` writes it so). It is kept in a temporary file of
/// the renderer's own, deleted with the renderer. Returns nil and sets
/// `error` if it can't be read or contains no material.
- (nullable instancetype)initWithMaterialXString:(NSString *)xml
                                           error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// The Metal device Storm renders with.
@property (nonatomic, readonly) id<MTLDevice> device;

/// Storm's command queue. Work encoded on this queue after a render (copying
/// the texture to the screen, reading it back) runs after Storm's own work.
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;

/// The USD path of the material bound to the shape, for example
/// "/World/MaterialX/Materials/M_BrushedCopper". The first material in the
/// file, until bindMaterialAtPath: chooses another. Empty if an update
/// left no material to show.
@property (nonatomic, readonly) NSString *boundMaterialPath;

/// The USD paths of every material in the file, in file order. The last
/// path component is the MaterialX material's name.
@property (nonatomic, readonly) NSArray<NSString *> *materialPaths;

/// Binds the material at `path` (one of materialPaths) to the shape.
/// Returns NO, and changes nothing, if there is no material there.
- (BOOL)bindMaterialAtPath:(NSString *)path;

/// Replaces the document shown with `xml` (a renderer made from text
/// only). The next render shows the change. The bound material stays bound
/// if it still exists; otherwise the first material is bound, or none.
/// Returns NO and sets `error`, keeping what was shown, if the text can't
/// be read.
- (BOOL)updateMaterialXString:(NSString *)xml error:(NSError **)error;

/// The shape the material is shown on (M7a): the sphere until set. The
/// material shown stays bound; the camera stays where it is.
@property (nonatomic) MGPreviewShape shape;

/// The latitude-longitude HDR image lighting the shape (the dome light's
/// texture), or nil for OpenUSD's default, an outdoor scene
/// ("StinsonBeach.hdr", as in usdview). Nil until set.
@property (nonatomic, copy, nullable) NSURL *environmentURL;

/// Whether the distant key light shines, as well as the environment. YES
/// until set. An environment with its own bright lights (a studio's soft
/// boxes) needs none.
@property (nonatomic) BOOL keyLightEnabled;

/// The name of the Hydra renderer in use ("GL" for Storm, whatever its backend).
@property (nonatomic, readonly) NSString *rendererName;

/// The identifier of the Hydra renderer plugin in use, such as
/// "HdStormRendererPlugin". Storm until setRendererID:error: changes it.
@property (nonatomic, readonly) NSString *rendererID;

/// The identifiers of every Hydra renderer plugin found (M5e), such as
/// "HdStormRendererPlugin" and "HdEmbreeRendererPlugin", best first.
@property (class, nonatomic, readonly) NSArray<NSString *> *availableRendererIDs;

/// The name a renderer plugin gives itself, such as "Embree", for a picker.
+ (NSString *)displayNameForRendererID:(NSString *)rendererID;

/// Renders with the Hydra renderer plugin `rendererID` (one of
/// availableRendererIDs) from the next frame on. The stage, camera and
/// lights stay; the renderer reads the scene afresh. Returns NO and sets
/// `error`, keeping the current renderer, if it can't be loaded.
- (BOOL)setRendererID:(NSString *)rendererID error:(NSError **)error;

/// Orbit camera, looking at the origin. Angles in degrees.
@property (nonatomic) double azimuth;
/// Height above the equator, in degrees. Clamped to ±89.
@property (nonatomic) double elevation;
/// Distance from the origin, in scene units. The sphere has radius 1, and
/// the other shapes about the same room.
@property (nonatomic) double distance;

/// Renders one frame of `width` × `height` pixels.
///
/// Returns Storm's colour output: an RGBA16Float texture of scene-linear
/// light (lin_rec709) encoded with the sRGB curve, unclamped (values above
/// 1 stay above 1). Negative components, which the curve can't encode,
/// come out as NaN. Decode it to get the linear light back (ViewportKit's
/// DisplayPass does, before its view transform). The texture belongs to
/// Storm and is reused by the next call, so copy it before rendering again.
/// Returns nil if Storm produced no output.
- (nullable id<MTLTexture>)renderWithWidth:(NSInteger)width height:(NSInteger)height;

/// True once Storm has finished all background work (shader compilation,
/// texture loading) for the last frame. Until then, rendering again may
/// produce a different image.
@property (nonatomic, readonly, getter=isConverged) BOOL converged;

@end

NS_ASSUME_NONNULL_END
