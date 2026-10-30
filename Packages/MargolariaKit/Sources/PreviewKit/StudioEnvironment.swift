// StudioEnvironment.swift
//
// The viewport's default lighting (M3b): a neutral photo studio, drawn by
// code into a latitude-longitude HDR image that the dome light uses. Grey
// walls and a darker floor, and four soft boxes (rectangular diffuse
// panels, as photographers use): a key light to the upper left of the
// default camera, a fill to its right, a rim light behind, and one
// overhead. Every value is grey (R = G = B), so the light adds no colour of
// its own, and the materials' colours are what you see.
//
// Why drawn and not a photograph: a photographed environment (OpenUSD's
// outdoor default) colours everything with its sky and ground, and its sun
// makes highlights that hide the material. A drawn one is neutral by
// construction, needs no licence and no file in the repository, and can be
// given to MaterialXView (`--envRad`) to compare renderers under exactly
// the same light.
//
// The image is written once, as a Radiance .hdr file (the format of
// OpenUSD's own default environment), in the temporary folder. The
// viewport's dome light and the swatches (SwatchEnvironment) both read it;
// it moved here from ViewportKit in M3c.
//
// Introduces (SWIFT): `Float.exponent` and `Float(sign:exponent:significand:)`,
// building `Data` from bytes, `static let` initialised by a closure.

import Foundation
import simd

/// The studio environment image.
public enum StudioEnvironment {
    /// Image size: 1024 × 512 texels, about 0.35° each, finer than any
    /// detail in the image (the soft boxes have soft edges).
    static let width: Int = 1024
    static let height: Int = 512

    /// The .hdr file, written on first use. Nil if it couldn't be written;
    /// the viewport then keeps OpenUSD's default environment.
    ///
    /// The name carries a version number: change it whenever the image
    /// changes, so a file left by an older build isn't reused.
    ///
    /// SWIFT: `static let x = { ... }()` runs the closure once, the first
    /// time `x` is read, and keeps the result: a lazily computed constant.
    /// Swift makes this thread-safe (like C++'s function-local statics).
    public static let fileURL: URL? = {
        let url: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Margolaria-studio-environment-2.hdr")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        do {
            // Atomically: written to a temporary name and then renamed, so
            // a second process starting at the same moment never reads a
            // half-written file.
            try radianceHDR().write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }()

    // MARK: The studio

    /// A soft box: a glowing rectangle, seen from the centre of the studio.
    struct SoftBox {
        /// Direction from the sphere towards the middle of the box.
        let centre: SIMD3<Float>
        /// Directions along the box's width and height: perpendicular to
        /// `centre` and to each other.
        let across: SIMD3<Float>
        let up: SIMD3<Float>
        /// Half the box's width and height, as seen from the sphere: the
        /// tangent of the angle from the middle to an edge.
        let halfWidth: Float
        let halfHeight: Float
        /// The light it gives off (radiance), the same in R, G and B.
        let radiance: Float

        /// A box facing the sphere from `direction`, upright: its height
        /// is along the world's up axis as far as possible.
        ///
        /// SWIFT: `simd_normalize`, `simd_cross` and `simd_dot` work on any
        /// SIMD3 of Float or Double, from Apple's simd library.
        init(direction: SIMD3<Float>, halfWidth: Float, halfHeight: Float, radiance: Float,
             upHint: SIMD3<Float> = SIMD3(0, 1, 0)) {
            centre = simd_normalize(direction)
            across = simd_normalize(simd_cross(upHint, centre))
            up = simd_cross(centre, across)
            self.halfWidth = halfWidth
            self.halfHeight = halfHeight
            self.radiance = radiance
        }

        /// The light reaching the sphere from `direction` (a unit vector).
        func radiance(towards direction: SIMD3<Float>) -> Float {
            // Where the direction meets the plane of the box, one unit
            // away: (x, y) on the box, 0 in the middle.
            let forward: Float = simd_dot(direction, centre)
            guard forward > 0 else {
                return 0
            }
            let x: Float = simd_dot(direction, across) / forward
            let y: Float = simd_dot(direction, up) / forward
            // Full inside the box, fading to nothing across a border 15% of
            // its size, so its reflections have soft edges.
            return radiance * Self.edge(abs(x), halfWidth) * Self.edge(abs(y), halfHeight)
        }

        /// 1 well inside `half`, 0 well outside, smooth in between.
        private static func edge(_ distance: Float, _ half: Float) -> Float {
            1 - simd_smoothstep(half * 0.85, half * 1.15, distance)
        }
    }

