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

#include <atomic>
#include <map>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <thread>

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
    /// The run's number, for interrupt().
    int64_t id = 0;
    /// The thread running the script, for interrupt().
    unsigned long threadId = 0;
    /// True while the script's own code runs: interrupt() raises
    /// KeyboardInterrupt in it then, and not while run() starts or ends it.
    bool interruptible = false;
};

/// The run in progress, set by run() for the duration of a script; null
/// otherwise, when the module's functions raise. Read and changed only by
/// a thread holding Python's global lock (the GIL), which is what keeps
/// run() and interrupt() from seeing it half-changed.
Session* session = nullptr;

/// Set once Python is running.
bool running = false;

/// Set if Python failed to start: it can't be started twice.
bool failed = false;

/// The Consoles' namespaces (M6c), by number: dictionaries of their
/// variables. Changed with the GIL held. Never freed, not even when the
/// app quits: freeing Python objects then, after Python's own state, would
/// crash.
std::map<int, py::object>* consoles = new std::map<int, py::object>();
int nextConsole = 1;

/// The number of the last run interrupt() was called for. Atomic, as it
/// is set without the GIL: a run that hasn't started its code yet finds it
/// as it does, however soon interrupt()'s thread gets the GIL.
std::atomic<int64_t> stopRequested{0};

/// A command a script registered (`@margolaria.command`, M6d): its title,
/// and the function run when it is chosen.
struct Command {
    std::string title;
    py::object function;
};

/// The commands registered, in the order they were first registered.
/// Changed with the GIL held, and never freed, as `consoles`.
std::vector<Command>* registered = new std::vector<Command>();

/// Their titles, also kept apart under a lock of their own, so the app can
/// read them without waiting for the GIL, which a script running a long
/// call into MaterialX may hold for a while.
std::mutex titlesLock;
mxbridge::StringVector titles;

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

/// The run's document, or a RuntimeError in a startup script, which has none.
mxbridge::Document& CurrentDocument() {
    Session& run = Current();
    if (!run.document.isLoaded()) {
        throw std::runtime_error("No document: startup scripts run before any is open. Register a command with "
                                 "@margolaria.command(\"Title\"): it runs on the document of the window it is "
                                 "chosen in.");
    }
    return run.document;
}

/// Registers `function` as the command `title`, replacing one registered
/// with that title before: a startup script run again, or a function
/// typed again in the Console.
void Register(const std::string& title, const py::object& function) {
    for (Command& command : *registered) {
        if (command.title == title) {
            command.function = function;
            return;
        }
    }
    registered->push_back(Command{title, function});
    std::lock_guard<std::mutex> lock(titlesLock);
    titles.push_back(title);
}

/// Holds Python's global lock (the GIL) for this thread while it exists,
/// on any thread: Python makes a state for a thread it hasn't seen, and
/// drops it after. Python's own API (PyGILState), not pybind11's
/// gil_scoped_acquire: that makes the state from pybind11's record of the
/// interpreter, which isn't set in ours, and crashed on a worker thread.
class Gil {
public:
    Gil() : _state(PyGILState_Ensure()) {}
    ~Gil() { PyGILState_Release(_state); }
    Gil(const Gil&) = delete;
    Gil& operator=(const Gil&) = delete;

private:
    PyGILState_STATE _state;
};

/// Raises EditRefused with MXBridge's message if the edit wasn't made.
void Check(bool made, const std::string& errorMessage) {
    if (!made) {
        throw EditRefused(errorMessage);
    }
}

