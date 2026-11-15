// MGUSDExporter.mm
//
// Implementation of MGUSDExporter (M5b, and spike M5a). The stage is built
// as the viewport's is (MGStormRenderer.mm), from a file of the text,
// through UsdMtlx, then flattened: every opinion from the referenced .mtlx
// copied into one layer, so nothing refers to the MaterialX file any more.
//
//   MaterialX text ──file──▶ UsdMtlx ──reference──▶ stage (/MaterialX,
//                                                      │  or /World with a shape)
//                                                      │ Flatten()
//                                                      ▼
//                                   one layer ──Export──▶ .usda / .usdc
//                                             └─UsdUtils─▶ .usdz (textures packaged)

#import "MGUSDExporter.h"
#import "MGPreviewShapes.h"

#include <cstdio>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include <pxr/pxr.h>
#include <pxr/base/tf/diagnosticMgr.h>
#include <pxr/base/tf/errorMark.h>
#include <pxr/base/tf/pathUtils.h>
#include <pxr/base/tf/stringUtils.h>
#include <pxr/usd/sdf/attributeSpec.h>
#include <pxr/usd/sdf/primSpec.h>
#include <pxr/usd/sdf/layer.h>
#include <pxr/usd/usd/primRange.h>
#include <pxr/usd/usd/stage.h>
#include <pxr/usd/sdf/zipFile.h>
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

/// Collects the warnings OpenUSD posts while it exists (M7d): an export
/// keeps one, and its warnings are the next `lastExportWarnings`, so the
/// tests can check an export warns about nothing.
///
/// With a delegate, OpenUSD stops printing diagnostics itself, for every
/// thread, so this prints them as it would: the app's log and the command
/// line's standard error still show them.
class WarningCollector : public TfDiagnosticMgr::Delegate {
public:
    WarningCollector() {
        TfDiagnosticMgr::GetInstance().AddDelegate(this);
    }

    ~WarningCollector() override {
        TfDiagnosticMgr::GetInstance().RemoveDelegate(this);
    }

    void IssueWarning(const TfWarning &warning) override {
        Print("Warning", warning.GetCommentary());
        // A delegate hears every thread's warnings, including those of a
        // renderer drawing meanwhile (the viewport, swatches; other tests).
        // Exports don't use Hydra, so warnings from OpenUSD's imaging code
        // (pxr/imaging: Hydra, Storm) aren't theirs. The export's own come
        // from pxr/usd (Sdf, Usd, UsdMtlx, UsdUtils) and pxr/base.
        if (warning.GetContext().GetFile() && std::string(warning.GetContext().GetFile()).find("/imaging/")
                                                  != std::string::npos) {
            return;
        }
        // Warnings come from OpenUSD's worker threads too.
        std::lock_guard<std::mutex> lock(_mutex);
        _warnings.push_back(warning.GetCommentary());
    }

    void IssueStatus(const TfStatus &status) override {
        Print("Status", status.GetCommentary());
    }

    void IssueError(const TfError &error) override {
        Print("Error", error.GetCommentary());
    }

    void IssueFatalError(const TfCallContext &, const std::string &message) override {
        Print("Fatal error", message);
    }

    /// The warnings so far, as an array for Swift.
    NSArray<NSString *> *Warnings() {
        std::lock_guard<std::mutex> lock(_mutex);
        NSMutableArray<NSString *> *warnings = [NSMutableArray array];
        for (const std::string &warning : _warnings) {
            [warnings addObject:@(warning.c_str())];
        }
        return warnings;
    }

private:
    static void Print(const char *kind, const std::string &message) {
        fprintf(stderr, "%s: %s\n", kind, message.c_str());
    }

    std::mutex _mutex;
    std::vector<std::string> _warnings;
};

/// The last export's warnings (`lastExportWarnings`).
NSArray<NSString *> *LastExportWarnings = @[];

