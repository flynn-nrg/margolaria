// PythonBridge.h
//
// The C++ API that Swift sees for running Python (M6). ScriptKit (Swift)
// imports this header; nothing else in Margolaria talks to Python directly.
//
// Python is embedded: the interpreter (Python.framework, from
// scripts/fetch-python.sh) runs inside Margolaria's process, and scripts
// work on the app's own documents. `margolaria.document()` in a script
// returns the document being edited as a PyMaterialX `Document`
// (scripts/build-pymaterialx.sh): the same C++ object as the app's, so
// what the script changes, the app sees.
//
// The `margolaria` module (M6b) is built in, here: the editor's edits on
// that document (MXBridge's, refusals raised as `margolaria.EditRefused`),
// and `with margolaria.edit("Name"):` for undo steps of the script's own.
// What only the Swift side can do (the selection, validation, export,
// colour conversion) is asked of it through a HostFunction.
//
// The Console (M6c) runs its entries the same way, in a namespace of its
// own kept between them. Runs are on a worker thread, so the window can
// offer to stop one: `interrupt` raises KeyboardInterrupt in it.
//
// The same rules as MXBridge.h, so it imports cleanly into Swift: no Python,
// pybind11 or MaterialX headers here; no exceptions cross into Swift (a
// script's exceptions come back as its output); simple types only.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "MXBridge.h"

namespace pybridge {

/// One undo step a script made: its name, and the document as it was at
/// its end (an independent copy).
struct Step {
    std::string name;
    mxbridge::Document after;
};

/// What running a script gave.
struct RunResult {
    /// False if the script raised an exception (a SyntaxError included).
    bool succeeded = false;
    /// What it printed, standard output and standard error together, in
    /// order; for a script that raised, ending with its traceback.
    std::string output;
    /// For a script that succeeded, its undo steps, in order: each
    /// `with margolaria.edit(...)` block that changed the document, and
    /// each stretch of changes between them, named after the script.
    /// Empty if it changed nothing. For a script that failed, empty: the
    /// caller puts the document back as it was.
    std::vector<Step> steps;
    /// True if it ended with KeyboardInterrupt: `interrupt`, usually.
    bool interrupted = false;
};

/// Whether a Console's lines so far make a statement to run.
enum class EntryState {
    /// A whole statement: run it.
    complete,
    /// The start of one (`for x in y:`, an open bracket): more lines needed.
    incomplete,
    /// A syntax error, whatever comes next.
    invalid,
};

/// A call from a script to the Swift side, such as `margolaria.issues()`:
/// `function` names it ("issues"), with its `arguments`. The host fills in
/// `results`, or `error` if it failed; `refused` makes the error an
/// `EditRefused`, as for an edit, rather than a `RuntimeError`.
struct HostCall {
    std::string function;
    mxbridge::StringVector arguments;
    mxbridge::StringVector results;
    std::string error;
    bool refused = false;
};

/// The Swift side's function for HostCalls: a C function pointer, which
/// Swift can make from a closure that captures nothing. `context` is what
/// was passed to `run`, for the host to find itself again.
using HostFunction = void (*)(void* context, HostCall* call);

/// The embedded interpreter. One per process: Python keeps its state in
/// globals, so these are static functions, not methods of an object.
///
/// `start` is called on the main thread; the others on any thread. One
/// `run` at a time: it gives the script the document, which isn't safe to
/// change from two threads, so the caller doesn't touch the document until
/// `run` returns, and answers the HostFunction meanwhile.
class Interpreter {
public:
    /// Starts Python, once; later calls do nothing and return true.
    /// `home` is the folder holding `lib/python3.13`: in Python.framework,
    /// `Versions/3.13`. `sitePackages` is added to Python's import path: it
    /// holds the `MaterialX` package. `cacheFolder`, if not empty, is where
    /// Python keeps the modules it compiled (`.pyc`), for later launches;
    /// never in the app, which is signed. Returns false and sets
    /// `errorMessage` if Python can't start; it can't be started again in
    /// this process.
    static bool start(const std::string& home, const std::string& sitePackages, const std::string& cacheFolder,
                      std::string& errorMessage);

    /// True once start() has succeeded.
    static bool isRunning();

    /// The interpreter's version, as `sys.version` gives it. "" before start().
    static std::string version();

    /// Runs `code` as a script, named `filename` in tracebacks, in a fresh
    /// `__main__` namespace; or, if `console` isn't 0, as an entry typed in
    /// that Console (`openConsole`), in its namespace, printing the value
    /// of an expression as Python's own console does. While it runs,
    /// `margolaria.document()` returns `document`, and the module's edits
    /// change it; after, they raise. Changes outside `margolaria.edit`
    /// blocks make steps named `stepName`. `host` answers the calls only
    /// Swift can (it may be null: those calls then raise), on the thread
    /// running the script. `runID` names the run for `interrupt`: larger
    /// than any run's before. Python must be running.
    static RunResult run(const std::string& code, const std::string& filename, const std::string& stepName,
                         int console, int64_t runID, const mxbridge::Document& document, HostFunction host,
                         void* hostContext);

    /// Stops the run `runID`: raises KeyboardInterrupt in the script, as
    /// Ctrl-C in a terminal would; if it hasn't started yet, as soon as it
    /// does; if it has ended, nothing. Returns at once; the script stops at
    /// its next line of Python (not inside a long MaterialX call, which it
    /// finishes first).
    static void interrupt(int64_t runID);

    /// A new Console's namespace, with `MaterialX` (as `mx`) and
    /// `margolaria` imported; 0 if Python isn't running.
    static int openConsole();

    /// Forgets a Console's namespace, and the variables in it.
    static void closeConsole(int console);

    /// Whether `source`, a Console's lines so far, is a statement to run,
    /// as Python's console decides (the `codeop` module). For an invalid
    /// one, `errorMessage` is the SyntaxError, as the console prints it.
    static EntryState checkEntry(const std::string& source, const std::string& filename, std::string& errorMessage);
};

} // namespace pybridge
