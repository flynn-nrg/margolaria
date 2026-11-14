// MGPreviewShapes.mm
//
// The preview shapes (MGPreviewShapes.h). The sphere moved out of
// MGStormRenderer.mm in M5a, for the USD exporter; the others came in M7a.
//
// The sphere comes from OpenUSD's own generator. The others are built
// here: the plane and the cloth as grids, the cylinder and the shader ball
// by turning a profile around the Y axis (`Lathe`), as a lathe does. Every
// vertex has its own normal and texture coordinates ("vertex"
// interpolation), so a seam or a sharp edge is two rows of vertices at the
// same place.

#import "MGPreviewShapes.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include <pxr/base/gf/matrix4d.h>
#include <pxr/base/gf/range3f.h>
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
UsdGeomMesh DefineSphereMesh(const UsdStageRefPtr &stage, const SdfPath &path) {
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


// --- The other shapes (M7a) ---------------------------------------------

/// A mesh being built: one normal and one pair of texture coordinates per
/// point.
struct MeshData {
    std::vector<GfVec3f> points;
    std::vector<GfVec3f> normals;
    std::vector<GfVec2f> st;
    VtIntArray counts;
    VtIntArray indices;

    /// Adds a vertex and returns its index.
    int AddVertex(const GfVec3f &point, const GfVec3f &normal, const GfVec2f &uv) {
        points.push_back(point);
        normals.push_back(normal);
        st.push_back(uv);
        return static_cast<int>(points.size()) - 1;
    }

    /// Adds a face, its corners turned the way USD expects (anticlockwise
    /// seen from outside, "rightHanded"): if the corners' order makes the
    /// face point against its vertices' normals, it is reversed. Saves
    /// working out the order by hand for every part.
    void AddFace(std::vector<int> corners) {
        // Newell's method: the face's normal, for any polygon.
        GfVec3f geometric(0.0f);
        GfVec3f given(0.0f);
        for (size_t i = 0; i < corners.size(); ++i) {
            const GfVec3f &a = points[corners[i]];
            const GfVec3f &b = points[corners[(i + 1) % corners.size()]];
            geometric += GfVec3f((a[1] - b[1]) * (a[2] + b[2]), (a[2] - b[2]) * (a[0] + b[0]),
                                 (a[0] - b[0]) * (a[1] + b[1]));
            given += normals[corners[i]];
        }
        if (GfDot(geometric, given) < 0.0f) {
            std::reverse(corners.begin(), corners.end());
        }
        counts.push_back(static_cast<int>(corners.size()));
        for (const int corner : corners) {
            indices.push_back(corner);
        }
    }

    /// Normals from the faces, for a shape without exact ones (the
    /// cloth): each point's is the sum of its faces' normals, which
    /// weights them by area.
    void ComputeNormals() {
        std::fill(normals.begin(), normals.end(), GfVec3f(0.0f));
        size_t corner = 0;
        for (const int count : counts) {
            for (int i = 0; i < count; ++i) {
                const GfVec3f &p = points[indices[corner + i]];
                const GfVec3f &next = points[indices[corner + (i + 1) % count]];
                const GfVec3f &previous = points[indices[corner + (i + count - 1) % count]];
                normals[indices[corner + i]] += GfCross(next - p, previous - p);
            }
            corner += count;
        }
        for (GfVec3f &normal : normals) {
            normal.Normalize();
        }
    }

    /// Moves the points so the shape's bounding box is centred on the
    /// origin, as the sphere is.
    void Centre() {
        GfRange3f box;
        for (const GfVec3f &p : points) {
            box.UnionWith(p);
        }
        const GfVec3f middle = box.GetMidpoint();
        for (GfVec3f &p : points) {
            p -= middle;
        }
    }
};

/// A point of a profile turned by `Lathe`: its distance from the Y axis,
/// its height, and its normal in the same plane (outwards, unit length).
struct ProfilePoint {
    float r;
    float y;
    GfVec2f normal;
};

/// A part of a profile, smooth inside: where two sections meet, the
/// surface has an edge (their points are separate vertices).
struct ProfileSection {
    std::vector<ProfilePoint> points;
    /// How it is textured. Turned (the default): u once around, v along
    /// the profile, by length, continuing from section to section. Flat:
    /// across, as seen from above (`top`) or from below, for caps.
    enum class Mapping { turned, flatTop, flatBottom } mapping = Mapping::turned;

    /// Appends a straight line from the last point (or from `from`, if the
    /// section is empty) to `to`, in `steps` pieces. The normal is the
    /// line's direction turned clockwise: outwards for a profile drawn from
    /// the bottom up on the outside, up for a top cap drawn inwards.
    void Line(const GfVec2f &from, const GfVec2f &to, int steps) {
        const GfVec2f direction = (to - from).GetNormalized();
        const GfVec2f normal(direction[1], -direction[0]);
        for (int i = points.empty() ? 0 : 1; i <= steps; ++i) {
            const GfVec2f p = from + (to - from) * (float(i) / steps);
            points.push_back({p[0], p[1], normal});
        }
    }

    /// Appends an arc around `centre` from angle `from` to `to` (degrees,
    /// anticlockwise from the +r axis), in `steps` pieces. Drawn
    /// anticlockwise, it bulges out (a rounded edge, a ball); clockwise, it
    /// is hollow (a fillet, a groove), and its normals point to the centre.
    void Arc(const GfVec2f &centre, float radius, float from, float to, int steps) {
        const float sign = to > from ? 1.0f : -1.0f;
        for (int i = points.empty() ? 0 : 1; i <= steps; ++i) {
            const float angle = float(M_PI / 180.0) * (from + (to - from) * float(i) / steps);
            const GfVec2f outward(std::cos(angle), std::sin(angle));
            GfVec2f p = centre + outward * radius;
            // On the axis exactly, where cos(90°) leaves a trace, so Lathe
            // closes the shape there.
            if (std::abs(p[0]) < 1e-5f) {
                p[0] = 0.0f;
            }
            points.push_back({p[0], p[1], outward * sign});
        }
    }
};

/// Turns `sections` around the Y axis in `around` steps. A section's
/// first or last point on the axis (r = 0) closes it with triangles.
void Lathe(MeshData &mesh, const std::vector<ProfileSection> &sections, int around) {
    // v by length along the turned sections, so a texture isn't stretched
    // along the profile.
    float total = 0.0f;
    for (const ProfileSection &section : sections) {
        if (section.mapping != ProfileSection::Mapping::turned) {
            continue;
        }
        for (size_t i = 1; i < section.points.size(); ++i) {
            total += std::hypot(section.points[i].r - section.points[i - 1].r,
                                section.points[i].y - section.points[i - 1].y);
        }
    }
    float length = 0.0f;
    for (const ProfileSection &section : sections) {
        // The flat parts' size, for mapping them across once.
        float capRadius = 0.0f;
        for (const ProfilePoint &p : section.points) {
            capRadius = std::max(capRadius, p.r);
        }
        // Rows of `around + 1` vertices: the first and last are at the
        // same place, with u = 0 and u = 1 (the seam, behind, as the
        // sphere's).
        std::vector<int> rows;
        for (size_t i = 0; i < section.points.size(); ++i) {
            const ProfilePoint &p = section.points[i];
            if (i > 0 && section.mapping == ProfileSection::Mapping::turned) {
                length += std::hypot(p.r - section.points[i - 1].r, p.y - section.points[i - 1].y);
            }
            rows.push_back(static_cast<int>(mesh.points.size()));
            for (int j = 0; j <= around; ++j) {
                const float u = float(j) / around;
                // Starting behind (-Z), so u = 0.5 faces the camera (+Z).
                const float angle = float(2 * M_PI) * u - float(M_PI);
                const float s = std::sin(angle);
                const float c = std::cos(angle);
                const GfVec3f point(p.r * s, p.y, p.r * c);
                const GfVec3f normal(p.normal[0] * s, p.normal[1], p.normal[0] * c);
                GfVec2f uv;
                switch (section.mapping) {
                case ProfileSection::Mapping::turned:
                    // On the axis, each triangle of the fan has its own
                    // vertex there, in the middle of its u span.
                    uv = GfVec2f(p.r == 0.0f ? (j + 0.5f) / around : u, length / total);
                    break;
                case ProfileSection::Mapping::flatTop:
                    uv = GfVec2f(0.5f + point[0] / (2 * capRadius), 0.5f - point[2] / (2 * capRadius));
                    break;
                case ProfileSection::Mapping::flatBottom:
                    uv = GfVec2f(0.5f + point[0] / (2 * capRadius), 0.5f + point[2] / (2 * capRadius));
                    break;
                }
                mesh.AddVertex(point, normal, uv);
            }
        }
        for (size_t i = 0; i + 1 < rows.size(); ++i) {
            const bool lowerOnAxis = section.points[i].r == 0.0f;
            const bool upperOnAxis = section.points[i + 1].r == 0.0f;
            for (int j = 0; j < around; ++j) {
                const int a = rows[i] + j, b = rows[i] + j + 1;
                const int c = rows[i + 1] + j + 1, d = rows[i + 1] + j;
                if (lowerOnAxis) {
                    mesh.AddFace({a, c, d});
                } else if (upperOnAxis) {
                    mesh.AddFace({a, b, d});
                } else {
                    mesh.AddFace({a, b, c, d});
                }
            }
        }
    }
}

/// How many steps around the turned shapes: the sphere's 96.
constexpr int kAround = 96;

/// The plane: a square card 2 across, upright, facing +Z.
MeshData PlaneMesh() {
    MeshData mesh;
    // Finely divided anyway: the lights fall across it more evenly, and a
    // displacement would have points to move.
    const int steps = 32;
    for (int j = 0; j <= steps; ++j) {
        for (int i = 0; i <= steps; ++i) {
            const float u = float(i) / steps, v = float(j) / steps;
            mesh.AddVertex(GfVec3f(2 * u - 1, 2 * v - 1, 0), GfVec3f(0, 0, 1), GfVec2f(u, v));
        }
    }
    for (int j = 0; j < steps; ++j) {
        for (int i = 0; i < steps; ++i) {
            const int a = j * (steps + 1) + i;
            mesh.AddFace({a, a + 1, a + steps + 2, a + steps + 1});
        }
    }
    return mesh;
}

/// The cylinder: radius 0.8, 1.8 high, its edges rounded (radius 0.08),
/// so highlights run along them as on a real object.
MeshData CylinderMesh() {
    const float radius = 0.8f, half = 0.9f, round = 0.08f;
    ProfileSection bottom, side, top;
    bottom.mapping = ProfileSection::Mapping::flatBottom;
    bottom.Line(GfVec2f(0, -half), GfVec2f(radius - round, -half), 8);
    side.Arc(GfVec2f(radius - round, -half + round), round, -90, 0, 8);
    side.Line(GfVec2f(radius, -half + round), GfVec2f(radius, half - round), 24);
    side.Arc(GfVec2f(radius - round, half - round), round, 0, 90, 8);
    top.mapping = ProfileSection::Mapping::flatTop;
    top.Line(GfVec2f(radius - round, half), GfVec2f(0, half), 8);
    MeshData mesh;
    Lathe(mesh, {bottom, side, top}, kAround);
    return mesh;
}

/// Margolaria's shader ball: a ball (radius 0.78) with a groove around its
/// middle, on a neck and a round foot. The groove's sharp edges and hollow,
/// the ball, and the foot's flat top and rounded rim show a material on
/// every kind of curvature.
MeshData ShaderBallMesh() {
    const GfVec2f centre(0, 0.08f);
    const float radius = 0.78f, groove = 0.05f, neck = 0.2f;
    // Where the neck meets the ball, and the groove's edges on it.
    const float neckAngle = float(std::asin(-std::sqrt(radius * radius - neck * neck) / radius) * 180 / M_PI);
    const float grooveAngle = float(std::asin(groove / radius) * 180 / M_PI);
    const float grooveR = std::sqrt(radius * radius - groove * groove);

    ProfileSection base, foot, lower, hollow, upper;
    base.mapping = ProfileSection::Mapping::flatBottom;
    base.Line(GfVec2f(0, -1.0f), GfVec2f(0.63f, -1.0f), 8);
    // The foot's rim, its top sloping in to the neck, a fillet, the neck.
    foot.Arc(GfVec2f(0.63f, -0.95f), 0.05f, -90, 0, 6);
    foot.Line(GfVec2f(0.68f, -0.95f), GfVec2f(0.68f, -0.88f), 4);
    foot.Arc(GfVec2f(0.63f, -0.88f), 0.05f, 0, 90, 6);
    foot.Line(GfVec2f(0.63f, -0.83f), GfVec2f(0.30f, -0.80f), 12);
    foot.Arc(GfVec2f(0.30f, -0.70f), 0.10f, -90, -180, 8);
    foot.Line(GfVec2f(neck, -0.70f), GfVec2f(neck, centre[1] + radius * float(std::sin(neckAngle * M_PI / 180))), 2);
    // The ball below the groove, the groove (hollow: drawn clockwise),
    // and the ball above it, up to the top.
    lower.Arc(centre, radius, neckAngle, -grooveAngle, 36);
    hollow.Arc(GfVec2f(grooveR, centre[1]), groove, 270, 90, 12);
    upper.Arc(centre, radius, grooveAngle, 90, 40);

    MeshData mesh;
    Lathe(mesh, {base, foot, lower, hollow, upper}, kAround);
    mesh.Centre();
    return mesh;
}

/// The cloth: a square cloth, 2.4 across, dropped on a ball (radius 0.7,
/// not drawn). It lies on the ball's top, leaves it 55° from the top,
/// bends down, and hangs in folds, which grow as it falls: the cloth is
/// wider than the circle it hangs from. The corners, farther from the
/// middle, hang lowest, as a handkerchief's do.
///
/// Shaped by formula rather than simulated, so it is the same every time
/// and costs nothing; its normals come from its faces.
MeshData ClothMesh() {
    const float size = 2.4f, ball = 0.7f;
    const float leave = float(55 * M_PI / 180); // where it leaves the ball
    const float bend = 0.35f;                     // how long it takes to hang straight
    const int steps = 128;

    MeshData mesh;
    for (int j = 0; j <= steps; ++j) {
        for (int i = 0; i <= steps; ++i) {
            const float u = float(i) / steps, v = float(j) / steps;
            // Where the point is on the flat cloth: x across, z towards
            // the camera; and so how far from the middle, in which direction.
            const float x = (u - 0.5f) * size, z = (0.5f - v) * size;
            const float distance = std::hypot(x, z);
            const float direction = std::atan2(z, x);
            float out, height;
            if (distance <= ball * leave) {
                // On the ball.
                out = ball * std::sin(distance / ball);
                height = ball * std::cos(distance / ball);
            } else {
                // Off it: from where it leaves, heading down at the ball's
                // slope there, turning to hang straight down. Followed in
                // small steps along the cloth.
                out = ball * std::sin(leave);
                height = ball * std::cos(leave);
                const float hanging = distance - ball * leave;
                const int pieces = 48;
                const float piece = std::min(hanging, bend) / pieces;
                for (int k = 0; k < pieces; ++k) {
                    const float t = (k + 0.5f) * piece / bend;
                    const float smooth = t * t * (3 - 2 * t);
                    const float slope = leave + (float(M_PI / 2) - leave) * smooth;
                    out += std::cos(slope) * piece;
                    height -= std::sin(slope) * piece;
                }
                height -= std::max(0.0f, hanging - bend);
                // The folds: eight around, unevenly spaced, deeper lower down.
                const float depth = 0.09f * std::min(1.0f, hanging / 0.6f);
                out += depth * std::sin(8 * direction + 0.8f * std::sin(2 * direction + 0.5f));
            }
            mesh.AddVertex(GfVec3f(out * std::cos(direction), height, out * std::sin(direction)), GfVec3f(0, 1, 0),
                           GfVec2f(u, v));
        }
    }
    for (int j = 0; j < steps; ++j) {
        for (int i = 0; i < steps; ++i) {
            const int a = j * (steps + 1) + i;
            // Anticlockwise seen from above, while the cloth is still flat:
            // the top side out.
            mesh.counts.push_back(4);
            for (const int corner : {a, a + 1, a + steps + 2, a + steps + 1}) {
                mesh.indices.push_back(corner);
            }
        }
    }
    mesh.ComputeNormals();
    // A little larger, to fill about the sphere's room.
    for (GfVec3f &p : mesh.points) {
        p *= 1.15f;
    }
    mesh.Centre();
    return mesh;
}

/// Defines `data` as a mesh at `path`.
UsdGeomMesh DefineMesh(const UsdStageRefPtr &stage, const SdfPath &path, const MeshData &data, bool doubleSided) {
    VtVec3fArray points(data.points.begin(), data.points.end());
    GfRange3f box;
    for (const GfVec3f &p : data.points) {
        box.UnionWith(p);
    }
    UsdGeomMesh mesh = UsdGeomMesh::Define(stage, path);
    mesh.CreatePointsAttr(VtValue(points));
    mesh.CreateFaceVertexCountsAttr(VtValue(data.counts));
    mesh.CreateFaceVertexIndicesAttr(VtValue(data.indices));
    mesh.CreateNormalsAttr(VtValue(VtVec3fArray(data.normals.begin(), data.normals.end())));
    mesh.SetNormalsInterpolation(UsdGeomTokens->vertex);
    mesh.CreateSubdivisionSchemeAttr(VtValue(UsdGeomTokens->none));
    mesh.CreateExtentAttr(VtValue(VtVec3fArray{box.GetMin(), box.GetMax()}));
    // A card or a cloth is seen from behind too; closed shapes aren't.
    mesh.CreateDoubleSidedAttr(VtValue(doubleSided));
    UsdGeomPrimvar st = UsdGeomPrimvarsAPI(mesh).CreatePrimvar(TfToken("st"), SdfValueTypeNames->TexCoord2fArray,
                                                               UsdGeomTokens->vertex);
    st.Set(VtVec2fArray(data.st.begin(), data.st.end()));
    return mesh;
}

} // namespace

