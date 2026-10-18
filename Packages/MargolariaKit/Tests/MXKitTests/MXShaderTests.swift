// MXShaderTests.swift
//
// Tests for MSL generation (spike M0c). Each test also writes the generated
// source next to the snapshots (VIEWPORT_SNAPSHOT_DIR, or the temporary
// folder), so it can be read.

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
