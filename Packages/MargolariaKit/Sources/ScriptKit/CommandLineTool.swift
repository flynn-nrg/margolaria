// CommandLineTool.swift
//
// The `margolaria` command line (M6e), for pipelines: run a script on a
// .mtlx file and save the result, or export a file as USD, USDZ or a
// shader, without a window. It is Margolaria's own executable,
// Margolaria.app/Contents/MacOS/Margolaria, started with a subcommand
// (PLAN.md §8.7): MargolariaApp.main asks `CommandLineTool.run` first, and
// only starts the app if the arguments aren't a command line, as Blender
// does with `--background`. So the tool is the signed, notarized app
// itself, with its frameworks and Python. On the PATH, it is a symbolic
// link named `margolaria` (docs/SCRIPTING.md, The command line).
//
//   margolaria run SCRIPT [FILE] [-o OUTPUT]
//   margolaria export usd FILE OUTPUT
//   margolaria export usdz FILE OUTPUT [--material NAME] [--shape SHAPE]
//   margolaria export shader FILE ELEMENT FOLDER [--language LANGUAGE]
//                                                [--colorspace SPACE] [--oslc PATH]
//
// Each does what the app does (Run Script… then Save As…, the Export
// commands, the Generated Shader tab's Export…), with the same code, so it
// writes the same files.
//
// Introduces (SWIFT): `CommandLine.arguments`; `FileHandle.standardError`.

import Foundation
import MXKit
import ViewportKit

/// The command line's subcommands, run without a window.
@MainActor
public enum CommandLineTool {
    /// Writes text somewhere: standard output or standard error, or a
    /// test's string.
    public typealias Writer = (String) -> Void

    /// The exit statuses: success, a command that failed (a script that
    /// raised, a file that couldn't be read or written), and arguments
    /// that don't make a command (as most Unix tools exit with 2).
    public static let succeeded: Int32 = 0
    public static let failed: Int32 = 1
    public static let usageError: Int32 = 2

    /// How to use the tool, as `margolaria help` prints it.
    public static let usage: String = """
        Usage:
          margolaria run SCRIPT [FILE] [-o OUTPUT]
              Runs the Python script SCRIPT on FILE (a .mtlx file; a new, empty document if
              there is none), as File > Run Script… does, and saves the result as OUTPUT.
              Without -o, nothing is saved. What the script prints goes to standard output;
              a traceback to standard error.
          margolaria export usd FILE OUTPUT
              Writes FILE's materials as USD (.usda, .usdc or .usd), as File > Export as USD….
          margolaria export usdz FILE OUTPUT [--material NAME] [--shape SHAPE]
              Writes a USDZ package, as File > Export as USDZ…: SHAPE (sphere, the default;
              plane, cylinder, cloth or shader_ball) with the material NAME (the first if not
              given), the other materials, and every texture.
          margolaria export shader FILE ELEMENT FOLDER [--language LANGUAGE]
                                   [--colorspace SPACE] [--oslc PATH]
              Writes the shader generated for ELEMENT ("brick", "NG_brick/out") into FOLDER,
              as the Generated Shader tab's Export…. LANGUAGE: msl (the default), glsl, osl or
              osl_network. SPACE: lin_rec709 or acescg (the default: the document's working
              space). For osl, PATH is an oslc that also compiles it to .oso.
          margolaria help
              Shows this.

        Started without a command, margolaria is the app.
        """

    /// The first arguments that make a command line.
    private static let commands: Set<String> = ["run", "export", "help", "--help", "-h"]

    /// Runs the command in `arguments` (`CommandLine.arguments`: the
    /// program's path, then what was typed after it), if it is one, and
    /// returns its exit status; nil if it isn't, and the app should start.
    /// Python starts from `location` if the command needs it.
    ///
    /// SWIFT: `CommandLine.arguments` is the program's `argv`, as an array
    /// of Strings.
    public static func run(_ arguments: [String], location: Python.Location = .inApp(appBundle),
                           output: Writer = { print($0, terminator: "") },
                           errors: Writer = standardError) -> Int32? {
        // The app is also started with arguments of AppKit's, such as
        // Xcode's `-NSDocumentRevisionsDebugMode YES`, and with the files
        // it opens: none are a command.
        guard arguments.count > 1, commands.contains(arguments[1]) else {
            return nil
        }
        let words: [String] = Array(arguments.dropFirst(2))
        do {
            switch arguments[1] {
            case "run":
                return try runScript(Options(words, values: ["-o", "--output"]), location: location,
                                     output: output, errors: errors)
            case "export":
                guard let kind = words.first else {
                    throw UsageError("export what? usd, usdz or shader.")
                }
                return try export(kind, Array(words.dropFirst()), errors: errors)
            default:
                output(usage + "\n")
                return succeeded
            }
        } catch let error as UsageError {
            errors("margolaria: \(error.message)\nmargolaria help shows how to use it.\n")
            return usageError
        } catch {
            errors("margolaria: \(error.localizedDescription)\n")
            return failed
        }
    }

