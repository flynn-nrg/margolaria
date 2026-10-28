// ColorConverter.swift
//
// Converts colours from one colour space to another, with OCIO's CPU
// processor. Made by ``ColorConfiguration/converter(from:to:)``.
//
// Introduces (SWIFT): `SIMD3`, Swift's small fixed-size vector type.

import ColorBridge
import CxxStdlib

/// A conversion between two colour spaces of a config.
///
/// SWIFT: `@unchecked Sendable`: the C++ processor is immutable, and OCIO
/// processors may be applied from several threads at once (ColorBridge.h).
public struct ColorConverter: @unchecked Sendable {
    /// The C++ handle.
    let handle: colorbridge.Processor

    /// True when converting changes nothing (the same space under two names,
    /// or a data space).
    public var isIdentity: Bool {
        handle.isNoOp()
    }

    /// Converts one RGB colour.
    ///
    /// SWIFT: `SIMD3<Double>` is three Doubles that behave like one value:
    /// `a + b`, `a * 2` and `a.x`/`a.y`/`a.z` work element by element, like
    /// a GLSL/Metal `double3`, and it is a plain value (no heap). Colours,
    /// positions and directions are its usual uses.
    ///
    /// OCIO works in 32-bit floats, so the result has float precision.
    public func convert(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        if isIdentity {
            return rgb
        }
        // SWIFT: `FloatVector` is the C++ `std::vector<float>` (a typedef in
        // ColorBridge.h). Swift gives imported vectors an initializer from
        // any Swift sequence, and makes them collections we can index.
        let input = colorbridge.FloatVector([Float(rgb.x), Float(rgb.y), Float(rgb.z)])
        let output = handle.applyRGB(input)
        return SIMD3<Double>(Double(output[0]), Double(output[1]), Double(output[2]))
    }
}
