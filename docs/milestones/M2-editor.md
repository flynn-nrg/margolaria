# M2: Editor

**Goal** (PLAN.md §8): add, delete and connect nodes; inspector editing; undo; save with a lossless round trip. **Exit criterion:** round-trip tests on the MaterialX example corpus pass with a byte-equivalent or semantically equal diff.

**Result: met.** All 50 examples in MaterialX 1.39.5 are written back semantically equal (`Element::isEquivalent`); 49 of them byte for byte. The one that differs, `standard_surface_chess_set.mtlx`, is the only example with blank lines between elements, which MaterialX's writer doesn't keep.

Each PR's own exit criterion is checked by a test, most of them on the whole corpus:

| PR | Exit criterion | Test |
|---|---|---|
| M2a | Moving and deleting nodes undo, redo, autosave and reopen correctly; the round trip passes on all 50 examples | `MXCorpusTests` (round trip), `GraphBuilderTests` ("Editing on the canvas") |
| M2b | Every input type in the examples can be edited and undone | `MXCorpusTests`: every editable input of every example takes a new value, and the snapshot undo puts it back |
| M2c | Dragging a colour in the inspector updates the sphere while dragging | `StormUpdateTests`; a value change costs about 3 ms |
| M2d | Any example can be rewired by mouse, with undo | `GraphWiringTests`: every wire in every example is cut and redrawn through the canvas's gestures, then undone |
| M2e1 | Every library node can be added and changed to each of its variants, leaving a valid document | `MXNodeCatalogTests`: all ~800 nodedefs |
| M2e2 | A material can be built from an empty document without touching the XML | `BuildFromNothingTests`: a textured, tinted OpenPBR material built through the canvas's calls, validated, round-tripped and rendered |

Dates: 2026-10-24 to 2026-10-26. Six PRs: #15 (M2a), #16 (M2b), #17 (M2c), #19 (M2d), #20 (M2e1), #21 (M2e2). The app and MargolariaKit grew from about 9,000 to 16,300 lines of Swift, C++ and Objective-C++, and from 54 to 121 test functions.

## What was built

