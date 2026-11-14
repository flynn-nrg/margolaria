// USDZExportTests.swift
//
// M5c's exit criterion, the automated part (PLAN.md §8.6): every example,
// with each of its materials on the sphere, exports as a USDZ that passes
// OpenUSD's validators, holds every texture it refers to, and is drawn by
// RealityKit, the engine of Quick Look and Reality Composer Pro: from its
// MaterialX graph (a ShaderGraphMaterial) for every material Margolaria
// doesn't warn about, a fallback for the others, and never nothing. Since
// M7a, also each preview shape (exportsShape).
//
// RealityKit draws offscreen here with RealityRenderer, as in spike M5a
// (Spikes/M5aUSDZ/RealityKitRender.swift), lit by Storm's environment.
// With M5C_EXPORT_DIR set, the files are kept there, for opening in Quick
// Look and Reality Composer Pro by hand.
//
// Introduces (SWIFT): `RealityRenderer`, `Entity(contentsOf:)` and
// `withCheckedThrowingContinuation` in a test (as in the spike's script);
// `async` tests on the main actor.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import MXKit
import RealityKit
import Testing
import ViewportKit

/// Draws USD files with RealityKit, offscreen.
///
/// SWIFT: `@MainActor`: RealityKit's entities and renderer may only be used
/// on the main thread, so the whole class is, and so are its callers.
@MainActor
final class RealityKitDrawing {
    /// One for all the tests: making a renderer and its environment takes
    /// a while.
    static let shared: RealityKitDrawing? = try? RealityKitDrawing()

    private let renderer: RealityRenderer
    private let device: MTLDevice
    /// Storm's environment, set on the first drawing (loading it is async).
    private var lit: Bool = false

    /// The background, a mid grey, which a drawn sphere must differ from.
    static let background = CGColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1)

    init() throws {
        renderer = try RealityRenderer()
        renderer.cameraSettings.colorBackground = .color(Self.background)
        device = try #require(MTLCreateSystemDefaultDevice())
    }

    /// What RealityKit made of the file at `url`: its materials' type
    /// names ("ShaderGraphMaterial"), and a picture of it, 64 pixels
    /// square, after 30 frames (RealityKit compiles shader graphs in the
    /// background; the model isn't drawn until then).
    func draw(_ url: URL) async throws -> (kinds: [String], image: CGImage) {
        if !lit {
            lit = true
            if let source = CGImageSourceCreateWithURL(Self.environment as CFURL, nil),
               let environment = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                renderer.lighting.resource = try await EnvironmentResource(equirectangular: environment)
                renderer.lighting.intensityExponent = 0
            }
        }
        renderer.entities.removeAll()
        let entity = try await Entity(contentsOf: url)
        renderer.entities.append(entity)

        var kinds: [String] = []
        func visit(_ entity: Entity) {
            if let model = entity.components[ModelComponent.self] {
                kinds += model.materials.map { String(describing: type(of: $0)) }
            }
            entity.children.forEach(visit)
        }
        visit(entity)

        // Framed from the front, as the viewport frames the sphere.
        let bounds = entity.visualBounds(relativeTo: nil)
        let radius: Float = max(bounds.extents.x, bounds.extents.y) / 2
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 30
        camera.look(at: bounds.center, from: bounds.center + [0, 0, radius * 4.2], relativeTo: nil)
        renderer.entities.append(camera)
        renderer.activeCamera = camera

        let size: Int = 64
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size, height: size,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture: MTLTexture = try #require(device.makeTexture(descriptor: descriptor))
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
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
        let linear = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let picture = try #require(CIImage(mtlTexture: texture, options: [.colorSpace: linear]))
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(size)))
        let image: CGImage = try #require(CIContext().createCGImage(picture, from: picture.extent, format: .RGBA8,
                                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        return (kinds, image)
    }

    /// OpenUSD's StinsonBeach.hdr, the environment Storm lights with.
    static let environment: URL = {
        var root = URL(filePath: #filePath)
        for _ in 0..<5 {
            root = root.deletingLastPathComponent()
        }
        return root.appending(path: "Vendor/SwiftUsd/swift-package/Libraries/Usd_Plug.xcframework/macos-arm64/"
            + "Usd_Plug.framework/Versions/A/Resources/usd/hdx/Resources/textures/StinsonBeach.hdr")
    }()
}

@Suite("USDZ export (M5c)", .serialized)
struct USDZExportTests {
    /// Where the files go: M5C_EXPORT_DIR, kept for opening by hand, or a
    /// temporary folder, removed afterwards.
    static let keptFolder: URL? = ProcessInfo.processInfo.environment["M5C_EXPORT_DIR"].map { URL(filePath: $0) }

