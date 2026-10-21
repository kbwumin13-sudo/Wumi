#!/usr/bin/env python3
"""Checks every translation table against the Simplified Chinese table (the list of keys in use):
missing keys, extra keys, and format specifiers that differ from the English key.

Usage: check_translations.py <project-root> [lang-code ...]
"""
import importlib
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts" / "l10n"))
from languages import LANGUAGES  # noqa: E402

SPEC = re.compile(r"%(?:(\d+)\$)?(@|lld|ld|d|f|\.\d+f|%)")


def specifiers(text):
    """Format specifiers as an ordered list of types, positional ones placed at their index."""
    found = SPEC.findall(text)
    plain = [t for pos, t in found if not pos and t != "%"]
    positional = {int(pos): t for pos, t in found if pos}
    if positional:
        return [positional.get(i + 1) for i in range(max(positional))]
    return plain


reference = importlib.import_module("zh_hans").ZH
codes = sys.argv[2:] or [c for c in LANGUAGES if c != "zh-Hans"]
problems = 0
for code in codes:
    module, name = LANGUAGES[code]
    if not (root / "scripts" / "l10n" / f"{module}.py").exists():
        print(f"{code}: no table")
        continue
    table = getattr(importlib.import_module(module), name)
    missing = sorted(set(reference) - set(table))
    extra = sorted(set(table) - set(reference))
    bad = [k for k, v in table.items() if sorted(filter(None, specifiers(k))) != sorted(filter(None, specifiers(v)))]
    print(f"{code}: {len(table)} strings, missing {len(missing)}, extra {len(extra)}, format mismatches {len(bad)}")
    for key in missing[:10]:
        print("  missing:", key)
    for key in bad[:10]:
        print("  format:", key, "=>", table[key])
    problems += len(missing) + len(bad)
sys.exit(1 if problems else 0)