| PR | Scope | Main pieces |
|---|---|---|
| **M2a** (#15) | Edits, undo, save | Bridge mutations behind one `Perform` (edits that MaterialX would make invalid are refused with `MXError.editRefused`) · `MXEdit.swift` · snapshot undo through `MaterialXDocument.edit(_:)` · saving and the version-upgrade prompt · `xpos`/`ypos` · included elements read-only · move and delete on the canvas · the round-trip corpus test |
| **M2b** (#16) | Inspector | `InspectorPanel` · `MXInspectable` (nodes, graph inputs and outputs) · inputs grouped by `uifolder`, set inputs marked · editors for numbers, sliders, colours, vectors, booleans, enums, strings and files · reset to default · jump to a connection's source · renaming |
| **M2c** (#17) | Live viewport | `previewXMLString()` (includes inlined, texture paths absolute) · the renderer's own temporary file, `TransferContent`ed into the referenced layer after each edit |
| **M2d** (#19) | Wiring | Drag to connect, with incompatible pins dimmed · pull a wire off an input to disconnect or move it · ⌥-drag to cut · drop on a node to choose among its inputs · "+N more inputs" expands · `DocumentWiring` |
| **M2e1** (#20) | Node library | `MXNodeCatalog` (nodedefs grouped into nodes and their type variants) · `LibraryPanel` sidebar tab, with search and drag-and-drop · Tab on the canvas opens `NodeSearchPopup` · the inspector's Type menu (`changeNodeDef`) |
| **M2e2** (#21) | Building from nothing | A wire dropped on empty canvas opens the search filtered to what can connect, and connects the result · `MXDocumentTemplate` and the File > New sheet (with "Open…") · `BuildFromNothingTests` |

The window now has every region of the mockup (PLAN.md §4.1) except the generated-shader and console panels: the sidebar has Document and Library tabs, and the inspector is on the right, under the viewport (either can be hidden from the toolbar).

## Decisions

The full list, with reasons, is in PLAN.md §8.1. The ones that shaped the code most:

1. **Every edit goes through one command layer** (M2a). The UI calls `MXDocument`'s mutating methods, grouped into named edits; Python will call the same ones (M6). The bridge checks every edit against MaterialX's rules and refuses what would leave the document invalid, so the UI's own checks (dimmed pins, read-only inputs) are a convenience, not the only guard.
2. **Undo keeps snapshots, not inverse operations** (M2a). Before each edit, the whole document is copied (`Document::copy()`); undo swaps it back. The largest example is 32 KB, so this is cheap, and it is correct for any edit, including a script's many steps as one undo. A slider drag is one snapshot, taken when it starts. Revisit if documents get large.
3. **Positions are saved in the Graph Editor's units** (M2a): one unit is one node, so layouts keep their proportions between the two editors. The first move in a level saves every node's position, so nothing jumps when auto-layout no longer places it.
4. **Elements from `xi:include`d files are read-only** (M2a). MaterialX writes includes back as `xi:include`, so edits to included elements would be lost on save. The inputs of a nodegraph that implements a nodedef (SimpleHair's) are read-only for a similar reason: they belong to the nodedef's interface.
5. **The viewport renders a file of its own, not the user's** (M2c, changed from `UsdMtlxRead`). Each edit rewrites a self-contained copy of the document, and USD's `TransferContent` tells Storm only what changed. A file, not a layer in memory, because Hydra rereads document-defined nodedefs from the document's file.
6. **Removing an input can change what a node is** (M2d). MaterialX matches a node to its nodedef by the types of the inputs present, so disconnecting `in2` of a `vector3 × float` multiply turned it into a `vector3 × vector3`. An input is now removed only when that can't happen; otherwise it stays, at its default. Type variants write `nodedef="..."` on the node (M2e1) for the same reason.
7. **The library lists nodes, not nodedefs** (M2e1). About 800 nodedefs become about 300 nodes, each added as its plain colour variant where there is one; the inspector's Type menu picks another. A wire's end chooses the variant itself (M2e2): a float wire makes `ND_multiply_float`.

## Problems found and fixed (worth remembering)

| Where | Problem | Fix |
|---|---|---|
| M2a | A helper on the bridge's private `Document::Impl` couldn't be used from a free template function | Helpers take `mx::DocumentPtr` |
| M2a | New node names: MaterialX doesn't always pick `scale1` after `scale` | Tests check the prefix, not the number |
| M2b | Editing SimpleHair's inputs failed ("has no input melaninConcentration"): its nodegraph implements a nodedef | The bridge refuses with a clear message; the inspector shows those inputs read-only |
| M2b | The bottom panel's tabs moved when it was empty (since M1d) | `ContentUnavailableView` given a full frame |
| M2c | SimpleHair rendered grey from an anonymous layer, though the same text from a file rendered correctly | The renderer writes a temporary file (decision 5) |
| M2c | `SdfLayer::Reload` failed ("Failed to define UsdPrim </MaterialX>"), leaving no materials | `OpenAsAnonymous` plus `TransferContent` |
| M2c | A crash on quitting, in `~UsdImagingGLEngine`, from an autorelease pool | The renderer's `init` returned another method's result; the helper now returns `BOOL` |
| M2d | The corpus test broke marble, brick and boombox by removing inputs (decision 6); an M2a bug that also affected Reset | `RemoveInput` keeps inputs the nodedef match depends on |
| M2d | `<output interfacename>` fails MaterialX's validation | Refused by the bridge and by the canvas's rules |
| M2d | A click on a connected input selected the node at the wire's other end | The canvas tracks the pressed node |
| M2e1 | Every node landed in the "document" group: `getNodeDefs()` on a document includes its data library's | `isFromDocument` compares each nodedef's `getDocument()` |
| M2e1 | `multiply` was grouped under "pbr", through its BSDF variants | A node's group is its default variant's |
| M2e1 | The colour panel opened in the screen's bottom-left corner the first time | Placed beside the pointer once, then remembered (`setFrameAutosaveName`) |
| M2e2 | The colour panel kept showing the previous node's colour, and could set it on the wrong node | The inspector's contents are rebuilt for each selection (`.id(selectedPath)`) |

## Not done / open

The ones for M3 are in PLAN.md §8.2.

- **Not in M2, as planned:** nodegraph creation and promote-to-interface, backdrops and two-way XML editing (M4); per-node thumbnails and OCIO colour pickers (M3).
- **Colours picked outside the working space's gamut** become negative components (the colour panel covers Display P3). To be decided with the OCIO pickers (M3).
- **The viewport's lighting** (OpenUSD's outdoor dome, no view transform) makes some examples look wrong; checking them against MaterialXView waits for M3's studio environment.
- **Blank lines** between elements are lost on save (the chess set). Harmless, but not byte for byte.
- **Undo snapshots** copy the whole document. Fine at the examples' sizes; to be measured if large documents appear.
- **Cancelling "Open…"** in the File > New sheet leaves no window open, as other Mac document apps do; File > New brings the sheet back.
- **Light mode** for the canvas: still always dark.
