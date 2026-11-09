// PythonConsole.swift
//
// The Console tab's Python REPL (M6c), without its view: what it has
// shown, what was typed before (Up and Down recall it), and the lines of a
// statement not finished yet. The app's view shows `lines`, passes each
// typed line to `enter`, runs the Script it returns (Python.start), and
// passes the result to `show`.
//
// Each Console has a namespace of its own (ConsoleNamespace), kept between
// entries, as `python3` keeps its variables: `doc = margolaria.document()`
// typed once is there for the next entries. As in Python's own console, a
// line that starts a block (`for node in doc.getNodes():`) asks for more
// lines, and a blank line ends it; an expression's value is printed.
//
// Introduces (SWIFT): a class whose `deinit` cleans up after a C++ API.

import Foundation
import Observation
import PythonBridge

/// A Console's Python namespace: the variables its entries define. Gone
/// with this object.
///
/// SWIFT: `Sendable`: a `final class` whose properties are all `let`s of
/// `Sendable` types can be shared between threads, and says so (a Script
/// carries it to the worker thread). Not `@MainActor`, so `deinit`, which
/// runs wherever the last reference goes, can use `id`.
public final class ConsoleNamespace: Sendable {
    /// PythonBridge's number for it.
    let id: Int32

    /// A new namespace; nil if Python isn't running.
    init?() {
        let id: Int32 = pybridge.Interpreter.openConsole()
        guard id != 0 else {
            return nil
        }
        self.id = id
    }

    /// SWIFT: `deinit` runs when the last reference goes, like a C++
    /// destructor or ObjC's `dealloc`: here, when the window closes, the
    /// namespace's Python objects go too (a `doc` kept in it holds the
    /// whole document).
    deinit {
        pybridge.Interpreter.closeConsole(id)
    }
}

/// A Python REPL on a document.
///
/// SWIFT: `@Observable`: the Console tab redraws when `lines` or the
/// prompt changes.
@MainActor
@Observable
public final class PythonConsole {
    /// How a line of the transcript is shown.
    public enum Style: Sendable {
        /// What was typed, after its prompt.
        case input
        /// What an entry printed.
        case output
        /// A traceback, or a syntax error.
        case error
        /// The Console's own messages: the greeting, a script's name.
        case note
    }

    /// One block of the transcript: a typed line, or what an entry printed
    /// (several lines).
    public struct Line: Identifiable, Sendable {
        public let id: Int
        public let style: Style
        public let text: String
    }

    /// What the Console has shown, oldest first.
    public private(set) var lines: [Line] = []

    /// The lines typed, oldest first, for Up and Down. Blank lines and
    /// repeats of the line before aren't kept, as a shell's history.
    public private(set) var history: [String] = []

    /// The lines of a statement not finished yet.
    private var pending: [String] = []

    /// What the next line is typed after: ">>> ", or "... " in the middle
    /// of a statement, as in Python's console.
    public var prompt: String {
        pending.isEmpty ? ">>> " : "... "
    }

    /// The name of the undo steps an entry makes ("Undo Console").
    public static let stepName: String = "Console"

    /// What tracebacks call the entries' code.
    static let filename: String = "<console>"

    @ObservationIgnored private var namespace: ConsoleNamespace? = nil
    @ObservationIgnored private var nextID: Int = 0
    /// The history entry shown by Up and Down, if any.
    @ObservationIgnored private var recalled: Int? = nil
    /// What was typed before Up, for Down to come back to.
    @ObservationIgnored private var draft: String = ""

    public init() {}

    /// Opens the namespace, once Python runs, and greets. Does nothing if
    /// it's open already, or if Python isn't running.
    public func begin() {
        guard namespace == nil, let namespace = ConsoleNamespace() else {
            return
        }
        self.namespace = namespace
        // "3.13.18 (main, ...)": the version is the first word.
        let version: String = Python.version.split(separator: " ").first.map(String.init) ?? ""
        append(.note, "Python \(version). margolaria and MaterialX (as mx) are imported; "
            + "margolaria.document() is this window's document.")
    }

