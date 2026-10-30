# Editor API and terminal application

The editor consists of three layers in `batteries/editor`:

- A pure Luau document store for text, transactions, history, and change events.
- Independent document views with cursors, selections, scrolling, and lexical Luau colors.
- A workspace for panes, splits, tabs, commands, scoped resources, and layout state.

The application in [examples/editor/init.luau](../examples/editor/init.luau) uses
those APIs. Its file browser, source editor, command palette, find, go-to-line,
and [function outline](../examples/editor/outline.luau) are ordinary pane factories.
A [separately loaded extension](../examples/editor/metrics.luau) adds document
statistics using a custom drawing surface.

```sh
build/release/lute/cli/lute examples/editor/init.luau examples/tui.luau
# Build a standalone editor:
build/release/lute/cli/lute compile examples/editor/init.luau --output build/lute-editor
build/lute-editor examples/tui.luau
# Optional session file and external extension:
build/lute-editor . --session build/editor-session.json --extension examples/editor/metrics.luau
```

The first argument can be a file, a new file path in an existing directory, or a
directory. Sessions are saved only with an explicit `--session` path, on accepted
quit. They store layout, file paths, cursors, and extension state, not unsaved
buffer contents. A failed restore leaves the original session file untouched.
Extensions load before restoration and must return `install(workspace)`.

| Key | Action |
| --- | --- |
| Ctrl-O | Open/new file by path |
| Ctrl-S | Save the focused document |
| Ctrl-Z / Ctrl-Y | Undo / redo |
| Ctrl-F / Ctrl-G | Find literal text / go to line |
| Ctrl-A | Select all |
| Ctrl-C / Ctrl-X / Ctrl-V | Copy/cut/paste through the workspace's internal clipboard |
| Tab / Shift-Tab in code | Indent / outdent; other controls use Tab for focus |
| F1 | Command palette; filter, then Enter runs the selected command |
| F3 | Function outline |
| F4 | Another view of the current document in a split |
| F5 | Reload a clean focused document; refresh when the file browser is focused |
| F6 / F7 | Next pane / next tab |
| F8 | Statistics pane, if its extension is installed |
| Ctrl-W | Close the focused pane/tab, respecting unsaved edits |
| Ctrl-Q / F10 | Quit, respecting unsaved edits |
| Escape | Clear a code selection, or dismiss a prompt/palette |

Use **Reload discarding changes** or **Quit without saving** explicitly from the
palette to discard edits. Enter in a find pane advances to the next match.
Mouse clicks position the cursor or activate tabs; dragging selects, and the
wheel scrolls. The clipboard is internal, not integrated with the OS clipboard.

## Documents without a terminal

Import the package through a configured source alias or relative path, as for
[the UI battery](ui.md). The standalone application uses relative imports so its
dependencies are bundled. To use only the pure model, import `editor/document`;
the package entrypoint also loads the view/workspace runtime dependencies.

```luau
local editor = require("../batteries/editor")
local doc = editor.document("local answer = 41\n")
doc:edit({ line = 1, column = 15 }, { line = 1, column = 17 }, "42")
doc:undo()
doc:redo()
print(doc:text())
```

Positions use **one-based lines and zero-based UTF-8 byte columns**, excluding
line endings. Ranges are half-open. Edits validate scalar boundaries and UTF-8
before mutation; NUL-containing binary data is rejected. Document coordinates
are separate from terminal cells: tabs, combining marks, and wide characters
need display mapping in a view.

| Document method | Behavior |
| --- | --- |
| `line(index)`, `linecount()` | Read a line or the number of lines |
| `text()` | Materialize exact file content, including preserved line endings |
| `slice(first, last)` | Read a logical range, joining lines with LF |
| `edit(first, last, text)` | One undoable range replacement; returns the insertion endpoint |
| `undo()`, `redo()` | Apply history; return false when empty |
| `dirty()`, `marksaved()` | Compare/mark saved history identity |
| `revision()` | Monotonic mutation version, including undo/redo/reset |
| `onchange(callback, priority?)` | Subscribe; returns a disposal function |
| `reset(text)` | Load exact text as a clean document and clear history |
| `stats()` | Byte count, block count, line-index rebuild count, undo payload bytes |

Original mixed LF/CRLF/CR endings are retained by unchanged lines and undo.
Inserted newlines use the document's initial line-ending convention. History is
bounded by 10,000 transactions and roughly 8 MiB of text payload; the newest
transaction is retained even if it exceeds the payload budget.

A change contains `first`/`last` in the old document and `finish` in the new one,
plus `revision` and an optional `reset` marker. Listeners are synchronous and
must not yield or edit the same document recursively. Views settle their
positions before ordinary priority-zero listeners; lower priorities run first.
All listeners are visited before a listener error is rethrown. Queue follow-up
work instead of mutating the document inside its change notification.

## Independent views

`editor.view(doc, clipboard?)` returns a view with a mountable `widget`.
Two views can mount the same document in different panes, sharing history and
content while keeping their own cursor, selection, and viewport.

- `cursor()` returns a document position. `cellcolumn()` returns the zero-based
  visual column, expanding tabs at four-cell stops.
- `goto(line, byteColumn?)`, `move(direction, extendSelection?)`, and
  `select(anchor, head)` move/select. `selectedtext()` reads the selection.
- `insert(text)` replaces the selection, or inserts at the cursor.
- `undo()`, `redo()`, and `find(literal)` update the shared model or selection.
- `state()` / `restore(state)` save/load cursor and viewport state.
- `onstate(callback)` installs a state observer. `close()` disposes the view's
  document subscription; pane factories should register it with `ctx:onclose`.

