# Margolaria — Plan

*Margolaria* is Basque for "painter". It is a native macOS tool for authoring MaterialX materials.

Status: planning (session 1, 2026-10-11). No code yet.

![Main window mockup](mockup/margolaria-mockup.png)

---

## 1. Goals

- Author, edit and validate MaterialX documents (`.mtlx`) in a node graph, with a live, accurate preview.
- Feel like a real Mac app: SwiftUI/AppKit, Metal rendering, document-based, undo, Quick Look later.
- Don't reinvent the wheel. MaterialX, OpenUSD, OpenColorIO and OpenImageIO are used through their existing C/C++ libraries (via Swift–C++ interop) or through Apple frameworks where they already exist.
- Round-trip safely. Opening and saving a document must not lose attributes, comments-as-data, `colorspace`, `channels`, custom nodedefs or unknown elements.
- **Built for power users.** The intended user is a **technical artist (TD)**: someone who knows MaterialX, USD and shading, reads `.mtlx` and shader code, and works with pipelines. The tool should make them faster, not shield them from the technology (see §1.1).
- **Learn Swift while building it.** This is the author's first Swift project; their background is C, C++, Go and Objective-C. Every line of Swift will be read and reviewed, and sometimes changed by hand. So the code is deliberately **over-commented**, as a teaching aid (see §6).
- **Ship a properly signed app.** From the first runnable build, the app is signed with the author's Apple Developer certificate, uses the Hardened Runtime, and can be notarized for distribution outside the App Store (see §7).

**Non-goals (for now):** texture painting, mesh editing, a full scene/layout tool, Windows/Linux, and a simplified "beginner mode".

### 1.1 Audience: the technical artist

What "power user" means for design decisions:

- **Show the real MaterialX concepts, without simplified names.** The UI uses the spec's terms: nodedef, nodegraph, interface input, `colorspace`, `channels`, look, `materialassign`. Node and input names are the real ones (`specular_roughness`, not "Shininess"). A friendly label can be shown *alongside* the real name, but never instead of it.
- **Nothing hidden, everything inspectable.** Every attribute in the document can be seen and edited, including ones the UI doesn't understand yet; those get a generic attribute editor. The XML, the generated shader, validation output and the resolved nodedef are each one click away.
- **Keyboard-first.** Every command is in the command palette (⌘K) and can be rebound. Common graph edits never require the mouse.
- **Precision over guesswork.** Values can be typed, not only scrubbed, and accept expressions like `0.5*2`. Colours show their numbers and colour space. The preview reports render time and which shader was generated.
- **Predictable and diffable files.** Output `.mtlx` is stable: attributes keep their order and the document is not reformatted unnecessarily, so files diff cleanly in git and survive review.
- **Scriptable in Python.** This is what technical artists already know from Blender, Houdini, Maya and Nuke. There is an embedded Python console, a `margolaria` module for scripting the app, and the standard `MaterialX` (PyMaterialX) and `pxr` modules. A command-line companion (`margolaria validate|upgrade|bake|export`) shares the same core library as the app.
- **Dense but tidy UI.** Show plenty of information on screen, like the mockup. Panels can be docked and collapsed, and layouts can be saved per task.

## 2. What exists today (research summary)

