// ColorConfiguration.swift
//
// Colour management for the app (M3a; PLAN.md §5, "ColorService"): an
// OpenColorIO config, its colour spaces, and converters between them.
// ColorBridge (C++) does the OCIO calls; this is the Swift API on top.
//
// The app uses OCIO's built-in ACES studio config, which is compiled into
// the library: there is no config file to find or ship. MaterialX's colour
// space names (lin_rec709, srgb_texture, acescg, g22_ap1, ...) are aliases
// in it, so a `colorspace` attribute can be passed to OCIO as it is.
//
// Introduces (SWIFT): nothing new; the patterns are MXLibrary's (a class
// around a C++ handle, a lazily loaded shared instance held in a Result).

import ColorBridge
import CxxStdlib

/// An OpenColorIO config: the colour spaces a document's colours can be in.
///
/// SWIFT: `@unchecked Sendable`, as for MXLibrary: only `let` properties,
/// and the C++ config is never changed after loading. OCIO configs are safe
/// to read from several threads (see ColorBridge.h).
public final class ColorConfiguration: @unchecked Sendable {
    /// The C++ handle.
    let handle: colorbridge.Config

    /// The config's name, such as "studio-config-v4.0.0_aces-v2.0_ocio-v2.5".
    public let name: String

    /// Every active colour space, scene and display ones, in the config's order.
    public let colorSpaces: [ColorSpace]

    /// The built-in config the app uses: the latest ACES studio config of
    /// this OCIO version (ACES 2.0 for OCIO 2.5).
    public static let studioURI: String = "ocio://studio-config-latest"

    /// The studio config, loaded on first use and then shared by the whole
    /// process. Holds the error instead if loading failed, so the UI can
    /// carry on without colour management rather than crash.
    public static let studio: Result<ColorConfiguration, any Error> = Result {
        try ColorConfiguration(builtin: studioURI)
    }

    /// OpenColorIO's version, such as "2.5.2".
    public static var ocioVersion: String {
        colorbridge.ocioVersion().colorKitString
    }

    /// Loads one of OCIO's built-in configs, such as ``studioURI``.
    public init(builtin uri: String) throws {
        var errorMessage = std.string()
        let config = colorbridge.Config.builtin(std.string(uri), &errorMessage)
        guard config.isLoaded() else {
            throw ColorError.configLoadFailed(errorMessage.colorKitString)
        }
        handle = config
        name = config.name().colorKitString
        colorSpaces = config.colorSpaces().map(ColorSpace.init)
    }

    /// The colour space with this name or alias, ignoring case ("acescg"
    /// finds "ACEScg"), or nil if the config has none.
    public func colorSpace(named name: String) -> ColorSpace? {
        let canonical: String = handle.canonicalName(std.string(name)).colorKitString
        guard !canonical.isEmpty else {
            return nil
        }
        return colorSpaces.first { $0.name == canonical }
    }

    /// A converter from one colour space to another, each given by name or
    /// alias.
    ///
    /// - Throws: ``ColorError/conversionFailed(_:)`` if either space is unknown.
    public func converter(from source: String, to destination: String) throws -> ColorConverter {
        var errorMessage = std.string()
        let processor = handle.processor(std.string(source), std.string(destination), &errorMessage)
        guard processor.isLoaded() else {
            throw ColorError.conversionFailed(errorMessage.colorKitString)
        }
        return ColorConverter(handle: processor)
    }
}

/// One colour space of a config.
public struct ColorSpace: Hashable, Identifiable, Sendable {
    /// The config's name, such as "ACEScg".
    public let name: String
    /// Other names that find it, MaterialX's among them ("acescg", "lin_ap1").
    public let aliases: [String]
    /// The config's grouping, such as "ACES" or "Utility".
    public let family: String
    /// The config's description of it.
    public let description: String
    /// "scene-linear", "sdr-video", "log", ...; empty when the config doesn't say.
    public let encoding: String
    /// A data space ("Raw"): numbers that aren't colours, left alone by conversions.
    public let isData: Bool
    /// A display space (what a monitor shows) rather than a scene space.
    public let isDisplay: Bool

    public var id: String { name }

    /// Copies the C++ description.
    init(_ info: colorbridge.ColorSpaceInfo) {
        name = info.name.colorKitString
        aliases = info.aliases.map(\.colorKitString)
        family = info.family.colorKitString
        description = info.description.colorKitString
        encoding = info.encoding.colorKitString
        isData = info.isData
        isDisplay = info.isDisplay
    }
}
