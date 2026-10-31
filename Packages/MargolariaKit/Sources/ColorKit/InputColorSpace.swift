// InputColorSpace.swift
//
// The colour spaces an input can be tagged with, and converting a colour's
// numbers from one to another (the inspector's colour space menu, after
// M3e). MaterialX stores a colour as numbers plus the name of the space
// they are in (`colorspace`, or the document's working space). Changing the
// space can mean two things:
//
//   convert       the colour stays the same: new numbers, new tag
//                 (0.5 grey in srgb_texture is 0.214 in lin_rec709)
//   reinterpret   the numbers stay the same: new tag only, so the colour
//                 changes (for a value typed in the wrong space)
//
// Image `file` inputs are only ever retagged: their numbers are in the file.
//
// Introduces (SWIFT): nothing new.

import Foundation

/// A colour space MaterialX names, as the inspector's menu offers it.
public struct InputColorSpace: Hashable, Identifiable, Sendable {
    /// Its MaterialX name, as written in `colorspace`.
    public let name: String
    /// A description for the menu, such as "sRGB encoded".
    public let title: String

    public var id: String { name }

    /// True for linear spaces (`lin_*` and ACEScg), the ones that make
    /// sense as a document's working space: shading adds and multiplies
    /// light, which only works on linear values.
    public var isLinear: Bool {
        name.hasPrefix("lin_") || name == "acescg"
    }

    public init(name: String, title: String) {
        self.name = name
        self.title = title
    }

    /// The space of a colour without any `colorspace` in a document that
    /// doesn't say: MaterialX's default working space.
    public static let documentDefault: String = "lin_rec709"

    /// The colour spaces of MaterialX's specification (1.39, "Color
    /// Spaces and Color Management Systems"), without the aliases
    /// (`lin_ap1` is acescg, `lin_srgb` is lin_rec709). Linear spaces
    /// first, then the encoded ones textures and display colours use.
    public static let standard: [InputColorSpace] = [
        InputColorSpace(name: "lin_rec709", title: "Linear Rec.709"),
        InputColorSpace(name: "acescg", title: "ACEScg (linear AP1)"),
        InputColorSpace(name: "lin_adobergb", title: "Linear Adobe RGB"),
        InputColorSpace(name: "lin_displayp3", title: "Linear Display P3"),
        InputColorSpace(name: "srgb_texture", title: "sRGB encoded"),
        InputColorSpace(name: "srgb_displayp3", title: "Display P3 encoded"),
        InputColorSpace(name: "adobergb", title: "Adobe RGB encoded"),
        InputColorSpace(name: "g22_rec709", title: "Gamma 2.2 Rec.709"),
        InputColorSpace(name: "g18_rec709", title: "Gamma 1.8 Rec.709"),
        InputColorSpace(name: "g22_ap1", title: "Gamma 2.2 AP1"),
        InputColorSpace(name: "g18_ap1", title: "Gamma 1.8 AP1"),
    ]

    /// The standard spaces `configuration` (the studio config by default)
    /// can convert: all but g18_ap1 with OCIO's built-in ACES config, which
    /// lacks it. Empty without colour management.
    public static func available(in configuration: ColorConfiguration? = nil) -> [InputColorSpace] {
        // SWIFT: `try?` gives nil for a config that failed to load, and
        // `guard let` turns that into "nothing to offer".
        guard let config = configuration ?? (try? ColorConfiguration.studio.get()) else {
            return []
        }
        return standard.filter { config.colorSpace(named: $0.name) != nil }
    }

    /// `numbers` (three components, or four with alpha) converted from the
    /// space `source` to the space `destination`, so the colour stays the
    /// same; nil for either means ``documentDefault``. Alpha is kept.
    ///
    /// - Throws: ColorKit's error if OCIO is unavailable or doesn't know
    ///   one of the spaces.
    public static func convert(_ numbers: [Double], from source: String?, to destination: String?,
                               configuration: ColorConfiguration? = nil) throws -> [Double] {
        let config: ColorConfiguration = try configuration ?? ColorConfiguration.studio.get()
        let converter: ColorConverter = try config.converter(from: source ?? documentDefault,
                                                             to: destination ?? documentDefault)
        guard numbers.count >= 3 else {
            return numbers
        }
        let rgb: SIMD3<Double> = converter.convert(SIMD3(numbers[0], numbers[1], numbers[2]))
        // SWIFT: `dropFirst(3)` is everything after the first three (alpha,
        // if any); `Array(...)` turns the slice back into an array.
        return [rgb.x, rgb.y, rgb.z] + Array(numbers.dropFirst(3))
    }
}
