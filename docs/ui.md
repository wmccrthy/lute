# Retained UI battery

`batteries/ui` adds a widget framework over `@std/tui`. Build a tree once, keep
references to widgets, and change properties through methods. It is entirely
Luau; the existing C++ terminal backend supplies input, Unicode measurement,
cell clipping, filled rectangles, and dirty-row frame diffs.

The larger example is [Lute Workbench](../examples/workbench/init.luau): a
12,000-project browser with a search field, inspector, asynchronous build
simulation, progress, and scrollable output. Its model, views, and application
wiring are separate modules. No network access or subprocesses are involved.

```sh
build/release/lute/cli/lute examples/workbench/init.luau
# Or compile and run a standalone application:
build/release/lute/cli/lute compile examples/workbench/init.luau --output build/lute-workbench
build/lute-workbench
```

Workbench controls: Tab/Shift-Tab changes focus, arrows navigate lists, Enter
activates controls, F5 builds the selected project, Escape resets the filter,
and Ctrl-C quits. Mouse selection and wheel navigation are enabled.

## Import and compose

Batteries are source libraries, not a public built-in alias for arbitrary user
scripts. Configure `batteries` to point at this repository's `batteries` directory,
or import the source by relative path. A source application's local
`.config.luau` can declare:

```luau
return { luau = { aliases = { batteries = "../../batteries" } } }
```

Paths are relative to the config file. For standalone compilation use relative
imports, as Workbench does: the existing compiler does not carry custom source
aliases into bundles. From a script two directories below the repository root,
use `require("../../batteries/ui")`; an `init.luau` entrypoint uses
`require("@self/../../batteries/ui")` to anchor at its own directory.

Then compose widgets with ordinary functions:

```luau
local ui = require("@batteries/ui")

local function searchpanel()
    local field = ui.input({ placeholder = "Search..." })
    local results = ui.list({ items = {} })
    local panel = ui.box({ title = "Search", flex = 1 }, { field, results })
    return { root = panel, field = field, results = results }
end

local panel = searchpanel()
local status = ui.text("Ready")
local app = ui.app(ui.column({ gap = 1 }, { panel.root, status }))
panel.field:on("change", function(event)
    status:settext("Query: " .. (event.value or ""))
end)
app:run({ mouse = true })
```

Widget objects retain identity, focus, caret position, selection, and scroll.
There is no per-frame tree construction, reconciliation, hook machinery, or
continuous frame loop. Use ordinary modules and functions for composition.

## Widgets and layout

Constructors are `text(value, options?)`, `button(label, options?)`,
`input(options?)`, `list(options?)`, and containers
`row(options?, children?)`, `column(options?, children?)`, `box(options?, children?)`.
Boxes default to a border and arrange children vertically.

Layout is in whole terminal cells. Options:

| Option | Behavior |
| --- | --- |
| `width`, `height` | Explicit size, clipped to available space |
| `flex` | Share leftover space along the parent's main axis, using integer weights |
| `gap` | Cell spacing between visible children |
| `padding` | Equal interior padding on all sides |
| `border`, `title` | ASCII border and an optional clipped title |
| `style` | Native TUI foreground/background and text styles |
| `visible` | False removes the widget and subtree from layout and focus navigation |

The root fills the viewport. Rows place children horizontally; columns/boxes
place them vertically. Children stretch along the cross axis unless explicitly
sized. Along the main axis they use an explicit size, a flex allocation, or their
natural size. Lists default to flex 1; other widgets need an explicit flex for
remaining space. Text, inputs, and buttons have a natural height of one cell.
Text is single-line; compose multiple labels for multiline content.

When space runs out, children are clipped in order; later children may get zero
space. Layout does not wrap or switch direction at breakpoints. Resize performs
a fresh arrangement and repaint. Zero-size OS viewport reports are clamped to
1×1. Input values and list selection survive resizing; logical focus survives
viewport clipping. Explicitly hiding/removing the focused widget moves focus to
the first available control. Tab traversal includes only visible, nonzero controls.

`bounds()` returns a copy of a widget's allocated rectangle. Children receive
only their parent's inner space. Text is cell-clipped using the native Unicode
width rules, and resizing repaints the entire viewport to erase stale content.
See the [native TUI guide](tui.md) for Unicode and terminal compatibility limits.

## Update and interact

