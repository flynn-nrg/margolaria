// MGStormRenderer.mm
//
// Implementation of MGStormRenderer: builds a USD stage around a .mtlx file
// and renders it with UsdImagingGLEngine, Hydra's ready-made front end, using
// the Storm render delegate on HgiMetal. Despite "GL" in its name,
// UsdImagingGLEngine is backend-neutral: it renders with whatever Hgi
// (Hydra Graphics Interface) driver it is given, here Metal.
//
// The pipeline for one frame:
//
//   USD stage ──UsdImaging──▶ Hydra scene ──Storm──▶ HgiMetal ──▶ colour AOV (id<MTLTexture>)
//                 ▲
//   .mtlx file ──UsdMtlx (file-format plugin) turns MaterialX into UsdShade prims
//   or XML text
//
// From a file, the stage references the file. From text (the app's edited
// document, M2c), the renderer writes the text to a private temporary file
// and references that; updating rewrites the file and reads it again into
// the layer, and USD tells UsdImaging and Storm what changed, so the next frame shows
// it.
//
// Why a file and not a layer in memory: for a nodedef defined in the
// document itself (SimpleHair's `simple_hair`), UsdMtlx records the
// document's file as the shader's source, and Hydra reads the nodedef and
// its implementation from there when it builds the shader. An anonymous
// layer has no file, so such materials fell back to Storm's plain grey.
//
// Storm generates Metal shaders from the MaterialX node graph itself (through
// MaterialX's MslShaderGenerator), so nothing here deals with shaders.

#import "MGStormRenderer.h"
#import "MGPreviewSphere.h"

#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <pxr/pxr.h>
#include <pxr/base/gf/frustum.h>
#include <pxr/base/gf/matrix4d.h>
#include <pxr/base/gf/rotation.h>
#include <pxr/base/gf/rect2i.h>
#include <pxr/base/gf/vec3d.h>
#include <pxr/base/tf/errorMark.h>
#include <pxr/imaging/cameraUtil/framing.h>
#include <pxr/imaging/hd/driver.h>
#include <pxr/imaging/hd/tokens.h>
#include <pxr/imaging/hdx/package.h>
#include <pxr/imaging/hdx/tokens.h>
#include <pxr/imaging/hgi/hgi.h>
#include <pxr/imaging/hgi/tokens.h>
#include <pxr/imaging/hgiMetal/hgi.h>
#include <pxr/imaging/hgiMetal/texture.h>
#include <pxr/usd/sdf/layer.h>
#include <pxr/usd/usd/primRange.h>
#include <pxr/usd/usd/stage.h>
#include <pxr/usd/usdGeom/metrics.h>
#include <pxr/usd/usdGeom/mesh.h>
#include <pxr/usd/usdGeom/primvarsAPI.h>
#include <pxr/usd/usdGeom/xformable.h>
#include <pxr/usd/usdLux/distantLight.h>
#include <pxr/usd/usdLux/domeLight.h>
#include <pxr/usd/usdShade/material.h>
#include <pxr/usd/usdShade/materialBindingAPI.h>
#include <pxr/usdImaging/usdImagingGL/engine.h>
#include <pxr/usdImaging/usdImagingGL/renderParams.h>

PXR_NAMESPACE_USING_DIRECTIVE

NSErrorDomain const MGStormRendererErrorDomain = @"MGStormRendererErrorDomain";

