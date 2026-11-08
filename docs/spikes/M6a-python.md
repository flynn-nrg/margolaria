# Spike M6a: Python in the signed app

**Question** (PLAN.md §8.7, M6a): can Margolaria embed Python 3.13 and MaterialX's Python bindings, run a script on the open document, and still sign, notarize and pass `spctl`? Where should Python come from, how are its modules signed, and what does it cost in size and launch time?

**Answer: yes, with one build step of our own.** Checked on the notarized build. BeeWare's Python-Apple-support embeds as it is, once thinned to arm64. PyMaterialX builds from MaterialX 1.39.5's sources against SwiftUsd's MaterialX in 14 seconds. A script gets the app's own document, the same C++ object, and changes it in place, as one undo step. Xcode signs Python.framework's binary but not the 63 compiled modules and 6 libraries inside it, so a build phase (`scripts/embed-python.sh`) signs them with our identity. With that, `codesign --verify --deep --strict` passes on the Debug app. Python adds 42 MB to the app, starts in about 8 ms, and imports MaterialX in about 15 ms; it starts only when a script first runs.

**Checked by the user** (2026-11-08), in a Debug run from Xcode: File > Run Script… with `add_brick.py` adds the material. The graph, XML tab, viewport and Issues ("Valid") show it, and its nodes are laid out as the editor's are. One Undo, "Run add_brick.py", takes all of it away.

**Checked by the user** (2026-11-08), on the notarized build from `scripts/release.sh`, which passes `spctl`: Run Script… with `list_materials.py` on `Car_Paint.mtlx` printed "Python 3.13.17, MaterialX 1.39.5" and the document's one material. That is the second half of M6's exit criterion.