| Tool | Kind | What it does well | Gaps / lessons |
|---|---|---|---|
| **MaterialX Graph Editor** (ASWF, ships with MaterialX) | Reference app, ImGui + imgui-node-editor | Loads and saves `.mtlx`; Tab-to-add with search; dives into nodegraphs (double-click, `U` to exit); type-coloured pins; background "group" nodes; property panel; shader-ball render view | Dev-tool UX. Can't create new `channels` connections or assign `colorspace`. No per-node previews. Not native. |
| **QuiltiX** (Prism Pipeline, Python/Qt, Apache-2.0) | Standalone editor | Node graph plus a **Hydra viewport**, so any Hydra delegate (Storm, Arnold, Karma) can preview; plugin hooks; custom nodedefs | Python/Qt; generic look. Its Hydra-based viewport is the approach to copy. |
| **Autodesk LookdevX** (Maya, and inside USD workflows) | DCC-embedded | **Per-node swatches** that update in real time; compounds; promote/demote attributes to the graph interface with a right-click; the Tab menu shows the source library; color-managed colour pickers; keeps a link to the `.mtlx` on disk so edits save back | Lives inside Maya. The best reference for UX polish. |
| **Houdini Solaris / Karma Material Builder** | DCC-embedded (VOPs) | MaterialX VOPs that translate to UsdShade automatically; promoted parameters organised into folders | Houdini-specific concepts (subnets, VOP contexts). Folders for promoted parameters are a good idea. |
| **Reality Composer Pro: Shader Graph** (Apple) | Native macOS | Native look; authors MaterialX inside USD; RealityKit-specific nodes; graph sits in a bottom editor pane with an Inspector on the right | **No per-node previews** (a known complaint). Tied to RealityKit. Closest to "native Mac" in feel. |
| **Substance 3D Designer** (Adobe) | Procedural texture authoring | Dockable Explorer / Graph / Properties / **2D view** / **3D view** / Library layout; multiple 2D views can each show any node's output | Not MaterialX-native. Its panel layout is the industry convention and users know it. |
| **Connecter** (macOS asset manager) | Asset browser with a MaterialX graph editor | Proves there is demand for MaterialX on the Mac; preview in an asset browser | Editing is a secondary feature. |
| **Blender / Unity Shader Graph** | General node editors | Unity: per-node previews. Blender: node frames, reroutes, Ctrl+Shift-click to preview a node (Node Wrangler add-on) | Not MaterialX-native. These are good interaction references. |

### Takeaways that shape the design

1. **The standard layout works:** library on the left, graph in the centre, viewport and inspector on the right, and a dockable bottom panel. Users of every tool above will feel at home.
2. **Per-node previews are the most-wanted missing feature** (RCP lacks them; LookdevX and Unity have them). MaterialX shader generation can produce a shader for *any* output, so we can render a small swatch per node.
3. **Use Hydra for the main viewport** (as QuiltiX does) so previews match what USD pipelines render. Storm on Metal is the default.
4. **Tab-to-add with fuzzy search** is universal. Make it type-aware: when you drag off a pin, show only compatible nodes.
5. **Promote to interface** (LookdevX, Houdini) is how users build reusable materials and custom nodedefs. Make it a first-class gesture.
6. **The text view matters.** MaterialX is human-readable XML. A live, two-way XML view is an advantage no current tool has.
7. **Validation should be visible**: an issue list plus inline badges on nodes. The reference editor's silent failures are a pain point.

## 3. Technology stack

All of the following was verified on 2026-10-11.

