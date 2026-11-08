// MargolariaModuleTests.swift
//
// Tests for the `margolaria` module (M6b): scripts as undo steps (M6's
// exit criterion), the editor's edits and their refusals, `with
// margolaria.edit(...)`, the document kept across an undo, and the calls
// the module makes to Swift (selection, issues, working space, export).
//
// Introduces (SWIFT): nothing new.

import Foundation
import Testing
import MXKit
@testable import ScriptKit

/// The window a script runs in, for the tests: a selection to read and
/// set, and a folder for relative export paths.
///
/// SWIFT: The class *adopts* the protocol (`: ScriptHost`) by having
/// everything it requires; a stored `var` meets a `{ get }` requirement.
@MainActor
final class TestHost: ScriptHost {
    var selection: [String] = []
    var documentFolder: URL? = nil

    func select(_ path: String) {
        selection = [path]
    }
}

@Suite("The margolaria module")
@MainActor
struct MargolariaModuleTests {
    init() throws {
        try Python.start(from: .inVendor())
    }

    /// A document with MaterialX's definitions, as the app's always has.
    func emptyDocument() throws -> MXDocument {
        let document = try MXDocument(xml: "<materialx version=\"1.39\"/>")
        document.setDataLibrary(try MXLibrary.bundled.get())
        return document
    }

    /// The exit criterion's script: a surface shader, a material, and an
    /// image read and connected, with the editor's edits and MaterialX's
    /// own API mixed.
    static let brick: String = """
        import MaterialX as mx
        import margolaria

        shader = margolaria.add_node("ND_standard_surface_surfaceshader", name="brick_shader")
        material = margolaria.add_node("ND_surfacematerial", name="brick")
        texture = margolaria.add_node("ND_image_color3", name="brick_color")
        margolaria.set_value(texture, "file", "brick.png")
        margolaria.connect(shader, "base_color", texture)
        margolaria.connect(material, "surfaceshader", shader)
        # MaterialX's API, on the same document.
        doc = margolaria.document()
        doc.getNode(shader).setInputValue("specular_roughness", 0.6)
        print(", ".join(node.getName() for node in doc.getNodes()))
        """

    @Test("A script builds a material as one undo step, which undoes and redoes (M6 exit criterion)")
    func exitCriterion() throws {
        let document = try emptyDocument()
        let before: MXDocument = document.copy()
        let undoManager = UndoManager()
        var changes: Int = 0

        let result = Python.run(Self.brick, named: "/scripts/brick.py", on: document, undoManager: undoManager,
                                changed: { _ in changes += 1 })
        #expect(result.succeeded, "\(result.output)")
        #expect(result.output == "brick_shader, brick, brick_color\n")
        #expect(result.steps == ["Run brick.py"])
        #expect(document.validate() == .valid, "\(document.validate())")
        let xml = try document.xmlString()
        #expect(xml.contains("<input name=\"base_color\" type=\"color3\" nodename=\"brick_color\" />"), "\(xml)")
        #expect(xml.contains("<input name=\"surfaceshader\" type=\"surfaceshader\" nodename=\"brick_shader\" />"),
                "\(xml)")
        #expect(xml.contains("<input name=\"specular_roughness\" type=\"float\" value=\"0.6\" />"), "\(xml)")
        let after: MXDocument = document.copy()