namespace {

// Where the .mtlx is referenced in the stage. UsdMtlx puts every material in
// a MaterialX document under /MaterialX/Materials, so the bound material ends
// up at /World/MaterialX/Materials/<name>.
const char *const kMaterialXRootPath = "/World/MaterialX";

/// The preview sphere.
const char *const kSpherePath = "/World/Sphere";

/// The lights (AddLights).
const char *const kKeyLightPath = "/World/Lights/Key";
const char *const kDomeLightPath = "/World/Lights/Dome";

/// Serializes engine creation. The first UsdImagingGLEngine loads Hydra's
/// renderer plugins into a process-wide registry, and that registry is not
/// safe to initialize from two threads at once: two renderers created in
/// parallel (as the tests did) crash while sorting the plugin list.
std::mutex gEngineCreationMutex;

/// An NSError with the given message.
NSError *MakeError(NSString *message) {
    return [NSError errorWithDomain:MGStormRendererErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

/// The path of OpenUSD's default environment map (an outdoor HDR,
/// "StinsonBeach.hdr"), the one usdview uses. It ships with the Hdx library
/// in SwiftUsd.
std::string DefaultEnvironmentPath() {
    return HdxPackageDefaultDomeLightTexture().GetString();
}

/// Adds a key light and a dome light, lit by OpenUSD's default environment
/// until environmentURL chooses another. Metals only reflect their
/// surroundings, so the dome needs an environment image.
void AddLights(const UsdStageRefPtr &stage) {
    UsdLuxDistantLight key = UsdLuxDistantLight::Define(stage, SdfPath(kKeyLightPath));
    key.CreateIntensityAttr(VtValue(3.0f));
    key.CreateAngleAttr(VtValue(2.0f));
    // A distant light shines down its local -Z axis. Tilt it to come from
    // above and to the right of the default camera.
    UsdGeomXformable(key.GetPrim()).AddRotateXYZOp().Set(GfVec3f(-40.0f, 35.0f, 0.0f));

    UsdLuxDomeLight dome = UsdLuxDomeLight::Define(stage, SdfPath(kDomeLightPath));
    dome.CreateIntensityAttr(VtValue(1.0f));
    dome.CreateTextureFileAttr(VtValue(SdfAssetPath(DefaultEnvironmentPath())));
}

/// Writes `xml` to the file at `path`, replacing it. On failure, returns
/// false with the reason in `message`.
bool WriteText(const std::string &xml, NSString *path, std::string &message) {
    NSError *error = nil;
    NSString *text = [[NSString alloc] initWithBytes:xml.data() length:xml.size() encoding:NSUTF8StringEncoding];
    if (text == nil || ![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        message = error ? error.localizedDescription.UTF8String : "The text is not UTF-8";
        return false;
    }
    return true;
}

/// Reads the file at `path` again, through the UsdMtlx plugin, and puts its
/// contents into `layer`. On failure, returns false and describes the
/// problem in `message`; the layer keeps what it had.
///
/// `layer->Reload()` would be the obvious call, but UsdMtlx can't reload a
/// layer in place ("Failed to define UsdPrim </MaterialX>"). So the file is
/// read into a fresh layer, the same way as the first time, and copied
/// across. TransferContent compares the two and sends USD's change notices
/// for what differs only, so a changed value reaches Storm as a value change.
bool ReloadMaterialX(const SdfLayerRefPtr &layer, NSString *path, std::string &message) {
    // OpenUSD reports problems by posting TfErrors rather than throwing.
    // A TfErrorMark collects those posted while it exists.
    TfErrorMark mark;
    SdfLayerRefPtr fresh = SdfLayer::OpenAsAnonymous(path.fileSystemRepresentation);
    if (fresh && mark.IsClean()) {
        layer->TransferContent(fresh);
        return true;
    }
    for (const TfError &error : mark) {
        message += error.GetCommentary() + "\n";
    }
    // Handled here: don't let them be reported again as unhandled.
    mark.Clear();
    if (message.empty()) {
        message = "UsdMtlx could not read the document";
    }
    return false;
}

/// Every UsdShadeMaterial at or below `root`, in stage order (for UsdMtlx,
/// the MaterialX document's order).
/// Every connection under `root`, as text ("a.inputs:x -> b.outputs:y",
/// one per line): to tell whether a reload changed the networks' shape.
std::string ConnectionSignature(const UsdPrim &root) {
    std::string signature;
    for (const UsdPrim &prim : UsdPrimRange(root)) {
        for (const UsdAttribute &attribute : prim.GetAttributes()) {
            SdfPathVector targets;
            attribute.GetConnections(&targets);
            for (const SdfPath &target : targets) {
                signature += attribute.GetPath().GetString() + " -> " + target.GetString() + "\n";
            }
        }
    }
    return signature;
}

std::vector<UsdShadeMaterial> FindMaterials(const UsdPrim &root) {
    std::vector<UsdShadeMaterial> materials;
    for (const UsdPrim &prim : UsdPrimRange(root)) {
        if (prim.IsA<UsdShadeMaterial>()) {
            materials.push_back(UsdShadeMaterial(prim));
        }
    }
    return materials;
}

} // namespace

@implementation MGStormRenderer {
    // C++ objects as Objective-C++ instance variables. ARC doesn't manage
    // them; the compiler runs their constructors on alloc and their
    // destructors on dealloc, in reverse declaration order. The engine renders
    // with the Hgi, so _hgi is declared first and therefore destroyed last.
    HgiUniquePtr _hgi;
    std::unique_ptr<UsdImagingGLEngine> _engine;
    UsdStageRefPtr _stage;
    // When made from text: the temporary file holding it, and its layer.
    // Nil and null when made from a file.
    NSString *_textFile;
    SdfLayerRefPtr _materialLayer;
    NSString *_boundMaterialPath;
    NSArray<NSString *> *_materialPaths;
    NSURL *_environmentURL;
}

- (nullable instancetype)initWithMaterialXFile:(NSURL *)fileURL error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    // OpenUSD reports most problems through its own diagnostics (TfError),
    // but a C++ exception must never reach Swift, so catch everything here.
    try {
        // Opening a .mtlx as a USD layer goes through the UsdMtlx
        // file-format plugin, which ships in SwiftUsd.
        [self createStageWithMaterialX:fileURL.path.fileSystemRepresentation];
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeError(@(exception.what()));
        }
        return nil;
    }
    return [self finishSettingUpForName:fileURL.lastPathComponent error:error] ? self : nil;
}

- (nullable instancetype)initWithMaterialXString:(NSString *)xml error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    // A file of our own, deleted in dealloc. The name only needs to be
    // unique; UsdMtlx picks its file format from the ".mtlx" extension.
    NSString *name = [NSString stringWithFormat:@"Margolaria-preview-%@.mtlx", NSUUID.UUID.UUIDString];
    _textFile = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    try {
        std::string message;
        if (!WriteText(xml.UTF8String, _textFile, message)) {
            if (error != nullptr) {
                *error = MakeError(@(message.c_str()));
            }
            return nil;
        }
        [self createStageWithMaterialX:_textFile.fileSystemRepresentation];
        // The stage opened the file as a layer when it was referenced; keep
        // a handle to reload it.
        _materialLayer = SdfLayer::Find(_textFile.fileSystemRepresentation);
        if (!_materialLayer) {
            if (error != nullptr) {
                *error = MakeError(@"UsdMtlx could not read the document");
            }
            return nil;
        }
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeError(@(exception.what()));
        }
        return nil;
    }
    return [self finishSettingUpForName:@"the document" error:error] ? self : nil;
}

