// MXShaderExport.swift
//
// Writes generated shader code to files (M5d, PLAN.md §8.6): Export
// Shader… in the app, and the tests. OSL is also compiled to .oso, with
// an oslc the caller names (the app's is chosen by the user; the tests use
// scripts/build-osl.sh's), since that is what OSL renderers load.
//
// What each language writes, into one folder:
//
//   MSL          <name>.vert.metal, <name>.frag.metal
//   GLSL         <name>.vert.glsl, <name>.frag.glsl
//   OSL          <name>.osl, and <name>.oso with oslc
//   OSL network  <name>.oslgroup (the shader group), and every .oso it
//                names, copied from MaterialX's compiled library, so a
//                renderer given the folder as its shader search path finds
//                them all
//
// Introduces (SWIFT): `Process` and `Pipe` (running a command-line tool),
// a nested function.

import Foundation

/// Writes shader code to files, and compiles OSL.
///
/// SWIFT: An `enum` with no cases is a namespace for static functions: it
/// can't be instantiated, unlike a struct with a private init.
public enum MXShaderExport {
    /// Writes `code` into `folder` (created if needed) as files named after
    /// `name` (see the file comment), and returns them. For OSL, `oslc`, if
    /// given, compiles the .osl to an .oso beside it.
    ///
    /// - Throws: a file error, or ``MXError/compileFailed(_:)`` with oslc's
    ///   messages (the .osl is written first, and stays).
    public static func write(_ code: MXShaderCode, named name: String, to folder: URL, oslc: URL?,
                             library: MXLibrary) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        /// Writes `text` to the file `fileName` in the folder.
        ///
        /// SWIFT: A nested function can use the enclosing function's local
        /// variables (`files`, `folder`), like a closure with a name.
        func save(_ text: String, as fileName: String) throws {
            let url: URL = folder.appending(path: fileName)
            try text.write(to: url, atomically: true, encoding: .utf8)
            files.append(url)
        }
        switch code.language {
        case .msl:
            try save(code.vertexSource, as: "\(name).vert.metal")
            try save(code.pixelSource, as: "\(name).frag.metal")
        case .glsl:
            try save(code.vertexSource, as: "\(name).vert.glsl")
            try save(code.pixelSource, as: "\(name).frag.glsl")
        case .osl:
            try save(code.pixelSource, as: "\(name).osl")
            if let oslc {
                let compiled: URL = folder.appending(path: "\(name).oso")
                try compileOSL(files[0], to: compiled, oslc: oslc, library: library)
                files.append(compiled)
            }
        case .oslNetwork:
            try save(code.pixelSource, as: "\(name).oslgroup")
            for path in code.osoFiles {
                let source = URL(filePath: path)
                let copy: URL = folder.appending(path: source.lastPathComponent)
                // copyItem refuses to replace a file, and an export may
                // overwrite an earlier one.
                // SWIFT: `try?` turns a thrown error into nil, ignored here:
                // the file may well not exist.
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: source, to: copy)
                files.append(copy)
            }
        }
        return files
    }

    /// Compiles the OSL shader `source` to `output` with the oslc at
    /// `oslc`, finding MaterialX's OSL headers in `library`. Blocks until
    /// oslc has finished, so call it off the main thread.
    ///
    /// - Throws: ``MXError/compileFailed(_:)`` with oslc's messages, or if
    ///   oslc can't be run.
    public static func compileOSL(_ source: URL, to output: URL, oslc: URL, library: MXLibrary) throws {
        // SWIFT: `Process` runs another program, like posix_spawn: the
        // executable and its arguments, here without a shell, so paths with
        // spaces need no quoting. A `Pipe` collects what it prints.
        let process = Process()
        process.executableURL = oslc
        process.arguments = [
            "-q",
            "-I\(library.oslIncludeFolder.path(percentEncoded: false))",
            "-o", output.path(percentEncoded: false),
            source.path(percentEncoded: false),
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw MXError.compileFailed("Could not run \(oslc.path(percentEncoded: false)): \(error.localizedDescription)")
        }
        // Read before waiting: a process that fills the pipe's buffer
        // blocks until someone reads it, and would never exit.
        let data: Data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let messages: String = String(decoding: data, as: UTF8.self)
            throw MXError.compileFailed(messages.isEmpty ? "oslc exited with \(process.terminationStatus)" : messages)
        }
    }
}