    /// Takes one typed line, showing it. Returns the entry to run once the
    /// lines so far make a statement; nil while more lines are needed, or
    /// if they have a syntax error (shown, and the lines dropped). Python
    /// must be running.
    public func enter(_ line: String) -> Script? {
        begin()
        append(.input, prompt + line)
        if !line.allSatisfy(\.isWhitespace), line != history.last {
            history.append(line)
        }
        recalled = nil
        draft = ""
        // A line of spaces counts as blank: it ends a block, even when the
        // view put the indentation in by itself.
        let text: String = line.allSatisfy(\.isWhitespace) ? "" : line
        if pending.isEmpty, text.isEmpty {
            return nil
        }
        guard let namespace else {
            append(.error, "Python isn't running.")
            return nil
        }
        pending.append(text)
        let source: String = pending.joined(separator: "\n")
        var message = std.string()
        let state: pybridge.EntryState = pybridge.Interpreter.checkEntry(std.string(source), std.string(Self.filename),
                                                                         &message)
        // SWIFT: A C++ `enum class` comes into Swift as a struct with
        // static members (see MXShaderLanguage.bridgeValue), so it is
        // compared with `==` rather than switched over.
        if state == .incomplete {
            return nil
        }
        pending = []
        if state == .invalid {
            append(.error, message.swiftString)
            return nil
        }
        // Only comments: nothing to run, as in Python's console.
        let code: [Substring] = source.split(separator: "\n").filter { line in
            let trimmed: String = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        if code.isEmpty {
            return nil
        }
        return Script(code: source, filename: Self.filename, name: "Console", stepName: Self.stepName,
                      console: namespace)
    }

    /// Shows what a run printed: a traceback as an error. `title`, for a
    /// script run from a file rather than typed here, comes first.
    public func show(_ result: ScriptResult, title: String? = nil) {
        if let title {
            append(.note, title)
        }
        append(result.succeeded ? .output : .error, result.output)
    }

    /// Shows an error that kept an entry from running.
    public func show(_ error: any Error) {
        append(.error, error.localizedDescription)
    }

    /// Forgets the lines shown, and a statement not finished. The history
    /// and the variables stay.
    public func clear() {
        lines = []
        pending = []
    }

    /// The indentation for the line after `line`, in a statement not
    /// finished: `line`'s, and four spaces more after a colon, as Python's
    /// own console (3.13) does. "" outside a statement.
    public func indentation(after line: String) -> String {
        guard !pending.isEmpty else {
            return ""
        }
        let indentation: String = String(line.prefix(while: { $0 == " " }))
        let code: Substring = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return code.trimmingCharacters(in: .whitespaces).hasSuffix(":") ? indentation + "    " : indentation
    }

    /// The history entry before the one shown (Up): the last line typed,
    /// first. `text` is what the line holds now, kept for Down to come
    /// back to. nil when there's nothing older.
    public func older(than text: String) -> String? {
        let index: Int
        if let recalled {
            index = recalled - 1
        } else {
            draft = text
            index = history.count - 1
        }
        guard index >= 0 else {
            return nil
        }
        recalled = index
        return history[index]
    }

    /// The history entry after the one shown (Down), or, after the newest,
    /// what was typed before Up. nil when not in the history.
    public func newer() -> String? {
        guard let recalled else {
            return nil
        }
        if recalled + 1 < history.count {
            self.recalled = recalled + 1
            return history[recalled + 1]
        }
        self.recalled = nil
        return draft
    }

    /// Adds a block to the transcript, without its last line break.
    private func append(_ style: Style, _ text: String) {
        var text: Substring = text[...]
        while text.hasSuffix("\n") {
            text = text.dropLast()
        }
        guard !text.isEmpty || style == .input else {
            return
        }
        lines.append(Line(id: nextID, style: style, text: String(text)))
        nextID += 1
    }
}
