// ScriptHost.swift
//
// The `margolaria` module's calls that only Swift can answer (M6b): the
// selection, which is the window's; validation, export and the working
// space, which MXKit, ColorKit and Export.swift do as the app does. The
// module is C++ (PythonBridge.cpp); it calls back through one C function
// pointer, with a HostCall naming the function and its arguments, on the
// script's thread. ScriptRun.swift hands the call to the main thread
// (M6c), where HostCalls answers it.
//
// Introduces (SWIFT): declaring a protocol of our own, with `{ get }`
// requirements; changing a C++ struct through a pointer's `pointee`.

import ColorKit
import Foundation
import MXBridge
import MXKit
import PythonBridge
import ViewportKit

/// What a script asks of the window it runs in: the app's document window,
/// or a test's stand-in.
///
/// SWIFT: A protocol: a list of requirements a type promises to meet, like
/// a Go interface or an ObjC protocol. `{ get }`: a property the type must
/// let others read; a stored `var` or a computed property both do.
/// `AnyObject`: only classes can adopt it (the window state is shared,
/// not copied).
@MainActor
public protocol ScriptHost: AnyObject {
    /// The paths of the elements selected on the canvas: what
    /// `margolaria.selection()` returns.
    var selection: [String] { get }
    /// Selects the element at `path` on the canvas: `margolaria.select()`.
    func select(_ path: String)
    /// The folder of the document's file, against which the export
    /// functions' relative paths are taken; nil for a document never saved.
    var documentFolder: URL? { get }
}

/// One run's answers to the module's calls: the document it runs on, and
/// the host. Made by `Python.start`, for its ScriptRun.
@MainActor
final class HostCalls {
    let document: MXDocument
    let host: ScriptHost?

    init(document: MXDocument, host: ScriptHost?) {
        self.document = document
        self.host = host
    }

    /// Answers `call`, filling in its results or its error. On the main
    /// thread, while the script's thread waits (ScriptRun.swift).
    ///
    /// SWIFT: `call.pointee` is the C++ struct the pointer points at, read
    /// and changed in place, as `call->results` would be in C++.
    func answer(_ call: UnsafeMutablePointer<pybridge.HostCall>) {
        let function: String = call.pointee.function.swiftString
        let arguments: [String] = call.pointee.arguments.map(\.swiftString)
        do {
            for result in try answer(function, arguments) {
                call.pointee.results.push_back(std.string(result))
            }
        } catch MXError.editRefused(let message) {
            call.pointee.error = std.string(message)
            call.pointee.refused = true
        } catch {
            call.pointee.error = std.string(error.localizedDescription)
        }
    }

    /// The module's function `function`, given `arguments` in the order
    /// PythonBridge.cpp passes them.
    private func answer(_ function: String, _ arguments: [String]) throws -> [String] {
        switch function {
        case "selection":
            return try window().selection
        case "select":
            try window().select(arguments[0])
            return []
        case "issues":
            // Four fields per issue, in margolaria.Issue's order.
            return document.issues().flatMap { issue in
                [issue.elementPath, issue.message, issue.severity == .error ? "error" : "warning",
                 issue.source == .materialX ? "materialx" : "margolaria"]
            }
        case "working_space":
            return [document.workingSpace(of: arguments[0]).active]
        case "set_working_space":
            try setWorkingSpace(arguments[0].isEmpty ? nil : arguments[0], of: arguments[1],
                                converting: arguments[2] == "convert")
            return []
        case "export_usd":
            try Export.usd(document, to: try url(arguments[0]))
            return []
        case "export_usdz":
            guard let shape = ViewportShape(rawValue: arguments[2]) else {
                throw ScriptError.unknownShape(arguments[2])
            }
            try Export.usdz(document, to: try url(arguments[0]), material: arguments[1].isEmpty ? nil : arguments[1],
                            shape: shape)
            return []
        case "export_shader":
            let files: [URL] = try Export.shader(of: arguments[0], in: document, language: arguments[2],
                                                 colorSpace: arguments[3], to: try url(arguments[1]),
                                                 oslc: arguments[4].isEmpty ? nil : try url(arguments[4]))
            return files.map { $0.path(percentEncoded: false) }
        default:
            throw ScriptError.unknownFunction(function)
        }
    }

    /// The host, or an error for a script run without a window (a test's,
    /// or later the command line's).
    private func window() throws -> ScriptHost {
        guard let host else {
            throw ScriptError.noWindow
        }
        return host
    }

    /// `path` as a file URL: absolute, or relative to the document's folder.
    private func url(_ path: String) throws -> URL {
        let expanded: String = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(filePath: expanded)
        }
        guard let folder = host?.documentFolder else {
            throw ScriptError.relativePath(path)
        }
        return folder.appending(path: expanded)
    }

    /// As the working space menu does (WorkingSpaceMenu.swift), converting
    /// with ColorKit. If it fails halfway, the document is put back.
    private func setWorkingSpace(_ space: String?, of path: String, converting: Bool) throws {
        let convert: (([Double], String, String) throws -> [Double])? = converting
            ? { numbers, from, to in try InputColorSpace.convert(numbers, from: from, to: to) }
            : nil
        let before: MXDocument = document.copy()
        do {
            try document.setWorkingSpace(space, of: path, convert: convert)
        } catch {
            document.restore(from: before)
            throw error
        }
    }
}

/// Why a module function couldn't be answered; raised in Python as a
/// RuntimeError with this message.
enum ScriptError: Error, LocalizedError {
    case noWindow
    case relativePath(String)
    case unknownLanguage(String)
    case unknownShape(String)
    case unknownFunction(String)
    /// A material asked for, and those there are.
    case noMaterial(String, [String])

    var errorDescription: String? {
        switch self {
        case .noWindow:
            return "No window: the selection is only there when a script runs in Margolaria's window."
        case .relativePath(let path):
            return "\(path) is relative, but the document has no folder yet: save it, or give an absolute path."
        case .unknownLanguage(let language):
            return "No shader language \(language): msl, glsl, osl or osl_network."
        case .unknownShape(let shape):
            return "No preview shape \(shape): "
                + ViewportShape.allCases.map(\.rawValue).joined(separator: ", ") + "."
        case .unknownFunction(let function):
            return "margolaria.\(function)() isn't known to this version of Margolaria."
        case .noMaterial(let material, let materials):
            return "No material called \(material) in the document"
                + (materials.isEmpty ? "." : ": " + materials.joined(separator: ", ") + ".")
        }
    }
}