    /// A folder for one test's files, and whether to remove it afterwards.
    static func folder() throws -> (URL, remove: Bool) {
        let folder: URL = keptFolder ?? FileManager.default.temporaryDirectory.appending(path: "USDZExport-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, keptFolder == nil)
    }

    /// Exports `document` as a USDZ at `url`, with `material` on `shape`,
    /// and checks the package: OpenUSD's validators find nothing, and
    /// every texture it refers to is inside it, by relative path.
    static func exportAndCheck(_ document: MXDocument, material: String, to url: URL, _ label: String,
                               shape: ViewportShape = .sphere) throws {
        try? FileManager.default.removeItem(at: url)
        try MGUSDExporter.exportPreview(fromMaterialXString: try document.usdzXMLString(), to: url,
                                        materialName: material, shape: shape.bridged)
        let problems: [String] = MGUSDExporter.validationMessagesForFile(at: url)
        #expect(problems.isEmpty, "\(label): \(problems)")
        let packaged: Set<String> = Set(MGUSDExporter.filesInPackage(at: url))
        for path in MGUSDExporter.assetPathsInFile(at: url) {
            #expect(packaged.contains(path), "\(label): \(path) isn't in the package \(packaged.sorted())")
        }
    }

    /// Records an issue unless RealityKit drew something other than the
    /// background in the middle of `image`.
    static func expectDrawn(_ image: CGImage, _ label: String) {
        let middle = Fixtures.pixel(image, x: 32, y: 32)
        let corner = Fixtures.pixel(image, x: 2, y: 2)
        let difference: Int = abs(Int(middle.r) - Int(corner.r)) + abs(Int(middle.g) - Int(corner.g))
            + abs(Int(middle.b) - Int(corner.b))
        #expect(difference > 6, "\(label): nothing drawn (\(middle) in the middle, \(corner) around)")
    }

    @Test("Every example's materials export as USDZ that RealityKit draws, from the graph unless warned (M5c)",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Examples.files)
    @MainActor
    func exportsExample(_ url: URL) async throws {
        let drawing: RealityKitDrawing = try #require(RealityKitDrawing.shared)
        let (folder, remove) = try Self.folder()
        defer {
            if remove {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let name: String = url.deletingPathExtension().lastPathComponent
        let issues: [String] = document.quickLookIssues()
        let materials: [String] = try document.graph(at: "").nodes.filter { $0.type == "material" }.map(\.name)
        #expect(!materials.isEmpty, "\(name): no material")
        for material in materials {
            let label = "\(name) \(material)"
            let usdz: URL = folder.appending(path: "\(name).\(material).usdz")
            try Self.exportAndCheck(document, material: material, to: usdz, label)
            let (kinds, image) = try await drawing.draw(usdz)
            // The warning names the material if, and only if, RealityKit
            // falls back.
            let warned: Bool = issues.contains { $0.hasPrefix(material + " uses ") }
            if warned {
                #expect(!kinds.contains("ShaderGraphMaterial"), "\(label): warned, but drawn from its graph")
            } else {
                #expect(kinds == ["ShaderGraphMaterial"], "\(label): \(kinds), not drawn from its graph")
            }
            Self.expectDrawn(image, label)
        }
    }

    @Test("Each preview shape exports as a USDZ named after it, which RealityKit draws from the graph (M7a)",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: ViewportShape.allCases)
    @MainActor
    func exportsShape(_ shape: ViewportShape) async throws {
        let drawing: RealityKitDrawing = try #require(RealityKitDrawing.shared)
        let (folder, remove) = try Self.folder()
        defer {
            if remove {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        // Textured, so the shape's texture coordinates are exercised.
        let url: URL = try #require(Examples.files.first { $0.lastPathComponent == "standard_surface_brass_tiled.mtlx" })
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let usdz: URL = folder.appending(path: "brass.\(shape.rawValue).usdz")
        try Self.exportAndCheck(document, material: "Tiled_Brass", to: usdz, "\(shape)", shape: shape)

        let entity = try await Entity(contentsOf: usdz)
        let name: String = shape == .shaderBall ? "ShaderBall" : shape.title
        #expect(entity.findEntity(named: name) != nil, "\(shape): no \(name) in the scene")
        let (kinds, image) = try await drawing.draw(usdz)
        #expect(kinds == ["ShaderGraphMaterial"], "\(shape): \(kinds), not drawn from its graph")
        Self.expectDrawn(image, "\(shape)")
    }

    /// A brick texture from MaterialX's resources, greyscale (one channel).
    static let brick: String = {
        var root = URL(filePath: #filePath)
        for _ in 0..<5 {
            root = root.deletingLastPathComponent()
        }
        return root.appending(path: "Vendor/MaterialX/resources/Images/brick_base_gray.jpg").path(percentEncoded: false)
    }()

    /// A document whose material's base colour is an `image` reading
    /// `file` as a colour, through a definition made in the document if
    /// `asDefinition` (the spike's `m4_definition`, which Reality Composer
    /// Pro drew red).
    static func imageDocument(reading file: String, asDefinition: Bool) throws -> MXDocument {
        let document = try MXDocument(xml: StormRendererTests.emptyDocument)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let image: String = try document.addNode(nodeDef: "ND_image_color3", named: "tex")
        try document.setValue(file, ofInput: "file", on: image)
        try document.setColorSpace("srgb_texture", ofInput: "file", on: image)
        try StormRendererTests.addMaterial(reading: image, to: document)
        if asDefinition {
            let graph: String = try document.collapse([image])
            _ = try document.promote(input: "file", on: "\(graph)/\(image)", as: "file")
            _ = try document.makeNodeDefinition(from: graph, as: MXNodeDefSpec(node: "bricks", name: "ND_bricks_color3",
                                                                              nodeGroup: "texture2d", version: "1.0"))
        }
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
        return document
    }

    @Test("A greyscale image read as a colour is read as a float and converted, computing the same (M5c)",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: [false, true])
    @MainActor
    func rewritesGreyscaleImages(asDefinition: Bool) async throws {
        let drawing: RealityKitDrawing = try #require(RealityKitDrawing.shared)
        let (folder, remove) = try Self.folder()
        defer {
            if remove {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        let label: String = asDefinition ? "m5c_greyscale_definition" : "m5c_greyscale_image"
        let document = try Self.imageDocument(reading: Self.brick, asDefinition: asDefinition)
        let text: String = try document.usdzXMLString()
        #expect(text.contains(#"type="float""#) && text.contains("<convert"), "\(label): not rewritten\n\(text)")
        // The file's space done by the library's nodes, not the image.
        #expect(!text.contains("srgb_texture") && text.contains("<ifgreater"), "\(label): no transform\n\(text)")
        // The transform's mix, weighted by a colour, spelled out as a sum.
        #expect(!text.contains("<mix") && text.contains("<subtract"), "\(label): mix left\n\(text)")

        // Storm: the rewritten text looks like the document.
        let viewport = try MGStormRenderer(materialXString: try document.viewportXMLString())
        let rewritten = try MGStormRenderer(materialXString: text)
        StormRendererTests.compare(try StormRendererTests.renderMaterials(of: document, with: viewport),
                                   try Self.renderMaterials(with: rewritten), label)

        // RealityKit: drawn from its graph.
        let usdz: URL = folder.appending(path: "\(label).usdz")
        try Self.exportAndCheck(document, material: "M", to: usdz, label)
        let (kinds, image) = try await drawing.draw(usdz)
        #expect(kinds == ["ShaderGraphMaterial"], "\(label): \(kinds)")
        Self.expectDrawn(image, label)
        Self.expectGreyTexture(image, label)
    }

    /// Records an issue unless the middle of `image` shows a grey texture:
    /// every pixel nearly neutral, and not all the same. A graph RealityKit
    /// can't compile draws cyan stripes (a colour-weighted mix did, before
    /// SpellOutWeightedMixes); one it reads wrong, a plain colour.
    static func expectGreyTexture(_ image: CGImage, _ label: String) {
        var darkest: Int = 255
        var lightest: Int = 0
        for y in 24..<40 {
            for x in 24..<40 {
                let pixel = Fixtures.pixel(image, x: x, y: y)
                // SWIFT: `[Int(…), …]` turns the pixel's three UInt8 into an
                // array, so `max()`/`min()` find its brightest and darkest
                // channel. They return optionals (an empty array has
                // neither), hence the `!`: three elements, never empty.
                let channels: [Int] = [Int(pixel.r), Int(pixel.g), Int(pixel.b)]
                guard channels.max()! - channels.min()! <= 12 else {
                    Issue.record("\(label): not grey, \(pixel) at (\(x), \(y))")
                    return
                }
                darkest = min(darkest, channels[1])
                lightest = max(lightest, channels[1])
            }
        }
        #expect(lightest - darkest > 10, "\(label): no texture, \(darkest)...\(lightest)")
    }

    @Test("A colour image read as a colour is left as it is (M5c)")
    func keepsColourImages() throws {
        let wood: String = URL(filePath: Self.brick).deletingLastPathComponent().appending(path: "wood_color.jpg")
            .path(percentEncoded: false)
        let document = try Self.imageDocument(reading: wood, asDefinition: false)
        #expect(try document.usdzXMLString() == (try document.usdXMLString()))
    }

    /// Every material `renderer` shows, by name, as renderMaterials(of:with:)
    /// draws them, without replacing its text.
    static func renderMaterials(with renderer: MGStormRenderer) throws -> [String: CGImage] {
        var images: [String: CGImage] = [:]
        for path in renderer.materialPaths {
            #expect(renderer.bindMaterial(atPath: path))
            images[(path as NSString).lastPathComponent] = renderer.snapshot(width: 64, height: 64,
                                                                            viewTransform: StormRendererTests.untoneMapped)
        }
        return images
    }
}