        // One more step, named after the script.
        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == "Run brick.py")
        undoManager.undo()
        #expect(document.difference(from: before) == nil)
        #expect(!undoManager.canUndo)
        undoManager.redo()
        #expect(document.difference(from: after) == nil)
        #expect(changes == 2)
    }

    @Test("A script that raises leaves the document unchanged and adds no step")
    func raisingChangesNothing() throws {
        let document = try emptyDocument()
        let before: MXDocument = document.copy()
        let undoManager = UndoManager()
        let script = Self.brick + "\nraise RuntimeError('changed my mind')\n"
        let result = Python.run(script, named: "brick.py", on: document, undoManager: undoManager)
        #expect(!result.succeeded)
        #expect(result.output.hasSuffix("RuntimeError: changed my mind\n"), "\(result.output)")
        #expect(result.steps.isEmpty)
        #expect(document.difference(from: before) == nil)
        #expect(!undoManager.canUndo)
    }

    @Test("A script that changes nothing adds no step")
    func readingAddsNoStep() throws {
        let document = try emptyDocument()
        let undoManager = UndoManager()
        _ = Python.run(Self.brick, named: "brick.py", on: document)
        let result = Python.run("import margolaria\nprint(len(margolaria.document().getMaterialNodes()))",
                                named: "count.py", on: document, undoManager: undoManager)
        #expect(result.output == "1\n")
        #expect(result.steps.isEmpty)
        #expect(!undoManager.canUndo)
    }

    @Test("Every edit refused comes to Python as margolaria.EditRefused, leaving the document as it was")
    func refusalsRaise() throws {
        let document = try emptyDocument()
        _ = Python.run(Self.brick, named: "brick.py", on: document)
        let before: MXDocument = document.copy()
        // One refusal of each edit, from what MXBridge checks.
        let refused: [String] = [
            "margolaria.add_node('ND_no_such_node')",
            "margolaria.add_node('ND_add_float', parent='no_such_graph')",
            "margolaria.remove_node('no_such_node')",
            "margolaria.rename_node('brick', 'brick_shader')",
            "margolaria.rename_node('brick', 'not a name')",
            "margolaria.change_nodedef('brick_color', 'ND_no_such_node')",
            "margolaria.set_value('brick_shader', 'base', 'not a number')",
            "margolaria.set_value('no_such_node', 'base', 0.5)",
            "margolaria.reset_input('no_such_node', 'base')",
            "margolaria.set_colorspace('no_such_node', 'file', 'srgb_texture')",
            // A colour into a float, a material into a shader, and a loop.
            "margolaria.connect('brick_shader', 'base', 'brick_color')",
            "margolaria.connect('brick_shader', 'base_color', 'brick')",
            "margolaria.connect('brick_color', 'file', 'brick_color')",
            "margolaria.connect_interface('brick_shader', 'base', 'no_such_input')",
            "margolaria.disconnect('no_such_node', 'base')",
            "margolaria.set_position('no_such_node', 1, 2)",
        ]
        for edit in refused {
            let script = """
                import margolaria
                try:
                    \(edit)
                except margolaria.EditRefused as refusal:
                    assert isinstance(refusal, ValueError)
                    print("refused:", refusal)
                """
            let result = Python.run(script, named: "refuse.py", on: document)
            #expect(result.succeeded, "\(edit): \(result.output)")
            #expect(result.output.hasPrefix("refused: ") && result.output.count > "refused: \n".count,
                    "\(edit): \(result.output)")
            #expect(document.difference(from: before) == nil, "\(edit): \(document.difference(from: before) ?? "")")
        }
    }

    @Test("Values: strings, numbers, booleans, tuples and MaterialX's own types")
    func valueTypes() throws {
        let document = try emptyDocument()
        let script = """
            import MaterialX as mx
            import margolaria

            shader = margolaria.add_node("ND_standard_surface_surfaceshader", name="s")
            margolaria.set_value(shader, "base", 0.25)
            margolaria.set_value(shader, "base_color", (0.5, 0.25, 1))
            margolaria.set_value(shader, "specular_color", mx.Color3(0.1, 0.2, 0.3))
            margolaria.set_value(shader, "thin_walled", True)
            margolaria.set_value(shader, "emission_color", "1, 0, 0")
            """
        let result = Python.run(script, named: "values.py", on: document)
        #expect(result.succeeded, "\(result.output)")
        let xml = try document.xmlString()
        for input in ["name=\"base\" type=\"float\" value=\"0.25\"",
                      "name=\"base_color\" type=\"color3\" value=\"0.5, 0.25, 1\"",
                      "name=\"specular_color\" type=\"color3\" value=\"0.1, 0.2, 0.3\"",
                      "name=\"thin_walled\" type=\"boolean\" value=\"true\"",
                      "name=\"emission_color\" type=\"color3\" value=\"1, 0, 0\""] {
            #expect(xml.contains(input), "\(input) in \(xml)")
        }
    }

    @Test("with margolaria.edit(...) blocks are steps of their own, and a block that raises is taken back")
    func editBlocks() throws {
        let document = try emptyDocument()
        let undoManager = UndoManager()
        let script = """
            import margolaria

            margolaria.add_node("ND_add_float", name="before")
            with margolaria.edit("Add Pair"):
                margolaria.add_node("ND_add_float", name="first")
                with margolaria.edit("Inner"):
                    margolaria.add_node("ND_add_float", name="second")
            with margolaria.edit("Nothing"):
                pass
            try:
                with margolaria.edit("Broken"):
                    margolaria.add_node("ND_add_float", name="lost")
                    raise KeyError("lost")
            except KeyError:
                pass
            margolaria.add_node("ND_add_float", name="after")
            """
        let result = Python.run(script, named: "pairs.py", on: document, undoManager: undoManager)
        #expect(result.succeeded, "\(result.output)")
        #expect(result.steps == ["Run pairs.py", "Add Pair", "Run pairs.py"])
        #expect(document.topLevelElements.map(\.name) == ["before", "first", "second", "after"])

        // Undo takes back one step at a time.
        undoManager.undo()
        #expect(document.topLevelElements.map(\.name) == ["before", "first", "second"])
        #expect(undoManager.undoActionName == "Add Pair")
        undoManager.undo()
        #expect(document.topLevelElements.map(\.name) == ["before"])
        undoManager.undo()
        #expect(document.topLevelElements.isEmpty)
        #expect(!undoManager.canUndo)
    }

    @Test("A document kept from one run is still the document after an undo")
    func documentKeptAcrossUndo() throws {
        let document = try emptyDocument()
        let undoManager = UndoManager()
        let keep = """
            import builtins, margolaria
            builtins.kept = margolaria.document()
            margolaria.add_node("ND_add_float", name="undone")
            """
        _ = Python.run(keep, named: "keep.py", on: document, undoManager: undoManager)
        undoManager.undo()
        #expect(document.topLevelElements.isEmpty)
        // The kept object sees the undo, and its changes are the app's.
        let use = "print(len(kept.getNodes()))\nkept.addNode('add', 'added', 'float')"
        let result = Python.run(use, named: "use.py", on: document)
        #expect(result.output == "0\n", "\(result.output)")
        #expect(document.topLevelElements.map(\.name) == ["added"])
    }

    @Test("An edit function kept from one run edits the next run's document")
    func functionKeptAcrossRuns() throws {
        let document = try emptyDocument()
        _ = Python.run("import builtins, margolaria\nbuiltins.later = margolaria.add_node", named: "keep.py",
                       on: document)
        // Run on another document: `later` works there, on that one.
        let other = try emptyDocument()
        let result = Python.run("later('ND_add_float')", named: "use.py", on: other)
        #expect(result.succeeded, "\(result.output)")
        #expect(document.topLevelElements.isEmpty)
        #expect(other.topLevelElements.count == 1)
    }

    @Test("The selection is the host's, read and set")
    func selection() throws {
        let document = try emptyDocument()
        let host = TestHost()
        host.selection = ["brick"]
        let result = Python.run("import margolaria\nprint(margolaria.selection())\nmargolaria.select('other')",
                                named: "select.py", on: document, host: host)
        #expect(result.output == "['brick']\n", "\(result.output)")
        #expect(host.selection == ["other"])

        // Without a window, a RuntimeError.
        let alone = Python.run("import margolaria\nmargolaria.selection()", named: "select.py", on: document)
        #expect(!alone.succeeded)
        #expect(alone.output.contains("RuntimeError: No window"), "\(alone.output)")
    }

    @Test("issues() lists what the Issues tab does")
    func issues() throws {
        let document = try emptyDocument()
        let script = """
            import margolaria
            print(margolaria.issues())
            margolaria.document().addNode("mutliply", "typo", "float")
            for issue in margolaria.issues():
                print(issue.severity, issue.source, issue.path)
            """
        let result = Python.run(script, named: "issues.py", on: document)
        #expect(result.succeeded, "\(result.output)")
        #expect(result.output == "[]\nerror margolaria typo\n", "\(result.output)")
    }

    @Test("The working space is read and set as the editor does, converting colours")
    func workingSpace() throws {
        let document = try emptyDocument()
        let script = """
            import margolaria
            shader = margolaria.add_node("ND_standard_surface_surfaceshader", name="s")
            margolaria.set_value(shader, "base_color", (0.5, 0.5, 0.5))
            print(margolaria.working_space())
            margolaria.set_working_space("acescg")
            print(margolaria.working_space())
            print(margolaria.document().getNode("s").getInput("base_color").getValueString())
            """
        let result = Python.run(script, named: "space.py", on: document)
        #expect(result.succeeded, "\(result.output)")
        let lines = result.output.split(separator: "\n")
        #expect(lines.prefix(2) == ["lin_rec709", "acescg"], "\(result.output)")
        // A grey stays a grey, in any space.
        #expect(lines.count == 3 && lines[2].hasPrefix("0.5"), "\(result.output)")
    }

    @Test("The examples in docs/scripting run as SCRIPTING.md says")
    func examples() throws {
        // docs/scripting, found from this file in the repository.
        let examples = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "docs/scripting")
        let document = try emptyDocument()
        let host = TestHost()
        let undoManager = UndoManager()

        let brick = try String(contentsOf: examples.appending(path: "brick.py"), encoding: .utf8)
        let built = Python.run(brick, named: "brick.py", on: document, host: host, undoManager: undoManager)
        #expect(built.succeeded, "\(built.output)")
        #expect(built.steps == ["Run brick.py", "Tint Bricks"])
        // No issues: the document isn't saved, so brick.png isn't looked for.
        #expect(built.output == "Refused, as expected: Can't connect color3 to float\n", "\(built.output)")
        #expect(host.selection == ["brick"])
        #expect(document.validate() == .valid, "\(document.validate())")

        let report = try String(contentsOf: examples.appending(path: "report.py"), encoding: .utf8)
        let reported = Python.run(report, named: "report.py", on: document, host: host, undoManager: undoManager)
        #expect(reported.succeeded, "\(reported.output)")
        #expect(reported.output.hasPrefix("1 material, in lin_rec709:\n  brick: standard_surface\nSelected: brick\n"),
                "\(reported.output)")
        #expect(reported.steps.isEmpty)
        #expect(undoManager.undoActionName == "Tint Bricks")
    }

    @Test("Exports USD and a shader, with paths relative to the document's folder")
    func export() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MargolariaModuleTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try emptyDocument()
        let host = TestHost()
        host.documentFolder = folder
        let script = Self.brick + """

            margolaria.export_usd("brick.usda")
            for file in margolaria.export_shader("brick", "shaders", language="glsl"):
                print(file.split("/")[-1])
            """
        let result = Python.run(script, named: "export.py", on: document, host: host)
        #expect(result.succeeded, "\(result.output)")
        #expect(result.output.hasSuffix("brick.vert.glsl\nbrick.frag.glsl\n"), "\(result.output)")
        let usda = try String(contentsOf: folder.appending(path: "brick.usda"), encoding: .utf8)
        #expect(usda.contains("def Material \"brick\""), "\(usda.prefix(2000))")

        // A relative path without a folder.
        let unsaved = Python.run("import margolaria\nmargolaria.export_usd('x.usda')", named: "export.py",
                                 on: document)
        #expect(unsaved.output.contains("RuntimeError: x.usda is relative"), "\(unsaved.output)")
    }
}
