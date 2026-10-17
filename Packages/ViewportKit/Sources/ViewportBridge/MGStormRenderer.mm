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
//
// Storm generates Metal shaders from the MaterialX node graph itself (through
// MaterialX's MslShaderGenerator), so nothing here deals with shaders.

#import "MGStormRenderer.h"

#include <exception>
#include <memory>
#include <mutex>
#include <string>

#include <pxr/pxr.h>
#include <pxr/base/gf/frustum.h>
#include <pxr/base/gf/matrix4d.h>
#include <pxr/base/gf/rect2i.h>
#include <pxr/base/gf/vec3d.h>
#include <pxr/imaging/cameraUtil/framing.h>
#include <pxr/imaging/hd/driver.h>
#include <pxr/imaging/hd/tokens.h>
#include <pxr/imaging/geomUtil/sphereMeshGenerator.h>
#include <pxr/imaging/hdx/package.h>
#include <pxr/imaging/hdx/tokens.h>
#include <pxr/imaging/hgi/hgi.h>
#include <pxr/imaging/hgi/tokens.h>
#include <pxr/imaging/hgiMetal/hgi.h>
#include <pxr/imaging/hgiMetal/texture.h>
#include <pxr/usd/usd/primRange.h>
#include <pxr/usd/usd/stage.h>
#include <pxr/usd/usdGeom/metrics.h>
#include <pxr/usd/usdGeom/mesh.h>
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

/// Defines a finely tessellated sphere mesh of radius 1 at `path`.
///
/// A UsdGeomSphere would be simpler, but UsdImaging tessellates implicit
/// spheres coarsely (about 10 sides), which ruins reflections. GeomUtil is
/// the same generator UsdImaging uses, just with more segments.
UsdGeomMesh DefineSphereMesh(const UsdStageRefPtr &stage, const SdfPath &path) {
    using Generator = GeomUtilSphereMeshGenerator;
    const size_t numRadial = 96; // segments around the equator
    const size_t numAxial = 48;  // segments from pole to pole

    const PxOsdMeshTopology topology = Generator::GenerateTopology(numRadial, numAxial);

    VtVec3fArray points(Generator::ComputeNumPoints(numRadial, numAxial));
    Generator::GeneratePoints(points.begin(), numRadial, numAxial, 1.0f);

    VtVec3fArray normals(Generator::ComputeNumNormals(numRadial, numAxial));
    Generator::GenerateNormals(normals.begin(), numRadial, numAxial);

    UsdGeomMesh mesh = UsdGeomMesh::Define(stage, path);
    mesh.CreatePointsAttr(VtValue(points));
    mesh.CreateFaceVertexCountsAttr(VtValue(topology.GetFaceVertexCounts()));
    mesh.CreateFaceVertexIndicesAttr(VtValue(topology.GetFaceVertexIndices()));
    mesh.CreateNormalsAttr(VtValue(normals));
    mesh.SetNormalsInterpolation(UsdGeomTokens->vertex);
    // Plain polygons: no subdivision surface, use the normals as given.
    mesh.CreateSubdivisionSchemeAttr(VtValue(UsdGeomTokens->none));
    mesh.CreateExtentAttr(VtValue(VtVec3fArray{GfVec3f(-1.0f), GfVec3f(1.0f)}));
    return mesh;
}

