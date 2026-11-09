// ConsoleTests.swift
//
// Tests for the Console (M6c): entries typed line by line, each that
// changes the document one undo step (M6c's criterion), its namespace,
// blocks, errors and history; and scripts on the worker thread, stopped
// with KeyboardInterrupt.
//
// Introduces (SWIFT): `#expect(throws:)`.

import Foundation
import Testing
import MXKit
import PythonBridge
@testable import ScriptKit

@Suite("The Console, and stopping scripts")
@MainActor
struct ConsoleTests {
    init() throws {
        try Python.start(from: .inVendor())
    }

    func emptyDocument() throws -> MXDocument {
        let document = try MXDocument(xml: "<materialx version=\"1.39\"/>")
        document.setDataLibrary(try MXLibrary.bundled.get())
        return document
    }

    /// Types `lines` in `console`, running each entry they make on
    /// `document`, as the Console tab does. Returns the entries' results.
    @discardableResult
    func type(_ lines: [String], in console: PythonConsole, on document: MXDocument,
              undoManager: UndoManager? = nil, host: ScriptHost? = nil) -> [ScriptResult] {
        var results: [ScriptResult] = []
        for line in lines {
            if let script = console.enter(line) {
                let result = Python.run(script, on: document, host: host, undoManager: undoManager)
                console.show(result)
                results.append(result)
            }
        }
        return results
    }

    @Test("Typing the exit criterion's script line by line builds the same material, one undo step per entry")
    func exitCriterionLineByLine() throws {
        let fromFile = try emptyDocument()
        _ = Python.run(MargolariaModuleTests.brick, named: "brick.py", on: fromFile)

        let document = try emptyDocument()
        let empty: MXDocument = document.copy()
        let undoManager = UndoManager()
        let console = PythonConsole()
        let lines: [String] = MargolariaModuleTests.brick.components(separatedBy: "\n")
        let results = type(lines, in: console, on: document, undoManager: undoManager)

        #expect(results.allSatisfy { $0.succeeded }, "\(results.map(\.output))")
        #expect(document.difference(from: fromFile) == nil)
        #expect(results.last?.output == "brick_shader, brick, brick_color\n")
        // Three nodes added, a value set, two connections, a value set
        // with MaterialX's API: seven entries changed the document. The
        // imports, `doc = ...`, the comment and the print didn't.
        #expect(results.filter { !$0.steps.isEmpty }.count == 7)
        var undone: Int = 0
        while undoManager.canUndo {
            #expect(undoManager.undoActionName == "Console")
            undoManager.undo()
            undone += 1
            if undone == 1 {
                // The last entry first: the roughness set with MaterialX.
                let xml = try document.xmlString()
                #expect(!xml.contains("specular_roughness"), "\(xml)")
                #expect(xml.contains("nodename=\"brick_shader\""), "\(xml)")
            }
        }
        #expect(undone == 7)
        #expect(document.difference(from: empty) == nil)
    }

    @Test("Variables stay between entries, and an expression's value is printed")
    func namespaceAndEcho() throws {
        let document = try emptyDocument()
        let console = PythonConsole()
        let results = type(["x = 20", "x + 1", "None", "doc = margolaria.document()", "doc.getVersionString()",
                            "str(mx.Color3(1, 0.5, 0))"],
                           in: console, on: document)
        #expect(results.map(\.output) == ["", "21\n", "", "", "'1.39'\n", "'1, 0.5, 0'\n"])

        // Another Console has its own variables.
        let other = PythonConsole()
        let result = type(["x"], in: other, on: document).first
        #expect(result?.succeeded == false)
        #expect(result?.output.contains("NameError: name 'x' is not defined") == true, "\(result?.output ?? "")")
    }

    @Test("A block takes several lines, ended by a blank one, and is one entry")
    func blocks() throws {
        let document = try emptyDocument()
        let undoManager = UndoManager()
        let console = PythonConsole()
        #expect(console.prompt == ">>> ")
        #expect(console.enter("for name in ['a', 'b']:") == nil)
        #expect(console.prompt == "... ")
        #expect(console.indentation(after: "for name in ['a', 'b']:") == "    ")
        #expect(console.enter("    margolaria.add_node('ND_constant_float', name=name)") == nil)
        #expect(console.indentation(after: "    margolaria.add_node('ND_constant_float', name=name)") == "    ")
        // The indentation the view puts in, left as it is: a blank line.
        let script = try #require(console.enter("    "))
        #expect(console.prompt == ">>> ")
        #expect(console.indentation(after: "    ") == "")

        let result = Python.run(script, on: document, undoManager: undoManager)
        #expect(result.succeeded, "\(result.output)")
        // The add_node calls' values are printed, as Python's console
        // prints every expression statement's in an entry.
        #expect(result.output == "'a'\n'b'\n")
        #expect(result.steps == ["Console"])
        #expect(document.topLevelElements.map(\.name) == ["a", "b"])
    }