    /// The four soft boxes, placed for the viewport's default camera, which
    /// looks at the sphere from 30° round to the right (+X) of the +Z axis.
    /// `toCamera`, `right` and `up` below are that camera's directions.
    ///
    /// The radiances make a white diffuse sphere about 0.8 where the key
    /// light falls on it, and an 18% grey one show as middle grey.
    static let softBoxes: [SoftBox] = {
        let azimuth: Float = 30 * .pi / 180
        let toCamera = SIMD3<Float>(sin(azimuth), 0, cos(azimuth))
        let right = SIMD3<Float>(cos(azimuth), 0, -sin(azimuth))
        let up = SIMD3<Float>(0, 1, 0)
        return [
            // Key: large, in front, above and to the left.
            SoftBox(direction: 0.6 * toCamera - 0.5 * right + 0.6 * up,
                    halfWidth: 0.35, halfHeight: 0.25, radiance: 6),
            // Fill: a tall strip to the right, dimmer, to lift the shadows.
            SoftBox(direction: 0.4 * toCamera + 0.9 * right + 0.1 * up,
                    halfWidth: 0.3, halfHeight: 0.45, radiance: 1.2),
            // Rim: a narrow strip behind and to the left, which outlines
            // the sphere against the background.
            SoftBox(direction: -0.8 * toCamera - 0.3 * right + 0.5 * up,
                    halfWidth: 0.12, halfHeight: 0.5, radiance: 6),
            // Top: a small square overhead.
            SoftBox(direction: up, halfWidth: 0.25, halfHeight: 0.25, radiance: 3,
                    upHint: toCamera),
        ]
    }()

    /// The light from `direction` (a unit vector, +Y up): the walls and
    /// floor, plus any soft box in that direction.
    static func radiance(towards direction: SIMD3<Float>) -> Float {
        // Walls brighten gently towards the ceiling; the floor is darker.
        // The horizon is a soft line, not a step.
        let wall: Float = 0.12 + 0.08 * max(direction.y, 0)
        let floor: Float = 0.03
        let background: Float = floor + (wall - floor) * simd_smoothstep(-0.05, 0.05, direction.y)
        // SWIFT: `reduce(start) { total, element in ... }` folds a
        // sequence into one value, like std::accumulate.
        return softBoxes.reduce(background) { total, box in
            total + box.radiance(towards: direction)
        }
    }

    /// The direction texel (column, row) of the image shows, as Storm's
    /// dome light maps it: the first row stored is straight *down* (-Y),
    /// the last straight up, the middle row the horizon. Going along a row,
    /// the image goes round the Y axis from -Z, through +X (a quarter of the
    /// way), +Z (half way) and -X (three quarters). Found by rendering a
    /// mirror sphere (StudioRenderTests): an image's first stored row is
    /// usually its top, but Storm reads .hdr files bottom row first.
    static func direction(column: Int, row: Int) -> SIMD3<Float> {
        // Texel centres: u and v from 0 to 1.
        let u: Float = (Float(column) + 0.5) / Float(width)
        let v: Float = (Float(row) + 0.5) / Float(height)
        let polar: Float = (1 - v) * .pi            // from +Y, 0 to π
        let azimuth: Float = u * 2 * .pi - .pi / 2  // round the Y axis, from -Z
        return SIMD3(sin(polar) * cos(azimuth), cos(polar), sin(polar) * sin(azimuth))
    }

    // MARK: The file

    /// The image as a Radiance .hdr file (RGBE: three 8-bit mantissas
    /// sharing one 8-bit exponent per texel, without run-length encoding).
    static func radianceHDR() -> Data {
        var data = Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y \(height) +X \(width)\n".utf8)
        // SWIFT: `reserveCapacity` allocates once up front, like
        // std::vector::reserve.
        data.reserveCapacity(data.count + width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let value: Float = radiance(towards: direction(column: column, row: row))
                // SWIFT: `append(contentsOf:)` adds the bytes of an array.
                data.append(contentsOf: rgbe(value, value, value))
            }
        }
        return data
    }

    /// One texel in RGBE form: the largest component's binary exponent is
    /// shared, and each component keeps 8 bits of mantissa against it.
    static func rgbe(_ r: Float, _ g: Float, _ b: Float) -> [UInt8] {
        let largest: Float = max(r, g, b)
        guard largest > 1e-32 else {
            return [0, 0, 0, 0]
        }
        // SWIFT: Every floating-point value can tell its `exponent` and
        // `significand`: largest = significand × 2^exponent, with the
        // significand in [1, 2). C's frexp gives [0.5, 1) instead, hence
        // the + 1 below.
        let exponent: Int = Int(largest.exponent) + 1
        // Scales the largest component to just under 256.
        let scale: Float = 256 / Float(sign: .plus, exponent: exponent, significand: 1)
        return [UInt8(min(r * scale, 255)), UInt8(min(g * scale, 255)), UInt8(min(b * scale, 255)),
                UInt8(exponent + 128)]
    }
}