PXR_NAMESPACE_OPEN_SCOPE

UsdGeomMesh MGDefinePreviewMesh(const UsdStageRefPtr &stage, const SdfPath &path, MGPreviewShape shape) {
    // Another shape at the same path starts afresh: none of the old
    // mesh's attributes (face-varying "st", doubleSided) may linger.
    stage->RemovePrim(path);
    switch (shape) {
    case MGPreviewShapePlane:
        return DefineMesh(stage, path, PlaneMesh(), true);
    case MGPreviewShapeCylinder:
        return DefineMesh(stage, path, CylinderMesh(), false);
    case MGPreviewShapeCloth:
        return DefineMesh(stage, path, ClothMesh(), true);
    case MGPreviewShapeShaderBall:
        return DefineMesh(stage, path, ShaderBallMesh(), false);
    case MGPreviewShapeSphere:
    default:
        return DefineSphereMesh(stage, path);
    }
}

std::string MGPreviewShapeName(MGPreviewShape shape) {
    switch (shape) {
    case MGPreviewShapePlane:
        return "Plane";
    case MGPreviewShapeCylinder:
        return "Cylinder";
    case MGPreviewShapeCloth:
        return "Cloth";
    case MGPreviewShapeShaderBall:
        return "ShaderBall";
    case MGPreviewShapeSphere:
    default:
        return "Sphere";
    }
}

PXR_NAMESPACE_CLOSE_SCOPE
