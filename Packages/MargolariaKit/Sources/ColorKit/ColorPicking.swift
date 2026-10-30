// ColorPicking.swift
//
// What the inspector's colour picker (M3e) computes, without any UI: a
// colour is picked in one space (the menu's: the input's own, linear
// Rec.709, ACEScg, sRGB or Display P3) and stored in another, the input's
// (`colorspace`, or the document's working space). OCIO converts both
// ways, so a pick gives exactly the values OCIO's conversion gives.
//
// Out of gamut (PLAN.md §8.2, decided in M3e): a saturated colour picked in
// a wide space (ACEScg, Display P3) can lie outside a narrower input space
// (lin_rec709), which shows as negative components. The values are kept, as
// MaterialX allows them; the picker says so and offers to clip them
// (negative components set to 0, in the input's space).
//
// Also here: HSV, and hex for the encoded spaces, on the picked values.
//
// Introduces (SWIFT): `simd_max`/`simd_min` on whole vectors, `String(format:)`
// with `%02X`, `Int(_:radix:)`.

import Foundation
import simd

/// A colour space the picker offers.
public struct PickSpace: Hashable, Identifiable, Sendable {
    /// Its MaterialX name (an alias in OCIO's studio config).
    public let name: String
    /// How the menu shows it.
    public let title: String
    /// True for spaces whose values are encoded for display, 0 to 1, as
    /// other apps' colour pickers and hex codes are: sRGB and Display P3.
    /// False for linear spaces, whose values can go above 1 (light).
    public let isEncoded: Bool

    public var id: String { name }

    public init(name: String, title: String, isEncoded: Bool) {
        self.name = name
        self.title = title
        self.isEncoded = isEncoded
    }

    /// The spaces offered besides the input's own: two linear working
    /// spaces, and the two display encodings colours are usually given in.
    public static let offered: [PickSpace] = [
        PickSpace(name: "lin_rec709", title: "Linear Rec.709", isEncoded: false),
        PickSpace(name: "acescg", title: "ACEScg", isEncoded: false),
        PickSpace(name: "srgb_texture", title: "sRGB", isEncoded: true),
        PickSpace(name: "srgb_displayp3", title: "Display P3", isEncoded: true),
    ]

    /// The input's own space, for picking its numbers as they are stored.
    /// Encoded if it is one of the offered encoded spaces.
    public static func input(_ name: String) -> PickSpace {
        let encoded: Bool = offered.first(where: { $0.name == name })?.isEncoded ?? false
        return PickSpace(name: name, title: "Input's (\(name))", isEncoded: encoded)
    }
}

/// Converts colours between a pick space and the input's space.
public struct ColorPicking: Sendable {
    /// The input's space (where values are stored) and the pick space.
    public let inputSpace: String
    public let pickSpace: String
    private let toInput: ColorConverter
    private let toPick: ColorConverter

    /// - Throws: ColorKit's error if OCIO is unavailable or doesn't know
    ///   one of the spaces.
    public init(input inputSpace: String, pick pickSpace: String,
                configuration: ColorConfiguration? = nil) throws {
        let config: ColorConfiguration = try configuration ?? ColorConfiguration.studio.get()
        self.inputSpace = inputSpace
        self.pickSpace = pickSpace
        toInput = try config.converter(from: pickSpace, to: inputSpace)
        toPick = try config.converter(from: inputSpace, to: pickSpace)
    }

    /// The stored values, as the pick space shows them.
    public func picked(fromInput values: SIMD3<Double>) -> SIMD3<Double> {
        toPick.convert(values)
    }

    /// Picked values, converted to the input's space to be stored.
    public func input(fromPicked values: SIMD3<Double>) -> SIMD3<Double> {
        toInput.convert(values)
    }

    // MARK: Gamut

    /// How far below 0 a component may be and still count as in gamut:
    /// OCIO's matrices round, so a colour at the gamut's edge can come out
    /// at -1e-7.
    static let gamutTolerance: Double = 1e-5

