// MGUSDExporter.h
//
// Writes a MaterialX document as USD: the document's materials translated
// to UsdShade by OpenUSD's UsdMtlx plugin and written out (flattened), so
// the file stands alone.
//
//  - File > Export as USD… (M5b): the materials only, as .usda or .usdc,
//    for referencing into a scene.
//  - Spike M5a (docs/spikes/M5a-usdz.md), which M5c turns into Export as
//    USDZ…: with a preview sphere bound to the first material, as .usda
//    or .usdz (packaged with its textures).
//
// Same rules as MGStormRenderer.h: no OpenUSD headers, no exceptions, only
// Foundation types.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// How a USDZ is packaged.
typedef NS_ENUM(NSInteger, MGUSDZPackaging) {
    /// UsdUtilsCreateNewUsdzPackage: the layer and its dependencies, as they are.
    MGUSDZPackagingPlain,
    /// UsdUtilsCreateNewARKitUsdzPackage: flattened into one layer first, and
    /// checked against what ARKit (Quick Look) accepts.
    MGUSDZPackagingARKit,
};

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

/// Writes the MaterialX document `xml` to `url` as USD; the format follows
/// the extension (.usda, .usdc, .usdz). The text must stand on its own (no
/// includes, absolute texture paths: MXKit's preview text). With
/// `previewSphere`, the stage has a sphere bound to the first material.
/// Returns NO, with OpenUSD's messages in `error`, if anything failed.
+ (BOOL)exportMaterialXString:(NSString *)xml
                        toURL:(NSURL *)url
                previewSphere:(BOOL)previewSphere
                    packaging:(MGUSDZPackaging)packaging
                        error:(NSError **)error;

/// Every problem OpenUSD's validators (all of those registered) find in
/// the file at `url`, one message each, prefixed by the validator's name.
+ (NSArray<NSString *> *)validationMessagesForFileAtURL:(NSURL *)url;

/// Every file a USD file depends on, by asset path as written (textures,
/// sublayers, references), to see what a USDZ will carry.
+ (NSArray<NSString *> *)assetPathsInFileAtURL:(NSURL *)url;

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
