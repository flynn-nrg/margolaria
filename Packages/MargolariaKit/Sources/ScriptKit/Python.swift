// Python.swift
//
// Running Python scripts on documents (M6): the embedded interpreter,
// started once, and scripts run on an MXDocument. The C++ underneath is
// PythonBridge; this file only turns its results into Swift's.
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
    public let succeeded: Bool
    /// What it printed, standard output and error together; for a script
    /// that raised, ending with its traceback.
    public let output: String
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
    /// `sitePackages` the MaterialX package.
    public struct Location: Sendable {
        public let home: URL
        public let sitePackages: URL

        public init(home: URL, sitePackages: URL) {
            self.home = home
            self.sitePackages = sitePackages
        }

        /// Where the app's bundle has them (project.yml).
        public static func inApp(_ bundle: Bundle = .main) -> Location {
            Location(home: bundle.privateFrameworksURL!.appending(path: "Python.framework/Versions/3.13"),
                     sitePackages: bundle.resourceURL!.appending(path: "Python/site-packages"))
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
    /// this document, as a MaterialX.Document. Changes the document in
    /// place; making them undoable is the caller's (the app runs scripts
    /// inside an edit). `filename` names the script in tracebacks.
    /// Python must have been started.
    public static func run(_ code: String, named filename: String, on document: MXDocument) -> ScriptResult {
        let result = pybridge.Interpreter.run(std.string(code), std.string(filename), document.handle)
        return ScriptResult(succeeded: result.succeeded, output: result.output.swiftString)
    }
}