    /// True if `values` (in a space's RGB) lie outside that space's gamut:
    /// a component below 0.
    public static func isOutOfGamut(_ values: SIMD3<Double>) -> Bool {
        simd_reduce_min(values) < -gamutTolerance
    }

    /// `values` with negative components set to 0: the nearest colour in
    /// gamut along each axis. Simple, and what most tools do; it changes
    /// the colour a little, which is why it is offered, not automatic.
    ///
    /// SWIFT: `simd_max(v, 0)` works on all three components at once.
    public static func clipped(_ values: SIMD3<Double>) -> SIMD3<Double> {
        simd_max(values, SIMD3(repeating: 0))
    }

    // MARK: HSV

    /// Hue (0–1, red at 0), saturation (0–1) and value (the largest
    /// component, which can exceed 1 in a linear space) of an RGB colour.
    /// Negative components are taken as 0.
    public static func hsv(fromRGB rgb: SIMD3<Double>) -> SIMD3<Double> {
        let c: SIMD3<Double> = clipped(rgb)
        let maximum: Double = simd_reduce_max(c)
        let minimum: Double = simd_reduce_min(c)
        let chroma: Double = maximum - minimum
        var hue: Double = 0
        if chroma > 0 {
            if maximum == c.x {
                hue = (c.y - c.z) / chroma
            } else if maximum == c.y {
                hue = (c.z - c.x) / chroma + 2
            } else {
                hue = (c.x - c.y) / chroma + 4
            }
            hue /= 6
            if hue < 0 {
                hue += 1
            }
        }
        let saturation: Double = maximum > 0 ? chroma / maximum : 0
        return SIMD3(hue, saturation, maximum)
    }

    /// The RGB colour of a hue, saturation and value (see ``hsv(fromRGB:)``).
    public static func rgb(fromHSV hsv: SIMD3<Double>) -> SIMD3<Double> {
        let hue: Double = (hsv.x - floor(hsv.x)) * 6
        let saturation: Double = min(max(hsv.y, 0), 1)
        let value: Double = max(hsv.z, 0)
        let chroma: Double = value * saturation
        // The middle component, rising and falling between the sixths of
        // the hue circle.
        let x: Double = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let base: SIMD3<Double>
        switch Int(hue) % 6 {
        case 0: base = SIMD3(chroma, x, 0)
        case 1: base = SIMD3(x, chroma, 0)
        case 2: base = SIMD3(0, chroma, x)
        case 3: base = SIMD3(0, x, chroma)
        case 4: base = SIMD3(x, 0, chroma)
        default: base = SIMD3(chroma, 0, x)
        }
        return base + SIMD3(repeating: value - chroma)
    }

    // MARK: Hex

    /// "#RRGGBB" for encoded values (0–1, clamped), as other apps write
    /// them.
    ///
    /// SWIFT: `String(format: "%02X", n)` is printf's two-digit upper-case
    /// hex.
    public static func hex(_ rgb: SIMD3<Double>) -> String {
        let bytes: SIMD3<Double> = (simd_min(simd_max(rgb, SIMD3(repeating: 0)), SIMD3(repeating: 1)) * 255).rounded(.toNearestOrAwayFromZero)
        return "#" + [bytes.x, bytes.y, bytes.z].map { String(format: "%02X", Int($0)) }.joined()
    }

    /// The colour of "#RRGGBB", "RRGGBB" or "#RGB", or nil.
    ///
    /// SWIFT: `Int(text, radix: 16)` parses hexadecimal, nil if it can't.
    public static func rgb(hex text: String) -> SIMD3<Double>? {
        var digits: String = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        if digits.count == 3 {
            // "#F80" is "#FF8800".
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6, let number = Int(digits, radix: 16) else {
            return nil
        }
        return SIMD3(Double((number >> 16) & 0xFF), Double((number >> 8) & 0xFF), Double(number & 0xFF)) / 255
    }
}
