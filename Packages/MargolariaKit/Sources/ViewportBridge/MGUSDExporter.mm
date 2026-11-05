// MGUSDExporter.mm
//
// Implementation of MGUSDExporter (spike M5a). The stage is built as the
// viewport's is (MGStormRenderer.mm), from a file of the text, through
// UsdMtlx, then flattened: every opinion from the referenced .mtlx copied
// into one layer, so nothing refers to the MaterialX file any more.
//
//   MaterialX text ──file──▶ UsdMtlx ──reference──▶ stage (/World, sphere)
//                                                      │ Flatten()
//                                                      ▼
//                                   one layer ──Export──▶ .usda / .usdc
//                                             └─UsdUtils─▶ .usdz (textures packaged)

#import "MGUSDExporter.h"
#import "MGPreviewSphere.h"

#include <string>
#include <vector>

#include <pxr/pxr.h>
#include <pxr/base/tf/errorMark.h>
#include <pxr/base/tf/stringUtils.h>
#include <pxr/usd/sdf/attributeSpec.h>
#include <pxr/usd/sdf/primSpec.h>
#include <pxr/usd/sdf/layer.h>
#include <pxr/usd/usd/primRange.h>
#include <pxr/usd/usd/stage.h>
#include <pxr/usd/usdGeom/metrics.h>
#include <pxr/usd/usdGeom/xform.h>
#include <pxr/usd/usdShade/material.h>
#include <pxr/usd/usdShade/materialBindingAPI.h>
#include <pxr/usd/usdUtils/usdzPackage.h>
#include <pxr/usdValidation/usdValidation/context.h>
#include <pxr/usdValidation/usdValidation/registry.h>

PXR_NAMESPACE_USING_DIRECTIVE

namespace {

NSError *MakeError(const std::string &message) {
    return [NSError errorWithDomain:@"MGUSDExporterErrorDomain"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : @(message.c_str())}];
}

/// The messages of the errors posted since `mark`, one per line; cleared so
/// they aren't reported again.
std::string Messages(TfErrorMark &mark) {
    std::string messages;
    for (const TfError &error : mark) {
        messages += error.GetCommentary() + "\n";
    }
    mark.Clear();
    return messages;
}

/// Removes the shading inputs that have neither a value nor a connection.
/// UsdMtlx declares one for every nodedef input whose default is a
/// geometric property (`normal`, `tangent`: "the geometry's own"), with no
/// value. Storm reads that as the default; RealityKit (Quick Look) rejects
/// the whole material ("Value type for input is not valid") and draws
/// nothing. Left out, the input takes its default everywhere.
void RemoveInputsWithoutValues(const SdfLayerRefPtr &layer) {
    std::vector<SdfPath> unset;
    std::function<void(const SdfPrimSpecHandle &)> visit = [&](const SdfPrimSpecHandle &prim) {
        for (const SdfAttributeSpecHandle &attribute : prim->GetAttributes()) {
            if (TfStringStartsWith(attribute->GetName(), "inputs:") && !attribute->HasDefaultValue()
                && attribute->GetConnectionPathList().GetAddedOrExplicitItems().empty()) {
                unset.push_back(attribute->GetPath());
            }
        }
        for (const SdfPrimSpecHandle &child : prim->GetNameChildren()) {
            visit(child);
        }
    };
    for (const SdfPrimSpecHandle &prim : layer->GetRootPrims()) {
        visit(prim);
    }
    for (const SdfPath &path : unset) {
        SdfPrimSpecHandle owner = layer->GetPrimAtPath(path.GetPrimPath());
        if (SdfAttributeSpecHandle attribute = layer->GetAttributeAtPath(path)) {
            owner->RemoveProperty(attribute);
        }
    }
}

} // namespace

@implementation MGUSDExporter