/// Ends a step called `name` if the document changed since the last one.
void Checkpoint(Session& run, const std::string& name) {
    if (!run.document.isLoaded()) {
        return;
    }
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
    // Every call asks about the document, or its window.
    CurrentDocument();
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
        mxbridge::Document& document = CurrentDocument();
        Session& run = Current();
        if (run.blockStarts.empty()) {
            // What changed before the block is a step of its own.
            Checkpoint(run, run.stepName);
        }
        run.blockStarts.push_back(document.copy());
        return std::static_pointer_cast<mx::Document>(document.materialXDocument());
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
        []() { return std::static_pointer_cast<mx::Document>(CurrentDocument().materialXDocument()); },
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

    // --- Commands (M6d) ------------------------------------------------

    module.def(
        "command",
        [](const py::object& title) {
            // `@margolaria.command` without the title gets the function
            // here: say what's missing, rather than pybind11's message.
            if (!py::isinstance<py::str>(title)) {
                throw py::type_error("margolaria.command takes the command's title: @margolaria.command(\"Title\")");
            }
            std::string name = title.cast<std::string>();
            if (name.empty()) {
                throw py::value_error("A command needs a title.");
            }
            // The decorator itself: registers the function, and returns it
            // as it is, so it can still be called by name.
            return py::cpp_function([name](const py::object& function) {
                if (!PyCallable_Check(function.ptr())) {
                    throw py::type_error("@margolaria.command(\"" + name + "\") decorates a function.");
                }
                Register(name, function);
                return function;
            });
        },
        py::arg("title"),
        "@margolaria.command(\"Title\") registers the function below it as a command: listed in the Scripts "
        "menu and the command palette, and run, with no arguments, on the document of the window it is "
        "chosen in, its changes one undo step called Title. A command registered again with the same title "
        "replaces the first.");

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
            Check(CurrentDocument().addNode(parent, nodeDef, name, newPath, error), error);
            return newPath;
        },
        py::arg("nodedef"), py::arg("parent") = "", py::arg("name") = "",
        "Adds a node defined by nodedef (\"ND_image_color3\") to the graph at parent (\"\" for the document), "
        "with the nodedef's defaults, as the editor does; name is a hint, made unique. Returns its path.");

    module.def(
        "remove_node",
        [](const std::string& path) {
            std::string error;
            Check(CurrentDocument().removeNode(path, error), error);
        },
        py::arg("path"), "Removes a node or nodegraph, disconnecting everything that used it.");

    module.def(
        "rename_node",
        [](const std::string& path, const std::string& name) {
            std::string newPath, error;
            Check(CurrentDocument().renameNode(path, name, newPath, error), error);
            return newPath;
        },
        py::arg("path"), py::arg("name"),
        "Renames a node, nodegraph or backdrop, updating what refers to it. Returns its new path.");

    module.def(
        "change_nodedef",
        [](const std::string& path, const std::string& nodeDef) {
            std::string error;
            Check(CurrentDocument().changeNodeDef(path, nodeDef, error), error);
        },
        py::arg("path"), py::arg("nodedef"),
        "Changes a node to another type variant (\"ND_multiply_color3FA\"), keeping the inputs and "
        "connections whose types still fit.");

    module.def(
        "set_value",
        [](const std::string& path, const std::string& input, const py::object& value) {
            std::string error;
            Check(CurrentDocument().setInputValue(path, input, ValueText(value), error), error);
        },
        py::arg("path"), py::arg("input"), py::arg("value"),
        "Sets an input's value, disconnecting it if it was connected: a string as MaterialX writes it "
        "(\"0.8, 0.2, 0.1\"), a number, a bool, a tuple of numbers or a MaterialX value (MaterialX.Color3).");

    module.def(
        "reset_input",
        [](const std::string& path, const std::string& input) {
            std::string error;
            Check(CurrentDocument().resetInput(path, input, error), error);
        },
        py::arg("path"), py::arg("input"), "Removes an input, so the node uses its nodedef's default again.");

    module.def(
        "set_colorspace",
        [](const std::string& path, const std::string& input, const py::object& colorSpace) {
            std::string error;
            std::string space = colorSpace.is_none() ? "" : colorSpace.cast<std::string>();
            Check(CurrentDocument().setInputColorSpace(path, input, space, error), error);
        },
        py::arg("path"), py::arg("input"), py::arg("colorspace"),
        "Sets an input's colorspace (None removes it), leaving its value as it is.");

    module.def(
        "connect",
        [](const std::string& path, const std::string& input, const std::string& source, const py::object& output) {
            std::string error;
            std::string outputName = output.is_none() ? "" : output.cast<std::string>();
            Check(CurrentDocument().connectInput(path, input, source, outputName, error), error);
        },
        py::arg("path"), py::arg("input"), py::arg("source"), py::arg("output") = py::none(),
        "Connects input of the node at path to the node or nodegraph source in the same graph (its output, "
        "if it has several). For an <output> element, input is \"\". Refused if the types differ, if it would "
        "make a loop, or if the input is uniform.");

    module.def(
        "connect_interface",
        [](const std::string& path, const std::string& input, const std::string& interface) {
            std::string error;
            Check(CurrentDocument().connectInterface(path, input, interface, error), error);
        },
        py::arg("path"), py::arg("input"), py::arg("interface"),
        "Connects an input inside a nodegraph to one of the graph's own inputs.");

    module.def(
        "disconnect",
        [](const std::string& path, const std::string& input) {
            std::string error;
            Check(CurrentDocument().disconnectInput(path, input, error), error);
        },
        py::arg("path"), py::arg("input"),
        "Disconnects an input (or an <output>, with input \"\"). A node's input with no value of its own is "
        "removed, so the node uses its default.");

    module.def(
        "set_position",
        [](const std::string& path, float x, float y) {
            std::string error;
            Check(CurrentDocument().setPosition(path, x, y, error), error);
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
        [](const py::object& path) { return CallHost("export_usd", {PathText(path)}); },
        py::arg("path"),
        "Writes the document's materials as USD (.usda, .usdc or .usd), as File > Export as USD. A relative "
        "path is relative to the document's folder. Returns the textures outside the file's folder, which it "
        "refers to by absolute path (empty when every texture is beside the file or inside its folder).");

    module.def(
        "export_usdz",
        [](const py::object& path, const py::object& material, const std::string& shape) {
            CallHost("export_usdz",
                     {PathText(path), material.is_none() ? "" : material.cast<std::string>(), shape});
        },
        py::arg("path"), py::arg("material") = py::none(), py::arg("shape") = "sphere",
        "Writes a USDZ package for Quick Look and Reality Composer Pro, as File > Export as USDZ: shape "
        "(sphere, plane, cylinder, cloth or shader_ball) with material (by name; the first if None), the other "
        "materials, and every texture.");

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
    // Python starts with this thread holding the GIL. Release it: run()
    // takes it on whichever thread runs a script (Gil).
    PyEval_SaveThread();
    return true;
}

