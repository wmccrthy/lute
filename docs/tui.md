# Terminal UI

Lute exposes a native terminal API at `@lute/tui` and a scoped application helper
at `@std/tui`. It uses the existing libuv dependency; no curses, terminfo, or widget
framework is required. See [the checklist application](../examples/tui.luau).

```luau
local tui = require("@std/tui")

tui.run({ mouse = true }, function(term)
    while true do
        local width, height = term:size()
        term:clear()
        term:text(2, 2, "Hello from Luau", { fg = "#82aaff", bold = true })
        term:text(2, height, `Terminal width: {width}. Press q to quit.`)
        term:present()
        local event = term:read()
        if event.kind == "key" and (event.key == "q" or (event.ctrl and event.key == "c")) then
            break
        end
    end
end)
```

## Sessions and ownership

- `tui.supported()` checks that stdin and stdout are TTYs and `TERM` is not `dumb`.
  It does not negotiate terminal capabilities or reserve the terminal.
- `tui.open(options?)` creates one process-wide session. `mouse` defaults to false;
  `escapedelay` defaults to 30 milliseconds (valid range 1–1000).
- `tui.run(options?, application)` calls the application with a session, allows it
  to yield, closes the session on return or error, then rethrows application errors.
- `term:close()` is idempotent. Other methods reject closed sessions. A pending
  read is resumed with an error on close. A second simultaneous read or present
  on the same session is rejected.

Opening switches to raw input, enters the alternate screen, hides the cursor,
resets styles, and enables bracketed paste. Closing restores these modes. Runtime
shutdown and garbage collection also close open sessions. `process.exit` has an
exit hook for restoration. External SIGINT, SIGTERM, and (POSIX) SIGHUP restore the
terminal and re-raise the signal with its default disposition. While a session is
open these signals therefore terminate the application; do not combine it with
custom handlers for those same signals. Ctrl-C in raw input is a key event; the
application decides how to handle it. Uncatchable termination cannot run cleanup.

Do not mix terminal sessions with `print`, external subprocess terminal output,
or outstanding standard I/O operations. New `@lute/io.read/write` calls are rejected
while a session owns the terminal. The application owns terminal content until close.

## Drawing

- `term:size()` returns `width, height`, measured in terminal cells.
- `term:clear()` clears the desired frame, not the physical terminal immediately.
- `term:text(x, y, value, style?)` draws at **one-based** cell coordinates. Text is
  clipped to the screen. Newlines move down a row and return to the initial x.
  Other C0/C1 controls, including escape, are discarded so text cannot inject
  terminal commands. Coordinates must be in −4096…4096.
- `term:present()` sends changed cells in one buffered asynchronous write and
  yields until the write completes. An unchanged frame performs no write. You
  can clear and redraw the whole desired frame on every event; only differences
  are sent to the terminal. Resize forces a complete repaint.

Style fields are `fg`, `bg`, `bold`, `dim`, `italic`, `underline`, and `reverse`.
Colors are integer palette indices 0–255 or RGB strings such as `"#82aaff"`.
Omitted colors use terminal defaults. Each text call starts with default styles;
styles do not leak between calls. Indexed/RGB colors require terminal support;
there is no automatic color-depth detection or downgrade.

The renderer uses fixed Unicode 16.0 scalar-width tables: combining marks and
format characters occupy zero cells; assigned East Asian W/F characters occupy
two; ambiguous-width characters occupy one. Invalid UTF-8 becomes U+FFFD. Combining
marks attach to the preceding cell. Complex emoji graphemes (ZWJ sequences, flags,
and variation-selector presentation) are not shaped as a single glyph; their
width can differ from a terminal's display. Use simple text for aligned layouts.
Screens are bounded to 4096 per dimension and 1,048,576 total cells. Zero-size
OS viewport reports are clamped to 1×1.

