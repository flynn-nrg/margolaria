// ViewportSettings.swift
//
// How the viewport lights and shows a material (M3b): the environment
// around the sphere, and the OCIO view transform that turns Storm's
// scene-linear frames into what the screen shows. Both are viewer
// preferences, not part of documents: the app keeps them in user defaults.
//
// Introduces (SWIFT): enums with `String` raw values, `switch` as an
// expression, toll-free bridging (`as CFString`).

import ColorKit
import CoreGraphics
import Foundation

/// The light around the preview sphere.
///
/// SWIFT: `String` after the colon gives every case a *raw value*, here its
/// name ("studio"), so a setting can be stored as text and read back with
/// `ViewportEnvironment(rawValue:)`, which is nil for unknown text.
/// `CaseIterable` adds `allCases`, the list of every case, for menus.
public enum ViewportEnvironment: String, CaseIterable, Identifiable, Sendable {
    /// A neutral studio with soft boxes (StudioEnvironment.swift), and no
    /// key light. The default.
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

    /// The dome light's image, or nil for OpenUSD's default.
    var imageURL: URL? {
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

/// An OCIO display and view: how scene-linear light is shown on the screen.
///
/// The display is the kind of monitor ("sRGB - Display"), the view how
/// light is mapped onto it ("ACES 2.0 - SDR 100 nits (Rec.709)" tone-maps,
/// compressing highlights; "Un-tone-mapped" only encodes, as MaterialXView
/// does). The names are those of OCIO's studio config
/// (ColorConfiguration.studio).
public struct ViewportViewTransform: Hashable, Sendable {
    public var display: String
    public var view: String

    public init(display: String, view: String) {
        self.display = display
        self.view = view
    }

    /// The colour space Storm renders in: MaterialX's default working
    /// space, which Storm's MaterialX shaders convert every input to.
    static let sceneSpace: String = "lin_rec709"

    /// The Core Graphics colour space of each display the viewport offers:
    /// what the screen is told its pixels are, so that macOS shows them
    /// correctly whatever the actual screen.
    ///
    /// Only standard dynamic range displays whose encoding Core Graphics
    /// knows exactly. OCIO's "Display P3 - Display" is Apple's Display P3
    /// (P3 primaries, D65 white, the sRGB curve). The config's other
    /// displays (Rec.1886's 2.4 gamma, the HDR ones) have no exact Core
    /// Graphics equivalent, or need the screen in HDR mode.
    ///
    /// SWIFT: The values are Swift Strings, not the CFStrings Core
    /// Graphics names its spaces with: a `static let` must be `Sendable`
    /// (safe to share between threads) in Swift 6, and CFString isn't
    /// marked so. `as String` and `as CFString` convert for free (toll-free
    /// bridging, as between NSString and CFStringRef).
    private static let displayColorSpaces: [String: String] = [
        "sRGB - Display": CGColorSpace.sRGB as String,
        "Display P3 - Display": CGColorSpace.displayP3 as String,
    ]

    /// The displays the viewport offers, in the config's order. Empty
    /// without colour management.
    public static var displays: [String] {
        guard let config = try? ColorConfiguration.studio.get() else {
            return []
        }
        return config.displays.filter { displayColorSpaces[$0] != nil }
    }

    /// The views of `display`, in the config's order.
    public static func views(for display: String) -> [String] {
        (try? ColorConfiguration.studio.get().views(for: display)) ?? []
    }

    /// The config's default: its first display, and that display's default
    /// view (ACES 2.0). Nil without colour management.
    public static var standard: ViewportViewTransform? {
        guard let config = try? ColorConfiguration.studio.get(),
              let display = displays.first,
              let view = config.defaultView(for: display)
        else {
            return nil
        }
        return ViewportViewTransform(display: display, view: view)
    }

    /// True when this display and view exist and are offered.
    public var isAvailable: Bool {
        Self.displayColorSpaces[display] != nil && Self.views(for: display).contains(view)
    }

    /// The Core Graphics colour space of the transform's output.
    var colorSpace: CGColorSpace? {
        // SWIFT: `flatMap` on an optional: nil stays nil, otherwise the
        // closure's result (itself optional) is the answer.
        Self.displayColorSpaces[display].flatMap { CGColorSpace(name: $0 as CFString) }
    }

    /// The transform as Metal code, for DisplayPass.
    ///
    /// - Throws: ColorKit's error if OCIO is unavailable or a name unknown.
    func shader() throws -> GPUShader {
        try ColorConfiguration.studio.get().displayShader(from: Self.sceneSpace, display: display, view: view)
    }
}

extension MGStormRenderer {
    /// Lights the sphere with `environment`.
    public func use(_ environment: ViewportEnvironment) {
        environmentURL = environment.imageURL
        keyLightEnabled = environment.usesKeyLight
    }
}
