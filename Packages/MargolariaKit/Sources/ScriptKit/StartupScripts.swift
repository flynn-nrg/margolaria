// StartupScripts.swift
//
// The user's startup scripts (M6d): the `.py` files in
// `~/Library/Application Support/Margolaria/Scripts`, run when Margolaria
// starts, one after the other in alphabetical order, with no document.
// They set things up, mainly registering commands:
//
//   import margolaria
//
//   @margolaria.command("Add Brick Material")
//   def add_brick():
//       margolaria.add_node("ND_standard_surface_surfaceshader", name="brick")
//
// The app lists the commands in its Scripts menu and its command palette,
// and runs one on the document of the window it is chosen in
// (`Script.command`), its changes one undo step named after it.
//
// A startup script that fails is reported (each window's Console shows
// its traceback) and the next one runs: an error in one doesn't stop the
// app, nor the others. Each runs on its worker thread, as any script does,
// so a slow one doesn't hold up the app; Scripts > Stop Script stops it.
//
// Introduces (SWIFT): `ArraySlice` (`array[...]`); `localizedStandardCompare`.

import Foundation

/// The startup scripts, and what their last run gave.
@MainActor
public enum StartupScripts {
    /// What one startup script gave.
    public struct Report: Sendable {
        /// Its file's name: "commands.py".
        public let name: String
        public let result: ScriptResult
    }

    /// Where the startup scripts are: `Python.userFolder`'s `Scripts`.
    public nonisolated static var folder: URL {
        Python.userFolder.appending(path: "Scripts")
    }

    /// What the last run of the startup scripts gave, one report per
    /// script in the order they ran; nil until it has ended.
    public private(set) static var reports: [Report]? = nil

    /// Counts the runs that have ended, so a Console shows each one's
    /// reports once (PythonConsole.showStartupScripts).
    public private(set) static var generation: Int = 0

    /// True from `run` until its last script has ended.
    public private(set) static var isRunning: Bool = false

    /// The startup scripts in `folder`: its `.py` files, by name (as
    /// Finder sorts them: "2.py" before "10.py"). None if it doesn't exist.
    ///
    /// SWIFT: `localizedStandardCompare` compares strings as Finder does:
    /// numbers by value, capitals with their lowercase letters.
    public static func scripts(in folder: URL) -> [URL] {
        let files: [URL] = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                         options: .skipsHiddenFiles)) ?? []
        return files
            .filter { $0.pathExtension == "py" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Runs the startup scripts in `folder`, after forgetting the commands
    /// registered before (scripts run again register theirs again).
    /// Python is started from `location` first, if there are scripts to
    /// run and it isn't running. Each script waits up to `patience` for
    /// the one before (Python.start); `finished` is called with the
    /// reports once the last has ended. Does nothing if they are running
    /// already.
    public static func run(in folder: URL = folder, from location: Python.Location, waitingUpTo patience: TimeInterval,
                           finished: @escaping ([Report]) -> Void) {
        guard !isRunning else {
            return
        }
        isRunning = true
        reports = nil
        if Python.isRunning {
            Python.clearCommands()
        }
        let scripts: [URL] = scripts(in: folder)
        guard !scripts.isEmpty else {
            end([], finished: finished)
            return
        }
        do {
            try Python.start(from: location)
        } catch {
            end([Report(name: "Python", result: .failed(error.localizedDescription))], finished: finished)
            return
        }
        // SWIFT: `scripts[...]` is the whole array as an `ArraySlice`: a
        // view of part of an array, sharing its storage, as a Go slice
        // does. `dropFirst()` on it is another slice, without the first
        // element, made without copying.
        run(scripts[...], waitingUpTo: patience, reports: [], finished: finished)
    }

    /// Runs the first of `scripts`, then, once it has ended, the rest.
    private static func run(_ scripts: ArraySlice<URL>, waitingUpTo patience: TimeInterval, reports: [Report],
                            finished: @escaping ([Report]) -> Void) {
        guard let url = scripts.first else {
            end(reports, finished: finished)
            return
        }
        let next: (ScriptResult) -> Void = { result in
            run(scripts.dropFirst(), waitingUpTo: patience,
                reports: reports + [Report(name: url.lastPathComponent, result: result)], finished: finished)
        }
        do {
            let code: String = try String(contentsOf: url, encoding: .utf8)
            _ = try Python.start(.file(code, path: url.path(percentEncoded: false)), waitingUpTo: patience,
                                 finished: next)
        } catch {
            // Unreadable, or another script is running (one typed in a
            // Console meanwhile): reported as this one's failure.
            next(.failed(error.localizedDescription))
        }
    }

    /// The run has ended.
    private static func end(_ reports: [Report], finished: ([Report]) -> Void) {
        self.reports = reports
        generation += 1
        isRunning = false
        finished(reports)
    }
}
