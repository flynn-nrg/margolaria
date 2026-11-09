# Scripting Margolaria

Margolaria runs Python 3.13 on the open document: File > Run Script… picks a `.py` file and runs it on the document in the front window, and the bottom panel's **Console** tab runs what you type, line by line. Both use two modules:

- **`MaterialX`**: MaterialX's own Python API (PyMaterialX 1.39.5), the same as in Houdini or MaterialX's Graph Editor.
- **`margolaria`**: the open document, the editor's edits on it, undo steps, the selection, validation and export.

`margolaria.document()` is the app's own document, not a copy, so anything a script does with MaterialX's API, the window shows when the script ends. Examples: [`scripting/brick.py`](scripting/brick.py) builds a material, and [`scripting/report.py`](scripting/report.py) only reads.

What a script prints is shown in the Console tab when it ends. If it raises, its traceback is shown there, and the document is put back as it was.

## The Console

The Console tab is a Python prompt on the window's document, as `python3` is in a terminal: type a line after `>>>` and press Return. `margolaria` and `MaterialX` (as `mx`) are imported already.

```
>>> doc = margolaria.document()
>>> [node.getName() for node in doc.getNodes()]
['brick_shader', 'brick', 'brick_color']
>>> for name in ["a", "b"]:
...     margolaria.add_node("ND_constant_float", name=name)
...
'a'
'b'
```

- **Each entry is an undo step**, "Undo Console", if it changes the document: a line, or a block such as the `for` above. Entries that only read add none. `with margolaria.edit("Name"):` works as in a script. Undo takes back what an entry changed in the document; the Console still shows the entry, as a terminal keeps what was typed, and its variables keep their values.
- **Variables stay** from one entry to the next, until the window closes. Each window has its own.
- **Blocks:** a line ending in `:` asks for more (the prompt becomes `...`, indented); an empty line ends the block. Tab inserts four spaces.
- **Values:** an expression's value is printed, as in Python's own console, and kept as `_`. That includes each expression in a block: the `for` above prints the names `add_node` returns.
- **History:** Up and Down go through the lines typed. Clear empties the tab; the variables and history stay.
- A syntax error is shown before anything runs; an exception shows its traceback (`File "<console>"`), and takes back what the entry changed.

## Long scripts and Stop

A script, or a Console entry, that runs for more than a moment shows a **Running… Stop** sheet. Until it ends, the window shows the document as it was before it; the script works on the document itself.

**Stop** (or Escape, or ⌘.) raises `KeyboardInterrupt` in the script at its next line of Python, as Ctrl-C does in a terminal, and its changes are taken back. A script stops only between lines of Python: a long call into MaterialX, or a `time.sleep()`, finishes first. A script that catches `KeyboardInterrupt` (a bare `except:`) keeps running.

One script runs at a time, in the whole app: starting another meanwhile, from another window, says which is running instead. `input()` has nothing to read, and raises `EOFError`.

## Undo

A script's changes are **one undo step**, named after it: "Undo Run brick.py". A script that changes nothing adds no step, and doesn't mark the document as edited.

For steps of its own, a script uses `with margolaria.edit("Name"):`. The block's changes are one step called "Name". Changes before and after it are steps named after the script. If the block raises, its changes are taken back before the exception goes on, so a script can catch it and carry on:

```python
with margolaria.edit("Tint Bricks"):
    tint = margolaria.add_node("ND_multiply_color3", name="brick_tint")
    margolaria.connect(tint, "in1", "brick_color")
```

Blocks inside blocks belong to the outermost one.

The document object stays the same through Undo and Redo: a `doc = margolaria.document()` kept from an earlier run (in a module of your own, for example) sees the document as it is now. Elements taken from it before an Undo (`doc.getNode("brick")`) are not in it any more: get them again.

## Paths

The `margolaria` functions name elements by path, as MaterialX does, from the document's top level: `"brick_shader"`, `"NG_brick/noise1"`. Functions that add or rename an element return its path.

## The editor's edits

