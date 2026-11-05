// MGPreviewSphere.h
//
// The preview sphere, shared by the Storm renderer (the viewport) and the
// USD exporter (M5a): a finely tessellated mesh with texture coordinates.
// A private header of ViewportBridge (not in include/): C++, for the
// bridge's own .mm files only.

#pragma once

#include <pxr/pxr.h>
#include <pxr/usd/sdf/path.h>
#include <pxr/usd/usd/stage.h>
#include <pxr/usd/usdGeom/mesh.h>

PXR_NAMESPACE_OPEN_SCOPE

/// Defines a finely tessellated sphere mesh of radius 1 at `path`, poles on
/// Y, with texture coordinates in the "st" primvar.
UsdGeomMesh MGDefineSphereMesh(const UsdStageRefPtr &stage, const SdfPath &path);

PXR_NAMESPACE_CLOSE_SCOPE
