// CommandLineToolTests.swift
//
// Tests for the `margolaria` command line (M6e): running a script and each
// export gives the same files as the app's own calls (M6e's criterion:
// Run Script… then Save, Export as USD…, Export as USDZ…, the Generated
// Shader tab's Export…); what isn't a command line starts the app; and
// arguments that don't make a command are refused with status 2.
//
// Introduces (SWIFT): nothing new.

import Foundation
import Testing
import MXKit
import ViewportKit
@testable import ScriptKit

@Suite("The command line")
@MainActor
struct CommandLineToolTests {
    /// What a command wrote, and its status.
    struct Run {
        let status: Int32?
        let output: String
        let errors: String
    }

    /// The repository, from this file.
    nonisolated static let repository: URL = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// MaterialX's tiled brass: a material with two textures, beside it.
    nonisolated static let brass: URL = repository
        .appending(path: "Vendor/MaterialX/resources/Materials/Examples/StandardSurface/standard_surface_brass_tiled.mtlx")

    nonisolated static var hasBrass: Bool {
        FileManager.default.fileExists(atPath: brass.path(percentEncoded: false))
    }

    /// Runs `margolaria` with `arguments`, collecting what it writes.
    func margolaria(_ arguments: String...) -> Run {
        var output: String = ""
        var errors: String = ""
        let status: Int32? = CommandLineTool.run(["/Applications/Margolaria.app/Contents/MacOS/Margolaria"] + arguments,
                                                 location: .inVendor(), output: { output += $0 },
                                                 errors: { errors += $0 })
        return Run(status: status, output: output, errors: errors)
    }

