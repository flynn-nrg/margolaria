// MGPreviewShapes.h
//
// The preview shapes (M7a; the sphere alone since M5a), shared by the
// Storm renderer (the viewport) and the USD exporter: finely tessellated
// meshes with texture coordinates and normals. A private header of
// ViewportBridge (not in include/): C++, for the bridge's own .mm files
// only.

#pragma once

#import "MGPreviewShape.h"

#include <string>

#include <pxr/pxr.h>
#include <pxr/usd/sdf/path.h>
#include <pxr/usd/usd/stage.h>
#include <pxr/usd/usdGeom/mesh.h>

PXR_NAMESPACE_OPEN_SCOPE

/// Defines the mesh of `shape` at `path`, replacing whatever was there,
/// with texture coordinates in the "st" primvar. The sphere is the same
/// mesh as before M7a.
UsdGeomMesh MGDefinePreviewMesh(const UsdStageRefPtr &stage, const SdfPath &path, MGPreviewShape shape);

/// The prim name a USDZ export gives the shape: "Sphere", "Plane",
/// "Cylinder", "Cloth", "ShaderBall".
std::string MGPreviewShapeName(MGPreviewShape shape);

PXR_NAMESPACE_CLOSE_SCOPE
