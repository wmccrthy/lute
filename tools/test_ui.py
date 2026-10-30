#!/usr/bin/env python3
"""Exercise retained UI scheduling and viewport changes against an actual PTY.

Usage: python3 tools/test_ui.py path/to/lute [path/to/compiled-workbench]
The tiny screen reader handles only the native renderer's CUP/SGR/DEC output;
it lets assertions inspect final cell contents rather than raw diff fragments.
"""
import codecs
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parent.parent
BINARY = str(Path(sys.argv[1]).resolve())


class Screen:
    def __init__(self, width, height):
        self.pending = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.resize(width, height)

    def resize(self, width, height):
        self.width, self.height = width, height
        self.cells = [[" "] * width for _ in range(height)]
        self.x = self.y = 0

    def feed(self, data):
        self.pending += self.decoder.decode(data)
        offset = 0
        while offset < len(self.pending):
            char = self.pending[offset]
            if char == "\x1b":
                if offset + 1 >= len(self.pending):
                    break
                if self.pending[offset + 1] == "[":
                    end = offset + 2
                    while end < len(self.pending) and not ("@" <= self.pending[end] <= "~"):
                        end += 1
                    if end == len(self.pending):
                        break
                    body, final = self.pending[offset + 2:end], self.pending[end]
                    if final in "Hf":
                        coords = [int(v or "1") for v in body.split(";")]
                        self.y = coords[0] - 1
                        self.x = coords[1] - 1 if len(coords) > 1 else 0
                    elif final == "h" and body == "?1049":
                        self.resize(self.width, self.height)
                    offset = end + 1
                    continue
                offset += 2
                continue
            if char == "\r":
                self.x = 0
            elif char == "\n":
                self.y += 1
            elif char >= " ":
                if self.x >= self.width:
                    self.x = 0
                    self.y += 1
                if 0 <= self.y < self.height and 0 <= self.x < self.width:
                    self.cells[self.y][self.x] = char
                self.x += 1
            offset += 1
        self.pending = self.pending[offset:]

    def text(self):
        return "\n".join("".join(row) for row in self.cells)


class Terminal:
    def __init__(self, command, cwd=ROOT):
        self.master, self.slave = pty.openpty()
        self.before = termios.tcgetattr(self.slave)
        self.screen = Screen(100, 30)
        self.resize(100, 30)
        self.child = subprocess.Popen(command, stdin=self.slave, stdout=self.slave, stderr=subprocess.PIPE,
                                      cwd=cwd, env={**os.environ, "TERM": "xterm-256color"})

    def resize(self, width, height):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))
        self.screen.resize(max(1, width), max(1, height))

    def waitfor(self, text, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if text in self.screen.text():
                return
            if select.select([self.master], [], [], 0.02)[0]:
                self.screen.feed(os.read(self.master, 65536))
            if text in self.screen.text():
                return
            if self.child.poll() is not None:
                raise AssertionError(("process exited", self.child.returncode, self.child.stderr.read().decode(), self.screen.text()))
        raise AssertionError(("did not render", text, self.screen.text()))

    def send(self, data):
        os.write(self.master, data)

    def finish(self):
        # Keep consuming output during exit, just as a terminal emulator does;
        # otherwise a large final frame can fill the PTY and block its writer.
        deadline = time.monotonic() + 5
        while self.child.poll() is None and time.monotonic() < deadline:
            if select.select([self.master], [], [], 0.02)[0]:
                self.screen.feed(os.read(self.master, 65536))
        self.child.wait(timeout=0.1)
        errors = self.child.stderr.read().decode()
        assert self.child.returncode == 0 and not errors, (self.child.returncode, errors)
        after = termios.tcgetattr(self.slave)
        after[3] &= ~getattr(termios, "PENDIN", 0)
        self.before[3] &= ~getattr(termios, "PENDIN", 0)
        assert after == self.before, "terminal modes were not restored"

    def close(self):
        if self.child.poll() is None:
            self.child.kill()
            self.child.wait()
        self.child.stderr.close()
        os.close(self.master)
        os.close(self.slave)


def fixture():
    terminal = Terminal([BINARY, str(ROOT / "tests/tui/framework.luau")])
    try:
        terminal.waitfor("viewport 100x30")
        terminal.send(b"hello")
        terminal.waitfor("value hello")
        # The next label is set by an async task while read() is pending.
        terminal.waitfor("background ready")
        for width, height in [(40, 12), (0, 0), (120, 40), (1, 1), (60, 15)]:
            terminal.resize(width, height)
            if width > 1:
                terminal.waitfor(f"viewport {width}x{height}")
            else:
                # A one-cell viewport has no room for a marker. Wait for one
                # output byte so the grow tests a fully applied tiny layout.
                assert select.select([terminal.master], [], [], 3)[0], "tiny viewport never repainted"
                terminal.screen.feed(os.read(terminal.master, 65536))
        terminal.send(b"\x03")
        terminal.finish()
        print("PASS framework: async redraws, edit routing, shrink/grow including 0x0/1x1, clean shutdown")
    finally:
        terminal.close()


def workbench(command):
    terminal = Terminal(command, cwd=ROOT if len(command) > 1 else tempfile.gettempdir())
    try:
        terminal.waitfor("LUTE WORKBENCH")
        terminal.send(b"runtime")
        terminal.waitfor("2400 projects")
        terminal.send(b"\x1b[15~")  # F5 starts a build while the input owns focus.
        terminal.waitfor("Build complete:")
        terminal.resize(40, 12)
        terminal.waitfor("LUTE WORKBENCH")
        terminal.resize(120, 40)
        terminal.waitfor("Successful builds:")
        terminal.waitfor("2400 projects")
        terminal.send(b"\x03")
        terminal.finish()
        print("PASS workbench: filter 12,000 rows, async build, viewport shrink/grow, retained state")
    finally:
        terminal.close()


errors = Terminal([BINARY, str(ROOT / "tests/tui/framework_errors.luau")])
try:
    errors.finish()
    assert "caught framework errors" in errors.screen.text(), errors.screen.text()
    print("PASS framework: async job/paint errors propagate and release terminal ownership")
finally:
    errors.close()
fixture()
workbench([BINARY, str(ROOT / "examples/workbench/init.luau")])
if len(sys.argv) > 2:
    workbench([str(Path(sys.argv[2]).resolve())])
