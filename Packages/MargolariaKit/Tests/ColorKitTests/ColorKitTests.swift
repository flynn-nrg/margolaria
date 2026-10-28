// ColorKitTests.swift
//
// Tests for colour management (M3a): OCIO's built-in studio config loads,
// knows every colour space MaterialX names, and converts colours as the
// spaces' published definitions say: the sRGB curve, pure gamma curves and
// the ACES AP1 to Rec. 709 matrix.
//
// Introduces (SWIFT): nothing new.

import ColorKit
import Foundation
import MXKit
import Testing

@Suite("Colour management")
struct ColorKitTests {
    /// The studio config the app uses.
    func studio() throws -> ColorConfiguration {
        try ColorConfiguration.studio.get()
    }

    /// True when `a` and `b` differ by at most `tolerance` in every component.
    func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, within tolerance: Double = 1e-5) -> Bool {
        let difference: SIMD3<Double> = a - b
        return abs(difference.x) <= tolerance && abs(difference.y) <= tolerance && abs(difference.z) <= tolerance
    }

    @Test("The built-in studio config is OCIO 2.5's ACES 2.0 one")
    func config() throws {
        let config = try studio()
        #expect(ColorConfiguration.ocioVersion.hasPrefix("2.5."))
        #expect(config.name.contains("studio-config") && config.name.contains("aces-v2.0"))
        #expect(config.colorSpaces.contains { $0.isDisplay })
        #expect(config.colorSpaces.contains { $0.isData })
        // Names and aliases are found whatever their case.
        #expect(config.colorSpace(named: "acescg")?.name == "ACEScg")
        #expect(config.colorSpace(named: "lin_ap1")?.name == "ACEScg")
        #expect(config.colorSpace(named: "no_such_space") == nil)
    }

    @Test("Every colour space MaterialX names is in the config")
    func materialXNames() throws {
        let config = try studio()
        let document = try MXDocument(xml: #"<?xml version="1.0"?><materialx version="1.39" />"#)
        document.setDataLibrary(try MXLibrary.bundled.get())
        // MaterialX converts each of its colour spaces to lin_rec709 with a
        // nodedef named ND_<space>_to_lin_rec709_color3.
        let prefix = "ND_", suffix = "_to_lin_rec709_color3"
        let names: [String] = document.nodeDefinitions.map(\.name)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .map { String($0.dropFirst(prefix.count).dropLast(suffix.count)) }
        #expect(names.count >= 10)
        for name in names + ["lin_rec709", "lin_ap1"] {
            #expect(config.colorSpace(named: name) != nil, "\(name)")
        }
    }

    @Test("srgb_texture decodes with the sRGB curve")
    func sRGB() throws {
        let converter = try studio().converter(from: "srgb_texture", to: "lin_rec709")
        // IEC 61966-2-1: ((v + 0.055) / 1.055)^2.4 above 0.04045, v / 12.92 below.
        let expected = SIMD3<Double>(pow((0.5 + 0.055) / 1.055, 2.4), 0.02 / 12.92, 1)
        let decoded: SIMD3<Double> = converter.convert(SIMD3(0.5, 0.02, 1))
        // To float precision: OCIO's fast pow approximation (its default
        // optimisation) was off by 2e-5, and ColorBridge turns it off.
        #expect(close(decoded, expected, within: 1e-6), "\(decoded)")
    }

    @Test("g22_ap1 is a pure 2.2 gamma on ACEScg")
    func gamma() throws {
        let converter = try studio().converter(from: "g22_ap1", to: "acescg")
        #expect(close(converter.convert(SIMD3(0.5, 0.25, 0)), SIMD3(pow(0.5, 2.2), pow(0.25, 2.2), 0)))
    }

    @Test("ACEScg to lin_rec709 is the ACES AP1 to Rec. 709 matrix; white stays white")
    func primaries() throws {
        let converter = try studio().converter(from: "acescg", to: "lin_rec709")
        // The first column of the AP1 to linear Rec. 709 matrix (ACES,
        // Bradford adaptation from D60 to D65).
        #expect(close(converter.convert(SIMD3(1, 0, 0)), SIMD3(1.70505, -0.13026, -0.02400), within: 1e-4))
        #expect(close(converter.convert(SIMD3(1, 1, 1)), SIMD3(1, 1, 1), within: 1e-4))
    }

    @Test("Converting to any MaterialX space and back gives the colour back")
    func roundTrips() throws {
        let config = try studio()
        let colour = SIMD3<Double>(0.18, 0.5, 0.8)
        for name in ["srgb_texture", "g22_rec709", "g18_rec709", "rec709_display", "acescg", "g22_ap1",
                     "adobergb", "lin_adobergb", "srgb_displayp3", "lin_displayp3"] {
            let there: SIMD3<Double> = try config.converter(from: "lin_rec709", to: name).convert(colour)
            let back: SIMD3<Double> = try config.converter(from: name, to: "lin_rec709").convert(there)
            #expect(close(back, colour, within: 1e-4), "\(name): \(back)")
        }
    }

    @Test("Same space, alias and data conversions change nothing; unknown spaces throw")
    func identities() throws {
        let config = try studio()
        #expect(try config.converter(from: "lin_ap1", to: "ACEScg").isIdentity)
        #expect(try config.converter(from: "raw", to: "acescg").isIdentity)
        #expect(!(try config.converter(from: "srgb_texture", to: "lin_rec709").isIdentity))
        #expect(throws: ColorError.self) {
            try config.converter(from: "no_such_space", to: "lin_rec709")
        }
    }
}
