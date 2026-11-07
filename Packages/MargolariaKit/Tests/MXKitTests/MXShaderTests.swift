// MXShaderTests.swift
//
// Tests for MSL generation (spike M0c). Each test also writes the generated
// source next to the snapshots (VIEWPORT_SNAPSHOT_DIR, or the temporary
// folder), so it can be read.
//
// Since M5d, also shader code in every language, and writing it to files
// (MXShaderExport). Every example's, compiled and rendered, is checked by
// PreviewKitTests' GeneratedShaderTests.

import Foundation
import Testing
@testable import MXKit

@Suite("MSL generation")
struct MXShaderTests {
    /// The copper fixture, with the standard libraries attached.
    func copperDocument() throws -> (MXDocument, MXLibrary) {
        let library: MXLibrary = try MXLibrary.bundled.get()
        let document = try MXDocument.read(from: Fixtures.url("brushed_copper.mtlx"))
        document.setDataLibrary(library)
        return (document, library)
    }

    /// Writes generated source to a file for inspection.
    func save(_ source: String, as name: String) throws {
        let folderPath: String = ProcessInfo.processInfo.environment["VIEWPORT_SNAPSHOT_DIR"]
            ?? FileManager.default.temporaryDirectory.path
        let url = URL(fileURLWithPath: folderPath).appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        print("Generated MSL: \(url.path)")
    }

    @Test("Generates MSL for a node inside a nodegraph")
    func nodeOutput() throws {
        let (document, library) = try copperDocument()
        let shader = try document.generateMSL(for: "NG_copper/grain", library: library)
        try save(shader.vertexSource, as: "grain.vert.metal")
        try save(shader.pixelSource, as: "grain.frag.metal")

        #expect(shader.outputType == "float")
        #expect(shader.pixelSource.contains("FragmentMain"))
        // The node's inputs become uniforms with the document's values.
        let amplitude = try #require(shader.uniforms.first(where: { $0.name.hasSuffix("amplitude") }))
        #expect(amplitude.value == [0.25])
    }

    @Test("Generates MSL for a material")
    func material() throws {
        let (document, library) = try copperDocument()
        let shader = try document.generateMSL(for: "M_BrushedCopper", library: library)
        try save(shader.vertexSource, as: "copper.vert.metal")
        try save(shader.pixelSource, as: "copper.frag.metal")
        #expect(shader.outputType == "material")
    }

    @Test("Lists the elements a shader can be generated for, with paths")
    func shadeableElements() throws {
        let (document, _) = try copperDocument()
        let paths: [String] = document.shadeableElements.map { $0.path }
        #expect(paths == ["NG_copper/grain", "NG_copper/roughness_out", "SR_copper", "M_BrushedCopper"])
    }

    @Test("An unknown path is an error, not a crash")
    func unknownPath() throws {
        let (document, library) = try copperDocument()
        #expect(throws: MXError.self) {
            _ = try document.generateMSL(for: "NoSuchNode", library: library)
        }
    }
}

@Suite("Shader code (M5d)")
struct MXShaderCodeTests {
    @Test("Generates every language for a material: stages, Ci, and the network's compiled shaders",
          arguments: MXShaderLanguage.allCases)
    func everyLanguage(_ language: MXShaderLanguage) throws {
        let (document, library) = try MXShaderTests().copperDocument()
        let code: MXShaderCode = try document.generateCode(for: "M_BrushedCopper", in: language, library: library)
        #expect(code.language == language)
        #expect(!code.pixelSource.isEmpty)
        switch language {
        case .msl, .glsl:
            #expect(!code.vertexSource.isEmpty)
            #expect(code.osoFiles.isEmpty)
        case .osl:
            // One shader, named after the material, assigning Ci.
            #expect(code.vertexSource.isEmpty)
            #expect(code.pixelSource.contains("shader M_BrushedCopper"))
            #expect(code.pixelSource.contains("Ci = "))
            #expect(code.osoFiles.isEmpty)
        case .oslNetwork:
            // A group ending in the node that assigns Ci, whose shaders
            // are all in MaterialX's compiled library.
            #expect(code.vertexSource.isEmpty)
            #expect(code.pixelSource.contains(" oslSetCi ;"))
            #expect(!code.osoFiles.isEmpty)
            for file in code.osoFiles {
                #expect(FileManager.default.fileExists(atPath: file), "\(file)")
                // SWIFT: `(file as NSString).lastPathComponent` would do
                // too; URL is Swift's own way.
                let shader: String = URL(filePath: file).deletingPathExtension().lastPathComponent
                #expect(code.pixelSource.contains("shader \(shader) "), "\(shader) isn't in the group")
            }
        }
    }