- (void)dealloc {
    if (_textFile != nil) {
        [NSFileManager.defaultManager removeItemAtPath:_textFile error:nil];
    }
}

/// Creates the stage, referencing the MaterialX file at `materialXPath`
/// under /World/MaterialX. May throw.
- (void)createStageWithMaterialX:(const std::string &)materialXPath {
    _stage = UsdStage::CreateInMemory();
    UsdGeomSetStageUpAxis(_stage, UsdGeomTokens->y);
    UsdPrim materialXRoot = _stage->DefinePrim(SdfPath(kMaterialXRootPath));
    materialXRoot.GetReferences().AddReference(materialXPath, SdfPath("/MaterialX"));
}

/// The rest of initialisation, the same for files and text: the sphere
/// with the first material bound, the lights, and the Storm engine.
/// `name` describes the source in error messages. Returns NO, with `error`
/// set, on failure.
///
/// It returns a BOOL, not `self`, on purpose: under ARC, an object returned
/// by a method outside the `init` family is autoreleased, so `return [self
/// finish...]` from an initializer would free the renderer only when an
/// autorelease pool drains, possibly on another thread after OpenUSD's
/// global state is gone at exit (a crash in ~UsdImagingGLEngine).
- (BOOL)finishSettingUpForName:(NSString *)name error:(NSError **)error {
    try {
        UsdPrim materialXRoot = _stage->GetPrimAtPath(SdfPath(kMaterialXRootPath));
        const std::vector<UsdShadeMaterial> materials = FindMaterials(materialXRoot);
        if (materials.empty()) {
            if (error != nullptr) {
                *error = MakeError([NSString stringWithFormat:@"No material found in %@", name]);
            }
            return NO;
        }
        [self listMaterials:materials];

        // The preview sphere, with the first material bound to it.
        UsdGeomMesh sphere = MGDefineSphereMesh(_stage, SdfPath(kSpherePath));
        UsdShadeMaterialBindingAPI::Apply(sphere.GetPrim()).Bind(materials.front());
        _boundMaterialPath = _materialPaths.firstObject;

        AddLights(_stage);

        // --- The renderer -------------------------------------------------
        // The platform default Hgi on macOS is HgiMetal. It creates its own
        // MTLDevice (the system default) and command queue.
        _hgi = Hgi::CreatePlatformDefaultHgi();
        if (!_hgi) {
            if (error != nullptr) {
                *error = MakeError(@"Metal is not available");
            }
            return NO;
        }

        // An HdDriver hands our Hgi to Hydra, so Storm renders with it
        // instead of creating another one.
        UsdImagingGLEngine::Parameters parameters;
        parameters.driver = HdDriver{HgiTokens->renderDriver, VtValue(_hgi.get())};
        parameters.rendererPluginId = TfToken("HdStormRendererPlugin");
        {
            // `lock_guard` holds the mutex until the end of this block.
            std::lock_guard<std::mutex> lock(gEngineCreationMutex);
            _engine = std::make_unique<UsdImagingGLEngine>(parameters);
        }

        [self configureEngine];
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeError(@(exception.what()));
        }
        return NO;
    }

    _azimuth = 30.0;
    _elevation = 15.0;
    _distance = 5.0;
    _keyLightEnabled = YES;
    return YES;
}

