// PythonBridge.cpp
//
// Embeds Python (the C API, through pybind11's C++ wrappers) and hands
// MaterialX documents to scripts. See PythonBridge.h.
//
// pybind11 must be the same version as PyMaterialX's, built by the same
// compiler: pybind11 keeps its table of C++ types in the interpreter, under
// a name made from its version and the compiler's ABI, and two builds share
// it only when those agree. That is how `margolaria.document()` can return
// an `mx::DocumentPtr` that Python sees as PyMaterialX's `Document` class.
// scripts/build-pymaterialx.sh copies the headers it used to
// Vendor/PyMaterialX/include, which Package.swift puts on our include path.

#include "PythonBridge.h"

// Python's own header first, as its documentation asks: it sets macros
// that change how the C library's headers are read.
#include <Python.h>

// Not <pybind11/embed.h>: the copy MaterialX ships leaves it out. What it
// would do for us, registering a module compiled into the app, is one call
// (PyImport_AppendInittab, in start()).
#include <pybind11/pybind11.h>

#include <MaterialXCore/Document.h>

namespace py = pybind11;
namespace mx = MaterialX;

namespace pybridge {

namespace {

/// The document `margolaria.document()` returns: set by run() for the
/// duration of a script, null otherwise.
mx::DocumentPtr currentDocument;

/// Set once Python is running.
bool running = false;

/// Set if Python failed to start: it can't be started twice.
bool failed = false;

/// The thread state saved when start() releases Python's global lock
/// (the GIL), so run() can take it again from the same thread.
PyThreadState* mainThreadState = nullptr;

} // namespace

// The `margolaria` module, compiled into the app rather than loaded from a
// file: start() adds it to Python's table of built-in modules, so `import
// margolaria` finds it there. PYBIND11_MODULE defines the function that
// makes the module, `PyInit_margolaria`, as a compiled extension module's
// would be. The spike (M6a) gives it one function; M6b makes it the
// scripting API.
PYBIND11_MODULE(margolaria, module) {
    module.doc() = "Margolaria's scripting API.";
    module.def(
        "document",
        []() -> mx::DocumentPtr {
            if (!currentDocument) {
                throw std::runtime_error("No document: margolaria.document() works while Margolaria runs a script.");
            }
            return currentDocument;
        },
        "The document the script is run on, as a MaterialX.Document.");
}

bool Interpreter::start(const std::string& home, const std::string& sitePackages, std::string& errorMessage) {
    if (running) {
        return true;
    }
    if (failed) {
        errorMessage = "Python failed to start earlier, and can't be started again.";
        return false;
    }

    // Before Python starts, as its built-in modules are fixed then.
    PyImport_AppendInittab("margolaria", PyInit_margolaria);

    // An isolated configuration: Python ignores PYTHON* environment
    // variables, the user's own site-packages and the current folder, so a
    // Python installed on the Mac can't change what Margolaria's runs.
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    // Where the standard library is, rather than Python guessing from the
    // executable's path (Margolaria's, not a python3's).
    PyStatus status = PyConfig_SetBytesString(&config, &config.home, home.c_str());
    // Python's .pyc files would be written next to the sources, inside the
    // signed app (PLAN.md §7.1: nothing writes into the bundle).
    config.write_bytecode = 0;
    // Ctrl-C and other signals stay the app's.
    config.install_signal_handlers = 0;
    if (!PyStatus_Exception(status)) {
        status = Py_InitializeFromConfig(&config);
    }
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        failed = true;
        errorMessage = status.err_msg ? status.err_msg : "Python failed to start.";
        return false;
    }

    try {
        py::module_::import("sys").attr("path").attr("append")(sitePackages);
    } catch (const py::error_already_set& error) {
        failed = true;
        errorMessage = error.what();
        return false;
    }

    running = true;
    // Python starts with this thread holding the GIL. Release it until
    // run() needs it, so the lock isn't held while the app does other work.
    mainThreadState = PyEval_SaveThread();
    return true;
}

bool Interpreter::isRunning() {
    return running;
}

std::string Interpreter::version() {
    if (!running) {
        return "";
    }
    py::gil_scoped_acquire gil;
    return py::module_::import("sys").attr("version").cast<std::string>();
}

RunResult Interpreter::run(const std::string& code, const std::string& filename,
                           const mxbridge::Document& document) {
    RunResult result;
    if (!running) {
        result.output = "Python isn't running.";
        return result;
    }

    // Take the GIL back for this thread: start() released it.
    PyEval_RestoreThread(mainThreadState);
    {
        py::module_ sys = py::module_::import("sys");
        // What the script prints goes into a string, not the app's stdout.
        py::object buffer = py::module_::import("io").attr("StringIO")();
        py::object savedOut = sys.attr("stdout");
        py::object savedErr = sys.attr("stderr");
        sys.attr("stdout") = buffer;
        sys.attr("stderr") = buffer;

        currentDocument = std::static_pointer_cast<mx::Document>(document.materialXDocument());
        try {
            // PyMaterialX first: it registers the Document class, which
            // margolaria.document() needs to return one.
            py::module_::import("MaterialX");

            py::dict globals;
            globals["__name__"] = "__main__";
            globals["__file__"] = filename;
            globals["__builtins__"] = py::module_::import("builtins");
            // compile() then exec(), rather than py::exec, so tracebacks
            // name the script's file and lines.
            py::object compiled = py::module_::import("builtins").attr("compile")(code, filename, "exec");
            py::module_::import("builtins").attr("exec")(compiled, globals);
            result.succeeded = true;
        } catch (py::error_already_set& error) {
            // sys.exit() ends the script, not the app; exit(0) and exit()
            // count as success.
            if (error.matches(PyExc_SystemExit)) {
                py::object exitCode = error.value().attr("code");
                result.succeeded = exitCode.is_none()
                    || (py::isinstance<py::int_>(exitCode) && exitCode.cast<int>() == 0);
            } else {
                py::module_::import("traceback").attr("print_exception")(error.value());
            }
        } catch (const std::exception& error) {
            // A C++ exception outside Python's (pybind11 converts those
            // raised inside a call): reported like a Python error.
            buffer.attr("write")(std::string("Error: ") + error.what() + "\n");
        }
        currentDocument = nullptr;

        sys.attr("stdout") = savedOut;
        sys.attr("stderr") = savedErr;
        result.output = buffer.attr("getvalue")().cast<std::string>();
    }
    // Every Python object above is released (the block's end) before the GIL.
    mainThreadState = PyEval_SaveThread();
    return result;
}

} // namespace pybridge
