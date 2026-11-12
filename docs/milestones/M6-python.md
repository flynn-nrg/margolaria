# M6: Python

**Goal** (PLAN.md §8): make Margolaria scriptable in Python. That means an embedded interpreter; a Console tab as a Python REPL; a `margolaria` module (document, selection, commands, undo grouping) with PyMaterialX on the shared document; startup scripts and user commands in the command palette; and a command line. **Exit criterion:** a script can build a material and appear in the undo history as one step; the signed and notarized build still passes `spctl`.

**Result: met.** Checked two ways:
- **By `MargolariaModuleTests`** (M6b): a script builds a material from nothing (a surface shader, a material, a texture read and connected), and the document gains one undo step, named after the script. Undo gives back the document as it was before the script, and Redo as it was after. A script that raises leaves the document unchanged and adds no step.
- **By the user:** `docs/scripting/brick.py` run in the app and undone one step at a time ("Tint Bricks", then "Run brick.py") (M6b). The notarized build was accepted by Gatekeeper after each PR that changed the bundle. On 2026-11-12, after M6e, it was checked on a second Mac:

  ```
  $ spctl --assess --type execute -vv ~/Downloads/Margolaria.app
  /Users/mmendez/Downloads/Margolaria.app: accepted
  source=Notarized Developer ID
  origin=Developer ID Application: Miguel Mendez (XXXXXXXXX)
  ```

Each PR's own exit criterion is checked by a test:

| PR | Exit criterion | Test |
|---|---|---|
| M6a | A spike report; the notarized build runs a script that imports `MaterialX` and prints the open document's materials, and passes `spctl` | `docs/spikes/M6a-python.md`, `PythonTests`, and the user's check of the notarized build |
| M6b | M6's criterion (above); every `MXEdit` refusal comes to Python as an exception | `MargolariaModuleTests` |
| M6c | The criterion's script typed in the Console, line by line, builds the same material; Undo takes back one entry at a time | `ConsoleTests` |
| M6d | A command registered by a startup script appears in the palette and the menu, runs as one undo step, and an error in a startup script is reported without stopping the app | `CommandTests` (menu and palette checked by the user) |
| M6e | Running a script and each export from the command line gives the same files as the app; the tool works from the notarized build | `CommandLineToolTests` (USDZ compared by its contents, as zips record times), and the user's check of the notarized build |

Dates: 2026-11-08 (plan) to 2026-11-12. Six PRs: #50 (the M6 plan), #51 (M6a), #52 (M6b), #53 (M6c), #54 (M6d), #55 (M6e). The app and MargolariaKit grew from about 35,200 to 39,900 lines of Swift, C++ and Objective-C++, and from 257 to 299 test functions, all 42 new ones in ScriptKitTests. Two package targets are new: PythonBridge (C++, about 1,000 lines) and ScriptKit (Swift, about 1,500). Three build scripts (about 350 lines) are new too, along with `docs/SCRIPTING.md`, the scripting guide, and its three examples in `docs/scripting`.

## What was built