/// Keeps `collector`'s warnings as the last export's.
void KeepWarnings(WarningCollector &collector) {
    NSArray<NSString *> *warnings = collector.Warnings();
    @synchronized([MGUSDExporter class]) {
        LastExportWarnings = warnings;
    }
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

/// Calls `body` with every attribute of every prim in `layer`.
void ForEachAttribute(const SdfLayerRefPtr &layer, const std::function<void(const SdfAttributeSpecHandle &)> &body) {
    std::function<void(const SdfPrimSpecHandle &)> visit = [&](const SdfPrimSpecHandle &prim) {
        for (const SdfAttributeSpecHandle &attribute : prim->GetAttributes()) {
            body(attribute);
        }
        for (const SdfPrimSpecHandle &child : prim->GetNameChildren()) {
            visit(child);
        }
    };
    for (const SdfPrimSpecHandle &prim : layer->GetRootPrims()) {
        visit(prim);
    }
}

/// Removes the shading inputs that have neither a value nor a connection.
/// UsdMtlx declares one for every nodedef input whose default is a
/// geometric property (`normal`, `tangent`: "the geometry's own"), with no
/// value. Storm reads that as the default; RealityKit (Quick Look) rejects
/// the whole material ("Value type for input is not valid") and draws
/// nothing. Left out, the input takes its default everywhere.
void RemoveInputsWithoutValues(const SdfLayerRefPtr &layer) {
    std::vector<SdfPath> unset;
    ForEachAttribute(layer, [&](const SdfAttributeSpecHandle &attribute) {
        if (TfStringStartsWith(attribute->GetName(), "inputs:") && !attribute->HasDefaultValue()
            && attribute->GetConnectionPathList().GetAddedOrExplicitItems().empty()) {
            unset.push_back(attribute->GetPath());
        }
    });
    // Removed afterwards: removing while visiting would change the lists
    // being walked.
    for (const SdfPath &path : unset) {
        SdfPrimSpecHandle owner = layer->GetPrimAtPath(path.GetPrimPath());
        if (SdfAttributeSpecHandle attribute = layer->GetAttributeAtPath(path)) {
            owner->RemoveProperty(attribute);
        }
    }
}

/// `path` with symbolic links resolved (/tmp is /private/tmp), if it
/// exists; as it is otherwise.
std::string RealPath(const std::string &path) {
    const std::string real = TfRealPath(path);
    return real.empty() ? path : real;
}

/// Rewrites the absolute asset paths of `layer` (the textures' files) that
/// lie in `folder` or below as relative ones, "./" and the rest: OpenUSD
/// reads those relative to the layer's own file, wherever it is moved.
/// Returns the paths left absolute (M7d: the app warns about them).
NSArray<NSString *> *MakeAssetPathsRelative(const SdfLayerRefPtr &layer, const std::string &folder) {
    const std::string prefix = RealPath(folder) + "/";
    NSMutableOrderedSet<NSString *> *absolute = [NSMutableOrderedSet orderedSet];
    ForEachAttribute(layer, [&](const SdfAttributeSpecHandle &attribute) {
        const VtValue value = attribute->GetDefaultValue();
        if (!value.IsHolding<SdfAssetPath>()) {
            return;
        }
        const std::string path = value.UncheckedGet<SdfAssetPath>().GetAssetPath();
        if (!TfIsRelativePath(path)) {
            const std::string real = RealPath(path);
            if (TfStringStartsWith(real, prefix)) {
                attribute->SetDefaultValue(VtValue(SdfAssetPath("./" + real.substr(prefix.size()))));
            } else {
                [absolute addObject:@(path.c_str())];
            }
        }
    });
    return absolute.array;
}

/// Copies the textures `layer` refers to by absolute path into `folder`,
/// the folder the layer is packaged from, each source folder becoming a
/// numbered one ("0/brass_color.jpg"), and refers to the copies by
/// relative path (M7d).
///
/// UsdUtils' packaging renames them the same way itself, but then warns
/// "Failed to resolve reference @0/brass_color.jpg@" for every texture
/// after the first from a folder: it remembers only the first path it
/// renamed into each numbered folder, and looks for the others at their
/// new paths, which don't exist outside the package
/// (UsdUtils_DirectoryRemapper, OpenUSD 26.08). The package was right; the
/// warning wasn't. Paths already relative to the layer need no renaming.
/// A file that can't be copied keeps its path, for OpenUSD to package or
/// report.
void CopyTexturesBeside(const SdfLayerRefPtr &layer, NSString *folder) {
    std::map<std::string, std::string> folders; // source folder -> "0"
    std::map<std::string, std::string> copies;  // source file -> "0/name"
    NSFileManager *files = NSFileManager.defaultManager;
    ForEachAttribute(layer, [&](const SdfAttributeSpecHandle &attribute) {
        const VtValue value = attribute->GetDefaultValue();
        if (!value.IsHolding<SdfAssetPath>()) {
            return;
        }
        const std::string path = value.UncheckedGet<SdfAssetPath>().GetAssetPath();
        if (path.empty() || TfIsRelativePath(path)) {
            return;
        }
        auto copy = copies.find(path);
        if (copy == copies.end()) {
            const std::string number = std::to_string(folders.size());
            const std::string numbered = folders.insert({TfGetPathName(path), number}).first->second;
            const std::string relative = numbered + "/" + TfGetBaseName(path);
            NSString *destination = [folder stringByAppendingPathComponent:@(relative.c_str())];
            [files createDirectoryAtPath:destination.stringByDeletingLastPathComponent
                withIntermediateDirectories:YES attributes:nil error:nil];
            // A copy on APFS is a clone: no bytes are copied.
            if (![files copyItemAtPath:@(path.c_str()) toPath:destination error:nil]) {
                return;
            }
            copy = copies.insert({path, relative}).first;
        }
        attribute->SetDefaultValue(VtValue(SdfAssetPath(copy->second)));
    });
}

/// What UsdMtlx makes of the MaterialX text `xml`, flattened into one
/// layer, with inputs without values removed. Under `/MaterialX` (the
/// default prim), or, with `preview`, under `/World/MaterialX`
/// with the preview `shape` bound to the material named `materialName`
/// (or the first), in decimetres, Y up, as Quick Look wants. `folder` is a folder
/// of the caller's for the MaterialX file. Null, with `error` set, on
/// failure; OpenUSD's messages are left in `mark`.
SdfLayerRefPtr FlattenedMaterials(NSString *xml, NSString *folder, bool preview, MGPreviewShape shape,
                                  NSString *materialName, TfErrorMark &mark, NSError **error) {
    // UsdMtlx reads files, not text.
    NSString *mtlxPath = [folder stringByAppendingPathComponent:@"material.mtlx"];
    if (![xml writeToFile:mtlxPath atomically:YES encoding:NSUTF8StringEncoding error:error]) {
        return nullptr;
    }
    UsdStageRefPtr stage = UsdStage::CreateInMemory();
    SdfPath materialXPath("/MaterialX");
    if (preview) {
        UsdGeomSetStageUpAxis(stage, UsdGeomTokens->y);
        // Decimetres: the radius-1 sphere (and the other shapes) is 20 cm across in AR (Quick Look
        // places objects at their real size).
        UsdGeomSetStageMetersPerUnit(stage, 0.1);
        UsdGeomXform world = UsdGeomXform::Define(stage, SdfPath("/World"));
        stage->SetDefaultPrim(world.GetPrim());
        materialXPath = SdfPath("/World/MaterialX");
    }
    UsdPrim materialX = stage->DefinePrim(materialXPath);
    if (!preview) {
        stage->SetDefaultPrim(materialX);
    }
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
            const std::string messages = Messages(mark);
            *error = MakeError("The document has no material to export" + (messages.empty() ? "" : ": " + messages));
        }
        return nullptr;
    }
    if (preview) {
        UsdShadeMaterial bound = materials.front();
        for (const UsdShadeMaterial &material : materials) {
            if (materialName && material.GetPrim().GetName().GetString() == materialName.UTF8String) {
                bound = material;
                break;
            }
        }
        // Named after the shape: /World/Sphere, /World/ShaderBall ...
        UsdGeomMesh mesh = MGDefinePreviewMesh(stage, SdfPath("/World/" + MGPreviewShapeName(shape)), shape);
        UsdShadeMaterialBindingAPI::Apply(mesh.GetPrim()).Bind(bound);
    }

    SdfLayerRefPtr flat = stage->Flatten();
    if (!flat) {
        if (error) {
            *error = MakeError("OpenUSD could not flatten the stage: " + Messages(mark));
        }
        return nullptr;
    }
    RemoveInputsWithoutValues(flat);
    // Flatten() says it was "Generated from Composed Stage of root layer"
    // (an in-memory one, unnamed).
    flat->SetDocumentation("Exported by Margolaria from MaterialX");
    return flat;
}

