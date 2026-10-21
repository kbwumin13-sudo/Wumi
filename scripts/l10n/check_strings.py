#!/usr/bin/env python3
"""Lists L()/LF() keys used in Sources and reports keys missing from a .strings table.

Usage: check_strings.py <Sources-dir> <Localizable.strings> [--missing-only]
"""
import pathlib
import re
import sys

KEY = re.compile(r'\bLF?\("((?:[^"\\]|\\.)*)"')


def used_keys(root):
    keys = set()
    for path in pathlib.Path(root).rglob("*.swift"):
        for match in KEY.finditer(path.read_text(encoding="utf-8")):
            keys.add(match.group(1).encode().decode("unicode_escape").encode("latin-1").decode("utf-8"))
    return keys


def table_keys(path):
    text = pathlib.Path(path).read_text(encoding="utf-8") if pathlib.Path(path).exists() else ""
    return {m.group(1).replace('\\"', '"') for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.M)}


def dynamic_keys(root):
    path = pathlib.Path(__file__).with_name("dynamic_keys.txt")
    if not path.exists():
        return set()
    return {line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip() and not line.startswith("#")}


def main():
    used = used_keys(sys.argv[1]) | dynamic_keys(sys.argv[1])
    have = table_keys(sys.argv[2])
    missing = sorted(used - have)
    if "--missing-only" not in sys.argv:
        print(f"used {len(used)} keys, table has {len(have)}, missing {len(missing)}")
    for key in missing:
        print(key)


if __name__ == "__main__":
    main()