Rendering includes line numbers, a software caret, selection, horizontal and
vertical scrolling, and incremental lexical Luau coloring. Long-bracket comments
and strings carry state between lines. Coloring isn't parsing or type analysis;
backtick interpolation is colored as string content. Editing moves by Unicode
scalar, not grapheme cluster, and inherits the native TUI's width limitations.
Soft wrapping, multiple selections, LSP/completion, and a system clipboard are
not implemented in this version.

## Register a pane

```luau
workspace:registerpane("test-results", function(ctx)
    local list = ctx.ui.list({ items = {} })
    ctx:on("tests.finished", function(report)
        list:setitems(report.items)
    end)
    ctx:command("tests.focus", "Focus test results", nil, function()
        workspace:focuspane(ctx.id)
    end)
    return {
        title = "Tests",
        view = list,
        save = function() return { selected = list:selected() } end,
    }
end)

workspace:openpane("test-results", { dock = "bottom", id = "tests" })
```

Factories receive `ctx.id`, restored `ctx.state`, `ctx.ui`, and `ctx.workspace`.
They return an unattached `view` and `title`. Optional fields:

- `save()` returns JSON-compatible extension state.
- `canclose()` vetoes normal close; explicit forced close bypasses it.
- `transient = true` omits prompts or temporary panes from saved layouts.
- `document` and `path` associate document-backed panes with the model.

The context owns `on(topic, callback)` subscriptions, `command(id, title, key?,
callback)` registrations, `spawn(callback)` tasks, and `onclose(callback)` cleanup.
`on` and `spawn` return idempotent disposal functions. Completed tasks release
their scope registrations. Closing disposes resources in reverse order, cancels
owned work, and prevents later scoped callbacks. A task closing its own pane can
finish its current callback. As with the UI runner, in-flight native operations
may finish after their Luau continuation has been canceled.

`ctx:emit(topic, payload)` publishes an event; `ctx:settitle(text)` and
`ctx:invalidate()` update pane presentation. Resource registration on a closed
context is rejected. Factories/paint callbacks should keep synchronous work short;
use scoped tasks for work that yields. Extension code has the runtime's normal
privileges; this is a module API, not a sandbox or package manager.

## Workspace API

`editor.workspace()` owns a UI `app`, `root`, `banner`, `statusbar`, and shared
`clipboard`. `run(options?)` opens the terminal and disposes panes on exit.
`quit(force?)` respects dirty documents; `close()` forcibly disposes resources.

- `openpane(kind, {id?, state?, dock?, target?})` adds a tab, or docks left/right/
  top/bottom of a target pane. `resizepane(id, percent)` adjusts its immediate split.
- `focuspane(id)`, `activepane()`, `panes()`, `nextpane()`, `nexttab()`, and
  `closepane(id, force?)` manage views. Widget identity survives layout rebuilding.
- `registercommand({id, title, key?, run, owner?})` returns a disposer.
  `execute(id)` and `commands()` use the focused pane's context. Pane commands
  shadow global IDs and keybindings; keys must be unique within a scope.
- `on(topic, callback)` / `emit(topic, payload)` form an application event bus.
  Built-in topics include `pane.focused`, `panes.changed`, `document.changed`,
  `document.saved`, and `workspace.quitting`.
- `snapshot()` / `restore(data)` handle versioned split/tab trees and pane state.
  Register factories first. Restore validates types/IDs and requires an empty
  workspace; a factory failure disposes already-created pane scopes.
- `opendocument(path)` returns the cached model for a normalized absolute path.
  `documents()` returns a copy of the path-to-document map.
- `savedocument(path)` refuses externally changed content, writes a temporary
  sibling, preserves existing regular-file permission bits via a copy, then
  renames it into place. Edits arriving during a save remain dirty. File operations
  own their cleanup independently of a canceled requesting pane.
- `reloaddocument(path, force?)` reads disk content into the existing model,
  preserving shared view identity while clearing history. Dirty reload requires
  explicit force. Concurrent edits during the read cause reload to fail.

The file layer currently refuses direct symbolic links. Save checks reduce
accidental overwrites but aren't a filesystem compare-and-swap or durable fsync
protocol; ownership, ACLs, and hard-link identity aren't promised. Reload or copy
your buffer elsewhere when an external-change conflict is reported.

## Custom drawing and performance

A pane can return `ctx.ui.surface({paint, input?, resize?}, options?)` instead of
standard controls. Its canvas has pane-local one-based coordinates, width,
height, focus, and `firstrow`/`lastrow` damage bounds. `text` and `fill` are clipped
at the boundary. Painting must not yield or mutate application state. Interactive
surfaces receive focus and can consume Tab before ordinary focus navigation.

`widget:invalidate(false, firstrow, lastrow)` coalesces row damage. The editor
uses it for local edits/caret changes; resizing or multiline lexical-state changes
expand damage as needed. A parent repaint overrides child damage safely.

The line store uses 256-line blocks: local character edits replace one line and
leave the block index intact. Structural edits rebuild the small block index.
Only visible rows are painted. Lexical state is cached incrementally; a first
jump into uncached content scans preceding lines to establish multiline state.
`text()`, initial loading, searching, large pastes, and saving remain proportional
to the affected file/range. A balanced rope and background parsing are possible
future improvements if measurements justify them.

```sh
build/bootstrap/lute/cli/lute test tests/batteries/editor.test.luau
python3 tools/test_editor.py build/release/lute/cli/lute build/lute-editor
build/release/lute/cli/lute tools/bench_editor.luau
```

The benchmark verifies one row per local edit/undo frame, no extra layout, and
no line-index rebuilds in a 20,000-line document. Timings exclude terminal I/O.
PTY tests edit real temporary files, check external-change refusal, save/reload,
permissions, dirty guards, shared views, commands, extension lifecycle, resizing,
and session restore. macOS is validated locally; other platforms need validation.
