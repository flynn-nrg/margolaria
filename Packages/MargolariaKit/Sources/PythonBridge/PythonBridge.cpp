// PythonBridge.cpp
//
// Embeds Python (the C API, through pybind11's C++ wrappers) and hands
// MaterialX documents to scripts, with the `margolaria` module. See
// PythonBridge.h.
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
#include <pybind11/stl.h>

#include <MaterialXCore/Document.h>

#include <stdexcept>

namespace py = pybind11;
namespace mx = MaterialX;

namespace pybridge {

namespace {

/// One run of a script: its document, and the undo steps it has made so far.
struct Session {
    /// The document the script runs on: a handle sharing the caller's.
    mxbridge::Document document;
    /// The name of steps made outside `margolaria.edit` blocks.
    std::string stepName;
    HostFunction host = nullptr;
    void* hostContext = nullptr;
    /// The document as the last step left it (at first, as it was before
    /// the script): changes since are the next step's.
    mxbridge::Document checkpoint;
    std::vector<Step> steps;
    /// For each `margolaria.edit` block entered and not left yet, outermost
    /// first: the document as it was when it was entered.
    std::vector<mxbridge::Document> blockStarts;
};

/// The run in progress, set by run() for the duration of a script; null
/// otherwise, when the module's functions raise.
Session* session = nullptr;

/// Set once Python is running.
bool running = false;

/// Set if Python failed to start: it can't be started twice.
bool failed = false;

/// The thread state saved when start() releases Python's global lock
/// (the GIL), so run() can take it again from the same thread.
PyThreadState* mainThreadState = nullptr;

/// An edit refused, as MXBridge refuses them: `margolaria.EditRefused` in
/// Python (registered in the module below).
struct EditRefused : std::runtime_error {
    using std::runtime_error::runtime_error;
};

/// The run in progress, or a RuntimeError for a function called outside one
/// (from a thread the script started, say, or kept for later).
Session& Current() {
    if (!session) {
        throw std::runtime_error("No document: the margolaria module works while Margolaria runs a script.");
    }
    return *session;
}

/// Raises EditRefused with MXBridge's message if the edit wasn't made.
void Check(bool made, const std::string& errorMessage) {
    if (!made) {
        throw EditRefused(errorMessage);
    }
}

/// Ends a step called `name` if the document changed since the last one.
void Checkpoint(Session& run, const std::string& name) {
    std::string difference;
    if (run.document.isEquivalent(run.checkpoint, difference)) {
        return;
    }
    mxbridge::Document after = run.document.copy();
    run.steps.push_back(Step{name, after});
    run.checkpoint = after;
}

/// Asks the Swift side for `function`; returns its results, or raises its
/// error.
mxbridge::StringVector CallHost(const std::string& function, mxbridge::StringVector arguments) {
    Session& run = Current();
    if (!run.host) {
        throw std::runtime_error("margolaria." + function + "() isn't available here.");
    }
    HostCall call;
    call.function = function;
    call.arguments = std::move(arguments);
    run.host(run.hostContext, &call);
    if (!call.error.empty()) {
        if (call.refused) {
            throw EditRefused(call.error);
        }
        throw std::runtime_error(call.error);
    }
    return call.results;
}

/// A value as MaterialX writes it in an input's `value`: a string as it is,
/// True and False as "true" and "false", a tuple or list of numbers as
/// "0.8, 0.2, 0.1", anything else (a number, a MaterialX.Color3) as
/// Python's str() gives it.
std::string ValueText(const py::handle& value) {
    if (py::isinstance<py::str>(value)) {
        return value.cast<std::string>();
    }
    // Before numbers: True is an int in Python.
    if (py::isinstance<py::bool_>(value)) {
        return value.cast<bool>() ? "true" : "false";
    }
    if (py::isinstance<py::tuple>(value) || py::isinstance<py::list>(value)) {
        std::string text;
        for (const py::handle& item : value) {
            text += (text.empty() ? "" : ", ") + ValueText(item);
        }
        return text;
    }
    return py::str(value).cast<std::string>();
}

/// A file path given as a str or a pathlib.Path (anything os.fspath takes).
std::string PathText(const py::object& path) {
    return py::module_::import("os").attr("fspath")(path).cast<std::string>();
}

/// `with margolaria.edit("Name"):` — the block's changes are one undo step
/// called "Name". If the block raises, its changes are taken back before
/// the exception goes on. Blocks inside blocks belong to the outermost.
class EditBlock {
public:
    explicit EditBlock(std::string name) : _name(std::move(name)) {}

