// SwatchGeometry.swift
//
// The sphere that swatches are drawn on, as Metal vertex and index buffers,
// and the vertex layout that tells Metal where each attribute lives.
//
// Generated MaterialX shaders read named vertex attributes: i_position,
// i_normal, i_tangent, i_bitangent, i_texcoord_0, depending on what the node
// graph uses. Every vertex here carries all of them; the vertex descriptor
// (built from the shader's own list of attributes) picks the ones it needs.
//
// Introduces (SWIFT): `SIMD3<Float>` and `simd` vector math, `stride(from:to:by:)`
// style loops with ranges (`0...n`), `MemoryLayout`, `withUnsafeBytes` on
// arrays, nested `enum` used for constants.

import Metal
import simd

/// One vertex of the swatch sphere.
///
/// The layout is fixed and tightly packed (14 floats, 56 bytes). Metal reads
/// it through the offsets in ``SwatchGeometry/attributeFormats``, not through
/// this struct, so the struct must never be reordered without updating them.
///
/// SWIFT: `SIMD3<Float>` would be 16 bytes (it is padded like a float4), so
/// the fields are plain Floats to get the packed layout Metal expects for
/// `.float3` attributes. A Swift struct of Floats has the same layout as the
/// equivalent C struct.
struct SwatchVertex {
    var px: Float, py: Float, pz: Float     // position
    var nx: Float, ny: Float, nz: Float     // normal
    var tx: Float, ty: Float, tz: Float     // tangent (direction of increasing u)
    var bx: Float, by: Float, bz: Float     // bitangent (direction of increasing v)
    var u: Float, v: Float                  // texture coordinate
}

/// A unit sphere, centred on the origin, ready to draw.
struct SwatchGeometry {
    /// Interleaved SwatchVertex data.
    let vertexBuffer: MTLBuffer
    /// Triangle list, 32-bit indices.
    let indexBuffer: MTLBuffer
    /// Number of indices in `indexBuffer`.
    let indexCount: Int

    /// The vertex buffer slot. Generated shaders put their uniform buffers in
    /// the low slots (0, 1, 2, ...), so the geometry uses the last one Metal
    /// allows, where it can't collide with them.
    static let bufferIndex: Int = 30

    /// For each attribute name a generated shader may ask for: its format and
    /// byte offset inside SwatchVertex.
    ///
    /// SWIFT: A dictionary literal, `[key: value, ...]`. The value is a tuple
    /// with labelled elements.
    static let attributeFormats: [String: (format: MTLVertexFormat, offset: Int)] = [
        "i_position": (.float3, 0),
        "i_normal": (.float3, 12),
        "i_tangent": (.float3, 24),
        "i_bitangent": (.float3, 36),
        "i_texcoord_0": (.float2, 48),
    ]

    /// Builds a UV sphere with `segments` divisions around the equator and
    /// half as many from pole to pole.
    init(device: any MTLDevice, segments: Int = 96) throws {
        let rings: Int = segments / 2
        var vertices: [SwatchVertex] = []
        var indices: [UInt32] = []

        // One row of vertices per ring, from the north pole (v = 0) to the
        // south pole (v = 1). The first and last column overlap (u = 0 and
        // u = 1), so the texture coordinates don't wrap inside a triangle.
        //
        // SWIFT: `0...rings` is a *closed range* (includes both ends), like
        // `for (int r = 0; r <= rings; ++r)`. `0..<segments` excludes the end.
        for ring in 0...rings {
            let v: Float = Float(ring) / Float(rings)
            let theta: Float = v * Float.pi            // 0 at the north pole
            for segment in 0...segments {
                let u: Float = Float(segment) / Float(segments)
                let phi: Float = u * 2 * Float.pi      // around the Y axis

                // Y is up. With u increasing, points go anticlockwise when
                // seen from above.
                let position = SIMD3<Float>(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi))
                // d(position)/d(phi), normalised. Undefined at the poles,
                // where it falls back to +X.
                var tangent = SIMD3<Float>(cos(phi), 0, -sin(phi))
                if simd_length(tangent) < 1e-6 {
                    tangent = SIMD3<Float>(1, 0, 0)
                }
                // SWIFT: `simd_cross` and `simd_normalize` come from Apple's
                // simd library, the same one Metal shaders use, so vector
                // math reads the same in Swift and in MSL.
                let bitangent: SIMD3<Float> = simd_normalize(simd_cross(position, tangent))

                vertices.append(SwatchVertex(
                    px: position.x, py: position.y, pz: position.z,
                    nx: position.x, ny: position.y, nz: position.z,
                    tx: tangent.x, ty: tangent.y, tz: tangent.z,
                    bx: bitangent.x, by: bitangent.y, bz: bitangent.z,
                    u: u, v: 1 - v))
            }
        }

        // Two triangles per quad between neighbouring rings.
        let rowLength: Int = segments + 1
        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = UInt32(ring * rowLength + segment)
                let b = UInt32((ring + 1) * rowLength + segment)
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }

        // SWIFT: `withUnsafeBytes` lends a raw pointer to the array's storage
        // for the duration of the closure, which is what makeBuffer copies
        // from. `MemoryLayout<T>.stride` is C's `sizeof` including padding.
        let vertexLength: Int = vertices.count * MemoryLayout<SwatchVertex>.stride
        let indexLength: Int = indices.count * MemoryLayout<UInt32>.stride
        guard let vertexBuffer = vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: vertexLength) }),
              let indexBuffer = indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: indexLength) })
        else {
            throw PreviewError.metal("Could not allocate the swatch geometry")
        }
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indices.count
    }

    /// A vertex descriptor that feeds `function`'s vertex attributes from
    /// SwatchVertex.
    ///
    /// - Throws: if the shader asks for an attribute the sphere doesn't have
    ///   (vertex colours, for example).
    static func vertexDescriptor(for function: any MTLFunction) throws -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        // SWIFT: `?? []` turns a nil array (no attributes) into an empty one.
        for attribute in function.vertexAttributes ?? [] where attribute.isActive {
            guard let entry = attributeFormats[attribute.name] else {
                throw PreviewError.unsupported("vertex attribute \(attribute.name)")
            }
            descriptor.attributes[attribute.attributeIndex].format = entry.format
            descriptor.attributes[attribute.attributeIndex].offset = entry.offset
            descriptor.attributes[attribute.attributeIndex].bufferIndex = bufferIndex
        }
        descriptor.layouts[bufferIndex].stride = MemoryLayout<SwatchVertex>.stride
        return descriptor
    }
}
