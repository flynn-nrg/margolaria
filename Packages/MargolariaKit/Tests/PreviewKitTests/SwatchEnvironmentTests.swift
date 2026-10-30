// SwatchEnvironmentTests.swift
//
// The swatches' diffuse light (M3c): the irradiance map must be the cosine
// convolution of the environment, looked up the way the shaders look it
// up. Checked against the studio's analytic radiance (StudioEnvironment),
// integrated over the sphere, and against a uniform environment, where
// every direction receives the same light.
//
// Introduces (SWIFT): nothing new.

import Foundation
import Metal
import simd
import Testing
@testable import PreviewKit

@Suite("Swatch environment", .serialized)
struct SwatchEnvironmentTests {
    /// The irradiance map's texels, as floats, row by row.
    static func texels(of texture: any MTLTexture) -> [SIMD4<Float>] {
        // SWIFT: `Float16` matches the texture's RGBA16Float texels; each
        // is converted to a Float afterwards.
        var halves = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        halves.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return stride(from: 0, to: halves.count, by: 4).map {
            SIMD4(Float(halves[$0]), Float(halves[$0 + 1]), Float(halves[$0 + 2]), Float(halves[$0 + 3]))
        }
    }

    /// (1/π) ∫ L(ω) max(0, N·ω) dω for the studio, N and ω in the world
    /// (Storm's convention), summed over a fine lat-long grid.
    static func studioIrradiance(facing normal: SIMD3<Float>) -> Float {
        let width: Int = 512
        let height: Int = 256
        var sum: Float = 0
        for row in 0..<height {
            for column in 0..<width {
                // Through StudioEnvironment.direction, in its own image's
                // texels (twice as many each way as this grid).
                let direction: SIMD3<Float> = StudioEnvironment.direction(column: column * 2, row: row * 2)
                let cosine: Float = simd_dot(normal, direction)
                if cosine > 0 {
                    let solidAngle: Float = (2 * .pi / Float(width)) * (.pi / Float(height)) * cos(asin(direction.y))
                    sum += StudioEnvironment.radiance(towards: direction) * cosine * solidAngle
                }
            }
        }
        return sum / .pi
    }

    @Test("The irradiance map is the cosine-weighted integral of the studio, for each direction")
    func studioIrradiance() throws {
        let device: any MTLDevice = try #require(MTLCreateSystemDefaultDevice())
        let queue: any MTLCommandQueue = try #require(device.makeCommandQueue())
        let environment = try SwatchEnvironment(imageURL: try #require(StudioEnvironment.fileURL), queue: queue)
        let map: [SIMD4<Float>] = Self.texels(of: environment.irradiance)
        let (width, height) = SwatchEnvironment.irradianceSize

        // Every fourth texel: up, down, towards the key light, the shadow
        // side and everything between.
        for row in stride(from: 0, to: height, by: 3) {
            for column in stride(from: 0, to: width, by: 4) {
                // The texel's direction in the shaders' convention, and the
                // world direction whose lookup lands on it: the matrix is
                // its own inverse (it negates all three axes).
                let lookup: SIMD3<Float> = SwatchEnvironment.latLongDirection(column: column, row: row,
                                                                              width: width, height: height)
                let normal: SIMD3<Float> = -lookup
                let expected: Float = Self.studioIrradiance(facing: normal)
                let value: Float = map[row * width + column].x
                // 5% and a little: the map is made from a 64 × 32 copy of
                // the image, whose soft boxes have soft edges.
                #expect(abs(value - expected) < 0.05 * expected + 0.01,
                        "facing \(normal): map \(value), integral \(expected)")
            }
        }
    }

    @Test("In a uniform environment, every direction receives the same light")
    func uniform() {
        // Radiance 2 everywhere: E / π = 2 in every direction.
        let texels = [SIMD4<Float>](repeating: SIMD4(2, 2, 2, 1), count: 64 * 32)
        let map: [SIMD4<Float>] = SwatchEnvironment.convolve(texels, width: 64, height: 32)
        for texel in map {
            #expect(abs(texel.x - 2) < 0.01, "\(texel)")
        }
    }
}
