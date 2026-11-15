// ViewTransform.swift
//
// An OCIO display and view: how scene-linear light becomes what the screen
// shows. The viewport (M3b) and the canvas's swatches (M3c) use the same
// one, so a node's swatch and the viewport agree. Chosen in the viewport's
// menu, kept in user defaults by the app.
//
// Moved here from ViewportKit in M3c (it was `ViewportViewTransform`), now
// that two kits use it.
//
// Introduces (SWIFT): nothing new (toll-free bridging, `as CFString`, is
// explained here; it appeared in M3b, when this was in ViewportSettings).

import CoreGraphics
import Foundation

/// An OCIO display and view.
///
/// The display is the kind of monitor ("sRGB - Display"), the view how
/// light is mapped onto it ("ACES 2.0 - SDR 100 nits (Rec.709)" tone-maps,
/// compressing highlights; "Un-tone-mapped" only encodes, as MaterialXView
/// does). The names are those of OCIO's studio config
/// (ColorConfiguration.studio).
public struct ViewTransform: Hashable, Sendable {
    public var display: String
    public var view: String

    public init(display: String, view: String) {
        self.display = display
        self.view = view
    }

    /// The colour space renders are in by default: MaterialX's default
    /// working space, which Storm's MaterialX shaders convert every input
    /// to. Since M7e, a swatch is in its document's working space, which
    /// may be another (``shader(from:)``).
    public static let sceneSpace: String = "lin_rec709"

    /// The Core Graphics colour space of each display offered: what the
    /// screen is told its pixels are, so that macOS shows them correctly
    /// whatever the actual screen.
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

    /// The displays offered, in the config's order. Empty without colour
    /// management.
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
    public static var standard: ViewTransform? {
        guard let config = try? ColorConfiguration.studio.get(),
              let display = displays.first,
              let view = config.defaultView(for: display)
        else {
            return nil
        }
        return ViewTransform(display: display, view: view)
    }

    /// `display` and `view` if they are offered, otherwise the default:
    /// how the app reads back a choice it saved, which a newer config may
    /// no longer have. Nil without colour management.
    public static func preferred(display: String, view: String) -> ViewTransform? {
        let chosen = ViewTransform(display: display, view: view)
        return chosen.isAvailable ? chosen : .standard
    }

    /// The same display's "Raw" view: values shown as they are, with no
    /// conversion at all. For data (roughness, masks, normals,
    /// positions), whose numbers aren't light and shouldn't be tone-mapped
    /// (M3d): a roughness of 0.5 shows as half the display's white. Nil if
    /// the config has no Raw view for this display.
    public var raw: ViewTransform? {
        let raw = ViewTransform(display: display, view: "Raw")
        return raw.isAvailable ? raw : nil
    }

    /// True when this display and view exist and are offered.
    public var isAvailable: Bool {
        Self.displayColorSpaces[display] != nil && Self.views(for: display).contains(view)
    }

    /// The Core Graphics colour space of the transform's output.
    public var colorSpace: CGColorSpace? {
        // SWIFT: `flatMap` on an optional: nil stays nil, otherwise the
        // closure's result (itself optional) is the answer.
        Self.displayColorSpaces[display].flatMap { CGColorSpace(name: $0 as CFString) }
    }

    /// The transform as Metal code, for PreviewKit's DisplayPass: from
    /// renders in `space` (M7e: the swatches compute in the document's
    /// working space; Storm, always in ``sceneSpace``).
    ///
    /// - Throws: ColorKit's error if OCIO is unavailable or a name unknown.
    public func shader(from space: String = sceneSpace) throws -> GPUShader {
        try ColorConfiguration.studio.get().displayShader(from: space, display: display, view: view)
    }
}
