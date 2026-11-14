// MGPreviewShape.h
//
// The shapes a material can be previewed on (M7a): the viewport's, and the
// one Export as USDZ… writes. Plain Objective-C, so Swift sees an ordinary
// enum (`MGPreviewShape.shaderBall`); the meshes themselves are built in
// MGPreviewShapes.mm.

#import <Foundation/Foundation.h>

/// A preview shape. Each fits about the sphere's room (radius 1 around the
/// origin, Y up), so the camera frames them all alike, and has texture
/// coordinates ("st") and normals.
typedef NS_ENUM(NSInteger, MGPreviewShape) {
    /// A sphere of radius 1, poles on Y. The default.
    MGPreviewShapeSphere,
    /// A square card, 2 across, upright and facing +Z (the camera's side),
    /// textured once across. Seen from both sides.
    MGPreviewShapePlane,
    /// An upright cylinder with softly rounded edges and flat caps: the
    /// side textured once around, the caps across.
    MGPreviewShapeCylinder,
    /// A square cloth draped over a hidden ball, hanging in folds: for
    /// fabrics. Textured once across the flat cloth. Seen from both sides.
    MGPreviewShapeCloth,
    /// Margolaria's shader ball: a ball with a groove around its middle,
    /// on a foot, to show a material on convex, concave and flat parts.
    MGPreviewShapeShaderBall,
};
