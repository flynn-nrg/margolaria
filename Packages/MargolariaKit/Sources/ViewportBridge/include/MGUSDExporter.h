// MGUSDExporter.h
//
// Writes a MaterialX document as USD (spike M5a, docs/spikes/M5a-usdz.md):
// the document's materials translated to UsdShade by OpenUSD's UsdMtlx
// plugin and written out (flattened), so the file stands alone; with a
// preview sphere bound to the first material if asked; as .usda, .usdc or
// .usdz (packaged with its textures).
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

@end

NS_ASSUME_NONNULL_END