/// Adds a key light and a dome light. Metals only reflect their
/// surroundings, so the dome needs an environment image.
void AddLights(const UsdStageRefPtr &stage) {
    UsdLuxDistantLight key = UsdLuxDistantLight::Define(stage, SdfPath("/World/Lights/Key"));
    key.CreateIntensityAttr(VtValue(3.0f));
    key.CreateAngleAttr(VtValue(2.0f));
    // A distant light shines down its local -Z axis. Tilt it to come from
    // above and to the right of the default camera.
    UsdGeomXformable(key.GetPrim()).AddRotateXYZOp().Set(GfVec3f(-40.0f, 35.0f, 0.0f));

    // OpenUSD's default environment map (an outdoor HDR, "StinsonBeach.hdr"),
    // the one usdview uses. It ships with the Hdx library in SwiftUsd.
    // TODO(M3): a neutral studio environment, chosen by the user.
    UsdLuxDomeLight dome = UsdLuxDomeLight::Define(stage, SdfPath("/World/Lights/Dome"));
    dome.CreateIntensityAttr(VtValue(1.0f));
    dome.CreateTextureFileAttr(VtValue(SdfAssetPath(HdxPackageDefaultDomeLightTexture().GetString())));
}

/// The first UsdShadeMaterial at or below `root`, or an invalid one.
UsdShadeMaterial FindFirstMaterial(const UsdPrim &root) {
    for (const UsdPrim &prim : UsdPrimRange(root)) {
        if (prim.IsA<UsdShadeMaterial>()) {
            return UsdShadeMaterial(prim);
        }
    }
    return UsdShadeMaterial();
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
    NSString *_boundMaterialPath;
}

- (nullable instancetype)initWithMaterialXFile:(NSURL *)fileURL error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    // OpenUSD reports most problems through its own diagnostics (TfError),
    // but a C++ exception must never reach Swift, so catch everything here.
    try {
        // --- The stage ----------------------------------------------------
        _stage = UsdStage::CreateInMemory();
        UsdGeomSetStageUpAxis(_stage, UsdGeomTokens->y);

        // Reference the MaterialX document. Opening a .mtlx as a USD layer
        // goes through the UsdMtlx file-format plugin, which ships in SwiftUsd.
        const std::string mtlxPath = fileURL.path.fileSystemRepresentation;
        UsdPrim materialXRoot = _stage->DefinePrim(SdfPath(kMaterialXRootPath));
        materialXRoot.GetReferences().AddReference(mtlxPath, SdfPath("/MaterialX"));

        UsdShadeMaterial material = FindFirstMaterial(materialXRoot);
        if (!material) {
            if (error != nullptr) {
                *error = MakeError([NSString stringWithFormat:@"No material found in %@",
                                                              fileURL.lastPathComponent]);
            }
            return nil;
        }
        _boundMaterialPath = @(material.GetPath().GetString().c_str());

        // The preview sphere, with the material bound to it.
        UsdGeomMesh sphere = DefineSphereMesh(_stage, SdfPath("/World/Sphere"));
        UsdShadeMaterialBindingAPI::Apply(sphere.GetPrim()).Bind(material);

        AddLights(_stage);

        // --- The renderer -------------------------------------------------
        // The platform default Hgi on macOS is HgiMetal. It creates its own
        // MTLDevice (the system default) and command queue.
        _hgi = Hgi::CreatePlatformDefaultHgi();
        if (!_hgi) {
            if (error != nullptr) {
                *error = MakeError(@"Metal is not available");
            }
            return nil;
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

        // Ask Storm for the colour output (AOV = "arbitrary output variable").
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
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeError(@(exception.what()));
        }
        return nil;
    }

    _azimuth = 30.0;
    _elevation = 15.0;
    _distance = 5.0;
    return self;
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

- (NSString *)rendererName {
    return @(_engine->GetRendererDisplayName(_engine->GetCurrentRendererId()).c_str());
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

        GfFrustum frustum;
        frustum.SetPerspective(30.0, static_cast<double>(w) / h, 0.1, 100.0);
        _engine->SetCameraState(view, frustum.ComputeProjectionMatrix());

        UsdImagingGLRenderParams params;
        params.clearColor = GfVec4f(0.18f, 0.18f, 0.18f, 1.0f);
        params.enableLighting = true;
        params.enableSceneLights = true;
        params.enableSceneMaterials = true;
        // Storm works in linear light; this converts its output to sRGB for
        // display. M3 replaces it with an OCIO view transform.
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
