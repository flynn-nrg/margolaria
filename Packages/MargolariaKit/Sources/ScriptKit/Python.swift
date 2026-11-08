// Python.swift
//
// Running Python scripts on documents (M6): the embedded interpreter,
// started once, and scripts run on an MXDocument as undo steps. The C++
// underneath is PythonBridge, with the `margolaria` module; this file
// turns its results into Swift's, and ScriptHost.swift answers the
// module's calls to Swift.
//
// Where Python lives: in the app, Python.framework is embedded in
// Contents/Frameworks and the MaterialX package in
// Contents/Resources/Python/site-packages (project.yml); in tests, both
// are found in Vendor, where scripts/fetch-python.sh and
// scripts/build-pymaterialx.sh put them.
//
// Introduces (SWIFT): the `package` access level (declared in
// MXDocument.swift and CxxString.swift, used here).

import Foundation
import MXBridge
import MXKit
import PythonBridge

/// What a script printed, and whether it ran to the end.
public struct ScriptResult: Sendable {
    /// False if the script raised an exception, a SyntaxError included.
    /// The document is then as it was before.
    public let succeeded: Bool
    /// What it printed, standard output and error together; for a script
    /// that raised, ending with its traceback.
    public let output: String
    /// The names of the undo steps it made, in order: "Run brick.py", and
    /// one for each `with margolaria.edit(...)` block that changed
    /// something. Empty if it changed nothing, or failed.
    public let steps: [String]
}

/// Why Python couldn't run a script.
public enum PythonError: Error, LocalizedError {
    /// Python.framework or the MaterialX package isn't where it should be.
    case notFound(String)
    /// Python failed to start, with its message.
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what):
            return "Python wasn't found: \(what)."
        case .startFailed(let message):
            return "Python failed to start: \(message)"
        }
    }
}

/// The embedded Python interpreter.
///
/// SWIFT: An `enum` with no cases can't be instantiated, so it serves as a
/// namespace for static members, as a C++ class with only static members
/// or a Go package would. The interpreter is one per process, so there is
/// nothing to make instances of.
///
/// `@MainActor`: every member runs on the main thread, where documents are
/// edited (PythonBridge.h). The compiler rejects calls from elsewhere.
@MainActor
public enum Python {
    /// Where Python's files are: `home` holds `lib/python3.13`,
    /// `sitePackages` the MaterialX package. `cache`, if not nil, is where
    /// Python keeps the modules it compiles, so later launches don't
    /// compile them again.
    public struct Location: Sendable {
        public let home: URL
        public let sitePackages: URL
        public let cache: URL?

        public init(home: URL, sitePackages: URL, cache: URL? = nil) {
            self.home = home
            self.sitePackages = sitePackages
            self.cache = cache
        }

        /// Where the app's bundle has them (project.yml), with the cache in
        /// the user's Caches folder (`~/Library/Caches/<bundle id>/Python`),
        /// as the app itself is signed and can't be written to.
        public static func inApp(_ bundle: Bundle = .main) -> Location {
            let caches: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            return Location(home: bundle.privateFrameworksURL!.appending(path: "Python.framework/Versions/3.13"),
                            sitePackages: bundle.resourceURL!.appending(path: "Python/site-packages"),
                            cache: caches?.appending(path: "\(bundle.bundleIdentifier ?? "Margolaria")/Python"))
        }

        /// Where the scripts in Vendor put them, for tests.
        ///
        /// SWIFT: `#filePath` is this source file's path when it was
        /// compiled, like C's `__FILE__`. The repository's Vendor folder is
        /// found from it: four folders up from Sources/ScriptKit.
        public static func inVendor(filePath: String = #filePath) -> Location {
            let root = URL(filePath: filePath)
                .deletingLastPathComponent() // ScriptKit
                .deletingLastPathComponent() // Sources
                .deletingLastPathComponent() // MargolariaKit
                .deletingLastPathComponent() // Packages
                .deletingLastPathComponent() // the repository
            return Location(
                home: root.appending(path: "Vendor/Python/Python.xcframework/macos-arm64/Python.framework/Versions/3.13"),
                sitePackages: root.appending(path: "Vendor/PyMaterialX/site-packages"))
        }
    }

    /// Starts Python from `location`, once; later calls do nothing.
    public static func start(from location: Location) throws {
        if pybridge.Interpreter.isRunning() {
            return
        }
        for url in [location.home.appending(path: "lib/python3.13"),
                    location.sitePackages.appending(path: "MaterialX")] {
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw PythonError.notFound(url.path(percentEncoded: false))
            }
        }
        var errorMessage = std.string()
        guard pybridge.Interpreter.start(std.string(location.home.path(percentEncoded: false)),
                                         std.string(location.sitePackages.path(percentEncoded: false)),
                                         std.string(location.cache?.path(percentEncoded: false) ?? ""),
                                         &errorMessage) else {
            throw PythonError.startFailed(errorMessage.swiftString)
        }
    }

    /// True once Python has started.
    public static var isRunning: Bool {
        pybridge.Interpreter.isRunning()
    }

    /// Python's version, as `sys.version` gives it ("3.13.18 (main, ...)");
    /// "" before it starts.
    public static var version: String {
        pybridge.Interpreter.version().swiftString
    }

    /// Runs `code` on `document`: `margolaria.document()` in the script is
    /// this document, as a MaterialX.Document, and the module's edits
    /// change it in place. `filename` names the script in tracebacks, and
    /// its last part names its undo steps ("Run brick.py").
    ///
    /// If the script succeeds, its undo steps are registered on
    /// `undoManager` (none if it changed nothing), and `changed` is called
    /// after each Undo and Redo of them, to show the document again. If it
    /// raises, the document is put back as it was, and nothing is
    /// registered. `host` answers `margolaria.selection()` and the like;
    /// without one, they raise. Python must have been started.
    public static func run(_ code: String, named filename: String, on document: MXDocument,
                           host: ScriptHost? = nil, undoManager: UndoManager? = nil,
                           changed: @escaping (MXDocument) -> Void = { _ in }) -> ScriptResult {
        let before: MXDocument = document.copy()
        let stepName: String = "Run \(URL(filePath: filename).lastPathComponent)"
        let calls = HostCalls(document: document, host: host)
        // SWIFT: `toOpaque()` is a raw pointer to `calls`, which doesn't
        // keep it alive; `withExtendedLifetime` does, until the closure
        // returns, so the pointer is good for the whole run.
        let result: pybridge.RunResult = withExtendedLifetime(calls) {
            pybridge.Interpreter.run(std.string(code), std.string(filename), std.string(stepName), document.handle,
                                     HostCalls.function, Unmanaged.passUnretained(calls).toOpaque())
        }
        guard result.succeeded else {
            document.restore(from: before)
            return ScriptResult(succeeded: false, output: result.output.swiftString, steps: [])
        }
        let steps: [MXUndoStep] = result.steps.map { step in
            MXUndoStep(name: step.name.swiftString,
                       after: MXDocument(handle: step.after, fileURL: document.fileURL, fileVersion: document.fileVersion))
        }
        if let undoManager {
            MXUndo.register(steps, on: undoManager, startingFrom: before, in: document, changed: changed)
        }
        return ScriptResult(succeeded: true, output: result.output.swiftString, steps: steps.map(\.name))
    }
}
