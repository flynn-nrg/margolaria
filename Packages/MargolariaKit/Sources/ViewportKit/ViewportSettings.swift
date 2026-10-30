// ViewportSettings.swift
//
// How the viewport lights a material (M3b): the environment around the
// sphere. A viewer preference, not part of documents: the app keeps it in
// user defaults. The view transform, the other setting, is ColorKit's
// ViewTransform (shared with the swatches since M3c).
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

extension MGStormRenderer {
    /// Lights the sphere with `environment`.
    public func use(_ environment: ViewportEnvironment) {
        environmentURL = environment.imageURL
        keyLightEnabled = environment.usesKeyLight
    }
}