/// The engine's settings, for a new engine or a newly chosen renderer
/// (a renderer plugin starts with its own defaults).
- (void)configureEngine {
    // Ask the renderer for the colour output (AOV = "arbitrary output
    // variable").
    _engine->SetRendererAov(HdAovTokens->color);

    // By default the engine ends each frame by "presenting" the image to
    // an OpenGL framebuffer (HgiInterop). There is no OpenGL context here,
    // and that step crashes inside glGetString. We read the colour texture
    // ourselves (renderWithWidth:height:), so switch presentation off.
    _engine->SetEnablePresentation(false);

    // Light the sphere with the dome's environment image, but don't draw
    // the image behind it: the background stays the neutral clear colour,
    // which makes the material easier to judge.
    _engine->SetRendererSetting(HdRenderSettingsTokens->domeLightCameraVisibility, VtValue(false));
}

/// Sets materialPaths from `materials`.
- (void)listMaterials:(const std::vector<UsdShadeMaterial> &)materials {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (const UsdShadeMaterial &material : materials) {
        [paths addObject:@(material.GetPath().GetString().c_str())];
    }
    _materialPaths = [paths copy];
}

- (BOOL)updateMaterialXString:(NSString *)xml error:(NSError **)error {
    if (!_materialLayer) {
        if (error != nullptr) {
            *error = MakeError(@"This renderer shows a file; it can't be updated from text");
        }
        return NO;
    }
    try {
        std::string message;
        const std::string before = ConnectionSignature(_stage->GetPrimAtPath(SdfPath(kMaterialXRootPath)));
        if (!WriteText(xml.UTF8String, _textFile, message) || !ReloadMaterialX(_materialLayer, _textFile, message)) {
            if (error != nullptr) {
                *error = MakeError(@(message.c_str()));
            }
            return NO;
        }
        // Materials may have been added, removed or renamed.
        UsdPrim materialXRoot = _stage->GetPrimAtPath(SdfPath(kMaterialXRootPath));
        // Storm (OpenUSD 26.08) notices changed values and new nodes, but
        // not a connection changed inside a nodegraph (its output
        // reconnected to another node): the sphere kept the old network
        // (found in M3d). When any connection changed, the reference to
        // the MaterialX layer is removed and added again: UsdImaging then
        // reads every material afresh. Value edits, such as a slider
        // drag, change no connection and stay cheap.
        if (ConnectionSignature(materialXRoot) != before) {
            materialXRoot.GetReferences().ClearReferences();
            materialXRoot.GetReferences().AddReference(_textFile.fileSystemRepresentation, SdfPath("/MaterialX"));
        }
        const std::vector<UsdShadeMaterial> materials = FindMaterials(materialXRoot);
        [self listMaterials:materials];
        if (![_materialPaths containsObject:_boundMaterialPath]) {
            UsdPrim sphere = _stage->GetPrimAtPath(SdfPath(kSpherePath));
            if (materials.empty()) {
                // Nothing to show: Storm draws the sphere in its fallback grey.
                UsdShadeMaterialBindingAPI(sphere).UnbindDirectBinding();
                _boundMaterialPath = @"";
            } else {
                UsdShadeMaterialBindingAPI(sphere).Bind(materials.front());
                _boundMaterialPath = _materialPaths.firstObject;
            }
        }
        return YES;
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeError(@(exception.what()));
        }
        return NO;
    }
}