| PR | Scope | Main pieces |
|---|---|---|
| **M6a** (#51) | Spike: Python in the signed app | `scripts/fetch-python.sh` (Python-Apple-support 3.13, checked by SHA-256, thinned to arm64) · `scripts/build-pymaterialx.sh` (PyMaterialXCore and Format, built against SwiftUsd's MaterialX) · `scripts/embed-python.sh` (a build phase signing Python's 63 modules and 6 libraries with our identity) · `PythonBridge` and `ScriptKit` · File > Run Script… as one `edit` · `docs/spikes/M6a-python.md` |
| **M6b** (#52) | The `margolaria` module | The app's own `mx::Document` handed to Python as PyMaterialX's `Document` · the editor's edits (`add_node`, `connect`, `set_value`, ...), with `MXEdit`'s refusals as `EditRefused` · `with margolaria.edit("Name"):` blocks, each an undo step of its own · selection, `issues()`, the working space · USD, USDZ and shader export · `ScriptHost`, the Swift side's answers · undo restoring into the same object (`MXUndo`, MXBridge's `restoreContents`) · runs that change nothing add no step · compiled modules cached in `~/Library/Caches` · `docs/SCRIPTING.md`, with `brick.py` and `report.py` |
| **M6c** (#53) | Console tab | The bottom panel's Console (`PythonConsole`: a namespace per window, `codeop` for blocks, history), each entry that changes the document one "Console" undo step · scripts and entries on a worker thread (`ScriptRun`, 8 MB stack), with a Running sheet and Stop after 0.25 s · Run Script's output in the Console |
| **M6d** (#54) | Startup scripts and user commands | `StartupScripts`, run at launch with no document · `@margolaria.command("Title")`, run by title on the front window's document, one undo step named after it · the Scripts menu (the commands, Stop Script, Reload Startup Scripts, Open Scripts Folder), listed by the palette under "Scripts" · the user's site-packages (`site.addsitedir`, `.pth` files read) · `commands.py` |
| **M6e** (#55) | Command line | `CommandLineTool`, asked by `MargolariaApp.main` before AppKit starts: `margolaria run SCRIPT [FILE] [-o OUTPUT]`, `export usd`, `export usdz [--material]`, `export shader [--language] [--colorspace] [--oslc]`, `help`; exit statuses 0, 1 and 2 · `CommandLineTool.appBundle`, following the PATH's symbolic link back to the app · one export path for the app, the scripts and the command line (ScriptKit's `Export`, MXKit's `MXShaderExport.generate`) |

Margolaria can now be driven from a script, a console, its own menus and palette, or a pipeline's shell, and every way edits the document through the same layer as the UI.

## Decisions

The full list, with reasons, is in PLAN.md §8.7. The ones that shaped the code most:

1. **A spike first** (M6a). The criterion's second half depends on embedding and signing an interpreter and its native modules, which only a notarized build could tell. Python-Apple-support fitted as it was, with no fallback needed. Xcode signs only the framework's own binary, so the modules are signed by a build phase of ours.
2. **PyMaterialX on the app's own document, not a copy, and no `pxr`** (M6a, M6b). The bridge and PyMaterialX share one pybind11 type table, so `margolaria.document()` is the C++ object the window edits. Scripters get the MaterialX API they already know, and there's no second object model to keep in step. SwiftUsd can't be built with Python, so `pxr` waits.
3. **Undo comes for free** (M6a, M6b). A script, a Console entry or a command is one `edit`, which keeps a copy of the document before it (§8.1), so PyMaterialX's direct edits need no command layer. Undo copies the contents back into the same object, so a `doc` kept in the Console still works afterwards.
4. **Scripts run on a worker thread, one at a time** (M6c). The main thread waits up to 0.25 s, answering the script's calls to Swift as they come, so most runs feel synchronous. After that a Running sheet shows a copy of the document, and Stop raises `KeyboardInterrupt` in the script.
5. **Pure-Python packages only** (M6d). Native packages signed by someone else are refused by library validation. Margolaria keeps the Hardened Runtime's protection rather than add `disable-library-validation` (§7.1).
6. **Startup scripts have no document** (M6d). They set things up, mainly registering commands. A command runs later on the front window's document, so the window it is chosen in decides what it edits.
7. **The command line is the app's own executable** (M6e). Started with a subcommand, as Blender's `--background`, it is the notarized binary, with its frameworks and Python. There's no second target to embed, sign and keep in step.
8. **One export path** (M6e). The app's Export commands, the scripts' `export_*` and the command line call the same code. The scripts' `export_shader` used to generate from the raw document, so its files could differ from the Generated Shader tab's; it now generates from the preview document, as the tab does.

## Problems found and fixed (worth remembering)

| Where | Problem | Fix |
|---|---|---|
| M6a | Xcode's "Embed & Sign" signs only Python.framework's own binary; its modules kept ad hoc signatures, which library validation and notarization refuse | `embed-python.sh` signs each module, then the framework, before Xcode signs the app |
| M6a | The embed phase ran while Xcode was still copying the framework in, and failed on a half-copied `Versions/Current` | The phase names the embedded framework as its input |
| M6a | MaterialX trims pybind11, with no `embed.h` | `margolaria` is an ordinary `PYBIND11_MODULE`, registered with `PyImport_AppendInittab` before Python starts |
| M6b | On a build where nothing else changed, the phase re-signed the MaterialX package, so the app's seal no longer matched | The package is copied only when Vendor's has changed, only what isn't signed as it should be is signed, and the package is declared as the phase's output |
| M6b | A refused edit could leave behind an input it had added | MXBridge's `Perform` undoes it |
| M6c | pybind11's `gil_scoped_acquire` crashed on a worker thread | PythonBridge takes the GIL with `PyGILState` |
| M6c | Typing in the Console's field would have put the keystrokes on the document's undo stack | The field has its own field editor |
| M6d | `docs/scripting/commands.py` was in the user's Scripts folder but not in the repository, so `CommandTests`' example test failed on a clean checkout (found in M6e) | Added to the repository |
| M6e | Through a symbolic link, `Bundle.main` is the link's folder, so Python wasn't found | `CommandLineTool.appBundle` resolves the executable and goes up to the app |
| M6e | Release builds (whole-module, explicit modules) didn't let ScriptKit see MXDocument's `package init`, used in Python.swift since M6b, so archives failed; Debug builds and `swift test` accepted it | The init is internal; other modules call `MXDocument.sharingFile(with:)` |
| M6e | `export_usdz` with an unknown material silently used the first | It raises, naming the document's materials |

## Not done / open

These are kept for the UX polish pass after the initial milestones:

- **A USDZ warning.** `export usdz` of the tiled brass prints OpenUSD's "Failed to resolve reference @0/brass_color.jpg@" (`assetLocalization.cpp`), though both textures are in the package. The app's Export as USDZ… shares the code, so the warning comes from the export itself, not from the command line. Find which path it resolves wrongly, or silence it (M6e).
- **`scripts/release.sh` can fail at its start.** `rm -rf build/release` sometimes says "Directory not empty", and running the script again works. Something may still be writing into the folder (Spotlight, or the last build's processes). Retry the delete, or move the folder aside first and delete it later (M6e).
- **PyMaterialX's generator bindings** (GenShader, GenMsl, GenOsl) aren't built: `margolaria` exports shaders itself. Build them if a script needs them (M6a).
- **Left for later** (§8.7): `pxr` (with PyPI's `usd-core`, or a SwiftUsd built with Python if that becomes possible); native packages, together with third-party Hydra renderers, which need the same entitlement; the MCP server (§8, ideas), which will use the `margolaria` module's edits.