/// A new folder of our own in the temporary folder.
NSString *NewTemporaryFolder() {
    NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return folder;
}

/// `value` as text for comparing files: an asset path as the file it
/// resolves to (as written if it doesn't resolve), anything else as
/// OpenUSD prints it.
std::string Describe(const VtValue &value) {
    if (value.IsHolding<SdfAssetPath>()) {
        const SdfAssetPath &asset = value.UncheckedGet<SdfAssetPath>();
        return asset.GetResolvedPath().empty() ? asset.GetAssetPath() : RealPath(asset.GetResolvedPath());
    }
    return TfStringify(value);
}

} // namespace

@implementation MGUSDExporter

+ (nullable NSArray<NSString *> *)exportMaterialsFromMaterialXString:(NSString *)xml
                                                              toURL:(NSURL *)url
                                                              error:(NSError **)error {
    NSString *folder = NewTemporaryFolder();
    WarningCollector warnings;
    TfErrorMark mark;
    bool written = false;
    NSArray<NSString *> *absolute = @[];
    // A C++ exception must never reach Swift.
    try {
        if (SdfLayerRefPtr flat = FlattenedMaterials(xml, folder, false, MGPreviewShapeSphere, nil, mark, error)) {
            absolute = MakeAssetPathsRelative(flat, url.URLByDeletingLastPathComponent.path.fileSystemRepresentation);
            written = flat->Export(url.path.fileSystemRepresentation);
            if (!written && error) {
                const std::string messages = Messages(mark);
                *error = MakeError(messages.empty() ? "OpenUSD could not write the file" : messages);
            }
        }
    } catch (const std::exception &exception) {
        if (error) {
            *error = MakeError(exception.what());
        }
        written = false;
    }
    [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
    // Warnings (posted as TfWarning, not errors) don't stop the export.
    mark.Clear();
    KeepWarnings(warnings);
    return written ? absolute : nil;
}

+ (BOOL)exportPreviewFromMaterialXString:(NSString *)xml
                                   toURL:(NSURL *)url
                            materialName:(nullable NSString *)materialName
                                   shape:(MGPreviewShape)shape
                                   error:(NSError **)error {
    // A folder of our own for the .mtlx and the flattened layer the USDZ
    // is packaged from.
    NSString *folder = NewTemporaryFolder();
    WarningCollector warnings;
    TfErrorMark mark;
    bool written = false;
    // A C++ exception must never reach Swift.
    try {
        if (SdfLayerRefPtr flat = FlattenedMaterials(xml, folder, true, shape, materialName, mark, error)) {
            CopyTexturesBeside(flat, folder);
            NSString *rootPath = [folder stringByAppendingPathComponent:@"root.usdc"];
            if (flat->Export(rootPath.fileSystemRepresentation)) {
                // The ARKit variant also checks the package against what
                // ARKit accepts; in the spike it gave the same files.
                written = UsdUtilsCreateNewARKitUsdzPackage(SdfAssetPath(rootPath.fileSystemRepresentation),
                                                            url.path.fileSystemRepresentation);
            }
            if (!written && error) {
                const std::string messages = Messages(mark);
                *error = MakeError(messages.empty() ? "OpenUSD could not write the package" : messages);
            }
        }
    } catch (const std::exception &exception) {
        if (error) {
            *error = MakeError(exception.what());
        }
        written = false;
    }
    [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
    // Warnings (posted as TfWarning, not errors) don't stop the export.
    mark.Clear();
    KeepWarnings(warnings);
    return written;
}

+ (NSArray<NSString *> *)lastExportWarnings {
    @synchronized(self) {
        return LastExportWarnings;
    }
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
    ForEachAttribute(layer, [&](const SdfAttributeSpecHandle &attribute) {
        const VtValue value = attribute->GetDefaultValue();
        if (value.IsHolding<SdfAssetPath>()) {
            [paths addObject:@(value.UncheckedGet<SdfAssetPath>().GetAssetPath().c_str())];
        }
    });
    mark.Clear();
    return paths;
}

+ (NSArray<NSString *> *)filesInPackageAtURL:(NSURL *)url {
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    TfErrorMark mark;
    // SdfZipFile iterates the package's entries, by name.
    if (const SdfZipFile zip = SdfZipFile::Open(url.path.fileSystemRepresentation)) {
        for (auto entry = zip.begin(); entry != zip.end(); ++entry) {
            [files addObject:@((*entry).c_str())];
        }
    }
    mark.Clear();
    return files;
}

+ (NSArray<NSString *> *)layersUsedByFileAtURL:(NSURL *)url {
    NSMutableArray<NSString *> *layers = [NSMutableArray array];
    TfErrorMark mark;
    if (UsdStageRefPtr stage = UsdStage::Open(url.path.fileSystemRepresentation)) {
        for (const SdfLayerHandle &layer : stage->GetUsedLayers()) {
            if (layer != stage->GetSessionLayer()) {
                [layers addObject:@(layer->GetIdentifier().c_str())];
            }
        }
    }
    mark.Clear();
    return layers;
}

+ (nullable NSDictionary<NSString *, NSString *> *)shadingOfFileAtURL:(NSURL *)url error:(NSError **)error {
    TfErrorMark mark;
    UsdStageRefPtr stage = UsdStage::Open(url.path.fileSystemRepresentation);
    if (!stage) {
        if (error) {
            *error = MakeError("Can't open: " + Messages(mark));
        }
        return nil;
    }
    NSMutableDictionary<NSString *, NSString *> *shading = [NSMutableDictionary dictionary];
    for (const UsdPrim &prim : stage->TraverseAll()) {
        shading[@(prim.GetPath().GetText())] = @(prim.GetTypeName().GetText());
        for (const UsdAttribute &attribute : prim.GetAttributes()) {
            VtValue value;
            const bool hasValue = attribute.Get(&value);
            SdfPathVector connections;
            attribute.GetConnections(&connections);
            if (!hasValue && connections.empty()) {
                continue;
            }
            std::string text = hasValue ? Describe(value) : "";
            for (const SdfPath &connection : connections) {
                text += " -> " + connection.GetString();
            }
            shading[@(attribute.GetPath().GetText())] = @(text.c_str());
        }
    }
    mark.Clear();
    return shading;
}

@end
