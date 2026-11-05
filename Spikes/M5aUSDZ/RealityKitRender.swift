// RealityKitRender.swift
//
// Spike M5a (docs/spikes/M5a-usdz.md): renders USD files with RealityKit,
// offscreen, the engine Quick Look and Reality Composer Pro use, and says
// which kind of material RealityKit made of each (ShaderGraphMaterial: it
// read the MaterialX graph; PhysicallyBasedMaterial: it fell back).
//
// A standalone script, not part of the Xcode project:
//
//   swiftc -parse-as-library -O Spikes/M5aUSDZ/RealityKitRender.swift -o /tmp/rkrender
//   /tmp/rkrender <environment.hdr> <output folder> file.usdz ...
//
// The environment lights the scene (OpenUSD's StinsonBeach.hdr, in
// SwiftUsd's Usd_Plug framework under usd/hdx/Resources/textures, is what
// Storm uses), with a key light from the upper right. Each file's sphere
// is framed and drawn after 30 frames, which gives RealityKit time to
// compile the shader graph, into <output folder>/<file>.png.
//
// Introduces (SWIFT): `RealityRenderer`, `Entity(contentsOf:)`,
// `withCheckedThrowingContinuation` (a callback API used from async code).

import CoreImage
import Foundation
import ImageIO
import Metal
import RealityKit
import UniformTypeIdentifiers

/// Draws the file at `path` and writes the picture to `out`; returns the
/// kinds of material RealityKit made, by type name.
@MainActor
func render(_ path: String, to out: String, renderer: RealityRenderer, device: MTLDevice) async throws -> [String] {
    renderer.entities.removeAll()
    let entity = try await Entity(contentsOf: URL(filePath: path))
    renderer.entities.append(entity)

    var kinds: [String] = []
    func visit(_ entity: Entity) {
        if let model = entity.components[ModelComponent.self] {
            kinds += model.materials.map { String(describing: type(of: $0)) }
        }
        entity.children.forEach(visit)
    }
    visit(entity)

    // Framed from the front, as Storm's viewport frames the sphere.
    let bounds = entity.visualBounds(relativeTo: nil)
    let radius: Float = max(bounds.extents.x, bounds.extents.y) / 2
    let camera = PerspectiveCamera()
    camera.camera.fieldOfViewInDegrees = 30
    camera.look(at: bounds.center, from: bounds.center + [0, 0, radius * 4.2], relativeTo: nil)
    renderer.entities.append(camera)
    renderer.activeCamera = camera
    let light = DirectionalLight()
    light.light.intensity = 1500
    light.look(at: .zero, from: [1, 1.5, 2], relativeTo: nil)
    renderer.entities.append(light)

    let size: Int = 256
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size, height: size,
                                                              mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    let texture: MTLTexture = device.makeTexture(descriptor: descriptor)!
    let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
    // RealityKit compiles shader graphs in the background; until then the
    // model isn't drawn.
    for _ in 0..<30 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try renderer.updateAndRender(deltaTime: 1.0 / 30, cameraOutput: output,
                                             onComplete: { _ in continuation.resume() })
            } catch {
                continuation.resume(throwing: error)
            }
        }
        try await Task.sleep(for: .milliseconds(40))
    }

    // Metal's rows run top down, Core Image's bottom up.
    let image = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])!
        .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(size)))
    let picture = CIContext().createCGImage(image, from: image.extent, format: .RGBA8,
                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    let destination = CGImageDestinationCreateWithURL(URL(filePath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, picture, nil)
    CGImageDestinationFinalize(destination)
    return kinds
}

@main
struct RealityKitRender {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 3 else {
            print("usage: rkrender <environment.hdr> <output folder> file.usdz ...")
            return
        }
        let device: MTLDevice = MTLCreateSystemDefaultDevice()!
        do {
            let renderer = try RealityRenderer()
            renderer.cameraSettings.colorBackground = .color(.init(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1))
            if let source = CGImageSourceCreateWithURL(URL(filePath: arguments[0]) as CFURL, nil),
               let environment = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                renderer.lighting.resource = try await EnvironmentResource(equirectangular: environment)
                renderer.lighting.intensityExponent = 0
            }
            for path in arguments.dropFirst(2) {
                let out: String = arguments[1] + "/" + (path as NSString).lastPathComponent + ".png"
                do {
                    let kinds = try await render(path, to: out, renderer: renderer, device: device)
                    print("\((path as NSString).lastPathComponent)\t\(kinds.joined(separator: ","))")
                } catch {
                    print("\((path as NSString).lastPathComponent)\tERROR \(error)")
                }
            }
        } catch {
            print("RealityRenderer: \(error)")
        }
    }
}
