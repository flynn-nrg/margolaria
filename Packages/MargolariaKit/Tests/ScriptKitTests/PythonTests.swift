// PythonTests.swift
//
// Tests for the embedded Python (M6a's spike): it starts from Vendor's
// Python.framework, imports the MaterialX package built against SwiftUsd's
// MaterialX, and a script changes the very document it's given.
//
// Introduces (SWIFT): nothing new.

import Foundation
import Testing
import MXKit
@testable import ScriptKit

@Suite("Embedded Python")
@MainActor
struct PythonTests {
    init() throws {
        try Python.start(from: .inVendor())
    }

    @Test("Starts Python 3.13 and imports MaterialX 1.39.5")
    func startsAndImports() throws {
        #expect(Python.version.hasPrefix("3.13."), "\(Python.version)")
        let result = Python.run("import MaterialX\nprint(MaterialX.__version__)", named: "version.py",
                                on: try MXDocument(xml: "<materialx version=\"1.39\"/>"))
        #expect(result.succeeded, "\(result.output)")
        #expect(result.output == "1.39.5\n")
    }

    @Test("A script builds a material in the document it's given")
    func buildsMaterial() throws {
        let document = try MXDocument(xml: "<materialx version=\"1.39\"/>")
        let script = """
            import MaterialX as mx
            import margolaria

            doc = margolaria.document()
            shader = doc.addNode("standard_surface", "brick_shader", mx.SURFACE_SHADER_TYPE_STRING)
            shader.setInputValue("base_color", mx.Color3(0.6, 0.25, 0.15))
            doc.addMaterialNode("brick", shader)
            print(len(doc.getMaterialNodes()), "material")
            """
        let result = Python.run(script, named: "brick.py", on: document)
        #expect(result.succeeded, "\(result.output)")
        #expect(result.output == "1 material\n")
        // The app's document is the one the script changed.
        #expect(document.topLevelElements.map(\.name) == ["brick_shader", "brick"])
        let xml = try document.xmlString()
        #expect(xml.contains("<input name=\"base_color\" type=\"color3\" value=\"0.6, 0.25, 0.15\" />"), "\(xml)")
    }

    @Test("The spike's scripts add a valid material, then list it")
    func spikeScripts() throws {
        // Spikes/M6aPython, found from this file in the repository.
        let spike = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Spikes/M6aPython")
        let document = try MXDocument(xml: "<materialx version=\"1.39\"/>")
        document.setDataLibrary(try MXLibrary.bundled.get())

        let add = try String(contentsOf: spike.appending(path: "add_brick.py"), encoding: .utf8)
        let added = Python.run(add, named: "add_brick.py", on: document)
        #expect(added.succeeded, "\(added.output)")
        #expect(added.output == "Added brick.\n")
        // Valid against MaterialX's definitions: every node and input exists
        // with the types the script gave.
        #expect(document.validate() == .valid, "\(document.validate())")

        let list = try String(contentsOf: spike.appending(path: "list_materials.py"), encoding: .utf8)
        let listed = Python.run(list, named: "list_materials.py", on: document)
        #expect(listed.succeeded, "\(listed.output)")
        #expect(listed.output.hasSuffix("1 material:\n  brick: open_pbr_surface\n"), "\(listed.output)")
    }

    @Test("An exception is reported with its traceback, naming the script")
    func reportsExceptions() throws {
        let document = try MXDocument(xml: "<materialx version=\"1.39\"/>")
        let result = Python.run("print('before')\nraise ValueError('no such node')", named: "broken.py",
                                on: document)
        #expect(!result.succeeded)
        #expect(result.output.hasPrefix("before\nTraceback"), "\(result.output)")
        #expect(result.output.contains("File \"broken.py\", line 2"), "\(result.output)")
        #expect(result.output.hasSuffix("ValueError: no such node\n"), "\(result.output)")
    }

    @Test("sys.exit ends the script, not the process")
    func exitEndsScript() throws {
        let document = try MXDocument(xml: "<materialx version=\"1.39\"/>")
        #expect(Python.run("import sys\nsys.exit()", named: "exit.py", on: document).succeeded)
        #expect(!Python.run("import sys\nsys.exit(2)", named: "exit.py", on: document).succeeded)
    }

    @Test("A function kept from one run reaches the next run's document")
    func documentOfEachRun() throws {
        let document = try MXDocument(xml: "<materialx version=\"1.39\"/>")
        // A function kept from one run, called in the next: the document
        // it reaches is the second run's.
        _ = Python.run("import builtins, margolaria\nbuiltins.kept = margolaria.document", named: "keep.py",
                       on: document)
        let other = try MXDocument(xml: "<materialx version=\"1.39\"><surfacematerial name=\"m\" type=\"material\"/></materialx>")
        let result = Python.run("print(kept().getMaterialNodes()[0].getName())", named: "use.py", on: other)
        #expect(result.output == "m\n", "\(result.output)")
    }
}