    @Test("A network's file paths are quoted, so a path with a space stays one value")
    func quotesFilenames() throws {
        let library: MXLibrary = try MXLibrary.bundled.get()
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <image name="tex" type="color3">
                <input name="file" type="filename" value="/textures/old bricks/base.png" />
              </image>
            </materialx>
            """)
        document.setDataLibrary(library)
        let code: MXShaderCode = try document.generateCode(for: "tex", in: .oslNetwork, library: library)
        #expect(code.pixelSource.contains(#"param string file "/textures/old bricks/base.png" ;"#), "\(code.pixelSource)")
        // The node's values are in the group (MaterialX leaves out those
        // of the node it starts from; the bridge starts from a dot node
        // reading it), and nothing is quoted twice.
        #expect(code.pixelSource.contains("shader IM_image_color3_genoslnetwork tex ;"))
        #expect(!code.pixelSource.contains(#""""#))
    }

    @Test("A node of a definition made in the document gets a network, from its implementation's nodes")
    func networkOfDefinition() throws {
        let library: MXLibrary = try MXLibrary.bundled.get()
        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodedef name="ND_twice_float" node="twice">
                <input name="in" type="float" value="1" />
                <output name="out" type="float" />
              </nodedef>
              <nodegraph name="NG_twice_float" nodedef="ND_twice_float">
                <multiply name="times" type="float">
                  <input name="in1" type="float" interfacename="in" />
                  <input name="in2" type="float" value="2" />
                </multiply>
                <output name="out" type="float" nodename="times" />
              </nodegraph>
              <twice name="doubled" type="float">
                <input name="in" type="float" value="0.25" />
              </twice>
            </materialx>
            """)
        document.setDataLibrary(library)
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
        let code: MXShaderCode = try document.generateCode(for: "doubled", in: .oslNetwork, library: library)
        #expect(code.pixelSource.contains("shader IM_multiply_float_genoslnetwork "), "\(code.pixelSource)")
        // The document itself is unchanged: the expansion is on a copy.
        #expect(try document.xmlString().contains("<twice name=\"doubled\""))
    }

    @Test("Writes each language's files", arguments: MXShaderLanguage.allCases)
    func writesFiles(_ language: MXShaderLanguage) throws {
        let (document, library) = try MXShaderTests().copperDocument()
        let code: MXShaderCode = try document.generateCode(for: "M_BrushedCopper", in: language, library: library)
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "MXShaderCodeTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: folder)
        }
        // Twice: a second export over the first replaces it.
        _ = try MXShaderExport.write(code, named: "copper", to: folder, oslc: nil, library: library)
        let files: [URL] = try MXShaderExport.write(code, named: "copper", to: folder, oslc: nil, library: library)
        let names: [String] = files.map(\.lastPathComponent)
        switch language {
        case .msl:
            #expect(names == ["copper.vert.metal", "copper.frag.metal"])
        case .glsl:
            #expect(names == ["copper.vert.glsl", "copper.frag.glsl"])
        case .osl:
            // No oslc given: the source only.
            #expect(names == ["copper.osl"])
        case .oslNetwork:
            #expect(names.first == "copper.oslgroup")
            #expect(names.dropFirst().allSatisfy { $0.hasSuffix(".oso") })
            #expect(names.count == code.osoFiles.count + 1)
        }
        for file in files {
            #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        }
    }

    @Test("An oslc that can't run is a compile error, not a crash")
    func missingCompiler() throws {
        let library: MXLibrary = try MXLibrary.bundled.get()
        #expect(throws: MXError.self) {
            try MXShaderExport.compileOSL(URL(filePath: "/nonexistent/a.osl"), to: URL(filePath: "/nonexistent/a.oso"),
                                          oslc: URL(filePath: "/nonexistent/oslc"), library: library)
        }
    }
}