Date: 2026-11-08. Python 3.13.17 (Python-Apple-support 3.13-b18), MaterialX 1.39.5 and pybind11 3.0.1 (from MaterialX's sources), SwiftUsd 8.1.0, macOS 27.0.1 on arm64.

## What was built

- **`scripts/fetch-python.sh`**: downloads Python-Apple-support's macOS package (checked against its SHA-256) into `Vendor/Python/Python.xcframework`. It keeps arm64 only, and removes the standard library's tests, CPython's own test modules, the `python3` executables and the framework's `Python.app`.
- **`scripts/build-pymaterialx.sh`**: builds PyMaterialXCore and PyMaterialXFormat, with MaterialX's own Python files, into `Vendor/PyMaterialX/site-packages/MaterialX`. It also copies the pybind11 headers it used to `Vendor/PyMaterialX/include`, for the bridge.
- **`scripts/embed-python.sh`**: the app's last build phase (project.yml). It copies the MaterialX package to `Contents/Resources/Python/site-packages`, then signs every `.so` and `.dylib` in it and in Python.framework with the app's identity and the Hardened Runtime (with a secure timestamp in Release), and the framework after them.
- **`PythonBridge`** (C++): starts the interpreter and runs scripts, capturing what they print and their tracebacks. It provides `margolaria.document()`, a module compiled into the app.
- **`ScriptKit`** (Swift): `Python.start(from:)` and `Python.run(_:named:on:)` on an `MXDocument`.
- **`MXBridge`**: `Document::materialXDocument()`, so the bridge can reach the `mx::Document` without MXBridge.h including MaterialX. `MXDocument.handle` became `package`, so ScriptKit can pass it.
- **File > Run Script…** (`MaterialXDocument.runScript`): runs a `.py` on the document inside `edit("Run <name>")`. Its output is shown in a sheet, and a traceback as the error.
- **`Spikes/M6aPython`**: `list_materials.py` prints the versions and the document's materials. `add_brick.py` adds a material: an `open_pbr_surface` whose roughness reads a checkerboard.
- **`PythonTests`** (ScriptKitTests, 6 tests):
  - Python 3.13 starts and imports MaterialX 1.39.5.
  - A script builds a material in the `MXDocument` it is given.
  - The spike's two scripts run, and what they build validates.
  - Tracebacks name the script and line.
  - `sys.exit()` ends only the script.
  - A function kept from one run reaches the next run's document.

## Findings

1. **Python-Apple-support fits as it is.** It is python.org's build, made relocatable, packaged as an xcframework with the standard library inside the framework (`Versions/3.13/lib/python3.13`). Every binary links only `@rpath/Python.framework/...` and the system. Python starts from it with an isolated configuration whose `home` is `Versions/3.13`, and a Python installed on the Mac can't affect it. Its `VERSIONS` file says 3.13.18, but the headers and `sys.version` say 3.13.17; the binaries are what counts.
2. **Size.** The download is 97 MB, for both architectures. Thinned to arm64 and without the tests, the framework is 37 MB in the app. The MaterialX package adds 5 MB.
3. **Launch time: none until used.** Python starts on the first Run Script, in about 8 ms, and `import MaterialX` takes about 15 ms more (a small C program on the same files, three runs). Python 3.13 freezes its startup modules into the binary, so the missing `.pyc` files don't slow it down. `write_bytecode` is off, as `.pyc` files would be written inside the signed bundle (§7.1). Every other standard-library module is compiled from source on its first import in each run. For M6b: a `pycache_prefix` in `~/Library/Caches/eu.emerald-isle.margolaria/`.
4. **Xcode signs only the framework's own binary.** Python.framework embeds as a package binary target, like OpenColorIO. Xcode's "Embed & Sign" signs `Versions/3.13/Python` and seals the rest as resources, so the modules in `lib-dynload` and OpenSSL's libraries kept `fetch-python.sh`'s ad hoc signatures. Library validation refuses ad hoc code under the Hardened Runtime, and notarization refuses the app. `embed-python.sh` signs each module, then the framework, before Xcode signs the app. Every module in the Debug app now carries our Team ID and the runtime flag, and `codesign --verify --deep --strict` passes. The phase must name the embedded framework as its input. Without one, Xcode ran it while it was still copying the framework in, and the build failed on a half-copied `Versions/Current` (the user's first Xcode build; the command line had happened to finish the copy first). Xcode signs the embedded frameworks in one batch after the phase. That re-signs Python.framework's binary and seals the signed modules as they are. *Found in M6b:* on a build where nothing else changed, Xcode doesn't sign the app again, but the phase re-copied the MaterialX package and re-signed it, so the app's seal no longer matched (`codesign --verify` failed after a second build). The phase now copies the package only when Vendor's has changed and signs only what isn't signed as it should be, and it declares the package as its output, so Xcode signs the app again whenever it ran.
5. **PyMaterialX from source, like MaterialXGenOsl.** The bindings compile with the flags MaterialX's CMake uses, against SwiftUsd's headers. They link only `@rpath/MaterialXCore` and `MaterialXFormat`, and leave Python's symbols to the interpreter that loads them (`-undefined dynamic_lookup`). Their rpath points at the app's `Contents/Frameworks`. In tests that folder doesn't exist, but dyld uses the MaterialX frameworks already loaded by the test process, as they have the same install names. Only Core and Format are built so far: the generators' bindings (GenShader, GenMsl, GenOsl) can wait until a script needs them, since `margolaria` will export shaders itself.
6. **The document is shared, not copied.** `margolaria.document()` returns the `mx::DocumentPtr` inside the app's `MXDocument`, and pybind11 presents it as PyMaterialX's `Document`. That works because the bridge and PyMaterialX are compiled with the same pybind11 headers and compiler, so they share pybind11's type table in the interpreter. A script's `addNode` changes the app's document, which `MXDocument` then reads (test "builds a material").
7. **MaterialX's pybind11 has no `embed.h`.** MaterialX trims pybind11 to what extension modules need. The `margolaria` module is an ordinary `PYBIND11_MODULE`, registered as a built-in module with `PyImport_AppendInittab` before Python starts. That is all `embed.h` would have done.
8. **One undo step for free** (checked in the app by the user). Run Script… calls the script inside `edit`, which keeps a copy of the document before it (§8.1). The whole script is one step, "Run add_brick.py", and a script that raises leaves the document as it was. No command layer was needed for PyMaterialX's own edits, as the plan expected.
9. **Questions for M6b**, which the spike didn't need to answer:
   - **References kept across an undo.** Undo replaces `MXDocument`'s handle, so a PyMaterialX object kept from an earlier run (in a module's global, or in the Console) still points at the old document. `margolaria.document()` always returns the current one: a kept *function* reaches the next run's document (tested). M6b decides whether undo should copy into the same object instead.
   - **A run that changes nothing** still registers an undo step, and marks the document edited (`list_materials.py`, seen on the notarized build). M6b compares the document before and after.
   - **Long scripts** block the main thread, and nothing can interrupt them yet.
   - **The GIL is released** between runs, so a later Console, or a background thread, can take it.

## Decisions settled

- **Where Python comes from** (§8.7, "to settle in M6a"): Python-Apple-support, pinned by build and SHA-256 in `scripts/fetch-python.sh`. No fallback needed.
