// CommandTests.swift
//
// Tests for startup scripts and user commands (M6d): a command registered
// by a startup script runs as one undo step, and an error in a startup
// script is reported while the others still run (M6d's criterion); the
// startup scripts' missing document, `@margolaria.command`'s rules, and
// the user's site-packages.
//
// Introduces (SWIFT): nothing new.

import Foundation
import Testing
import MXKit
@testable import ScriptKit

@Suite("Startup scripts and commands")
@MainActor
struct CommandTests {
    init() throws {
        try Python.start(from: .inVendor())
    }

    func emptyDocument() throws -> MXDocument {
        let document = try MXDocument(xml: "<materialx version=\"1.39\"/>")
        document.setDataLibrary(try MXLibrary.bundled.get())
        return document
    }

    /// A new, empty folder holding `files` (name: contents).
    func folder(_ files: [String: String]) throws -> URL {
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "CommandTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }
        return folder
    }

    /// Runs the startup scripts in `folder` until they have all ended.
    func runStartupScripts(in folder: URL) throws -> [StartupScripts.Report] {
        var ended: [StartupScripts.Report]? = nil
        StartupScripts.run(in: folder, from: .inVendor(), waitingUpTo: .infinity) { ended = $0 }
        return try #require(ended)
    }

    @Test("A startup script's command runs as one undo step; a failing startup script doesn't stop the others")
    func criterion() throws {
        let scripts: URL = try folder([
            "1 commands.py": """
                import margolaria

                @margolaria.command("Add Brick Material")
                def add_brick():
                    shader = margolaria.add_node("ND_standard_surface_surfaceshader", name="brick_shader")
                    material = margolaria.add_node("ND_surfacematerial", name="brick")
                    margolaria.connect(material, "surfaceshader", shader)
                    margolaria.set_value(shader, "base_color", (0.6, 0.2, 0.1))
                    print("added", material)
                """,
            "2 broken.py": "import margolaria\nmargolaria.no_such_function()\n",
            "10 after.py": "print('still ran')\n",
            "notes.txt": "not a script",
        ])
        var notified: Int = 0
        let observer = NotificationCenter.default.addObserver(forName: Python.commandsDidChange, object: nil,
                                                              queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let reports: [StartupScripts.Report] = try runStartupScripts(in: scripts)
        #expect(reports.map(\.name) == ["1 commands.py", "2 broken.py", "10 after.py"])
        #expect(reports.map(\.result.succeeded) == [true, false, true])
        #expect(reports[1].result.output.contains("2 broken.py\", line 2"), "\(reports[1].result.output)")
        #expect(reports[1].result.output.contains("AttributeError"), "\(reports[1].result.output)")
        #expect(reports[2].result.output == "still ran\n")
        #expect(StartupScripts.reports?.count == 3)
        #expect(Python.commands == ["Add Brick Material"])
        #expect(notified >= 1)

        let document = try emptyDocument()
        let before: MXDocument = document.copy()
        let undoManager = UndoManager()
        let result = Python.run(.command("Add Brick Material"), on: document, undoManager: undoManager)
        #expect(result.succeeded, "\(result.output)")
        #expect(result.output == "added brick\n")
        #expect(result.steps == ["Add Brick Material"])
        #expect(Set(document.topLevelElements.map(\.name)) == ["brick_shader", "brick"])
        #expect(undoManager.undoActionName == "Add Brick Material")
        undoManager.undo()
        #expect(!undoManager.canUndo)
        #expect(document.difference(from: before) == nil)
    }

    @Test("docs/scripting/commands.py registers its commands, which run as SCRIPTING.md says")
    func example() throws {
        // docs/scripting, found from this file in the repository.
        let example: URL = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "docs/scripting/commands.py")
        let scripts: URL = try folder(["commands.py": try String(contentsOf: example, encoding: .utf8)])
        let reports: [StartupScripts.Report] = try runStartupScripts(in: scripts)
        #expect(reports.map(\.result.succeeded) == [true], "\(reports.map(\.result.output))")
        #expect(Python.commands == ["Add Brick Material", "Print Issues"])

        let document = try emptyDocument()
        let host = TestHost()
        let undoManager = UndoManager()
        let added = Python.run(.command("Add Brick Material"), on: document, host: host, undoManager: undoManager)
        #expect(added.succeeded, "\(added.output)")
        #expect(added.steps == ["Add Brick Material"])
        #expect(host.selection == ["brick"])
        let printed = Python.run(.command("Print Issues"), on: document, host: host, undoManager: undoManager)
        #expect(printed.output == "0 issues\n", "\(printed.output)")
        #expect(printed.steps.isEmpty)
        #expect(undoManager.undoActionName == "Add Brick Material")
    }

