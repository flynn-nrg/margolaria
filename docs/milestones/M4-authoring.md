# M4: Authoring power

**Goal** (PLAN.md §8): nodegraph creation, promote to interface, custom nodedef authoring, backdrops, two-way XML editing, command palette. **Exit criterion:** can build a custom nodedef from scratch and use it in another document.

**Result: met.** `LibraryRoundTripTests` builds a definition in an empty document through the same calls as the UI:
1. add a node;
2. collapse it into a nodegraph;
3. give the graph an output and promote the node's inputs;
4. make the graph a definition.

It then saves the definition to a library folder and uses it in a second document, which includes the file as the Library panel does. The material renders in Storm like the same material built from a plain node, validates, and both documents survive saving and reopening.

Each PR's own exit criterion is checked by a test, most of them on the whole example corpus:

| PR | Exit criterion | Test |
|---|---|---|
| M4a | Collapsing nodes into a nodegraph, then ungrouping, keeps the document valid and the render the same; undo restores the document exactly | `MXNodeGraphEditTests`, `CollapseRenderTests`: every node that isn't a material or a nodegraph, alone and with the nodes it reads, in every example |
| M4b | Promoting every unconnected input of the examples' nodegraphs keeps each render the same; metadata round-trips through save | `MXInterfaceEditTests`, `PromoteRenderTests` |
| M4c1 | A nodegraph made into a definition and instanced renders the same as the graph did | `MXNodeDefEditTests`, `DefinitionRenderTests` |
| M4c2 | M4's criterion (above) | `LibraryRoundTripTests`, `BuildFromNothingTests`, `MXLibraryFilesTests` |
| M4d | Backdrops round-trip, move their nodes, and undo | `MXBackdropEditTests` (a backdrop around every level of every example, moved), `GraphBackdropTests` (made, dragged, resized and deleted as the canvas does) |
| M4e | Applying every example's own text changes nothing; an applied edit is one undo step; invalid text is never applied | `MXXMLEditTests`: same document, file text, preview text, issues and includes for every example; every unfinished prefix of a document refused; `MXXMLTextTests` checks the byte scanner against the old regular expressions |
| M4f | Every menu command can be found and run from the palette | `CommandPaletteTests`, on a menu bar built like the app's (the app has no test target) |

Dates: 2026-10-31 (plan) to 2026-11-03. Eight PRs: #34 (M4a), #35 (a layout fix: elements without a saved position are placed, and the positions kept), #36 (M4b), #37 (M4c1), #38 (M4c2), #39 (M4d), #40 (M4e), #41 (M4f). The app and MargolariaKit grew from about 22,800 to 31,700 lines of Swift, C++ and Objective-C++, and from 170 to 242 test functions.

## What was built