These make the same changes as the editor, with the same checks. An edit the editor would refuse (types that don't match, a loop, a name already taken, an element from an included file) raises **`margolaria.EditRefused`** (a `ValueError`), and changes nothing.

MaterialX's API can make any change, and doesn't check: these are the way to change the document as the editor does.

| Function | What it does |
|---|---|
| `add_node(nodedef, parent="", name="")` | Adds a node defined by `nodedef` (`"ND_image_color3"`) to the graph at `parent` (`""` is the document). `name` is a hint, made unique. Returns its path. |
| `remove_node(path)` | Removes a node or nodegraph, disconnecting what used it. |
| `rename_node(path, name)` | Renames a node, nodegraph or backdrop, and what refers to it. Returns the new path. |
| `change_nodedef(path, nodedef)` | Changes a node to another type variant (`"ND_multiply_color3FA"`), keeping the inputs and connections that still fit. |
| `set_value(path, input, value)` | Sets an input's value, disconnecting it. `value`: a string as MaterialX writes it (`"0.8, 0.2, 0.1"`), a number, a bool, a tuple of numbers, or a MaterialX value (`mx.Color3(...)`). |
| `reset_input(path, input)` | Removes an input, so the node uses its nodedef's default. |
| `set_colorspace(path, input, colorspace)` | Sets an input's `colorspace`; `None` removes it. The value stays as it is. |
| `connect(path, input, source, output=None)` | Connects `input` of the node at `path` to the node or nodegraph `source` in the same graph (its `output`, if it has several). For an `<output>` element, `input` is `""`. |
| `connect_interface(path, input, interface)` | Connects an input inside a nodegraph to one of the graph's own inputs. |
| `disconnect(path, input)` | Disconnects an input, or an `<output>` (`input` `""`). |
| `set_position(path, x, y)` | Sets `xpos` and `ypos`, in MaterialX's units. Nodes without a position are laid out by the canvas. |
| `working_space(path="")` | The working space: the colour space untagged colours are in, in the document (`""`) or a nodegraph. |
| `set_working_space(colorspace, path="", convert=True)` | Changes it (`None`: the parent's). With `convert`, colours keep their look, as the editor's Convert Colours does. Without, the numbers stay. |

## The window

| Function | What it does |
|---|---|
| `selection()` | The paths of what is selected on the canvas, as a list. |
| `select(path)` | Selects the node or backdrop at `path`, showing its graph, once the script has ended (if it succeeds). `selection()` returns it from then on. |

## Validation

`issues()` returns what the Issues tab lists, as `margolaria.Issue` named tuples: `path` (`""` for the document), `message`, `severity` (`"error"` or `"warning"`) and `source` (`"materialx"` for MaterialX's validation, `"margolaria"` for Margolaria's checks, such as nodes without a nodedef, or missing images). An empty list for a valid document.

## Export

Relative paths are relative to the document's folder; a document that was never saved needs absolute ones.

| Function | What it does |
|---|---|
| `export_usd(path)` | The document's materials as USD (`.usda`, `.usdc` or `.usd`), as File > Export as USD… |
| `export_usdz(path, material=None)` | A USDZ package for Quick Look and Reality Composer Pro, as File > Export as USDZ…: a sphere with `material` (by name; the first if `None`), the other materials, and every texture. |
| `export_shader(path, folder, language="msl", colorspace="lin_rec709", oslc=None)` | The shader MaterialX generates for the element at `path`, written into `folder` as the Generated Shader tab's Export… does. `language`: `"msl"`, `"glsl"`, `"osl"` or `"osl_network"`. `colorspace`: `"lin_rec709"` or `"acescg"`. For `"osl"`, `oslc` (the compiler's path) also compiles it to `.oso`. Returns the files' paths. |

## Limits for now

- What a script prints shows when it ends, not as it prints.
- The Console takes a line at a time: text pasted with several lines is entered as if typed one by one, and a block needs its empty line to end.
- Python packages you install yourself must be pure Python (PLAN.md §7.1); a folder for them comes in M6d.
- `pxr` (OpenUSD's Python API) isn't included (PLAN.md §8.7).