- (id<MTLDevice>)device {
    return static_cast<HgiMetal *>(_hgi.get())->GetPrimaryDevice();
}

- (id<MTLCommandQueue>)commandQueue {
    return static_cast<HgiMetal *>(_hgi.get())->GetQueue();
}

- (NSString *)boundMaterialPath {
    return _boundMaterialPath;
}

- (NSArray<NSString *> *)materialPaths {
    return _materialPaths;
}

- (BOOL)bindMaterialAtPath:(NSString *)path {
    if ([path isEqualToString:_boundMaterialPath]) {
        return YES;
    }
    try {
        UsdShadeMaterial material(_stage->GetPrimAtPath(SdfPath(path.UTF8String)));
        if (!material) {
            return NO;
        }
        // Rebinding is an ordinary stage edit; UsdImaging notices it and
        // Storm compiles the new material on the next render.
        UsdPrim sphere = _stage->GetPrimAtPath(SdfPath(kSpherePath));
        UsdShadeMaterialBindingAPI(sphere).Bind(material);
        _boundMaterialPath = [path copy];
        return YES;
    } catch (const std::exception &exception) {
        NSLog(@"MGStormRenderer: binding %@ failed: %s", path, exception.what());
        return NO;
    }
}

- (nullable NSURL *)environmentURL {
    return _environmentURL;
}

- (void)setEnvironmentURL:(nullable NSURL *)url {
    if (url == _environmentURL || [url isEqual:_environmentURL]) {
        return;
    }
    _environmentURL = [url copy];
    // A new texture file for the dome. Storm notices the change, loads the
    // image and prefilters it for diffuse and glossy lighting again.
    const std::string path = url != nil ? std::string(url.fileSystemRepresentation) : DefaultEnvironmentPath();
    UsdLuxDomeLight dome(_stage->GetPrimAtPath(SdfPath(kDomeLightPath)));
    dome.GetTextureFileAttr().Set(SdfAssetPath(path));
}

- (void)setKeyLightEnabled:(BOOL)enabled {
    _keyLightEnabled = enabled;
    // An inactive prim is left out of the stage, as if deleted, but keeps
    // its settings for when it is made active again.
    _stage->GetPrimAtPath(SdfPath(kKeyLightPath)).SetActive(enabled);
}

- (NSString *)rendererName {
    return @(_engine->GetRendererDisplayName(_engine->GetCurrentRendererId()).c_str());
}

- (NSString *)rendererID {
    return @(_engine->GetCurrentRendererId().GetText());
}

+ (NSArray<NSString *> *)availableRendererIDs {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    // The plugin registry is filled on first use (gEngineCreationMutex).
    std::lock_guard<std::mutex> lock(gEngineCreationMutex);
    for (const TfToken &id : UsdImagingGLEngine::GetRendererPlugins()) {
        [ids addObject:@(id.GetText())];
    }
    return [ids copy];
}