| Method | Behavior |
| --- | --- |
| `settext(text)` | Update label/button text |
| `setvalue(text)`, `value()` | Set/read input value; programmatic changes do not emit `change` |
| `setitems(items)` | Replace list data, preserving the selected item by ID when possible |
| `select(index)`, `selected()` | Change/read list selection; 0 means empty |
| `scroll()` | Current zero-based list row/input cell viewport offset |
| `setstyle(style)` | Replace the widget's style |
| `setvisible(boolean)` | Hide/show a widget and its subtree |
| `append(child)`, `remove(child)`, `children()` | Change/read container children |
| `on(name, callback)` | Install one handler per semantic event; returns the widget |
| `focused()` | Whether the widget has logical focus |

Use unique stable list IDs: `local items: {ui.item} = { { id = "a", text = "Alpha" } }`.
Optional item `style` overrides the list style. A list's `renderitem(item, index)`
returns a string and is called only for visible rows. Keep this callback pure,
synchronous, and inexpensive. Data replacement copies the item array and may
scan it to preserve selection; item records are treated as immutable.

Semantic handlers receive `{ kind, widget, value?, item?, index? }`:

- Inputs emit `change` and `submit`. They handle text, paste, arrows, Home/End,
  Backspace/Delete, and mouse caret placement. Editing moves by Unicode scalar,
  not grapheme cluster. Input values are bounded to 64 KiB; invalid UTF-8 or
  oversized external paste is ignored, and C0/C1 controls are removed.
- Lists emit `select` and `submit`. They support arrows/j/k, Home/End, Page Up/Down,
  mouse selection, and wheel movement. Changing selection keeps its row visible.
- Buttons emit `press` on Enter, Space, or mouse press.

`app:focus(widget)` changes focus explicitly. Focused widgets consume applicable
keys first. `app:onkey(function(event): boolean ... end)` handles unconsumed events;
return true when handled. Consequently typing `q` into an input does not trigger
a global `q` shortcut. Unhandled Ctrl-C quits by default. Call `app:quit()` to exit.
Handlers should be short; use `app:spawn` for work that yields.

## Async work and cleanup

```luau
button:on("press", function()
    app:spawn(function()
        local response = fetchSomething() -- may yield
        status:settext(response)
    end)
end)
```

`app:spawn(callback)` owns a task for the current run. `app:run(options?, start?)`
optionally calls `start` after the first frame, which can spawn startup work.
Property updates from jobs schedule redraws even while terminal input is pending.
Updates before a scheduled render are batched, and only one presentation is in
flight. Async task/paint errors close the terminal and propagate from `run`.
On exit, owned Luau tasks are canceled and pending terminal input is released.
Already-started native operations follow Lute's existing cancellation behavior:
the underlying operation may finish before the process exits, even though the
canceled Luau task no longer resumes. Release other external resources explicitly.

## Performance boundaries and verification

Ordinary value/style/selection changes repaint dirty widgets, not the full tree.
A dirty container covers its descendants, avoiding duplicate paints. Text-width
dependencies propagate through natural-size containers; labels in stretched
columns can repaint without relayout. Geometry/visibility/structure changes use
a full layout/repaint, with cached intrinsic measurements. This is deliberately
simpler than maintaining overlapping damage rectangles and a constraint solver.

The native backend scans and copies only touched rows on `present`; clean rows
are skipped, and unchanged cells produce no terminal output. An idle framework
schedules no frames. Existing libuv terminal polling still detects resizes.

`app:stats()` reports cumulative `layouts`, widget `paints`, and attempted
`frames` (a native diff can still emit zero bytes). `app:render(terminal)` and
`app:dispatch(event)` can drive the framework without opening a terminal; the
terminal adapter needs `size`, `fill`, `text`, and `present` methods.

```sh
build/bootstrap/lute/cli/lute test tests/batteries/ui.test.luau
build/bootstrap/tests/lute-tests --test-case='tui_*'
python3 tools/test_ui.py build/release/lute/cli/lute build/lute-workbench
build/release/lute/cli/lute tools/bench_ui.luau
```

The headless benchmark measures Lua-side update/layout/paint work, excluding
terminal I/O. It verifies that 10,000 field edits add zero layouts and zero
unrelated list row renders, with only 23 of 20,000 rows rendered initially.
PTY tests cover async redraws, error cleanup, preserved state across shrink/grow
(including zero-size OS reports), and the actual Workbench application. They use
a minimal cell reader for the renderer's ASCII CUP/SGR output, not a general
terminal emulator. macOS is validated locally; other platforms still need validation.
