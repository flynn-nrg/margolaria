// MGPreviewSphere.mm
//
// The preview sphere (MGPreviewSphere.h). Moved out of MGStormRenderer.mm
// in M5a, for the USD exporter.

#import "MGPreviewSphere.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include <pxr/base/gf/matrix4d.h>
#include <pxr/base/gf/rotation.h>
#include <pxr/imaging/geomUtil/sphereMeshGenerator.h>
#include <pxr/imaging/pxOsd/meshTopology.h>
#include <pxr/usd/usdGeom/primvarsAPI.h>

PXR_NAMESPACE_USING_DIRECTIVE

namespace {

/// Texture coordinates for a sphere with its poles on the Y axis: u goes
/// once around the equator (0 to 1, starting behind the sphere, so the
/// middle of a texture faces +Z, the default camera side), v from the bottom
/// pole (0) to the top (1).
///
/// They are "face-varying": one value per corner of each face rather than
/// one per point, because the faces along the seam need u = 1 on one side
/// and u = 0 on the other at the same points.
VtVec2fArray SphereTextureCoordinates(const VtVec3fArray &points, const PxOsdMeshTopology &topology) {
    const VtIntArray &counts = topology.GetFaceVertexCounts();
    const VtIntArray &indices = topology.GetFaceVertexIndices();
    VtVec2fArray st;
    st.reserve(indices.size());
    size_t corner = 0;
    for (const int count : counts) {
        // u and v for this face's corners, before fixing the seam and poles.
        std::vector<GfVec2f> face;
        for (int i = 0; i < count; ++i) {
            const GfVec3f &p = points[indices[corner + i]];
            const float u = 0.5f + std::atan2(p[0], p[2]) / float(2 * M_PI);
            const float v = 0.5f + std::asin(std::max(-1.0f, std::min(1.0f, p[1]))) / float(M_PI);
            face.push_back(GfVec2f(u, v));
        }
        // A face straddling the seam has corners near u = 0 and near u = 1;
        // move the small ones to just above 1 so the face doesn't span the
        // whole texture backwards.
        float minU = 1, maxU = 0;
        for (const GfVec2f &uv : face) {
            minU = std::min(minU, uv[0]);
            maxU = std::max(maxU, uv[0]);
        }
        if (maxU - minU > 0.5f) {
            for (GfVec2f &uv : face) {
                if (uv[0] < 0.5f) {
                    uv[0] += 1.0f;
                }
            }
        }
        // At a pole, u is meaningless (atan2 of ~0, ~0); use the average u
        // of the face's other corners, so the triangle fan meets cleanly.
        for (int i = 0; i < count; ++i) {
            if (std::abs(points[indices[corner + i]][1]) > 0.9999f) {
                float sum = 0;
                int others = 0;
                for (int j = 0; j < count; ++j) {
                    if (std::abs(points[indices[corner + j]][1]) <= 0.9999f) {
                        sum += face[j][0];
                        ++others;
                    }
                }
                if (others > 0) {
                    face[i][0] = sum / others;
                }
            }
        }
        for (const GfVec2f &uv : face) {
            st.push_back(uv);
        }
        corner += count;
    }
    return st;
}

/// Defines a finely tessellated sphere mesh of radius 1 at `path`, with
/// texture coordinates.
///
/// A UsdGeomSphere would be simpler, but UsdImaging tessellates implicit
/// spheres coarsely (about 10 sides), which ruins reflections. GeomUtil is
/// the same generator UsdImaging uses, just with more segments.
} // namespace

PXR_NAMESPACE_OPEN_SCOPE

UsdGeomMesh MGDefineSphereMesh(const UsdStageRefPtr &stage, const SdfPath &path) {
    using Generator = GeomUtilSphereMeshGenerator;
    const size_t numRadial = 96; // segments around the equator
    const size_t numAxial = 48;  // segments from pole to pole

    const PxOsdMeshTopology topology = Generator::GenerateTopology(numRadial, numAxial);

    // The generator puts the poles on the Z axis; our stage is Y-up, so turn
    // the sphere to put them on Y. (Until M1c the poles pointed roughly at
    // the camera, which only mattered once textures were mapped.)
    const GfMatrix4d poleToY = GfMatrix4d().SetRotate(GfRotation(GfVec3d(1, 0, 0), -90.0));

    VtVec3fArray points(Generator::ComputeNumPoints(numRadial, numAxial));
    Generator::GeneratePoints(points.begin(), numRadial, numAxial, 1.0f, &poleToY);

    VtVec3fArray normals(Generator::ComputeNumNormals(numRadial, numAxial));
    Generator::GenerateNormals(normals.begin(), numRadial, numAxial, &poleToY);

    UsdGeomMesh mesh = UsdGeomMesh::Define(stage, path);
    mesh.CreatePointsAttr(VtValue(points));
    mesh.CreateFaceVertexCountsAttr(VtValue(topology.GetFaceVertexCounts()));
    mesh.CreateFaceVertexIndicesAttr(VtValue(topology.GetFaceVertexIndices()));
    mesh.CreateNormalsAttr(VtValue(normals));
    mesh.SetNormalsInterpolation(UsdGeomTokens->vertex);
    // Plain polygons: no subdivision surface, use the normals as given.
    mesh.CreateSubdivisionSchemeAttr(VtValue(UsdGeomTokens->none));
    mesh.CreateExtentAttr(VtValue(VtVec3fArray{GfVec3f(-1.0f), GfVec3f(1.0f)}));

    // "st" is the primvar MaterialX's `texcoord` node reads in USD (UsdMtlx
    // and Storm use it for texture coordinate set 0).
    UsdGeomPrimvar st = UsdGeomPrimvarsAPI(mesh).CreatePrimvar(
        TfToken("st"), SdfValueTypeNames->TexCoord2fArray, UsdGeomTokens->faceVarying);
    st.Set(SphereTextureCoordinates(points, topology));
    return mesh;
}

PXR_NAMESPACE_CLOSE_SCOPE