+ (NSString *)displayNameForRendererID:(NSString *)rendererID {
    return @(UsdImagingGLEngine::GetRendererDisplayName(TfToken(rendererID.UTF8String)).c_str());
}

- (BOOL)setRendererID:(NSString *)rendererID error:(NSError **)error {
    if ([rendererID isEqualToString:self.rendererID]) {
        return YES;
    }
    try {
        bool loaded;
        {
            std::lock_guard<std::mutex> lock(gEngineCreationMutex);
            loaded = _engine->SetRendererPlugin(TfToken(rendererID.UTF8String));
        }
        if (!loaded) {
            if (error != nullptr) {
                *error = MakeError([NSString stringWithFormat:@"The renderer %@ could not be loaded", rendererID]);
            }
            return NO;
        }
        [self configureEngine];
        return YES;
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeError(@(exception.what()));
        }
        return NO;
    }
}

- (BOOL)isConverged {
    return _engine->IsConverged();
}

- (void)setElevation:(double)elevation {
    _elevation = std::max(-89.0, std::min(89.0, elevation));
}

- (nullable id<MTLTexture>)renderWithWidth:(NSInteger)width height:(NSInteger)height {
    if (width <= 0 || height <= 0) {
        return nil;
    }
    const int w = static_cast<int>(width);
    const int h = static_cast<int>(height);

    try {
        // Render target size, and the part of it the camera fills (all of it).
        _engine->SetRenderBufferSize(GfVec2i(w, h));
        _engine->SetFraming(CameraUtilFraming(GfRect2i(GfVec2i(0, 0), w, h)));

        // Orbit camera: a point on a sphere around the origin, looking at it.
        const double az = _azimuth * M_PI / 180.0;
        const double el = _elevation * M_PI / 180.0;
        const GfVec3d eye(_distance * std::cos(el) * std::sin(az),
                          _distance * std::sin(el),
                          _distance * std::cos(el) * std::cos(az));
        GfMatrix4d view;
        view.SetLookAt(eye, GfVec3d(0.0), GfVec3d(0.0, 1.0, 0.0));

        // A 30° field of view across the narrower side of the image, so the
        // sphere fits in tall, narrow views as well as wide ones. GfFrustum
        // takes the vertical angle; for a tall view, widen it until the
        // horizontal angle is 30°.
        const double aspect = static_cast<double>(w) / h;
        const double narrowFov = 30.0;
        double verticalFov = narrowFov;
        if (aspect < 1.0) {
            const double halfNarrow = narrowFov * M_PI / 360.0;
            verticalFov = 2.0 * std::atan(std::tan(halfNarrow) / aspect) * 180.0 / M_PI;
        }
        GfFrustum frustum;
        frustum.SetPerspective(verticalFov, aspect, 0.1, 100.0);
        _engine->SetCameraState(view, frustum.ComputeProjectionMatrix());

        UsdImagingGLRenderParams params;
        params.clearColor = GfVec4f(0.18f, 0.18f, 0.18f, 1.0f);
        params.enableLighting = true;
        params.enableSceneLights = true;
        params.enableSceneMaterials = true;
        // Storm works in linear light; this encodes its output as sRGB,
        // without tone mapping or clamping. ViewportKit's DisplayPass
        // decodes it again and applies the OCIO view transform (M3b).
        //
        // Why not `disabled`, which would leave the output linear: with
        // colour correction disabled, Storm (OpenUSD 26.08 on Metal) draws
        // no geometry into the colour AOV, only the clear colour and the
        // dome (found in M3b; see docs/PLAN.md §8.2). OpenUSD's own OCIO
        // mode isn't in SwiftUsd's build.
        params.colorCorrectionMode = HdxColorCorrectionTokens->sRGB;

        _engine->Render(_stage->GetPseudoRoot(), params);

        HgiTextureHandle texture = _engine->GetAovTexture(HdAovTokens->color);
        if (!texture) {
            return nil;
        }
        return static_cast<HgiMetalTexture *>(texture.Get())->GetTextureId();
    } catch (const std::exception &exception) {
        NSLog(@"MGStormRenderer: render failed: %s", exception.what());
        return nil;
    }
}

@end