+ (BOOL)exportMaterialXString:(NSString *)xml
                        toURL:(NSURL *)url
                previewSphere:(BOOL)previewSphere
                    packaging:(MGUSDZPackaging)packaging
                        error:(NSError **)error {
    // A folder of our own for the .mtlx (UsdMtlx reads files, and records
    // the file as the source of nodedefs the document defines) and the
    // flattened layer a USDZ is packaged from.
    NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *mtlxPath = [folder stringByAppendingPathComponent:@"material.mtlx"];
    if (![xml writeToFile:mtlxPath atomically:YES encoding:NSUTF8StringEncoding error:error]) {
        return NO;
    }

    TfErrorMark mark;
    UsdStageRefPtr stage = UsdStage::CreateInMemory();
    UsdGeomSetStageUpAxis(stage, UsdGeomTokens->y);
    // Decimetres: the radius-1 sphere is 20 cm across in AR (Quick Look
    // places objects at their real size).
    UsdGeomSetStageMetersPerUnit(stage, 0.1);
    UsdGeomXform world = UsdGeomXform::Define(stage, SdfPath("/World"));
    stage->SetDefaultPrim(world.GetPrim());
    UsdPrim materialX = stage->DefinePrim(SdfPath("/World/MaterialX"));
    // UsdMtlx puts everything under /MaterialX, and sets no default prim.
    materialX.GetReferences().AddReference(mtlxPath.fileSystemRepresentation, SdfPath("/MaterialX"));

    std::vector<UsdShadeMaterial> materials;
    for (const UsdPrim &prim : UsdPrimRange(materialX)) {
        if (prim.IsA<UsdShadeMaterial>()) {
            materials.push_back(UsdShadeMaterial(prim));
        }
    }
    if (materials.empty()) {
        if (error) {
            *error = MakeError("No material: " + Messages(mark));
        }
        return NO;
    }
    if (previewSphere) {
        UsdGeomMesh sphere = MGDefineSphereMesh(stage, SdfPath("/World/Sphere"));
        UsdShadeMaterialBindingAPI::Apply(sphere.GetPrim()).Bind(materials.front());
    }

    SdfLayerRefPtr flat = stage->Flatten();
    if (flat) {
        RemoveInputsWithoutValues(flat);
    }
    const std::string outPath = url.path.fileSystemRepresentation;
    bool written = false;
    if ([url.pathExtension.lowercaseString isEqualToString:@"usdz"]) {
        NSString *rootPath = [folder stringByAppendingPathComponent:@"root.usdc"];
        if (flat && flat->Export(rootPath.fileSystemRepresentation)) {
            const SdfAssetPath asset(rootPath.fileSystemRepresentation);
            written = packaging == MGUSDZPackagingARKit ? UsdUtilsCreateNewARKitUsdzPackage(asset, outPath)
                                                        : UsdUtilsCreateNewUsdzPackage(asset, outPath);
        }
    } else {
        written = flat && flat->Export(outPath);
    }
    [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
    // Warnings (posted as TfWarning, not errors) don't stop the export.
    const std::string messages = Messages(mark);
    if (!written) {
        if (error) {
            *error = MakeError(messages.empty() ? "OpenUSD could not write the file" : messages);
        }
        return NO;
    }
    return YES;
}

+ (NSArray<NSString *> *)validationMessagesForFileAtURL:(NSURL *)url {
    NSMutableArray<NSString *> *messages = [NSMutableArray array];
    TfErrorMark mark;
    UsdStageRefPtr stage = UsdStage::Open(url.path.fileSystemRepresentation);
    if (!stage) {
        [messages addObject:[@"Can't open: " stringByAppendingString:@(Messages(mark).c_str())]];
        return messages;
    }
    UsdValidationContext context(UsdValidationRegistry::GetInstance().GetOrLoadAllValidators());
    for (const UsdValidationError &problem : context.Validate(stage)) {
        if (problem.GetType() == UsdValidationErrorType::None) {
            continue;
        }
        [messages addObject:@(problem.GetErrorAsString().c_str())];
    }
    mark.Clear();
    return messages;
}

+ (NSArray<NSString *> *)assetPathsInFileAtURL:(NSURL *)url {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    TfErrorMark mark;
    SdfLayerRefPtr layer = SdfLayer::FindOrOpen(url.path.fileSystemRepresentation);
    if (!layer) {
        mark.Clear();
        return paths;
    }
    // Every asset-valued attribute default (the textures' `inputs:file`).
    std::function<void(const SdfPrimSpecHandle &)> visit = [&](const SdfPrimSpecHandle &prim) {
        for (const SdfAttributeSpecHandle &attribute : prim->GetAttributes()) {
            const VtValue value = attribute->GetDefaultValue();
            if (value.IsHolding<SdfAssetPath>()) {
                [paths addObject:@(value.UncheckedGet<SdfAssetPath>().GetAssetPath().c_str())];
            }
        }
        for (const SdfPrimSpecHandle &child : prim->GetNameChildren()) {
            visit(child);
        }
    };
    for (const SdfPrimSpecHandle &prim : layer->GetRootPrims()) {
        visit(prim);
    }
    mark.Clear();
    return paths;
}

@end
