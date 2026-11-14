// ViewportSettings.swift
//
// How the viewport lights a material (M3b): the environment around the
// sphere. A viewer preference, not part of documents: the app keeps it in
// user defaults. The view transform, the other setting, is ColorKit's
// ViewTransform (shared with the swatches since M3c).
//
// Since M5e, also the Hydra renderer that draws it (ViewportRenderer):
// Storm, or another renderer plugin found at run time. Today that is Storm
// alone: SwiftUsd's other one, Embree, is left out (see `unusable`).
//
// Since M7a, the shape the material is shown on (ViewportShape), which
// Export as USDZ… writes too.
//
// Introduces (SWIFT): enums with `String` raw values, `switch` as an
// expression.

import Foundation
import PreviewKit

/// The light around the preview sphere.
///
/// SWIFT: `String` after the colon gives every case a *raw value*, here its
/// name ("studio"), so a setting can be stored as text and read back with
/// `ViewportEnvironment(rawValue:)`, which is nil for unknown text.
/// `CaseIterable` adds `allCases`, the list of every case, for menus.
public enum ViewportEnvironment: String, CaseIterable, Identifiable, Sendable {
    /// A neutral studio with soft boxes (PreviewKit's StudioEnvironment),
    /// and no key light. The default.
    case studio
    /// OpenUSD's default outdoor environment (usdview's), with a distant
    /// key light: the viewport's lighting before M3b.
    case outdoor

    public var id: String { rawValue }

    /// The name shown in menus.
    ///
    /// SWIFT: Since Swift 5.9, `switch` can be an expression whose value is
    /// that of the chosen case, like a C ternary over many cases.
    public var title: String {
        switch self {
        case .studio: "Studio"
        case .outdoor: "Outdoor"
        }
    }

    /// The dome light's image, or nil for OpenUSD's default
    /// (StinsonBeach.hdr). The swatches are lit by the same image.
    public var imageURL: URL? {
        switch self {
        case .studio: StudioEnvironment.fileURL
        case .outdoor: nil
        }
    }

    /// Whether the distant key light shines too.
    var usesKeyLight: Bool {
        self == .outdoor
    }
}

/// The shape the material is shown on (M7a). Swatches stay spheres.
public enum ViewportShape: String, CaseIterable, Identifiable, Sendable {
    case sphere
    case plane
    case cylinder
    /// A square cloth draped over a ball, in folds: for fabrics.
    case cloth
    /// Margolaria's shader ball: a grooved ball on a foot.
    case shaderBall = "shader_ball"

    /// The raw value, as scripts and the command line name the shape
    /// (`shape="shader_ball"`, `--shape shader_ball`).
    public var id: String { rawValue }

    /// The name shown in menus.
    public var title: String {
        switch self {
        case .sphere: "Sphere"
        case .plane: "Plane"
        case .cylinder: "Cylinder"
        case .cloth: "Cloth"
        case .shaderBall: "Shader Ball"
        }
    }

    /// The user defaults key the app keeps the choice under, for every
    /// viewport (`@AppStorage`) and for Export as USDZ….
    public static let defaultsKey: String = "viewportShape"

    /// The shape chosen in the app, the sphere until one is.
    public static var chosen: ViewportShape {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(ViewportShape.init(rawValue:)) ?? .sphere
    }

    /// The same shape, as ViewportBridge names it.
    public var bridged: MGPreviewShape {
        switch self {
        case .sphere: .sphere
        case .plane: .plane
        case .cylinder: .cylinder
        case .cloth: .cloth
        case .shaderBall: .shaderBall
        }
    }
}

extension MGStormRenderer {
    /// Lights the sphere with `environment`.
    public func use(_ environment: ViewportEnvironment) {
        environmentURL = environment.imageURL
        keyLightEnabled = environment.usesKeyLight
    }
}

/// A Hydra renderer the viewport can draw with (M5e): Storm, or another
/// renderer plugin found when the app runs.
///
/// Unlike ViewportEnvironment, not an enum: the renderers are known only
/// at run time, from the plugins OpenUSD finds. The app stores the `id`.
public struct ViewportRenderer: Hashable, Identifiable, Sendable {
    /// The plugin's identifier, such as "HdStormRendererPlugin".
    public let id: String

    /// The name the plugin gives itself, such as "Embree", for menus.
    public var title: String {
        MGStormRenderer.displayName(forRendererID: id)
    }

    /// What it shows, for the picker's help tag.
    public var summary: String {
        switch id {
        case Self.storm.id:
            "Rendered by Hydra Storm on Metal, as in usdview: the document's MaterialX materials"
        default:
            "Rendered by the Hydra renderer \(title)"
        }
    }

    /// SWIFT: A `static let` is a constant of the type itself, read as
    /// `ViewportRenderer.storm` (or `.storm` where the type is known), and
    /// made once, on first use.
    ///
    /// Storm, the default: the renderer that draws MaterialX.
    public static let storm = ViewportRenderer(id: "HdStormRendererPlugin")

    /// Renderer plugins found but not offered.
    ///
    /// Embree (SwiftUsd's, OpenUSD's example path tracer): OpenUSD 26.08's
    /// Hydra copies its depth output, drawn on the CPU, from an R32Float
    /// texture into a Depth32Float one, a copy Metal doesn't allow; with
    /// Metal's validation on (Xcode's Debug runs) the app stops there
    /// (PLAN.md §8.2, M5e). It draws only shape anyway, not materials.
    static let unusable: Set<String> = ["HdEmbreeRendererPlugin"]

    /// Every renderer found and usable, Storm first.
    public static var available: [ViewportRenderer] {
        MGStormRenderer.availableRendererIDs.filter { !unusable.contains($0) }.map { ViewportRenderer(id: $0) }
    }

    /// The renderer `id` names if it is still found (a stored choice, from
    /// an earlier launch), otherwise Storm.
    public static func preferred(id: String) -> ViewportRenderer {
        available.first(where: { $0.id == id }) ?? .storm
    }
}
