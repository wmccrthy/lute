#!/usr/bin/env python3
"""POSIX PTY integration tests. No third-party Python packages required.

Usage: python3 tools/test_tui.py build/bootstrap/lute/cli/lute
Native parser/render tests live in Lute.Test; this exercises Luau bindings and
observable terminal state rather than repeating decoder assertions.
"""
import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

ROOT = Path(__file__).resolve().parent.parent
BINARY = str(Path(sys.argv[1]).resolve())
FIXTURE = str(ROOT / "tests/tui/session.luau")


def run(mode, action=None, example=False):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    before = termios.tcgetattr(slave)
    command = [BINARY, str(ROOT / "examples/tui.luau")] if example else [BINARY, FIXTURE, mode]
    child = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                             cwd=ROOT, env={**os.environ, "TERM": "xterm-256color"})
    output = bytearray()
    acted = False
    deadline = time.monotonic() + 8
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.02)
            if readable:
                try:
                    chunk = os.read(master, 65536)
                    output.extend(chunk)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
            marker = b"Lute / terminal checklist" if example else b"ready"
            if action and not acted and marker in output:
                action(child, master, slave)
                acted = True
            if child.poll() is not None:
                break
        else:
            raise AssertionError(f"{mode}: process hung; output={bytes(output)!r}")
        errors = child.stderr.read().decode(errors="replace")
        expected = -signal.SIGTERM if mode == "signal" else 0
        assert child.returncode == expected, (mode, child.returncode, errors, bytes(output))
        assert not action or acted, f"{mode}: never reached interactive frame"
        after = termios.tcgetattr(slave)
        # macOS can set PENDIN when tcsetattr restores canonical input. It is
        # transient kernel bookkeeping, not a terminal mode owned by the app.
        before[3] &= ~getattr(termios, "PENDIN", 0)
        after[3] &= ~getattr(termios, "PENDIN", 0)
        assert after == before, f"{mode}: terminal modes were not restored: {after!r}"
        # Drain the final restoration writes after process exit.
        while select.select([master], [], [], 0)[0]:
            output.extend(os.read(master, 65536))
        assert b"\x1b[?1049h" in output and b"\x1b[?1049l" in output, (mode, bytes(output))
        print(f"PASS {mode}")
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        child.stderr.close()
        os.close(master)
        os.close(slave)


def resize(_child, _master, slave):
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))


redirected = subprocess.run([BINARY, FIXTURE, "notty"], input=b"", capture_output=True, cwd=ROOT)
assert redirected.returncode == 0, redirected.stderr.decode()
print("PASS redirected stdin/stdout")
run("lifecycle", lambda _p, master, _s: os.write(master, b"\x1b[1;5A\x1b[200~hello\x1b[A\x1b[201~\x1b[<0;12;3M\x1b"))
run("error", lambda _p, master, _s: os.write(master, b"x"))
run("resize", resize)
run("pending")
run("shutdown")
run("exit")
run("signal", lambda child, _m, _s: child.send_signal(signal.SIGTERM))
run("example", lambda _p, master, _s: os.write(master, b"\x1b[B q"), example=True)