bool Interpreter::isRunning() {
    return running;
}

bool Interpreter::addSitePackages(const std::string& folder, std::string& errorMessage) {
    if (!running) {
        errorMessage = "Python isn't running.";
        return false;
    }
    Gil gil;
    try {
        py::module_::import("site").attr("addsitedir")(folder);
        return true;
    } catch (py::error_already_set& error) {
        errorMessage = error.what();
        return false;
    }
}

std::string Interpreter::version() {
    if (!running) {
        return "";
    }
    Gil gil;
    return py::module_::import("sys").attr("version").cast<std::string>();
}

RunResult Interpreter::run(const std::string& code, const std::string& filename, const std::string& stepName,
                           int console, const std::string& command, int64_t runID, const mxbridge::Document& document,
                           HostFunction host, void* hostContext) {
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
    if (document.isLoaded()) {
        run.checkpoint = document.copy();
    }

    // Take the GIL for this thread: start() released it.
    Gil gil;
    if (session) {
        result.output = "Another script is running.";
        return result;
    }
    if (console != 0 && consoles->count(console) == 0) {
        result.output = "This Console was closed.";
        return result;
    }

    py::module_ sys = py::module_::import("sys");
    py::module_ builtins = py::module_::import("builtins");
    // What the script prints goes into a string, not the app's stdout;
    // input() finds nothing to read, and raises EOFError, rather than
    // waiting for the app's stdin.
    py::object buffer = py::module_::import("io").attr("StringIO")();
    py::object savedOut = sys.attr("stdout");
    py::object savedErr = sys.attr("stderr");
    py::object savedIn = sys.attr("stdin");
    sys.attr("stdout") = buffer;
    sys.attr("stderr") = buffer;
    sys.attr("stdin") = py::module_::import("io").attr("StringIO")();

    run.id = runID;
    run.threadId = PyThread_get_thread_ident();
    session = &run;
    // The exception the script raised, if any.
    std::optional<py::error_already_set> raised;
    try {
        // PyMaterialX first: it registers the Document class, which
        // margolaria.document() needs to return one.
        py::module_::import("MaterialX");

        // The command's function, found before the script can be stopped:
        // a title that isn't registered is reported without running.
        py::object function;
        if (!command.empty()) {
            for (const Command& registeredCommand : *registered) {
                if (registeredCommand.title == command) {
                    function = registeredCommand.function;
                }
            }
            if (!function) {
                throw std::runtime_error("No command called " + command + ": the script that registered it may "
                                         "have changed. Reload the startup scripts.");
            }
        }

        // The namespace the code runs in. (A command's function has its
        // own: its module's.)
        py::object globals;
        if (console != 0) {
            globals = consoles->at(console);
        } else if (!function) {
            py::dict fresh;
            fresh["__name__"] = "__main__";
            fresh["__file__"] = filename;
            fresh["__builtins__"] = builtins;
            globals = fresh;
        }
        // compile() then exec(), rather than py::exec, so tracebacks
        // name the script's file and lines. A Console's entry is compiled
        // as Python's console compiles one ("single"): the value of an
        // expression is printed (sys.displayhook), and kept as `_`.
        run.interruptible = true;
        if (stopRequested == runID) {
            // Stopped before it started: raised as its first line runs.
            PyThreadState_SetAsyncExc(run.threadId, PyExc_KeyboardInterrupt);
        }
        if (function) {
            function();
        } else {
            py::object compiled = builtins.attr("compile")(code, filename, console != 0 ? "single" : "exec");
            builtins.attr("exec")(compiled, globals);
        }
        result.succeeded = true;
    } catch (py::error_already_set& error) {
        raised.emplace(std::move(error));
    } catch (const std::exception& error) {
        // A C++ exception outside Python's (pybind11 converts those
        // raised inside a call): reported like a Python error.
        buffer.attr("write")(std::string("Error: ") + error.what() + "\n");
    }
    // The script has ended: interrupt() mustn't raise in what follows, and
    // a KeyboardInterrupt it raised too late to land is dropped.
    run.interruptible = false;
    PyThreadState_SetAsyncExc(run.threadId, nullptr);

    if (raised) {
        // sys.exit() ends the script, not the app; exit(0) and exit()
        // count as success.
        if (raised->matches(PyExc_SystemExit)) {
            py::object exitCode = raised->value().attr("code");
            result.succeeded = exitCode.is_none()
                || (py::isinstance<py::int_>(exitCode) && exitCode.cast<int>() == 0);
        } else {
            result.interrupted = raised->matches(PyExc_KeyboardInterrupt);
            py::module_::import("traceback").attr("print_exception")(raised->value());
        }
        raised.reset();
    }
    if (result.succeeded) {
        // What changed since the last step is the last one.
        Checkpoint(run, stepName);
        result.steps = run.steps;
    }
    session = nullptr;

    sys.attr("stdout") = savedOut;
    sys.attr("stderr") = savedErr;
    sys.attr("stdin") = savedIn;
    result.output = buffer.attr("getvalue")().cast<std::string>();
    return result;
}