    /// A new, empty folder.
    func folder() throws -> URL {
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "CommandLineToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The document at `url`, as the app opens it.
    func open(_ url: URL) throws -> MXDocument {
        let document: MXDocument = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        return document
    }

    /// The files in `folder`, by name, with their contents.
    func contents(of folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            files[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return files
    }

    /// The files in the zip archive (a USDZ) at `url`, with their contents,
    /// extracted with macOS's unzip: two archives of the same files differ
    /// in the times recorded in them.
    func zipContents(of url: URL) throws -> [String: Data] {
        let folder: URL = try folder()
        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/unzip")
        unzip.arguments = ["-q", url.path(percentEncoded: false), "-d", folder.path(percentEncoded: false)]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: folder.path(percentEncoded: false))
        while let path = enumerator?.nextObject() as? String {
            let file: URL = folder.appending(path: path)
            if let data = try? Data(contentsOf: file) {
                files[path] = data
            }
        }
        return files
    }

    @Test("Without a subcommand, the app starts")
    func notACommand() {
        #expect(CommandLineTool.run(["Margolaria"]) == nil)
        #expect(CommandLineTool.run(["Margolaria", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        #expect(CommandLineTool.run(["Margolaria", "/Users/someone/brick.mtlx"]) == nil)
    }

    @Test("help shows how to use it; arguments that don't make a command exit with 2")
    func usage() {
        let help = margolaria("help")
        #expect(help.status == 0)
        #expect(help.output.hasPrefix("Usage:\n  margolaria run SCRIPT [FILE] [-o OUTPUT]"))

        let wrong: [([String], String)] = [
            (["run"], "run takes a script"),
            (["run", "a.py", "b.mtlx", "c.mtlx"], "run takes a script"),
            (["run", "a.py", "-o"], "-o needs a value"),
            (["run", "a.py", "--verbose"], "Unknown option --verbose"),
            (["export"], "export what?"),
            (["export", "obj", "a.mtlx", "a.obj"], "Can't export obj"),
            (["export", "usd", "a.mtlx"], "export usd takes"),
            (["export", "shader", "a.mtlx", "brick", "out", "--language", "hlsl"], "No shader language hlsl"),
        ]
        for (arguments, message) in wrong {
            var errors: String = ""
            let status: Int32? = CommandLineTool.run(["margolaria"] + arguments, location: .inVendor(),
                                                     output: { _ in }, errors: { errors += $0 })
            #expect(status == 2, "\(arguments)")
            #expect(errors.hasPrefix("margolaria: \(message)"), "\(arguments): \(errors)")
        }
    }

    @Test("run gives the file Run Script… and Save give; what the script prints goes to standard output")
    func runScript() throws {
        let folder: URL = try folder()
        let brick: URL = Self.repository.appending(path: "docs/scripting/brick.py")
        let saved: URL = folder.appending(path: "brick.mtlx")
        let run = margolaria("run", brick.path(percentEncoded: false), "-o", saved.path(percentEncoded: false))
        #expect(run.status == 0, "\(run.errors)")
        #expect(run.output == "Refused, as expected: Can't connect color3 to float\n")
        #expect(run.errors.isEmpty)

        // The app: a new document, the script run on it (as MaterialXDocument
        // does, with a window), then saved (its data(ofType:)).
        let document = try MXDocument(xml: #"<?xml version="1.0"?><materialx version="1.39" />"#)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let result = Python.run(.file(try String(contentsOf: brick, encoding: .utf8),
                                      path: brick.path(percentEncoded: false)),
                                on: document, host: TestHost())
        #expect(result.succeeded)
        #expect(try String(contentsOf: saved, encoding: .utf8) == (try document.xmlString()))

        // A script run on that file, reading it: nothing to save.
        let report = margolaria("run", Self.repository.appending(path: "docs/scripting/report.py").path(percentEncoded: false),
                                saved.path(percentEncoded: false))
        #expect(report.status == 0, "\(report.errors)")
        #expect(report.output.hasPrefix("1 material, in lin_rec709:\n  brick: standard_surface\nSelected: nothing\n"),
                "\(report.output)")
        #expect(report.errors.isEmpty)
    }

    @Test("run: a script that raises exits with 1 and its traceback; changes not saved are pointed out")
    func runFailures() throws {
        let folder: URL = try folder()
        let fails: URL = folder.appending(path: "fails.py")
        try "import margolaria\nmargolaria.add_node('ND_constant_float')\nraise ValueError('no')\n"
            .write(to: fails, atomically: true, encoding: .utf8)
        let failed = margolaria("run", fails.path(percentEncoded: false), "-o", folder.appending(path: "out.mtlx").path)
        #expect(failed.status == 1)
        #expect(failed.errors.contains("fails.py\", line 3"), "\(failed.errors)")
        #expect(failed.errors.hasSuffix("ValueError: no\n"))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "out.mtlx").path))

        let adds: URL = folder.appending(path: "adds.py")
        try "import margolaria\nmargolaria.add_node('ND_constant_float')\n".write(to: adds, atomically: true, encoding: .utf8)
        let unsaved = margolaria("run", adds.path(percentEncoded: false))
        #expect(unsaved.status == 0)
        #expect(unsaved.errors.contains("nothing was saved: give -o OUTPUT"))

        let missing = margolaria("run", folder.appending(path: "missing.py").path(percentEncoded: false))
        #expect(missing.status == 1)
        #expect(missing.errors.hasPrefix("margolaria: "))
    }

    @Test("A script's relative export paths are from the document's folder, as in the app")
    func relativePaths() throws {
        let folder: URL = try folder()
        let document: URL = folder.appending(path: "brick.mtlx")
        _ = margolaria("run", Self.repository.appending(path: "docs/scripting/brick.py").path(percentEncoded: false),
                       "-o", document.path(percentEncoded: false))
        let export: URL = folder.appending(path: "export.py")
        try "import margolaria\nmargolaria.export_usd('brick.usda')\n".write(to: export, atomically: true, encoding: .utf8)
        let run = margolaria("run", export.path(percentEncoded: false), document.path(percentEncoded: false))
        #expect(run.status == 0, "\(run.errors)")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "brick.usda").path(percentEncoded: false)))
    }

    @Test("export usd and usdz give the files Export as USD… and Export as USDZ… give",
          .enabled(if: hasBrass, "Run scripts/fetch-materialx-examples.sh to fetch the examples"))
    func exportUSD() throws {
        let folder: URL = try folder()
        let path: String = Self.brass.path(percentEncoded: false)
        // As MaterialXDocument.exportAsUSD and exportAsUSDZ (the material
        // the viewport shows: the first, until another is picked).
        let document: MXDocument = try open(Self.brass)
        for name in ["brass.usda", "brass.usdc"] {
            let usd = margolaria("export", "usd", path, folder.appending(path: "cli-\(name)").path)
            #expect(usd.status == 0)
            // The textures are in MaterialX's resources/Images, not beside
            // the file: listed, as the app warns about them (M7d).
            #expect(usd.errors.contains("2 textures outside its folder") && usd.errors.contains("brass_color.jpg"),
                    "\(usd.errors)")
            try MGUSDExporter.exportMaterials(fromMaterialXString: try document.usdXMLString(),
                                              to: folder.appending(path: "app-\(name)"))
            #expect(try Data(contentsOf: folder.appending(path: "cli-\(name)"))
                    == (try Data(contentsOf: folder.appending(path: "app-\(name)"))), "\(name)")
        }

        // No OpenUSD warning either (M7d: it warned "Failed to resolve
        // reference @0/brass_color.jpg@").
        let usdz = margolaria("export", "usdz", path, folder.appending(path: "cli.usdz").path)
        #expect(usdz.status == 0)
        #expect(usdz.errors.isEmpty, "\(usdz.errors)")
        #expect(MGUSDExporter.lastExportWarnings.isEmpty, "\(MGUSDExporter.lastExportWarnings)")
        try MGUSDExporter.exportPreview(fromMaterialXString: try document.usdzXMLString(),
                                        to: folder.appending(path: "app.usdz"), materialName: nil, shape: .sphere)
        let packaged: [String: Data] = try zipContents(of: folder.appending(path: "cli.usdz"))
        #expect(Set(packaged.keys) == ["root.usdc", "0/brass_color.jpg", "0/brass_roughness.jpg"])
        #expect(packaged == (try zipContents(of: folder.appending(path: "app.usdz"))))

        // Another shape (M7a), as when the viewport shows it; and from a
        // script, which names it too.
        #expect(margolaria("export", "usdz", path, folder.appending(path: "cli-ball.usdz").path,
                           "--shape", "shader_ball").status == 0)
        try MGUSDExporter.exportPreview(fromMaterialXString: try document.usdzXMLString(),
                                        to: folder.appending(path: "app-ball.usdz"), materialName: nil,
                                        shape: .shaderBall)
        let ball: [String: Data] = try zipContents(of: folder.appending(path: "cli-ball.usdz"))
        #expect(ball == (try zipContents(of: folder.appending(path: "app-ball.usdz"))))
        #expect(ball["root.usdc"] != packaged["root.usdc"])
        let script: URL = folder.appending(path: "ball.py")
        let written: URL = folder.appending(path: "script-ball.usdz")
        try "import margolaria\nmargolaria.export_usdz(\(written.path(percentEncoded: false).debugDescription), shape='shader_ball')\n"
            .write(to: script, atomically: true, encoding: .utf8)
        let run = margolaria("run", script.path(percentEncoded: false), path)
        #expect(run.status == 0, "\(run.errors)")
        #expect(try zipContents(of: written) == ball)

        let shape = margolaria("export", "usdz", path, folder.appending(path: "shape.usdz").path, "--shape", "teapot")
        #expect(shape.status == 2)
        #expect(shape.errors.hasPrefix("margolaria: No preview shape teapot: sphere, plane, cylinder, cloth, shader_ball."),
                "\(shape.errors)")

        let named = margolaria("export", "usdz", path, folder.appending(path: "named.usdz").path,
                               "--material", "no_such_material")
        #expect(named.status == 1)
        #expect(named.errors == "margolaria: No material called no_such_material in the document: Tiled_Brass.\n",
                "\(named.errors)")
    }

    @Test("export shader gives the files the Generated Shader tab's Export… gives, in each language",
          .enabled(if: hasBrass, "Run scripts/fetch-materialx-examples.sh to fetch the examples"))
    func exportShader() throws {
        let folder: URL = try folder()
        let document: MXDocument = try open(Self.brass)
        let library: MXLibrary = try MXLibrary.bundled.get()
        for (name, language) in Export.languages {
            let cli: URL = folder.appending(path: "cli-\(name)")
            let run = margolaria("export", "shader", Self.brass.path(percentEncoded: false), "SR_brass1",
                                 cli.path(percentEncoded: false), "--language", name)
            #expect(run.status == 0, "\(name): \(run.errors)")
            // As the tab: from the preview text, in the document's working
            // space, the files named after the element.
            let code: MXShaderCode = try MXShaderExport.generate(language, for: "SR_brass1",
                                                                 previewXML: try document.previewXMLString(),
                                                                 colorSpace: document.workingSpace(of: "").active,
                                                                 library: library)
            let app: URL = folder.appending(path: "app-\(name)")
            _ = try MXShaderExport.write(code, named: "SR_brass1", to: app, oslc: nil, library: library)
            let files: [String: Data] = try contents(of: cli)
            #expect(!files.isEmpty)
            #expect(files == (try contents(of: app)), "\(name)")
        }

        let acescg = margolaria("export", "shader", Self.brass.path(percentEncoded: false), "SR_brass1",
                                folder.appending(path: "acescg").path, "--language", "osl", "--colorspace", "acescg")
        #expect(acescg.status == 0)
        let osl: String = try String(contentsOf: folder.appending(path: "acescg/SR_brass1.osl"), encoding: .utf8)
        #expect(osl != (try String(contentsOf: folder.appending(path: "cli-osl/SR_brass1.osl"), encoding: .utf8)))

        let missing = margolaria("export", "shader", Self.brass.path(percentEncoded: false), "nothing",
                                 folder.appending(path: "nothing").path)
        #expect(missing.status == 1)
        #expect(missing.errors.contains("No element at path nothing"), "\(missing.errors)")
    }
}
