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
// The same rules as MXBridge.h, so it imports cleanly into Swift: no Python,
// pybind11 or MaterialX headers here; no exceptions cross into Swift (a
// script's exceptions come back as its output); simple types only.

#pragma once

#include <string>

#include "MXBridge.h"

namespace pybridge {

/// What running a script gave.
struct RunResult {
    /// False if the script raised an exception (a SyntaxError included).
    bool succeeded = false;
    /// What it printed, standard output and standard error together, in
    /// order; for a script that raised, ending with its traceback.
    std::string output;
};

/// The embedded interpreter. One per process: Python keeps its state in
/// globals, so these are static functions, not methods of an object.
///
/// Call them on one thread only (the main thread): a document isn't safe to
/// change from two threads, and `run` gives the script the document.
class Interpreter {
public:
    /// Starts Python, once; later calls do nothing and return true.
    /// `home` is the folder holding `lib/python3.13`: in Python.framework,
    /// `Versions/3.13`. `sitePackages` is added to Python's import path: it
    /// holds the `MaterialX` package. Returns false and sets `errorMessage`
    /// if Python can't start; it can't be started again in this process.
    static bool start(const std::string& home, const std::string& sitePackages, std::string& errorMessage);

    /// True once start() has succeeded.
    static bool isRunning();

    /// The interpreter's version, as `sys.version` gives it. "" before start().
    static std::string version();

    /// Runs `code` as a script, named `filename` in tracebacks, in a fresh
    /// `__main__` namespace. While it runs, `margolaria.document()` returns
    /// `document`; after, it raises. Python must be running.
    static RunResult run(const std::string& code, const std::string& filename, const mxbridge::Document& document);
};

} // namespace pybridge
