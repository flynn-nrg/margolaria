// ColorPickingTests.swift
//
// The colour picker's conversions (M3e). M3e's exit criterion: picks give
// the values OCIO's conversions give, in every space the picker offers. So:
// every pick space against every kind of input space, both ways; known
// values from the spaces' published definitions (the sRGB curve, the
// ACEScg and Display P3 primaries); and the gamut check, HSV and hex.
//
// Introduces (SWIFT): nothing new.

import ColorKit
import simd
import Testing

@Suite("Colour picking")
struct ColorPickingTests {
    /// Input spaces of each kind MaterialX documents use: linear Rec.709,
    /// sRGB-encoded textures, ACEScg, and a gamma-encoded wide space.
    static let inputSpaces: [String] = ["lin_rec709", "srgb_texture", "acescg", "g22_ap1"]

    static func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, within tolerance: Double = 1e-4) -> Bool {
        simd_reduce_max(simd_abs(a - b)) < tolerance
    }

    @Test("Every pick space, with every kind of input space, converts both ways as OCIO does")
    func everySpace() throws {
        let config: ColorConfiguration = try ColorConfiguration.studio.get()
        let samples: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(0.18, 0.18, 0.18), SIMD3(1, 1, 1),
                                        SIMD3(0.8, 0.3, 0.1), SIMD3(0.05, 0.6, 0.9)]
        for input in Self.inputSpaces {
            let spaces: [PickSpace] = [PickSpace.input(input)] + PickSpace.offered
            for space in spaces {
                let picking = try ColorPicking(input: input, pick: space.name)
                let toInput: ColorConverter = try config.converter(from: space.name, to: input)
                for sample in samples {
                    // A pick is stored as OCIO converts it...
                    #expect(Self.close(picking.input(fromPicked: sample), toInput.convert(sample), within: 1e-12),
                            "\(space.name) → \(input): \(sample)")
                    // ...and reads back as it was picked.
                    let back: SIMD3<Double> = picking.picked(fromInput: picking.input(fromPicked: sample))
                    #expect(Self.close(back, sample, within: 1e-6), "\(space.name) ↔ \(input): \(sample) → \(back)")
                }
            }
        }
    }

    @Test("Known values: the sRGB curve, the ACEScg and Display P3 primaries in linear Rec.709")
    func knownValues() throws {
        // sRGB 0.5 is 0.2140 linear (IEC 61966-2-1); white and black stay.
        let srgb = try ColorPicking(input: "lin_rec709", pick: "srgb_texture")
        #expect(Self.close(srgb.input(fromPicked: SIMD3(repeating: 0.5)), SIMD3(repeating: 0.214041)))
        #expect(Self.close(srgb.input(fromPicked: SIMD3(1, 0, 0)), SIMD3(1, 0, 0)))

        // ACEScg red in Rec.709: the first column of the AP1-to-Rec.709
        // matrix (with the CAT02 white point adaptation OCIO uses).
        let acescg = try ColorPicking(input: "lin_rec709", pick: "acescg")
        #expect(Self.close(acescg.input(fromPicked: SIMD3(1, 0, 0)), SIMD3(1.70505, -0.13026, -0.02400), within: 2e-4))

        // Display P3 green in Rec.709: (-0.2247, 1.0419, -0.0786).
        let p3 = try ColorPicking(input: "lin_rec709", pick: "srgb_displayp3")
        let green: SIMD3<Double> = p3.input(fromPicked: SIMD3(0, 1, 0))
        #expect(Self.close(green, SIMD3(-0.2247, 1.0419, -0.0786), within: 2e-3), "\(green)")
        // Both are outside Rec.709's gamut, which the picker reports.
        #expect(ColorPicking.isOutOfGamut(green))
        #expect(ColorPicking.clipped(green) == SIMD3(0, green.y, 0))
        // A grey is in every gamut, rounding aside.
        #expect(!ColorPicking.isOutOfGamut(p3.input(fromPicked: SIMD3(repeating: 0.5))))
    }

    @Test("HSV and back; value above 1 for linear light")
    func hsv() {
        for rgb in [SIMD3<Double>(0.8, 0.3, 0.1), SIMD3(0.1, 0.8, 0.3), SIMD3(0.3, 0.1, 0.8), SIMD3(2, 1, 0.5),
                    SIMD3(0.5, 0.5, 0.5), SIMD3(0, 0, 0)] {
            #expect(Self.close(ColorPicking.rgb(fromHSV: ColorPicking.hsv(fromRGB: rgb)), rgb, within: 1e-12), "\(rgb)")
        }
        #expect(Self.close(ColorPicking.hsv(fromRGB: SIMD3(1, 0, 0)), SIMD3(0, 1, 1)))
        #expect(Self.close(ColorPicking.hsv(fromRGB: SIMD3(0, 0, 2)), SIMD3(2.0 / 3, 1, 2)))
    }

    @Test("Hex codes, as other apps write them")
    func hex() {
        #expect(ColorPicking.hex(SIMD3(1, 0.5, 0)) == "#FF8000")
        #expect(ColorPicking.hex(SIMD3(1.5, -0.2, 0)) == "#FF0000")
        #expect(ColorPicking.rgb(hex: "#FF8000") == SIMD3(1, 128.0 / 255, 0))
        #expect(ColorPicking.rgb(hex: "f80") == SIMD3(1, 136.0 / 255, 0))
        #expect(ColorPicking.rgb(hex: "#12345") == nil)
        #expect(ColorPicking.rgb(hex: "nothex") == nil)
    }
}
