#!/usr/bin/env python3
"""Regenerate tui's fixed, locale-independent scalar-width tables.

Run with Python exposing Unicode 16.0.0 (Python 3.14). No runtime dependency.
Complex emoji/grapheme shaping is deliberately not inferred from these tables.
"""
from pathlib import Path
import unicodedata as unicode


def intervals(predicate):
    start = last = None
    for codepoint in range(0x110000):
        if predicate(chr(codepoint)):
            if last is not None and codepoint == last + 1:
                last = codepoint
            else:
                if last is not None:
                    yield start, last
                start = last = codepoint
    if last is not None:
        yield start, last


def main():
    if unicode.unidata_version != "16.0.0":
        raise SystemExit("Use a Python with Unicode 16.0.0 to reproduce the checked-in tables")
    result = "// Generated from Python Unicode 16.0.0. Zero width: Mn/Me/Cf; wide: assigned W/F.\n"
    predicates = {
        "zeroWidth": lambda c: unicode.category(c) in ("Mn", "Me", "Cf"),
        "wideWidth": lambda c: unicode.category(c) != "Cn" and unicode.east_asian_width(c) in ("W", "F"),
    }
    for name, predicate in predicates.items():
        result += f"static constexpr Interval {name}[] = {{\n"
        result += "".join(f"    {{0x{first:x}, 0x{last:x}}},\n" for first, last in intervals(predicate))
        result += "};\n"
    root = Path(__file__).resolve().parent.parent
    (root / "lute/tui/src/widths.inc").write_text(result)


if __name__ == "__main__":
    main()