    @Test("A syntax error is shown without running; an exception's traceback names <console>; nothing changes")
    func errors() throws {
        let document = try emptyDocument()
        let before: MXDocument = document.copy()
        let undoManager = UndoManager()
        let console = PythonConsole()

        #expect(console.enter("1 +* 2") == nil)
        #expect(console.prompt == ">>> ")
        #expect(console.lines.last?.style == .error)
        #expect(console.lines.last?.text.contains("SyntaxError") == true, "\(console.lines.last?.text ?? "")")

        let results = type(["margolaria.add_node('ND_constant_float', name='kept')",
                            "margolaria.connect('kept', 'value', 'missing')"],
                           in: console, on: document, undoManager: undoManager)
        #expect(results.map(\.succeeded) == [true, false])
        #expect(results[1].output.contains("File \"<console>\", line 1"), "\(results[1].output)")
        #expect(results[1].output.contains("margolaria.EditRefused"), "\(results[1].output)")
        #expect(console.lines.last?.style == .error)
        // The first entry's node stays; the second changed nothing.
        #expect(document.topLevelElements.map(\.name) == ["kept"])
        undoManager.undo()
        #expect(!undoManager.canUndo)
        #expect(document.difference(from: before) == nil)

        // Comments and blank lines run nothing.
        #expect(console.enter("# a comment") == nil)
        #expect(console.enter("") == nil)
        #expect(console.prompt == ">>> ")
    }

    @Test("Up and Down go through the lines typed, back to what was being typed")
    func history() throws {
        let console = PythonConsole()
        for line in ["a = 1", "", "b = 2", "b = 2", "c = 3"] {
            _ = console.enter(line)
        }
        #expect(console.history == ["a = 1", "b = 2", "c = 3"])
        #expect(console.older(than: "draft") == "c = 3")
        #expect(console.older(than: "c = 3") == "b = 2")
        #expect(console.older(than: "b = 2") == "a = 1")
        #expect(console.older(than: "a = 1") == nil)
        #expect(console.newer() == "b = 2")
        #expect(console.newer() == "c = 3")
        #expect(console.newer() == "draft")
        #expect(console.newer() == nil)
    }

    @Test("Stopping a script raises KeyboardInterrupt in it, and takes its changes back")
    func stop() throws {
        let document = try emptyDocument()
        let before: MXDocument = document.copy()
        let undoManager = UndoManager()
        let script = Script.file("""
            import margolaria
            margolaria.add_node("ND_constant_float", name="before_loop")
            while True:
                pass
            """, path: "loop.py")
        var ended: ScriptResult? = nil
        let run = try Python.start(script, on: document, undoManager: undoManager, waitingUpTo: 0.2) { ended = $0 }
        #expect(run.isRunning)
        #expect(ended == nil)
        #expect(ScriptRun.current === run)

        run.stop()
        #expect(run.wait(upTo: 10))
        let result = try #require(ended)
        #expect(!result.succeeded)
        #expect(result.interrupted)
        #expect(result.output.hasSuffix("KeyboardInterrupt\n"), "\(result.output)")
        #expect(document.difference(from: before) == nil)
        #expect(!undoManager.canUndo)
        #expect(ScriptRun.current == nil)
    }

    @Test("A script stopped before it starts doesn't run")
    func stopAtOnce() throws {
        let document = try emptyDocument()
        let before: MXDocument = document.copy()
        var ended: ScriptResult? = nil
        let script = Script.file("import margolaria\nmargolaria.add_node('ND_constant_float')\n", path: "add.py")
        // Stopping the next run before it exists: the earliest a Stop can
        // come, before its thread has even started. (Clicking Stop as it
        // starts is a race the script could win; this isn't.)
        pybridge.Interpreter.interrupt(ScriptRun.lastID + 1)
        _ = try Python.start(script, on: document, waitingUpTo: .infinity) { ended = $0 }
        #expect(ended?.interrupted == true, "\(ended?.output ?? "")")
        #expect(document.difference(from: before) == nil)
    }

    @Test("One script at a time; calls to Swift are answered after the wait too")
    func oneAtATime() throws {
        let document = try emptyDocument()
        let host = TestHost()
        host.selection = ["picked"]
        var ended: ScriptResult? = nil
        let script = Script.file("""
            import margolaria, time
            time.sleep(0.3)
            print(margolaria.selection())
            """, path: "slow.py")
        let run = try Python.start(script, on: document, host: host, waitingUpTo: 0) { ended = $0 }
        #expect(run.isRunning)

        // SWIFT: `#expect(throws:)` checks that the closure throws an
        // error of that type.
        #expect(throws: PythonError.self) {
            _ = try Python.start(.file("pass", path: "other.py"), on: document, waitingUpTo: 0) { _ in }
        }
        #expect(Python.run("pass", named: "other.py", on: document).output.contains("slow.py is still running"))

        #expect(run.wait(upTo: 10))
        #expect(ended?.output == "['picked']\n", "\(ended?.output ?? "")")
        #expect(Python.run("pass", named: "other.py", on: document).succeeded)
    }
}