    /// Margolaria.app, also when the tool is started through a symbolic
    /// link (`/usr/local/bin/margolaria`). `Bundle.main` is then the
    /// link's folder, where Python isn't, though the system's loader found
    /// the frameworks from the link's target. So the link is followed:
    /// the app is three folders up from Contents/MacOS/Margolaria.
    public nonisolated static var appBundle: Bundle {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return .main
        }
        let app: URL = executable
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Margolaria.app
        return Bundle(url: app) ?? .main
    }

    /// Writes `text` to standard error.
    ///
    /// SWIFT: `print` writes to standard output only; standard error is a
    /// FileHandle (NSFileHandle), written bytes at a time, as `write(2, ...)`.
    /// `nonisolated`, so it can be `run`'s default Writer, which isn't the
    /// main actor's.
    public nonisolated static func standardError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// `margolaria run SCRIPT [FILE] [-o OUTPUT]`.
    private static func runScript(_ options: Options, location: Python.Location, output: Writer,
                                  errors: Writer) throws -> Int32 {
        guard (1...2).contains(options.positional.count) else {
            throw UsageError("run takes a script, and a .mtlx file to run it on (or none, for a new document).")
        }
        let scriptURL: URL = file(options.positional[0])
        let fileURL: URL? = options.positional.count == 2 ? file(options.positional[1]) : nil
        let outputURL: URL? = options.value("-o", "--output").map(file)

        let code: String = try String(contentsOf: scriptURL, encoding: .utf8)
        let document: MXDocument = try open(fileURL)
        try Python.start(from: location)
        // Relative export paths in the script are taken from the
        // document's folder, as in the app; for a new document, from the
        // current folder.
        let host = CommandLineHost(documentFolder: fileURL?.deletingLastPathComponent()
                                   ?? URL(filePath: FileManager.default.currentDirectoryPath))
        let result: ScriptResult = Python.run(.file(code, path: scriptURL.path(percentEncoded: false)),
                                              on: document, host: host)
        guard result.succeeded else {
            errors(result.output)
            return failed
        }
        output(result.output)
        if let outputURL {
            // As the app saves (MaterialXDocument's data(ofType:)).
            try document.xmlString().write(to: outputURL, atomically: true, encoding: .utf8)
        } else if !result.steps.isEmpty {
            errors("margolaria: the script changed the document, but nothing was saved: give -o OUTPUT.\n")
        }
        return succeeded
    }

    /// `margolaria export KIND ...`.
    private static func export(_ kind: String, _ words: [String], errors: Writer) throws -> Int32 {
        switch kind {
        case "usd":
            let options = try Options(words, values: [])
            guard options.positional.count == 2 else {
                throw UsageError("export usd takes a .mtlx file and the USD file to write.")
            }
            let textures: [String] = try Export.usd(try open(file(options.positional[0])),
                                                    to: file(options.positional[1]))
            if let warning = Export.absoluteTexturesWarning(textures) {
                errors(warning)
            }
        case "usdz":
            let options = try Options(words, values: ["--material", "--shape"])
            guard options.positional.count == 2 else {
                throw UsageError("export usdz takes a .mtlx file and the USDZ file to write.")
            }
            let name: String = options.value("--shape") ?? ViewportShape.sphere.rawValue
            guard let shape = ViewportShape(rawValue: name) else {
                throw UsageError(ScriptError.unknownShape(name).localizedDescription)
            }
            try Export.usdz(try open(file(options.positional[0])), to: file(options.positional[1]),
                            material: options.value("--material"), shape: shape)
        case "shader":
            let options = try Options(words, values: ["--language", "--colorspace", "--oslc"])
            guard options.positional.count == 3 else {
                throw UsageError("export shader takes a .mtlx file, an element in it, and the folder to write into.")
            }
            let language: String = options.value("--language") ?? "msl"
            guard Export.languages[language] != nil else {
                throw UsageError("No shader language \(language): msl, glsl, osl or osl_network.")
            }
            let document: MXDocument = try open(file(options.positional[0]))
            // As the Generated Shader tab: the document's working space.
            let colorSpace: String = options.value("--colorspace") ?? document.workingSpace(of: "").active
            _ = try Export.shader(of: options.positional[1], in: document, language: language,
                                  colorSpace: colorSpace, to: file(options.positional[2]),
                                  oslc: options.value("--oslc").map(file))
        default:
            throw UsageError("Can't export \(kind): usd, usdz or shader.")
        }
        return succeeded
    }

    /// The document in the .mtlx file at `url`, with MaterialX's
    /// definitions, as the app opens it; nil: a new, empty one, as File >
    /// New makes.
    private static func open(_ url: URL?) throws -> MXDocument {
        let document: MXDocument = try url.map { try MXDocument.read(from: $0) }
            ?? MXDocument(xml: #"<?xml version="1.0"?><materialx version="1.39" />"#)
        document.setDataLibrary(try MXLibrary.bundled.get())
        return document
    }

    /// A path typed on the command line, as a file URL: relative paths are
    /// taken from the current folder.
    private static func file(_ path: String) -> URL {
        URL(filePath: path, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath + "/"))
            .absoluteURL
    }
}

/// Arguments that don't make a command, with what is wrong.
private struct UsageError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// A subcommand's arguments: the positional ones, in order, and the
/// options, each followed by its value (`-o out.mtlx`).
private struct Options {
    var positional: [String] = []
    private var values: [String: String] = [:]

    /// Reads `words`; `names` are the options this subcommand takes.
    init(_ words: [String], values names: Set<String>) throws {
        var index: Int = 0
        while index < words.count {
            let word: String = words[index]
            index += 1
            // "-" alone is a name, not an option.
            guard word.hasPrefix("-"), word.count > 1 else {
                positional.append(word)
                continue
            }
            guard names.contains(word) else {
                throw UsageError("Unknown option \(word).")
            }
            guard index < words.count else {
                throw UsageError("\(word) needs a value.")
            }
            values[word] = words[index]
            index += 1
        }
    }

    /// The value of the option, under any of its `names` ("-o", "--output").
    func value(_ names: String...) -> String? {
        names.compactMap { values[$0] }.first
    }
}

/// What a script run from the command line asks of its window: there is
/// none, so nothing is selected, and `margolaria.select()` does nothing.
@MainActor
private final class CommandLineHost: ScriptHost {
    let documentFolder: URL?
    var selection: [String] { [] }

    init(documentFolder: URL?) {
        self.documentFolder = documentFolder
    }

    func select(_ path: String) {}
}
