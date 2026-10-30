#!/usr/bin/env python3
"""Real editor workflow against temporary files and a PTY; no third-party packages.

Usage: python3 tools/test_editor.py path/to/lute [path/to/compiled-editor]
"""
import json
import os
from pathlib import Path
import select
import stat
import sys
import tempfile
import time
from test_ui import Terminal, ROOT

BINARY = str(Path(sys.argv[1]).resolve())
ENTRY = str(ROOT / "examples/editor/init.luau")
EXTENSION = str(ROOT / "examples/editor/metrics.luau")


def until(terminal, predicate, label, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        if select.select([terminal.master], [], [], 0.02)[0]:
            terminal.screen.feed(os.read(terminal.master, 65536))
        if terminal.child.poll() is not None:
            raise AssertionError((label, terminal.child.returncode, terminal.child.stderr.read().decode(), terminal.screen.text()))
    raise AssertionError((label, terminal.screen.text()))


def workflow(prefix):
    with tempfile.TemporaryDirectory(prefix="lute-editor-") as directory:
        source = Path(directory) / "sample.luau"
        original = "local function hello()\n    return 1\nend\nprint(hello())\n"
        source.write_text(original)
        source.chmod(0o755)
        cancellation = Terminal([BINARY, str(ROOT / "tests/editor/io_scope.luau"), str(source)])
        try:
            cancellation.finish()
        finally:
            cancellation.close()
        session = Path(directory) / "session.json"
        command = prefix + [str(source), "--session", str(session), "--extension", EXTENSION]
        terminal = Terminal(command, cwd=tempfile.gettempdir())
        try:
            terminal.waitfor("local function hello")
            terminal.send(b"\x1b[1;5F")  # Ctrl-End
            terminal.send(b"\x1b[200~-- saved from editor\n\x1b[201~")
            terminal.waitfor("Modified")
            source.write_text(original + "-- external change\n")
            terminal.send(b"\x13")
            terminal.waitfor("file changed on disk")
            assert source.read_text().endswith("-- external change\n")
            terminal.send(b"\x1bOP")
            terminal.waitfor("Commands /")
            terminal.send(b"Reload discarding changes\r")
            terminal.waitfor("Reloaded ")
            source.write_text(original)
            terminal.send(b"\x1b[15~")  # F5 reloads a clean document
            until(terminal, lambda: "-- external change" not in terminal.screen.text(), "reload did not update all views")
            terminal.send(b"\x1b[1;5F\x1b[200~-- saved from editor\n\x1b[201~")
            terminal.waitfor("Modified")
            terminal.send(b"\x13")  # Ctrl-S
            terminal.waitfor("Saved ")
            until(terminal, lambda: "-- saved from editor" in source.read_text(), "file did not save")
            assert stat.S_IMODE(source.stat().st_mode) == 0o755, "save changed permission bits"
            terminal.send(b"\x1a")  # Ctrl-Z
            terminal.waitfor("Modified")
            terminal.send(b"\x19")  # Ctrl-Y
            until(terminal, lambda: "Modified" not in terminal.screen.text(), "redo did not return to saved identity")
            terminal.send(b"\x06")  # Ctrl-F
            terminal.waitfor("Find /")
            terminal.send(b"return")
            terminal.waitfor("Match / Ln 2")
            terminal.send(b"\x1b")
            until(terminal, lambda: "Find /" not in terminal.screen.text(), "find pane did not close")
            terminal.send(b"\x07")  # Ctrl-G
            terminal.waitfor("Go to line")
            terminal.send(b"4\r")
            terminal.waitfor("Ln 4")
            terminal.send(b"\x1bOP")  # F1 command palette
            terminal.waitfor("Commands /")
            terminal.send(b"Save file\r")
            until(terminal, lambda: "Commands /" not in terminal.screen.text(), "command palette did not execute")
            terminal.send(b"\x1bOS")  # F4: another view of this document
            terminal.send(b"\x1b[200~-- shared view\n\x1b[201~")
            until(terminal, lambda: terminal.screen.text().count("-- shared view") >= 2, "split views did not share edits")
            terminal.send(b"\x1b[21~")  # F10 quit must refuse unsaved changes
            terminal.waitfor("Unsaved changes")
            assert terminal.child.poll() is None
            terminal.send(b"\x13")
            terminal.waitfor("Saved ")
            terminal.send(b"\x1bOR")  # F3: public-API outline pane
            terminal.waitfor("Outline")
            terminal.send(b"\x1b[19~")  # F8: separately loaded extension
            terminal.waitfor("Document statistics")
            terminal.waitfor("Bytes:")
            terminal.resize(30, 10)
            terminal.waitfor("LUTE EDITOR")
            terminal.resize(120, 40)
            terminal.waitfor("Document statistics")
            terminal.send(b"\x1b[21~")
            terminal.finish()
            contents = source.read_text()
            assert contents == "-- shared view\n" + original + "-- saved from editor\n", contents
            layout = json.loads(session.read_text())
            assert layout["version"] == 1
            assert "metrics" in session.read_text() and "outline" in session.read_text()
        finally:
            terminal.close()
        restored = Terminal(command, cwd=tempfile.gettempdir())
        try:
            restored.waitfor("Document statistics")
            restored.waitfor("Outline")
            restored.send(b"\x1b[21~")
            restored.finish()
            assert source.read_text() == contents, "session restore changed the document"
        finally:
            restored.close()
    print("PASS editor: edit/save, permissions, undo/redo, shared split, dirty quit guard, extension, resize, session restore")


lifecycle = Terminal([BINARY, str(ROOT / "tests/editor/lifecycle.luau")])
try:
    lifecycle.finish()
    print("PASS pane lifecycle: completed/canceled jobs, subscriptions, self-close, terminal cleanup")
finally:
    lifecycle.close()
workflow([BINARY, ENTRY])
if len(sys.argv) > 2:
    workflow([str(Path(sys.argv[2]).resolve())])