| Concern | Choice | Notes |
|---|---|---|
| Language / UI | Swift 6; AppKit app and documents, SwiftUI inside the windows | AppKit `NSDocument` (`MaterialXDocument`) for `.mtlx`, hosting SwiftUI views. **Changed in M1a** from SwiftUI's `DocumentGroup`/`ReferenceFileDocument`, which only gives a document the file's contents: MaterialX needs the file's location for `xi:include` and relative texture paths. NSDocument also brings autosave, versions, Revert To and the undo manager M2 needs. The `.mtlx` type is Apple's `io.aswf.materialx` (declared by macOS 27). |
| OpenUSD (+ Hydra, Storm, HgiMetal) | **[apple/SwiftUsd](https://github.com/apple/SwiftUsd)** 8.1.0 (OpenUSD **v26.08**, released 2026-08-03) | SwiftPM, through a local copy patched to skip SwiftUsd's Swift overlay, which we don't use (`scripts/fetch-swiftusd.sh`). Requires Swift–C++ interop and GNU++17. Ships HdStorm, HgiMetal, UsdImaging, OpenSubdiv, OpenEXR, Embree. Apache-2.0. |
| MaterialX | **MaterialX C++ as bundled in SwiftUsd**: Core, Format, GenShader, GenGlsl, **GenMsl**, Render, RenderHw, RenderGlsl xcframeworks | SwiftUsd does **not** include MaterialXRenderMsl, GenOsl or GenMdl. **Spike:** check that the MaterialX headers are reachable from Swift through SwiftUsd, and which MaterialX version it bundles (OpenUSD ≥ 25.05 defaults to 1.39). Fallback: our own xcframework of MaterialX 1.39.4 built at the same version as SwiftUsd's. |
| Shader generation for previews | MaterialX **MslShaderGenerator** + our own small Metal renderer for node swatches | The main viewport uses Hydra/Storm, which already runs MaterialX codegen internally. |
| Color management | **OpenColorIO** (C++), built as an xcframework | Needed for colour pickers, the viewport view transform and texture colour spaces. Not in SwiftUsd. Default config: ACES 2.0 studio. |
| Image I/O | **Apple ImageIO** first (handles EXR, PNG, JPEG, TIFF, HEIC), then **OpenImageIO** (C++) when we need `.tx`, tiled or mip-mapped files, or UDIMs | SwiftUsd's Hio already reads images for Hydra. Note: the Swift package called "OpenImageIO" (1amageek) is an unrelated pure-Swift codec library, **not** OIIO. |
| Graph canvas | Custom view: AppKit `NSView` + Core Animation, one layer per node (chosen in spike M0d over SwiftUI `Canvas` and Metal) | Must handle about 500 nodes at 120 fps, plus hit testing, marquee selection and wire routing |
| Text view | AppKit `NSTextView` (TextKit 2) with XML highlighting | Two-way sync with the graph |
| Scripting | **Embedded CPython 3.x** as a relocatable, signable `Python.framework`, for example from BeeWare's Python-Apple-support or a python.org build. PyMaterialX and USD's `pxr` are built against the **same** MaterialX and USD binaries the app uses. Our own `margolaria` module is bound with pybind11 or nanobind. | The same binaries are required so that Python and Swift operate on the *same* `mx::Document` in memory, not on copies. **Spike:** SwiftUsd does not appear to ship Python bindings, so we may have to build USD and MaterialX with Python enabled ourselves. |
| Build | Xcode project plus SwiftPM local packages; xcframeworks for the C++ dependencies | We can use SwiftUsd's own scripts as the template for building OCIO and OIIO |

Also worth watching: [wabiverse/SwiftUSD](https://github.com/wabiverse) is a community fork on top of apple/SwiftUsd, with a "HydraKit" Metal viewport that does picking and selection outlines. It may save work on the viewport. Evaluate it, but don't depend on it yet.

## 4. Interface design

See `docs/mockup/margolaria-mockup.png`. The source is `margolaria-mockup.svg`, regenerated by `generate_mockup.py`.

### 4.1 Window regions

1. **Toolbar.** Document title. View mode: **Graph / Split / Text**. Validation status pill. Preview renderer picker (Storm·Metal, or any installed Hydra delegate). Shader target picker (MSL/GLSL/OSL/MDL/Slang/WGSL, for the shader panel and export). Export menu (`.mtlx`, `.usda`/`.usdz` with UsdShade + MaterialX, baked textures later). Add-node button. Inspector toggle. Command palette (⌘K).
2. **Left sidebar** has two tabs:
   - **Document**: outline of materials, node graphs, looks/assignments and custom nodedefs. Each entry shows its shading model and has an issue badge.
   - **Library**: searchable node library grouped like the MaterialX stdlib (PBR, Texture, Procedural, Geometry, Math, Adjustment, Compositing, Conditional, Channel, Organization), followed by project and user nodedefs. Drag nodes onto the canvas.
3. **Graph canvas** (centre):
   - A breadcrumb bar for nested nodegraphs, plus Auto-layout, Frame and Previews toggles.
   - Nodes have a coloured header by category and a **live thumbnail**. Pins are coloured by MaterialX type (float, color3, vector2/3/4, surfaceshader, material, filename/string…). Unconnected inputs show their value inline. Uncommon inputs are collapsed into a "+N more inputs" row.
   - Backdrops (comment frames) for grouping, minimap, zoom indicator.
   - **Tab / drag-off-pin popup**: fuzzy search that shows type signatures and the source library. ⌥↩ inserts the node and connects it.
4. **Viewport** (top right): Hydra/Storm on Metal. Geometry: Sphere / Shaderball / Plane / custom mesh. Environment (HDRI) picker. OCIO view transform. Render time. Click any node to "solo" it (a temporary preview of that node's output).
5. **Inspector** (right): the selected node's name, category and nodedef, with a Docs link. Inputs are grouped by the nodedef's `uifolder` (for OpenPBR: Base, Specular, Transmission, Subsurface, Coat, Fuzz, Thin Film, Emission, Geometry). Widgets are chosen by type and `uimin`/`uimax`/`enum`: sliders, colour wells with colour-space labels, enum menus, file pickers. Connected inputs show their source and can be clicked to jump to it. ⌥-drag an input to promote it to the material or nodegraph interface.
6. **Bottom panel** (collapsible tabs):
   - **XML**: two-way synced text, with the selected node highlighted.
   - **Generated Shader**: source for the chosen target.
   - **Issues**: output of `Document::validate()` plus our own lint checks, for example a colour space on vector data or a missing file.
   - **Console**.
7. **Status bar**: MaterialX and OpenUSD versions, OCIO config, working space, graph statistics.

### 4.2 Key interactions

| Action | Gesture |
|---|---|
| Add node | Tab or right-click on the canvas; or drag off a pin (filtered to compatible types); or drag from the Library |
| Connect / disconnect | Drag pin to pin; ⌥-drag a wire to detach it; drop a node onto a wire to insert it |
| Enter / exit nodegraph | Double-click / `U` or breadcrumb (matches the MaterialX Graph Editor) |
| Frame selection / all | `F` / `A` |
| Solo-preview a node | ⌥-click the node's thumbnail (Blender's Ctrl+Shift-click idea) |
| Group | ⌘G puts the selection in a backdrop; ⌥⌘G collapses it into a nodegraph |
| Promote input | ⌥-drag it to the graph edge, or right-click → Promote |
| Command palette | ⌘K (every menu command, plus node search) |
| Undo / redo | ⌘Z / ⇧⌘Z: full history, including value scrubs coalesced into one step |

### 4.3 Visual language

- Follow macOS dark and light appearance. Use SF Pro for text and SF Mono for values and code. The mockup is drawn in dark mode.
- MaterialX type colours are consistent everywhere: pins, wires, inspector link chips and the XML view.
- Category colours appear only in node headers, and they are muted, so selection (accent blue) and errors (red) stand out.

## 5. Architecture sketch

```
Margolaria.app (SwiftUI)
 ├─ DocumentModel      Swift wrapper over mx::Document; the single source of truth; all edits are commands (undo)
 ├─ GraphLayout        node positions (stored as MaterialX xpos/ypos attributes, as the Graph Editor does)
 ├─ NodeLibrary        loads stdlib + pbrlib + project/user nodedefs; search index
 ├─ Validation         mx validate() + our own lint rules → Issues
 ├─ PreviewService     per-node swatches: MslShaderGenerator → Metal pipeline cache → offscreen renders
 ├─ Viewport           Hydra (UsdImaging + HdStorm/HgiMetal) of a generated USD stage that references the .mtlx
 ├─ ColorService       OCIO config, colour pickers, view transforms
 ├─ Scripting        embedded CPython; `margolaria` module exposes the same commands the UI uses (undoable)
 └─ UI                 Sidebar · GraphCanvas · Inspector · BottomPanel(XML/Shader/Issues) · Viewport
```

Principles:
- **Every edit is a command.** The UI and Python call the same command layer, which makes Python scripting possible without a rewrite. That's why M2's undo design already has to account for M6.
- **mx::Document is the model.** We never keep a parallel graph representation that could drift from it. UI state lives in views, and layout lives in `xpos`/`ypos`.
- **All C++ goes through a thin Swift layer** (`MXKit`), so the rest of the app is plain Swift.
- **Previews run off the main thread and can be cancelled.** Compiled pipelines are cached by a hash of the generated shader.

## 6. Learning Swift: code and commenting conventions

The code is written for a reader who knows C, C++, Go and Objective-C well and is new to Swift. That changes the usual trade-offs: comments that would be noise in a team of Swift veterans are what we want here.

### 6.1 Commenting rules

1. **Every file starts with a header comment.** It says what the file is for, where it fits in the architecture (§5), and which Swift concepts appear in it *for the first time*, for example "introduces: `struct` vs `class`, `guard let`".
2. **Every type, property and function has a `///` doc comment.** These show up in Xcode's Quick Help (⌥-click), which is a good habit to learn.
3. **Comment the language, not just the logic.** The first time a Swift construct appears in a file, explain what it does, even if it seems obvious. Where it helps, compare it to C/C++, Go or Objective-C. Constructs that always get an explanation:
   - Optionals: `?`, `!`, `if let`, `guard let`, `??`, optional chaining. Compare to nullable pointers and Go's `val, ok`.
   - Value types and reference types: `struct`/`enum` are copied, `class` is shared by reference. Explain copy-on-write, and compare to C++ value semantics and to ObjC objects.
   - `enum` with associated values and `switch` pattern matching. These are tagged unions, unlike C enums.
   - Protocols, protocol extensions, `some`/`any`. Compare to Go interfaces, ObjC protocols and C++ templates/concepts.
   - Extensions. These are like ObjC categories.
   - Closures, trailing-closure syntax, `$0` shorthand, and capture lists (`[weak self]`). Compare to ObjC blocks and C++ lambdas.
   - Memory management: ARC (the same model as ObjC ARC), `weak`/`unowned`, and retain cycles.
   - Errors: `throws`/`try`/`do-catch`. Compare to Go's `err` returns and to C++ exceptions.
   - Concurrency: `async`/`await`, `Task`, `actor`, `@MainActor`, `Sendable`, and why Swift 6 strict concurrency complains when it does. Compare to goroutines and channels, and to GCD.
   - SwiftUI specifics: `@State`, `@Binding`, `@Observable`, `@Environment`, and the result-builder syntax used in `var body`. Explain why `body` is a description of the UI, not the UI itself.
   - Generics, `where` clauses and associated types.
   - Access control (`private`, `fileprivate`, `internal`, `public`) and how modules work.
   - **Swift–C++ interop**, everywhere it appears: what a C++ type becomes in Swift (`std::string`, `std::vector`, `shared_ptr`, foreign reference types), what ownership means across the boundary, and where `Unsafe…Pointer` shows up and why that is dangerous.
4. **Explain the "why" for anything non-obvious.** For example: why this is a `class` and not a `struct`, why this runs on the main actor, or why this copy is cheap.
5. **Use `// SWIFT:` for comments about the language** and normal `//` comments for comments about the domain (MaterialX, USD, Metal). This lets you grep the teaching notes, and they could be removed one day if we wanted.
6. **Optional `// TRY:` markers** suggest small, safe changes to experiment with ("change this `struct` to a `class` and see what breaks").

### 6.2 Code style that helps learning

- **Prefer explicit over clever.** Write explicit type annotations where inference would hide what is going on. Avoid long chains of `map`/`filter`/`$0` until the concepts have been introduced, and explain them when they are used.
- **Small, single-purpose commits.** Each one introduces as few new Swift concepts as possible, so every diff can be reviewed line by line.
- **`docs/SWIFT_NOTES.md`** is a running glossary. Each new concept gets a short entry with a link to the file where it first appears, and the `// SWIFT:` comments can point to it.
- Use the standard tools (`swift-format` with the default config, Xcode's built-in tests through Swift Testing) rather than custom tooling, so what you learn transfers to other projects.

## 7. Signing and distribution

Goal: from M0 on, every runnable build is signed with the author's Apple Developer certificate. A release build can be notarized and runs on another Mac without Gatekeeper warnings.

### 7.1 Decisions

| Topic | Decision | Why |
|---|---|---|
| Distribution channel | **Developer ID**, outside the Mac App Store, with notarization | Simplest path. The App Store stays possible later (see the sandbox row). |
| Hardened Runtime | **On** for all configurations | Notarization requires it. Turning it on from day one means we never find out late that a C++ dependency breaks under it. |
| App Sandbox | **Off at first**, revisited before any App Store submission | A `.mtlx` file refers to textures by relative or absolute paths anywhere on disk. A sandboxed app can only read them after the user grants access, through security-scoped bookmarks or folder access. That is solvable, but it is extra work we don't want in M0–M2. |
| Signing configuration | Tracked `Config/Base.xcconfig` with an optional `#include? "Signing.local.xcconfig"`. The local file holds `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` and is in `.gitignore`. | The Team ID isn't secret, but keeping it out of the repo means anyone can clone and build with their own team. |
| Bundle identifier | **`eu.emerald-isle.margolaria`** (`Config/Base.xcconfig`); spikes use `eu.emerald-isle.margolaria.spike-*` | Must be stable before the first notarized release. Changing it later resets user preferences and permissions. |
| Embedded C++ frameworks | Dynamic xcframeworks (SwiftUsd, OCIO, OIIO) are set to **Embed & Sign**, so Xcode re-signs them with our identity. Static ones are linked into the binary. SwiftUsd's are all dynamic and arm64 only, so the app is **Apple silicon only** (`ARCHS = arm64`; spike M0e). | Under the Hardened Runtime, *library validation* refuses to load dylibs signed by a different team. |
| Bundle resources | USD `plugInfo.json` files, MaterialX `libraries/` and the OCIO config are shipped read-only inside `Contents/Resources`. **Nothing writes into the app bundle at runtime.** Shader and pipeline caches go to `~/Library/Caches/<bundle-id>/`. | Changing a signed bundle after signing breaks its signature. |
| Embedded Python (M6) | Every `.so`/`.dylib` in the bundled Python, and the bundled site-packages, is signed by us at build time. User-installed **pure-Python** packages work. User-installed packages with **native extensions** signed by someone else would be blocked by library validation. As with Hydra delegates below, that needs `disable-library-validation`, so we decide it deliberately. | Blender and Houdini users expect `pip install`, so this trade-off will come up. |
| Third-party Hydra delegates (M5) | Loading renderers such as Arnold or Karma at runtime needs the `com.apple.security.cs.disable-library-validation` entitlement. We postpone that and decide explicitly when we get there. | It weakens the Hardened Runtime's protection, so it should be a deliberate choice, not a default. |

### 7.2 Release pipeline (`scripts/release.sh`, since spike M0e)

1. `xcodebuild archive` with the Release configuration.
2. `xcodebuild -exportArchive`, with `method = developer-id` in the export options.
3. `xcrun notarytool submit --wait --keychain-profile <profile>`. The credentials are stored once with `notarytool store-credentials`, so they never appear in the repo or the script.
4. `xcrun stapler staple` on the `.app` (or the `.dmg`).
5. Checks: `codesign --verify --deep --strict --verbose=2`, then `spctl --assess --type execute -vv`.

## 8. Roadmap

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0: Spikes** | (a) Read and write a `.mtlx` from Swift using MaterialX through SwiftUsd. (b) Render a USD stage with a MaterialX material in Storm/Metal inside an `NSView`. (c) Generate MSL for a single node output and render a swatch. (d) Prototype a graph canvas with 500 nodes. (e) Set up the Xcode project with `Config/*.xcconfig`, Hardened Runtime and Developer ID signing. Embed SwiftUsd, then archive, notarize and staple a "hello" build. | Each spike is a small demo target in the repo, with notes. (e) passes `spctl --assess` on a second Mac or a clean user account. |
| **M1: Viewer** | Open `.mtlx`, read-only graph with auto-layout, viewport, XML tab, Issues tab | Opens every example in MaterialX `resources/Materials/Examples` |
| **M2: Editor** | Add, delete and connect nodes; inspector editing; undo; save with lossless round-trip (since M1d, XML comments are read as comment elements so MaterialX writes them back; `xi:include`s are written back as includes) | Round-trip tests on the MaterialX example corpus pass with a byte-equivalent or semantically equal diff |
| **M3: Previews & colour** | Per-node thumbnails, solo preview, OCIO colour pickers and view transform | Swatches update in under 100 ms after an edit on a typical graph |
| **M4: Authoring power** | Nodegraph creation, promote to interface, custom nodedef authoring, backdrops, two-way XML editing, command palette | Can build a custom nodedef from scratch and use it in another document |
| **M5: Pipeline** | USD/USDZ export, other Hydra delegates, shader export (MSL/GLSL/OSL), image I/O through OIIO | USDZ opens correctly in Reality Composer Pro / Quick Look |
| **M6: Python** | Embedded interpreter, Console tab as a Python REPL, `margolaria` module (document, selection, commands, undo grouping), PyMaterialX and `pxr` on the shared document, startup scripts and user commands in the command palette, a Python CLI | A script can build a material and appear in the undo history as one step; the signed and notarized build still passes `spctl` |

## 9. Open questions

1. Does SwiftUsd expose the MaterialX C++ API to Swift directly, or only link it internally for Hydra? (M0a.) This decides whether we build MaterialX ourselves.
2. ~~Should the canvas be SwiftUI `Canvas` or Metal?~~ **Decided: AppKit `NSView` + Core Animation**, one layer per node; no Metal (spike M0d, `docs/spikes/M0d-graph-canvas.md`).
3. Should RealityKit's custom MaterialX nodes (RealityKit PBR, Unlit, geometry modifiers) be supported as a library or target, for visionOS users?
4. Should we have our own reference path tracer later? The MaterialX roadmap mentions integrating OSL testrender, WGSL and MDL as reference renderers.
5. Document format: plain `.mtlx` only, or also open `.usda`/`.usdz` and edit the MaterialX materials inside them?
6. Licensing of the final app. The repo LICENSE already exists; every dependency above is Apache-2.0 or BSD-3.
7. ~~Are the SwiftUsd xcframeworks static or dynamic?~~ **Answered: dynamic** (108 frameworks, arm64 only). Xcode embeds and re-signs them; no library-validation exception is needed (spike M0e, `docs/spikes/M0e-signing-notarization.md`).
8. Is the Mac App Store a real goal? If yes, the App Sandbox and security-scoped texture access move earlier in the roadmap.
9. ~~How should power users script the app?~~ **Decided: Python** (§1.1, §3, M6). Still open: which Python version to pin, and whether to allow user-installed native packages (§7.1).

## 10. Sources

- MaterialX Graph Editor docs: <https://github.com/AcademySoftwareFoundation/MaterialX/blob/main/documents/DeveloperGuide/GraphEditor.md>
- MaterialX annual review, ASWF TAC, 2026-02-04 (1.39.4: hex-tiling, WGSL, NanoColor, animated materials; Slang codegen; OpenPBR Volume; reference path tracers): <https://tac.aswf.io/meetings/2026-02-04/MaterialX_TAC_Update_2026_Final.pdf>
- apple/SwiftUsd (changelog: 8.1.0 → OpenUSD v26.08): <https://github.com/apple/SwiftUsd>
- MaterialX in Hydra/Storm: <https://openusd.org/release/api/_page__material_x__in__hydra__u_s_d.html>
- QuiltiX: <https://github.com/PrismPipeline/QuiltiX>
- LookdevX for Maya, What's New: <https://help.autodesk.com/cloudhelp/2026/ENU/Maya-WhatsNew/files/GUID-26EA5B09-DA2E-4B71-9EA5-0391E4E5B8E8.htm>
- Houdini Solaris MaterialX: <https://www.sidefx.com/docs/houdini/solaris/materialx.html>
- Reality Composer Pro Graph Editor: <https://developer.apple.com/documentation/realitycomposerpro/realitycomposerpro-essentials-grapheditoroverview>
- RCP node previews forum thread: <https://developer.apple.com/forums/thread/747781>
- Substance 3D Designer interface: <https://experienceleague.adobe.com/en/docs/substance-3d-designer/using/workspace/interface>
- Connecter MaterialX editor: <https://blog.connecterapp.com/inside-connecters-materialx-node-graph-editor-0d7df2a54c6e>
- wabiverse SwiftUSD v26.8.3: <https://github.com/orgs/wabiverse/discussions/44>
