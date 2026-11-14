// MGUSDExporter.h
//
// Writes a MaterialX document as USD: the document's materials translated
// to UsdShade by OpenUSD's UsdMtlx plugin and written out (flattened), so
// the file stands alone.
//
//  - File > Export as USD… (M5b): the materials only, as .usda or .usdc,
//    for referencing into a scene.
//  - File > Export as USDZ… (M5c, after spike M5a, docs/spikes/M5a-usdz.md):
//    a preview shape (a sphere, or since M7a the viewport's) with the
//    materials, packaged with their textures,
//    for Quick Look and Reality Composer Pro.
//
// Same rules as MGStormRenderer.h: no OpenUSD headers, no exceptions, only
// Foundation types.

#import <Foundation/Foundation.h>

#import "MGPreviewShape.h"

NS_ASSUME_NONNULL_BEGIN

@interface MGUSDExporter : NSObject

/// Writes the materials of the MaterialX document `xml` to `url` as USD
/// (M5b), in the format the extension names (.usda text, .usdc or .usd
/// binary). The text must stand on its own: MXKit's `usdXMLString()`.
///
/// The file holds what UsdMtlx makes of the document, under one prim,
/// `/MaterialX` (the default prim, so a reference needs no prim path):
/// `Materials/<name>` (each Material with its shaders and nodegraphs),
/// `Shaders`, `NodeGraphs`. Nothing refers to the MaterialX text. Inputs
/// UsdMtlx declares without a value (`normal`, `tangent`) are left out.
/// Textures in `url`'s folder, or in folders inside it, are referred to
/// relative to the file (`./textures/brick.jpg`), so the folder can be
/// moved; others keep their absolute paths.
///
/// Returns NO, with OpenUSD's messages in `error`, if anything failed.
+ (BOOL)exportMaterialsFromMaterialXString:(NSString *)xml
                                     toURL:(NSURL *)url
                                     error:(NSError **)error;

/// Writes the MaterialX document `xml` to `url` as a USDZ package (M5c),
/// for Quick Look and Reality Composer Pro. The text must stand on its
/// own: MXKit's `usdzXMLString()`.
///
/// The scene is `shape`, about 20 cm across (decimetres, Y up), named
/// after it (`/World/Sphere`, `/World/ShaderBall` ...: MGPreviewShape.h),
/// bound to the material named `materialName` (the first if nil or not
/// found), and every material under `/World/MaterialX/Materials`, for
/// binding in Reality Composer Pro. Every texture is copied into the
/// package, by relative path, with UsdUtils' ARKit packaging (one layer,
/// checked against what ARKit accepts). Inputs without a value are left
/// out: RealityKit draws nothing for a material that has one.
///
/// Returns NO, with OpenUSD's messages in `error`, if anything failed.
+ (BOOL)exportPreviewFromMaterialXString:(NSString *)xml
                                   toURL:(NSURL *)url
                            materialName:(nullable NSString *)materialName
                                   shape:(MGPreviewShape)shape
                                   error:(NSError **)error;

/// Every problem OpenUSD's validators (all of those registered) find in
/// the file at `url`, one message each, prefixed by the validator's name.
+ (NSArray<NSString *> *)validationMessagesForFileAtURL:(NSURL *)url;

/// Every file a USD file depends on, by asset path as written (textures,
/// sublayers, references), to see what a USDZ will carry.
+ (NSArray<NSString *> *)assetPathsInFileAtURL:(NSURL *)url;

/// The files inside the USDZ package at `url`, by path in the package
/// (the layer first, then "0/brick.jpg" ...). Empty if it can't be read.
+ (NSArray<NSString *> *)filesInPackageAtURL:(NSURL *)url;

/// The layers OpenUSD reads to compose the file at `url`, by identifier
/// (its own and any it refers to; no session layer). One, the file
/// itself, for a file that stands alone.
+ (NSArray<NSString *> *)layersUsedByFileAtURL:(NSURL *)url;

/// The shading prims of the USD (or MaterialX, through UsdMtlx) file at
/// `url`, as text to compare two files by (M5b's tests), keyed by path:
///
///  - each prim at its path, as its type name ("Material", "Shader");
///  - each attribute with a value or a connection at its path, as its
///    value (asset paths resolved: where the file is, however it is
///    written), then its connections' paths.
///
/// Attributes with neither are left out: they say nothing. Returns nil,
/// with OpenUSD's messages in `error`, if the file can't be opened.
+ (nullable NSDictionary<NSString *, NSString *> *)shadingOfFileAtURL:(NSURL *)url
                                                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
