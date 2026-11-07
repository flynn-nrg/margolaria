// GeneratedShaderTests.swift
//
// M5d's exit criterion (PLAN.md §8.6): for every example in MaterialX's
// resources/Materials/Examples,
//
//   - every node with a swatch (SwatchPlan), and every material, generates
//     MSL, GLSL and both forms of OSL, apart from MaterialX's known
//     failures, listed below;
//   - the MSL compiles with Metal;
//   - every material's OSL, written by Export Shader…'s code
//     (MXShaderExport), compiles to .oso with oslc in the one-shader form,
//     and both forms render in OSL's testrender, alike: the network's
//     shaders, compiled from MaterialX's library, compute what the
//     inlined shader does.
//
// Also: a shader generated to compute in ACEScg (an ACEScg document's
// export) converts colours from other spaces with Margolaria's transforms,
// to the right numbers, as testshade prints them.
//
// The OSL tests need scripts/build-osl.sh's tools; without them they are
// skipped. With M5D_SHADER_DIR set, the exported files and the renders
// (<file>.<material>.png, one-shader form left, network right) are kept
// there, for reading.
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import MXKit
import PreviewKit
import Testing

@Suite("Generated shaders of every example (M5d)", .serialized)
struct GeneratedShaderTests {
    /// The repository's root folder.
    static let root: URL = {
        var root = URL(filePath: #filePath)
        for _ in 0..<5 {
            root = root.deletingLastPathComponent()
        }
        return root
    }()

    /// scripts/build-osl.sh's tool called `name`, if it has been built.
    static func oslTool(_ name: String) -> URL? {
        let url: URL = root.appending(path: "Vendor/OSL/install/bin/\(name)")
        return FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    static let oslc: URL? = oslTool("oslc")
    static let testrender: URL? = oslTool("testrender")
    static let testshade: URL? = oslTool("testshade")

    /// Where files are kept: M5D_SHADER_DIR, or nil.
    static let keptFolder: URL? = ProcessInfo.processInfo.environment["M5D_SHADER_DIR"].map { URL(filePath: $0) }

    /// Shaders MaterialX 1.39.5 can't generate, by "file element language",
    /// with why: the swatches' known failures (SwatchCorpusTests), whose
    /// MSL doesn't compile. The other languages generate them.
    static let knownFailures: Set<String> = Set(SwatchCorpusTests.knownFailures.map { "\($0) msl" })

    /// Each example, its preview text read back (as the swatches and the
    /// Generated Shader tab generate from it) with the data library, and
    /// the elements to generate: every swatch's, and every material.
    static func elements(of url: URL, library: MXLibrary) throws -> (MXDocument, [String]) {
        let original = try MXDocument.read(from: url)
        original.setDataLibrary(library)
        let xml: String = try original.xmlString()
        let custom = Set(original.topLevelElements.filter { $0.category == "nodedef" }.map(\.name))
        var paths: [String] = original.topLevelElements.filter { $0.type == "material" }.map(\.name)
        for level in [""] + original.nodeGraphs.map(\.path) {
            for request in SwatchPlan.requests(for: try original.graph(at: level), in: original, documentText: xml,
                                               customNodeDefs: custom)
            where !paths.contains(request.shaderPath) {
                paths.append(request.shaderPath)
            }
        }
        let preview = try MXDocument(xml: try original.previewXMLString())
        preview.setDataLibrary(library)
        return (preview, paths)
    }

    @Test("Every swatch's element and every material generates MSL, GLSL and OSL in both forms; the MSL compiles",
          .enabled(if: !SwatchCorpusTests.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"))
    func everyExampleGenerates() throws {
        let library: MXLibrary = try MXLibrary.bundled.get()
        let device: any MTLDevice = try #require(MTLCreateSystemDefaultDevice())
        var failures: [String: String] = [:]
        var count: Int = 0
        for url in SwatchCorpusTests.files {
            let (document, paths) = try Self.elements(of: url, library: library)
            for path in paths {
                for language in MXShaderLanguage.allCases {
                    let name = "\(url.lastPathComponent) \(path) \(language.rawValue)"
                    count += 1
                    do {
                        let code: MXShaderCode = try document.generateCode(for: path, in: language, library: library)
                        if language == .msl {
                            _ = try device.makeLibrary(source: code.vertexSource, options: nil)
                            _ = try device.makeLibrary(source: code.pixelSource, options: nil)
                        }
                        if language == .oslNetwork {
                            for file in code.osoFiles where !FileManager.default.fileExists(atPath: file) {
                                failures[name] = "names \(file), which doesn't exist"
                            }
                        }
                    } catch {
                        failures[name] = "\(error)"
                    }
                }
            }
        }
        print("Generated shaders of every example: \(count) generated, \(failures.count) failed")
        for (name, message) in failures where !Self.knownFailures.contains(name) {
            Issue.record("\(name): \(message)")
        }
        for name in Self.knownFailures where failures[name] == nil {
            Issue.record("\(name) works now: remove it from the known failures")
        }
    }

    /// An environment for testrender: a sky, brighter above, with a sun.
    /// From OSL's testsuite (render-mx-dielectric/envmap.osl).
    static let environment: String = """
        shader envmap(color sky = color(0.7, 0.8, 0.9), color horizon = color(0.3, 0.6, 0.9),
                      color sun = color(0.9, 0.8, 0.7), vector sun_dir = vector(1, 1, 1),
                      float sun_angle = 5.0)
        {
            vector dir = normalize(I);
            color c = mix(horizon, sky, dir.y * dir.y);
            float cos_ang = cos(radians(sun_angle / 2));
            if (dot(dir, normalize(sun_dir)) > cos_ang)
                c += sun / (1 - cos_ang);
            Ci = c * background();
        }
        """

    /// A testrender scene: the environment, and a sphere filling most of
    /// the picture, shaded by `group` (OSL's serialized shader group). For
    /// nil, the sphere is a speck behind the camera instead: testrender
    /// refuses a scene without one.
    static func scene(_ group: String?) -> String {
        let sphere: String = group.map { "<ShaderGroup>\n\($0)\n</ShaderGroup>\n<Sphere center=\"0,0,0\" radius=\"0.9\" />" }
            ?? "<ShaderGroup>shader envmap layer1;</ShaderGroup>\n<Sphere center=\"0,0,20\" radius=\"0.01\" />"
        return """
            <World>
               <Camera eye="0, 0, 10" look_at="0,0,0" fov="20" />
               <ShaderGroup>shader envmap layer1;</ShaderGroup>
               <Background resolution="256" />
            \(sphere)
            </World>
            """
    }

    /// Materials testrender can't draw, by "file.material", with why:
    /// its closures are a subset of MaterialX's, without hair
    /// (`chiang_hair_bsdf`). Their OSL is still compiled.
    static let notRendered: Set<String> = ["simple_hair_default.simple_hair_default"]

    /// Renders `scene` with testrender, 64 pixels square, finding shaders
    /// in `shaders`, and returns the picture.
    static func render(_ scene: String, in folder: URL, shaders: [URL], testrender: URL) throws -> CGImage {
        let sceneURL: URL = folder.appending(path: "scene-\(UUID().uuidString).xml")
        let imageURL: URL = sceneURL.deletingPathExtension().appendingPathExtension("exr")
        try scene.write(to: sceneURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: sceneURL)
            try? FileManager.default.removeItem(at: imageURL)
        }
        let process = Process()
        process.executableURL = testrender
        let searchPath: String = shaders.map { $0.path(percentEncoded: false) }.joined(separator: ":")
        process.arguments = ["--options", "searchpath:shader=\(searchPath)", "-r", "64", "64", "-aa", "4",
                             sceneURL.path(percentEncoded: false), imageURL.path(percentEncoded: false)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output: Data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // testrender reports a shader it can't load or run on its output,
        // without failing.
        let messages: String = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0, !messages.contains("ERROR"),
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MXError.compileFailed("testrender: \(messages)")
        }
        // ImageIO decodes when the picture is first drawn, and the file
        // is removed on return: drawn into a bitmap now.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()!
    }

    /// `image`'s pixels as 8-bit sRGB RGBA, row by row.
    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// The mean difference of two pictures' channels, 0...255.
    static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total: Int = 0
        for index in a.indices {
            total += abs(Int(a[index]) - Int(b[index]))
        }
        return Double(total) / Double(a.count)
    }

    /// Writes the two renders side by side as a PNG.
    static func keep(_ left: CGImage, _ right: CGImage, as url: URL) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: left.width * 2, height: left.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return
        }
        context.draw(left, in: CGRect(x: 0, y: 0, width: left.width, height: left.height))
        context.draw(right, in: CGRect(x: left.width, y: 0, width: right.width, height: right.height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    @Test("Every material's OSL compiles with oslc, and both forms render alike in testrender",
          .enabled(if: !SwatchCorpusTests.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          .enabled(if: oslc != nil && testrender != nil, "Run scripts/build-osl.sh to build OSL's tools"))
    func everyMaterialRendersInOSL() throws {
        let library: MXLibrary = try MXLibrary.bundled.get()
        let oslc: URL = try #require(Self.oslc)
        let testrender: URL = try #require(Self.testrender)
        let folder: URL = Self.keptFolder ?? FileManager.default.temporaryDirectory
            .appending(path: "GeneratedShaderTests-\(UUID().uuidString)")
        defer {
            if Self.keptFolder == nil {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        // The environment, compiled once.
        let common: URL = folder.appending(path: "common")
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        let environmentSource: URL = common.appending(path: "envmap.osl")
        try Self.environment.write(to: environmentSource, atomically: true, encoding: .utf8)
        try MXShaderExport.compileOSL(environmentSource, to: common.appending(path: "envmap.oso"), oslc: oslc,
                                      library: library)
        let empty: [UInt8] = Self.pixels(try Self.render(Self.scene(nil), in: folder, shaders: [common],
                                                         testrender: testrender))

        var count: Int = 0
        for url in SwatchCorpusTests.files {
            let (document, _) = try Self.elements(of: url, library: library)
            for material in document.topLevelElements.filter({ $0.type == "material" }).map(\.name) {
                let label = "\(url.deletingPathExtension().lastPathComponent).\(material)"
                count += 1
                do {
                    // Each form exported into its own folder, which is the
                    // renderer's shader search path, as a user would.
                    let single: URL = folder.appending(path: "\(label)/osl")
                    let network: URL = folder.appending(path: "\(label)/oslNetwork")
                    _ = try MXShaderExport.write(try document.generateCode(for: material, in: .osl, library: library),
                                                 named: material, to: single, oslc: oslc, library: library)
                    let group = try document.generateCode(for: material, in: .oslNetwork, library: library)
                    _ = try MXShaderExport.write(group, named: material, to: network, oslc: nil, library: library)
                    if Self.notRendered.contains(label) {
                        continue
                    }

                    let inlined: CGImage = try Self.render(Self.scene("shader \(material) layer1;"), in: folder,
                                                           shaders: [single, common], testrender: testrender)
                    let networked: CGImage = try Self.render(Self.scene(group.pixelSource), in: folder,
                                                             shaders: [network, common], testrender: testrender)
                    if Self.keptFolder != nil {
                        Self.keep(inlined, networked, as: folder.appending(path: "\(label).png"))
                    }
                    let a: [UInt8] = Self.pixels(inlined)
                    let b: [UInt8] = Self.pixels(networked)
                    // Something drawn: not the empty scene. Glass and
                    // chrome show only the sky, bent or reflected, and the
                    // soap bubble, a clear film, barely that (0.15), so
                    // this asks little; a shader that drew nothing would
                    // give 0, since testrender samples alike every time.
                    let drawn: Double = Self.meanDifference(a, empty)
                    #expect(drawn > 0.05, "\(label): nothing drawn (\(drawn) from the empty scene)")
                    let difference: Double = Self.meanDifference(a, b)
                    #expect(difference < 2, "\(label): the forms differ by \(difference)")
                } catch {
                    Issue.record("\(label): \(error)")
                }
            }
        }
        print("OSL of every example's materials: \(count) compiled and rendered in both forms")
    }

    /// Runs testshade on one point with `arguments`, and returns what it
    /// prints.
    static func shade(_ arguments: [String], testshade: URL) throws -> String {
        let process = Process()
        process.executableURL = testshade
        process.arguments = ["-g", "1", "1"] + arguments + ["--print"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output: Data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }

    /// The three numbers testshade prints for the output `name`, which it
    /// names without its layer ("    out : 0.6 0.07 0.02").
    static func printed(_ name: String, in output: String) -> [Double] {
        let line: Substring = output.split(separator: "\n").first { $0.contains("\(name) :") } ?? ""
        return line.split(separator: ":").last?.split(separator: " ").compactMap { Double($0) } ?? []
    }

    @Test("A shader computing in ACEScg converts other spaces' colours to it, as both forms compute",
          .enabled(if: oslc != nil && testshade != nil, "Run scripts/build-osl.sh to build OSL's tools"))
    func convertsToACEScg() throws {
        let library: MXLibrary = try MXLibrary.bundled.get()
        let oslc: URL = try #require(Self.oslc)
        let testshade: URL = try #require(Self.testshade)
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39" colorspace="acescg">
              <constant name="red" type="color3">
                <input name="value" type="color3" value="1, 0, 0" colorspace="lin_rec709" />
              </constant>
              <constant name="grey" type="color3">
                <input name="value" type="color3" value="0.5, 0.5, 0.5" colorspace="srgb_texture" />
              </constant>
              <constant name="own" type="color3">
                <input name="value" type="color3" value="0.25, 0.5, 0.75" />
              </constant>
            </materialx>
            """)
        document.setDataLibrary(library)
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "GeneratedShaderTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: folder)
        }
        // Rec.709 red in ACEScg: the first column of the Rec.709 to AP1
        // matrix. sRGB 0.5 is 0.214 linear, a grey in either space. The
        // document's own colours (ACEScg) are left as they are.
        let srgbHalf: Double = pow((0.5 + 0.055) / 1.055, 2.4)
        let expected: [String: [Double]] = [
            "red": [0.613097, 0.070194, 0.020616],
            "grey": [srgbHalf, srgbHalf, srgbHalf],
            "own": [0.25, 0.5, 0.75],
        ]
        for (name, values) in expected {
            // One shader: computing with the transform, and compiling.
            let single = try document.generateCode(for: name, in: .osl, library: library, colorSpace: "acescg")
            #expect(single.colorSpace == "acescg")
            #expect(name == "own" || single.pixelSource.contains("_to_acescg_color3("), "\(name): no transform")
            // Nothing converted out of ACEScg (sRGB's transform goes
            // through Rec.709 on its way in, by design).
            #expect(!single.pixelSource.contains("acescg_to_lin_rec709"), "\(name): converted to Rec.709")
            _ = try MXShaderExport.write(single, named: name, to: folder.appending(path: "\(name)-osl"), oslc: oslc,
                                         library: library)

            // The network, run: testshade prints the output of the layer
            // read by the Ci wrapper (the network's dot, `<name>_shown`).
            let network = try document.generateCode(for: name, in: .oslNetwork, library: library, colorSpace: "acescg")
            let shaders: URL = folder.appending(path: "\(name)-network")
            _ = try MXShaderExport.write(network, named: name, to: shaders, oslc: nil, library: library)
            let output: String = try Self.shade(["--options", "searchpath:shader=\(shaders.path(percentEncoded: false))",
                                                 "--group", network.pixelSource, "-o", "\(name)_shown.out", "null"],
                                                testshade: testshade)
            let computed: [Double] = Self.printed("out", in: output)
            #expect(computed.count == 3, "\(name): \(output)")
            for (a, b) in zip(computed, values) {
                #expect(abs(a - b) < 1e-5, "\(name): \(computed), not \(values)")
            }
        }
        // A space with no transforms to it computes in lin_rec709, and says so.
        let other = try document.generateCode(for: "red", in: .osl, library: library, colorSpace: "lin_displayp3")
        #expect(other.colorSpace == "lin_rec709")
    }
}