    @Test("The Console shows the startup scripts' output and tracebacks, once")
    func consoleReport() throws {
        let scripts: URL = try folder(["quiet.py": "x = 1\n", "loud.py": "print('hello')\n",
                                       "fails.py": "raise ValueError('bad setting')\n"])
        _ = try runStartupScripts(in: scripts)
        let console = PythonConsole()
        console.begin()
        let texts: [String] = console.lines.map(\.text)
        #expect(texts.contains("Startup script fails.py"))
        #expect(texts.contains { $0.hasSuffix("ValueError: bad setting") }, "\(texts)")
        #expect(texts.contains("Startup script loud.py"))
        #expect(texts.contains("hello"))
        #expect(!texts.contains("Startup script quiet.py"))
        let count: Int = console.lines.count
        console.showStartupScripts()
        #expect(console.lines.count == count)

        // Run again: shown again.
        _ = try runStartupScripts(in: scripts)
        console.showStartupScripts()
        #expect(console.lines.count > count)
    }

    @Test("Startup scripts run again forget the commands they no longer register")
    func reload() throws {
        let scripts: URL = try folder(["a.py": """
            import margolaria
            margolaria.command("First")(lambda: None)
            margolaria.command("Second")(lambda: None)
            """])
        _ = try runStartupScripts(in: scripts)
        #expect(Python.commands == ["First", "Second"])
        try "import margolaria\nmargolaria.command('Second')(lambda: None)\n"
            .write(to: scripts.appending(path: "a.py"), atomically: true, encoding: .utf8)
        _ = try runStartupScripts(in: scripts)
        #expect(Python.commands == ["Second"])

        // No scripts at all: no commands.
        _ = try runStartupScripts(in: try folder([:]))
        #expect(Python.commands.isEmpty)
        let result = Python.run(.command("First"), on: try emptyDocument())
        #expect(!result.succeeded)
        #expect(result.output.contains("No command called First"), "\(result.output)")
    }

    @Test("A startup script has no document: the document, the edits and the window's calls raise")
    func noDocument() throws {
        let scripts: URL = try folder(["probe.py": """
            import margolaria
            for call in [margolaria.document, margolaria.selection, margolaria.issues,
                         lambda: margolaria.add_node("ND_constant_float"),
                         lambda: margolaria.edit("Name").__enter__()]:
                try:
                    call()
                    print("ran")
                except RuntimeError as error:
                    print(str(error).split(":")[0])
            """])
        let reports: [StartupScripts.Report] = try runStartupScripts(in: scripts)
        #expect(reports.first?.result.succeeded == true)
        #expect(reports.first?.result.output == String(repeating: "No document\n", count: 5),
                "\(reports.first?.result.output ?? "")")
    }

    @Test("A command registered again replaces the first; a command needs a title; one that raises changes nothing")
    func registering() throws {
        let document = try emptyDocument()
        let before: MXDocument = document.copy()
        let undoManager = UndoManager()
        let setup = Python.run("""
            import margolaria

            @margolaria.command("Registering: Twice")
            def first():
                print("first")

            @margolaria.command("Registering: Twice")
            def second():
                print("second")

            @margolaria.command("Registering: Fails")
            def fails():
                margolaria.add_node("ND_constant_float", name="kept_until_it_raises")
                raise RuntimeError("halfway")

            # Decorated functions can still be called by name.
            second()
            """, named: "setup.py", on: document)
        #expect(setup.output == "second\n", "\(setup.output)")
        #expect(Python.commands.filter { $0.hasPrefix("Registering:") } == ["Registering: Twice", "Registering: Fails"])
        #expect(Python.run(.command("Registering: Twice"), on: document).output == "second\n")

        let failed = Python.run(.command("Registering: Fails"), on: document, undoManager: undoManager)
        #expect(!failed.succeeded)
        #expect(failed.output.contains("RuntimeError: halfway"), "\(failed.output)")
        #expect(!undoManager.canUndo)
        #expect(document.difference(from: before) == nil)

        let untitled = Python.run("""
            import margolaria
            @margolaria.command
            def oops():
                pass
            """, named: "untitled.py", on: document)
        #expect(untitled.output.contains("TypeError: margolaria.command takes the command's title"),
                "\(untitled.output)")
    }

    @Test("The user's site-packages folder is on the import path, with its .pth files")
    func sitePackages() throws {
        let elsewhere: URL = try folder(["commandtests_elsewhere.py": "WHERE = 'elsewhere'\n"])
        let packages: URL = try folder(["commandtests_helper.py": "def greet():\n    return 'hi'\n",
                                        "commandtests.pth": elsewhere.path(percentEncoded: false) + "\n"])
        try Python.addSitePackages(packages)
        let result = Python.run("""
            import commandtests_helper, commandtests_elsewhere
            print(commandtests_helper.greet(), commandtests_elsewhere.WHERE)
            """, named: "imports.py", on: try emptyDocument())
        #expect(result.output == "hi elsewhere\n", "\(result.output)")
    }

    @Test("Startup scripts are the folder's .py files, as Finder sorts them")
    func order() throws {
        let scripts: URL = try folder(["10.py": "", "2.py": "", "b.py": "", "A.py": "", "readme.md": ""])
        #expect(StartupScripts.scripts(in: scripts).map(\.lastPathComponent) == ["2.py", "10.py", "A.py", "b.py"])
        #expect(StartupScripts.scripts(in: scripts.appending(path: "missing")).isEmpty)
    }
}