void Interpreter::interrupt(int64_t runID) {
    if (!running) {
        return;
    }
    // For a run that hasn't started its code yet.
    stopRequested = runID;
    // For one that has: on a thread of its own, as taking the GIL waits
    // until the script's thread lets go of it, which Python does every few
    // milliseconds, but not during a long call into C++. The caller (the
    // main thread) mustn't wait for that.
    std::thread([runID] {
        Gil gil;
        // Still running its code? (Or it hasn't started, or has ended.)
        if (session && session->id == runID && session->interruptible) {
            // Raised when that thread next runs a line of Python.
            PyThreadState_SetAsyncExc(session->threadId, PyExc_KeyboardInterrupt);
        }
    }).detach();
}

int Interpreter::openConsole() {
    if (!running) {
        return 0;
    }
    Gil gil;
    py::dict globals;
    globals["__name__"] = "__main__";
    globals["__builtins__"] = py::module_::import("builtins");
    try {
        // As a Console in Houdini or Maya starts with `hou` or `cmds`.
        py::module_::import("builtins").attr("exec")("import MaterialX as mx\nimport margolaria\n", globals);
    } catch (py::error_already_set&) {
        // The entries' own imports will show what's wrong.
    }
    int console = nextConsole++;
    (*consoles)[console] = globals;
    return console;
}

void Interpreter::closeConsole(int console) {
    if (!running) {
        return;
    }
    Gil gil;
    consoles->erase(console);
}

mxbridge::StringVector Interpreter::commands() {
    std::lock_guard<std::mutex> lock(titlesLock);
    return titles;
}

void Interpreter::clearCommands() {
    if (!running) {
        return;
    }
    Gil gil;
    // The functions go, with the GIL held, as they are Python objects.
    registered->clear();
    std::lock_guard<std::mutex> lock(titlesLock);
    titles.clear();
}

EntryState Interpreter::checkEntry(const std::string& source, const std::string& filename, std::string& errorMessage) {
    if (!running) {
        errorMessage = "Python isn't running.";
        return EntryState::invalid;
    }
    Gil gil;
    try {
        // None for the start of a statement; the compiled code otherwise.
        py::object compiled = py::module_::import("codeop").attr("compile_command")(source, filename, "single");
        return compiled.is_none() ? EntryState::incomplete : EntryState::complete;
    } catch (py::error_already_set& error) {
        // SyntaxError, or ValueError and OverflowError for a bad literal:
        // the lines it names, with a caret, and the message.
        py::object lines = py::module_::import("traceback").attr("format_exception_only")(error.value());
        errorMessage = py::str("").attr("join")(lines).cast<std::string>();
        return EntryState::invalid;
    }
}

} // namespace pybridge
