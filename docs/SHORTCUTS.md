# Keyboard shortcuts

Every command of Margolaria and its shortcut (M7g, PLAN.md §8.4). The keys come from one table in the code, `Packages/MargolariaKit/Sources/GraphKit/Shortcuts.swift`; the menus and the canvas read them there, and `ShortcutTests` checks that this page says the same, that no two commands share a key where both apply, that none takes a key macOS keeps for itself, and that the Mac's usual keys (⌘C, ⌘Q…) keep their meaning.

**Where** a key works:

- **Anywhere**: in a document window, whatever has the focus.
- **Canvas**: while the graph canvas has keyboard focus (click it). The canvas's single keys would otherwise take letters from text fields, so their menu items show the key only while the canvas has focus. ⌘G is Group in Backdrop there, and Find Next everywhere else.
- **Outside the canvas**: everywhere but the canvas.
- **XML tab**: while the XML tab's text has focus.

The single keys follow MaterialX's Graph Editor where it has one: Tab, F, U, and P, its key for pinning the node it renders, which here shows the node alone in the viewport, as S does.

## Commands

| Command | Keys | Where |
|---|---|---|
| Margolaria › About Margolaria | — | |
| Margolaria › Settings… | ⌘, | Anywhere |
| Margolaria › Hide Margolaria | ⌘H | Anywhere |
| Margolaria › Hide Others | ⌥⌘H | Anywhere |
| Margolaria › Show All | — | |
| Margolaria › Quit Margolaria | ⌘Q | Anywhere |
| File › New | ⌘N | Anywhere |
| File › Open… | ⌘O | Anywhere |
| File › Open Recent | — | |
| File › Close | ⌘W | Anywhere |
| File › Save | ⌘S | Anywhere |
| File › Duplicate | ⇧⌘S | Anywhere |
| File › Rename… | — | |
| File › Move To… | — | |
| File › Revert To | — | |
| File › Export as USD… | ⇧⌘E | Anywhere |
| File › Export as USDZ… | ⌥⇧⌘E | Anywhere |
| File › Run Script… | ⌘R | Anywhere |
| Edit › Undo | ⌘Z | Anywhere |
| Edit › Redo | ⇧⌘Z | Anywhere |
| Edit › Cut | ⌘X | Anywhere |
| Edit › Copy | ⌘C | Anywhere |
| Edit › Paste | ⌘V | Anywhere |
| Edit › Duplicate | ⌘D | Anywhere |
| Edit › Delete | ⌫ | Canvas |
| Edit › Select All | ⌘A | Anywhere |
| Edit › Find… | ⌘F | Anywhere |
| Edit › Find Next | ⌘G | Outside the canvas |
| Edit › Find Previous | ⇧⌘G | Anywhere |
| View › Command Palette… | ⌘K | Anywhere |
| View › Graph | ⌘1 | Anywhere |
| View › Split | ⌘2 | Anywhere |
| View › Text | ⌘3 | Anywhere |
| View › XML | ⌥⌘1 | Anywhere |
| View › Issues | ⌥⌘2 | Anywhere |
| View › Generated Shader | ⌥⌘3 | Anywhere |
| View › Console | ⌥⌘4 | Anywhere |
| View › Document | ⌃⌘1 | Anywhere |
| View › Library | ⌃⌘2 | Anywhere |
| View › Show Sidebar | ⌃⌘S | Anywhere |
| View › Show Viewport | ⌥⌘P | Anywhere |
| View › Show Inspector | ⌥⌘I | Anywhere |
| View › Enter Full Screen | ⌃⌘F | Anywhere |
| Graph › Add Node… | ⇥ | Canvas |
| Graph › Frame All | A | Canvas |
| Graph › Frame Selection | F | Canvas |
| Graph › Open Nodegraph | ↩ | Canvas |
| Graph › Go Up One Level | U | Canvas |
| Graph › Show in Viewport Alone | S or P | Canvas |
| Graph › Show Node Previews | — | |
| Graph › Arrange | L | Canvas |
| Graph › Group in Backdrop | ⌘G | Canvas |
| Graph › Collapse into Nodegraph | ⌥⌘G | Anywhere |
| Graph › Ungroup Nodegraph | ⌥⇧⌘G | Anywhere |
| Scripts › *the scripts' commands* | — | |
| Scripts › Stop Script | ⌘. | Anywhere |
| Scripts › Reload Startup Scripts | — | |
| Scripts › Open Scripts Folder | — | |
| Window › Minimize | ⌘M | Anywhere |
| Window › Zoom | — | |
| Window › Bring All to Front | — | |
| Help › Acknowledgements | — | |
| XML tab › Apply | ⌘↩ | XML tab |
| XML tab › Revert | ⎋ | XML tab |

The inspector's commands (Reset to Default, Promote to Nodegraph Input, Make Node Definition…, Save to Library…) and the panels' buttons have no keys; the command palette (⌘K) runs any of them, and every menu command, by name.

## Gestures and other keys on the canvas

Not commands, so not in the table:

- Forward Delete (⌦) deletes, as ⌫ does.
- Escape abandons a wire or a cut being dragged.
- Space-drag or middle-drag pans; two-finger scroll pans; pinch, the mouse wheel or ⌥-scroll zoom.
- ⌥-drag across wires cuts them; inside a nodegraph, ⌥-dragging an input to the graph's left edge promotes it.
- ⌥-click a node's swatch or title solos it (as S does); double-click a nodegraph, or a node of a definition, opens it (as Return does).
- The right button is kept free, for context menus to come.