    mx::DocumentPtr enter() {
        Session& run = Current();
        if (run.blockStarts.empty()) {
            // What changed before the block is a step of its own.
            Checkpoint(run, run.stepName);
        }
        run.blockStarts.push_back(run.document.copy());
        return std::static_pointer_cast<mx::Document>(run.document.materialXDocument());
    }

    void exit(const py::object& exceptionType) {
        Session& run = Current();
        if (run.blockStarts.empty()) {
            return;
        }
        mxbridge::Document start = run.blockStarts.back();
        run.blockStarts.pop_back();
        // sys.exit() inside the block ends the script, keeping its changes.
        bool raised = !exceptionType.is_none() && !PyErr_GivenExceptionMatches(exceptionType.ptr(), PyExc_SystemExit);
        if (raised) {
            run.document.restoreContents(start);
        } else if (run.blockStarts.empty()) {
            Checkpoint(run, _name);
        }
    }

private:
    std::string _name;
};

} // namespace

// The `margolaria` module, compiled into the app rather than loaded from a
// file: start() adds it to Python's table of built-in modules, so `import
// margolaria` finds it there. PYBIND11_MODULE defines the function that
// makes the module, `PyInit_margolaria`, as a compiled extension module's
// would be.
//
// Paths name elements as MaterialX does, from the document's top level:
// "brick_shader", "NG_brick/noise1". Edits are MXBridge's, the same as the
// editor's (MXEdit.swift), and refusals raise EditRefused.
PYBIND11_MODULE(margolaria, module) {
    module.doc() = "Margolaria's scripting API: the open document, the editor's edits on it, "
                   "undo steps, validation and export.";

    py::register_exception<EditRefused>(module, "EditRefused", PyExc_ValueError);
    module.attr("EditRefused").attr("__doc__") =
        "An edit Margolaria refused, as the editor would: a type mismatch, a loop, a name taken, "
        "an element from an included file. The document is as it was before the edit.";

    py::object namedtuple = py::module_::import("collections").attr("namedtuple");
    module.attr("Issue") = namedtuple("Issue", py::make_tuple("path", "message", "severity", "source"),
                                      py::arg("module") = "margolaria");
    module.attr("Issue").attr("__doc__") =
        "A problem in the document, as the Issues tab lists it: the element's path (\"\" for the document), "
        "the message, the severity (\"error\" or \"warning\"), and the source (\"materialx\" for MaterialX's "
        "validation, \"margolaria\" for Margolaria's own checks).";

    // --- The document --------------------------------------------------

    module.def(
        "document",
        []() { return std::static_pointer_cast<mx::Document>(Current().document.materialXDocument()); },
        "The document the script is run on, as a MaterialX.Document: the app's own, so changes made with "
        "MaterialX's API are the app's too. It stays the same object after Undo.");

    py::class_<EditBlock>(module, "Edit", "A block of changes that is one undo step; see margolaria.edit().")
        .def("__enter__", &EditBlock::enter)
        .def("__exit__", [](EditBlock& block, const py::object& type, const py::object&, const py::object&) {
            block.exit(type);
            return false;
        });

    module.def(
        "edit", [](const std::string& name) { return EditBlock(name); }, py::arg("name"),
        "with margolaria.edit(\"Name\"): makes the block's changes one undo step called Name. If the block "
        "raises, its changes are taken back. Changes outside blocks are steps named after the script.");

    // --- The selection -------------------------------------------------

    module.def(
        "selection", []() { return CallHost("selection", {}); },
        "The paths of the elements selected on the canvas, as a list.");

    module.def(
        "select", [](const std::string& path) { CallHost("select", {path}); }, py::arg("path"),
        "Selects the node or backdrop at path on the canvas, showing its graph, once the script has ended.");

    // --- Edits ---------------------------------------------------------

    module.def(
        "add_node",
        [](const std::string& nodeDef, const std::string& parent, const std::string& name) {
            std::string newPath, error;
            Check(Current().document.addNode(parent, nodeDef, name, newPath, error), error);
            return newPath;
        },
        py::arg("nodedef"), py::arg("parent") = "", py::arg("name") = "",
        "Adds a node defined by nodedef (\"ND_image_color3\") to the graph at parent (\"\" for the document), "
        "with the nodedef's defaults, as the editor does; name is a hint, made unique. Returns its path.");

    module.def(
        "remove_node",
        [](const std::string& path) {
            std::string error;
            Check(Current().document.removeNode(path, error), error);
        },
        py::arg("path"), "Removes a node or nodegraph, disconnecting everything that used it.");

    module.def(
        "rename_node",
        [](const std::string& path, const std::string& name) {
            std::string newPath, error;
            Check(Current().document.renameNode(path, name, newPath, error), error);
            return newPath;
        },
        py::arg("path"), py::arg("name"),
        "Renames a node, nodegraph or backdrop, updating what refers to it. Returns its new path.");

    module.def(
        "change_nodedef",
        [](const std::string& path, const std::string& nodeDef) {
            std::string error;
            Check(Current().document.changeNodeDef(path, nodeDef, error), error);
        },
        py::arg("path"), py::arg("nodedef"),
        "Changes a node to another type variant (\"ND_multiply_color3FA\"), keeping the inputs and "
        "connections whose types still fit.");

    module.def(
        "set_value",
        [](const std::string& path, const std::string& input, const py::object& value) {
            std::string error;
            Check(Current().document.setInputValue(path, input, ValueText(value), error), error);
        },
        py::arg("path"), py::arg("input"), py::arg("value"),
        "Sets an input's value, disconnecting it if it was connected: a string as MaterialX writes it "
        "(\"0.8, 0.2, 0.1\"), a number, a bool, a tuple of numbers or a MaterialX value (MaterialX.Color3).");

    module.def(
        "reset_input",
        [](const std::string& path, const std::string& input) {
            std::string error;
            Check(Current().document.resetInput(path, input, error), error);
        },
        py::arg("path"), py::arg("input"), "Removes an input, so the node uses its nodedef's default again.");

    module.def(
        "set_colorspace",
        [](const std::string& path, const std::string& input, const py::object& colorSpace) {
            std::string error;
            std::string space = colorSpace.is_none() ? "" : colorSpace.cast<std::string>();
            Check(Current().document.setInputColorSpace(path, input, space, error), error);
        },
        py::arg("path"), py::arg("input"), py::arg("colorspace"),
        "Sets an input's colorspace (None removes it), leaving its value as it is.");

    module.def(
        "connect",
        [](const std::string& path, const std::string& input, const std::string& source, const py::object& output) {
            std::string error;
            std::string outputName = output.is_none() ? "" : output.cast<std::string>();
            Check(Current().document.connectInput(path, input, source, outputName, error), error);
        },
        py::arg("path"), py::arg("input"), py::arg("source"), py::arg("output") = py::none(),
        "Connects input of the node at path to the node or nodegraph source in the same graph (its output, "
        "if it has several). For an <output> element, input is \"\". Refused if the types differ, if it would "
        "make a loop, or if the input is uniform.");

    module.def(
        "connect_interface",
        [](const std::string& path, const std::string& input, const std::string& interface) {
            std::string error;
            Check(Current().document.connectInterface(path, input, interface, error), error);
        },
        py::arg("path"), py::arg("input"), py::arg("interface"),
        "Connects an input inside a nodegraph to one of the graph's own inputs.");

    module.def(
        "disconnect",
        [](const std::string& path, const std::string& input) {
            std::string error;
            Check(Current().document.disconnectInput(path, input, error), error);
        },
        py::arg("path"), py::arg("input"),
        "Disconnects an input (or an <output>, with input \"\"). A node's input with no value of its own is "
        "removed, so the node uses its default.");

    module.def(
        "set_position",
        [](const std::string& path, float x, float y) {
            std::string error;
            Check(Current().document.setPosition(path, x, y, error), error);
        },
        py::arg("path"), py::arg("x"), py::arg("y"),
        "Sets an element's xpos and ypos, in MaterialX's units (one node of MaterialX's Graph Editor). "
        "Nodes without a position are laid out by the canvas.");

    module.def(
        "working_space", [](const std::string& path) { return CallHost("working_space", {path}).at(0); },
        py::arg("path") = "",
        "The colour space untagged colours are in, in the document (\"\") or the nodegraph at path.");

    module.def(
        "set_working_space",
        [](const py::object& colorSpace, const std::string& path, bool convert) {
            std::string space = colorSpace.is_none() ? "" : colorSpace.cast<std::string>();
            CallHost("set_working_space", {space, path, convert ? "convert" : "keep"});
        },
        py::arg("colorspace"), py::arg("path") = "", py::arg("convert") = true,
        "Sets the working space of the document (\"\") or of the nodegraph at path (None: its parent's). "
        "With convert, colours keep their look, as the editor's Convert Colours: values are converted, and "
        "images tagged with the old space. Without, the numbers stay as they are.");

    // --- Validation ----------------------------------------------------

    module.def(
        "issues",
        []() {
            mxbridge::StringVector fields = CallHost("issues", {});
            py::list issues;
            py::object issue = py::module_::import("margolaria").attr("Issue");
            // Four fields per issue (MargolariaHost in ScriptKit).
            for (size_t i = 0; i + 3 < fields.size(); i += 4) {
                issues.append(issue(fields[i], fields[i + 1], fields[i + 2], fields[i + 3]));
            }
            return issues;
        },
        "Every problem the Issues tab would list, as margolaria.Issue tuples: MaterialX's validation and "
        "Margolaria's own checks. An empty list for a valid document.");

    // --- Export --------------------------------------------------------

    module.def(
        "export_usd",
        [](const py::object& path) { CallHost("export_usd", {PathText(path)}); },
        py::arg("path"),
        "Writes the document's materials as USD (.usda, .usdc or .usd), as File > Export as USD. A relative "
        "path is relative to the document's folder.");

    module.def(
        "export_usdz",
        [](const py::object& path, const py::object& material) {
            CallHost("export_usdz", {PathText(path), material.is_none() ? "" : material.cast<std::string>()});
        },
        py::arg("path"), py::arg("material") = py::none(),
        "Writes a USDZ package for Quick Look and Reality Composer Pro, as File > Export as USDZ: a sphere "
        "with material (by name; the first if None), the other materials, and every texture.");

    module.def(
        "export_shader",
        [](const std::string& path, const py::object& folder, const std::string& language,
           const std::string& colorSpace, const py::object& oslc) {
            return CallHost("export_shader", {path, PathText(folder), language, colorSpace,
                                              oslc.is_none() ? "" : PathText(oslc)});
        },
        py::arg("path"), py::arg("folder"), py::arg("language") = "msl", py::arg("colorspace") = "lin_rec709",
        py::arg("oslc") = py::none(),
        "Writes the shader MaterialX generates for the element at path into folder, as the Generated Shader "
        "tab's Export: language \"msl\", \"glsl\", \"osl\" or \"osl_network\", computing in colorspace "
        "(lin_rec709 or acescg). For osl, oslc (the compiler's path) also compiles it. Returns the files.");
}

bool Interpreter::start(const std::string& home, const std::string& sitePackages, const std::string& cacheFolder,
                        std::string& errorMessage) {
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
    // Compiled modules (.pyc) go to the cache folder, in a tree mirroring
    // the sources' paths, never next to the sources: inside the signed app
    // (PLAN.md §7.1: nothing writes into the bundle). Without a folder,
    // none are written.
    if (cacheFolder.empty()) {
        config.write_bytecode = 0;
    } else if (!PyStatus_Exception(status)) {
        status = PyConfig_SetBytesString(&config, &config.pycache_prefix, cacheFolder.c_str());
    }
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

RunResult Interpreter::run(const std::string& code, const std::string& filename, const std::string& stepName,
                           const mxbridge::Document& document, HostFunction host, void* hostContext) {
    RunResult result;
    if (!running) {
        result.output = "Python isn't running.";
        return result;
    }

    Session run;
    run.document = document;
    run.stepName = stepName;
    run.host = host;
    run.hostContext = hostContext;
    run.checkpoint = document.copy();

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

        session = &run;
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
        if (result.succeeded) {
            // What changed since the last step is the last one.
            Checkpoint(run, stepName);
            result.steps = run.steps;
        }
        session = nullptr;

        sys.attr("stdout") = savedOut;
        sys.attr("stderr") = savedErr;
        result.output = buffer.attr("getvalue")().cast<std::string>();
    }
    // Every Python object above is released (the block's end) before the GIL.
    mainThreadState = PyEval_SaveThread();
    return result;
}

} // namespace pybridge