Additional primitives support the [retained UI battery](ui.md):
`term:fill(x, y, width, height, style?)` fills a cell rectangle with spaces;
`tui.measure(text)` returns maximum line width and line count; and
`tui.clip(text, width, offset?)` clips a single line using a zero-based cell offset.
These helpers share the renderer's Unicode widths. Frames scan only touched rows.

## Events

`term:read()` returns the next event, yielding when none is queued:

| `kind` | Fields |
| --- | --- |
| `key` | `key`, `text`, `ctrl`, `alt`, `shift` |
| `paste` | `text` containing the exact bracketed-paste payload |
| `mouse` | `x`, `y`, `button`, `action`, `ctrl`, `alt`, `shift` |
| `resize` | `width`, `height` |

Named keys include `escape`, `enter`, `tab`, `backspace`, `space`, arrows,
`home`, `end`, `insert`, `delete`, `pageup`, `pagedown`, and `f1`–`f12`.
Printable keys use their UTF-8 text as `key` (space uses `"space"`). `text` is
empty for control and named keys. Ctrl-letter input and xterm modifiers are
decoded; protocols cannot distinguish every physical-key combination. Modifier
flags reflect encoded information, not inferred Shift/Caps Lock state.
Unknown completed escape sequences are ignored. A partial escape sequence times
out using `escapedelay`; a lone Escape then becomes its own key event. A longer
delay may help with remote terminals. Bracketed paste never times out as Escape.

Mouse coordinates are one-based. Buttons are 1=left, 2=middle, 3=right, 0=none.
Actions are `press`, `release`, `move`, `scrollup`, and `scrolldown`; scroll reports
use buttons 1/2 for the wheel direction. Mouse reporting is opt-in. Resize is
polled through libuv every 10 ms while the runtime is active, including Windows;
it does not depend on POSIX SIGWINCH. Consecutive queued resizes are coalesced.

Input is incremental across arbitrary read boundaries. Paste is limited to 1 MiB,
escape sequences to 128 bytes, and the event queue to 1024 entries. An overflow
closes the session and fails the reader instead of silently dropping typed input.
TTY, frame-write, and read errors likewise close the session.

## Protocol references and platform scope

The implementation follows [ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/)
for cursor positioning and SGR styles, and [xterm's control-sequence documentation](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
for alternate screen (`1049`), cursor visibility (`25`), bracketed paste (`2004`),
and SGR mouse reporting (`1002`/`1006`). Raw mode, dimensions, asynchronous input/output,
and mode restoration use [libuv's TTY API](https://docs.libuv.org/en/v1.x/tty.html).

Target terminals are UTF-8 VT-compatible emulators on macOS/Linux and modern
Windows terminals. The implementation uses `UV_TTY_MODE_RAW_VT` for Windows virtual
terminal input. Legacy Windows consoles and non-VT terminals are outside this
initial API. macOS has been exercised with real PTYs; Linux and Windows still
need platform validation. Full Unicode grapheme layout, widgets, and constraint
layout are follow-up work, not part of this primitive API.

## Build and verification

Use the existing [build instructions](../README.md#building-lute); no new project
dependencies are needed. After building, run:

```sh
build/bootstrap/tests/lute-tests --test-case='tui_*'
python3 tools/test_tui.py build/bootstrap/lute/cli/lute  # POSIX only
build/release/lute/cli/lute check examples/tui.luau
build/release/lute/cli/lute examples/tui.luau
# Optional standalone application:
build/release/lute/cli/lute compile examples/tui.luau --output build/tui-checklist
build/tui-checklist
```

Adjust binary paths to your build directory. C++ tests own input decoding,
bounds, and frame diffs. PTY tests exercise Luau contracts, yield/error cleanup,
resize, termination, and the actual example; they do not repeat the parser matrix.
`tools/generate_tui_widths.py` reproduces the checked-in width tables with a Python
whose `unicodedata` version is 16.0.0. Python is only needed for these developer tools.