| PR | Scope | Main pieces |
|---|---|---|
| **M4a** (#34) | Nodegraphs | Collapse into Nodegraph (⌥⌘G) and Ungroup (⇧⌥⌘G) in a new Graph menu · crossing connections become the graph's inputs and outputs · empty nodegraphs from the Library · a graph's outputs added, renamed and removed · copy, cut, paste and duplicate with MaterialX XML on the pasteboard · `MXNodeGraphEdit.swift` · `UngroupForStorm` for the viewport's text |
| **M4b** (#36) | Interface | Promote to Nodegraph Input (right-click, or ⌥-drag the input out to the left) · interface inputs added, renamed and removed · their UI metadata (`uiname`, `uifolder`, ranges, `enum`, `doc`) in the inspector · `MXInterfaceEdit.swift` |
| **M4c1** (#37) | Node definitions | Make Node Definition… (a sheet: node name, nodedef name, group, version, description) · the node takes the graph's place, the graph becomes `NG_<node>` · the definition edited in its own document · Edit Definition and double-click to open it · `MXNodeDefEdit.swift` · `ExpandInstance` for the viewport |
| **M4c2** (#38) | Libraries | `~/Documents/Margolaria/Libraries` ("My Library") and the document's folder in the Library tab · Save to Library… · using a library node adds its `xi:include` · included definitions shown read-only · `MXLibraryFiles.swift` |
| **M4d** (#39) | Backdrops | MaterialX's `<backdrop>` drawn on the canvas · Group in Backdrop (⌘G) · moved with what they contain, resized by a grip, notes · contents follow the nodes dragged in and out · `MXBackdropEdit.swift`, `DocumentBackdrops.swift` |
| **M4e** (#40) | XML editing | The XML tab editable, applied with ⌘↩ as one undo step · a bar with the first problem's line, Revert and Apply · `Document::readText` (the text read as the document's own file) · `MXXMLEdit.swift` · MXXMLText rewritten as a byte scanner · the window's status line moved into a VStack |
| **M4f** (#41) | Command palette | ⌘K · the menu bar read as commands (`MenuCommands`) · the inspector's and the view's commands through a SwiftUI preference · every node under "Add Node" · `FuzzyMatch` · the canvas keys as Graph menu items |

A document can now hold its own kinds of node and share them through library files. Backdrops organise the canvas, the XML can be edited directly, and every command can be reached from the keyboard.

## Decisions

The full list, with reasons, is in PLAN.md §8.5. The ones that shaped the code most:

1. **Definitions live in their own files and are used through `xi:include`** (M4c2). This is standard MaterialX, so MaterialXView, the Graph Editor and USD resolve them too. Copies would drift apart, and a search path alone would make documents depend on each tool's settings. The user library is in Documents (moved from Application Support during M4c2), because it is the user's work, to back up and share.
2. **A definition is edited by opening its file** (M4c1). There is one place to change it, and included definitions stay read-only. Its implementation isn't drawn on the top-level canvas, because it is the body of a kind of node, which nothing reads directly.
3. **Nodegraphs stay at the top level** (M4a). MaterialX 1.39.5 can't connect to a nodegraph inside another (§8.2), so Collapse, empty nodegraphs and pasting a nodegraph are refused inside one, with that reason.
4. **Every structural edit is checked by rendering** (M4a to M4c1). Collapsing, promoting and making a definition must keep the material's Storm image the same, on every example. This found the three Storm problems below.
5. **The viewport gets its own text, the document stays as written** (M4a, M4b, M4c1). Where Storm draws something wrong, the text sent to it is changed: nodegraphs are ungrouped, file colour spaces moved onto the image, definition nodes expanded. Each change computes the same result. Saved files and swatches are untouched.
6. **The pasteboard holds MaterialX XML** (M4a). Copy and paste work between levels and documents, and other MaterialX tools and text editors get the XML.
7. **Backdrops are MaterialX's `<backdrop>`** (M4d). They are in the specification, so they round-trip, unlike app-only metadata. What a backdrop contains follows the nodes, not its rectangle alone.
8. **XML editing is literal and never applies invalid text** (M4e). Apply changes only what was typed, for users who know MaterialX, with no renames followed. Text MaterialX can't read, or text between tags, is refused with its line. Typing has its own undo history until it is applied.
9. **The palette reads the menus** (M4f). It doesn't keep its own list of commands, so a new menu item is listed without any change. The canvas's single keys became Graph menu items without key equivalents: AppKit gives a menu item's key equivalent the key before the focused view, so a plain "A" would be taken from every text field.

## Problems found and fixed (worth remembering)

| Where | Problem | Fix |
|---|---|---|
| M4a | Collapsing nodes inside a nodegraph always gave an invalid document | MaterialX 1.39.5 can't connect to a nested nodegraph (§8.2); refused there, with the reason |
| M4a | Storm misdraws three kinds of nodegraph: read by a node that isn't a shader, holding a shader, or with inputs reading other nodes | The viewport's text ungroups them (`UngroupForStorm`) |
| M4a | Ungrouping "every nodegraph Storm misdraws" changed the shared standard library, and standard_surface's swatches then failed | `getNodeGraphs()` includes the data library's; edits walk the document's own children |
| M4a | Elements without a saved position were placed badly (#35) | They are placed, and the positions kept |
| M4b | A promoted image file lost its colour space in Storm: the chess set's pieces came out washed out | The preview text gives the image its file and space directly |
| M4c1 | A definition implemented with an image failed to compile in Storm (undeclared texture uniform) and drew grey | The viewport's text expands such nodes into their implementation (`ExpandInstance`) |
| M4c1 | Changing an element's children while looping over them crashed | `getChildren()` is the element's own list; the code copies it first |
| M4d | ⌘G was already Edit > Find Next, for the XML tab | It moves between the two items with the focus (`MainMenu.giveCommandG`): AppKit lets only one item hold a key equivalent |
| M4e | Foundation's XMLParser reported the line after a malformed tag | The first error's own line and column are kept |
| M4e | Finding elements with regular expressions took about 80 ms per keystroke on large files | A byte scanner: 0.2 ms, checked against the old expressions |
| M4e | Edit > Undo in the XML tab undid the document, not the typing | The text view answers `undo:` and `redo:` itself while it has edits |
| M4e | The window's status line hid the bottom of the XML tab and the inspector | The split views ignore safe-area insets; the line is now in a VStack |
| M4e | A doubled `>` read as an element without a category, with no line to show | Text between tags is refused, with its location |
| M4f | Group names outranked titles ("const" listed colour transform nodes before "contrast"), and 24 "Add Output: …" commands filled the list before typing | Title matches rank first; families of commands list only once something is typed |

## Not done / open

These are kept for the UX polish pass after the initial milestones:

- **Node search and library files.** The Tab search and the palette don't list library files' definitions; only the Library tab does.
- **Relative includes.** An include is written relative only when the library file is under the document's folder, and absolute otherwise (M4c2), so a document using My Library refers to a path on this Mac.
- **A definition's outputs and node name** (its category) can't be changed once made.
- **Backdrops and copy and paste.** Copying leaves backdrops out, and ungrouping drops the backdrops inside the nodegraph.
- **The palette** doesn't list an input's right-click actions (Reset to Default, Promote), and a hidden inspector offers none of its commands.
- **Left for later** (§8.5): choosing other library folders in Settings; nodedef versions beyond writing one; namespaces; definitions implemented in code rather than a nodegraph.
- **Keyboard shortcuts**, reviewed once the features are done (PLAN.md §8.4). The palette now lists every command, which is a good place to start.
- **Reports upstream.** To OpenUSD, with M3's: the three misdrawn kinds of nodegraph, file colour spaces through a nodegraph's input, and definitions implemented with an image. To MaterialX: connections to nested nodegraphs. Each has a workaround here; minimal reproductions are still to be written.
- **Not in M4, as planned:** USD/USDZ export, other Hydra delegates, shader export and OIIO (M5); Python (M6).
