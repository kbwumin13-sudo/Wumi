#!/usr/bin/env python3
"""Writes Resources/<lang>.lproj/Localizable.strings from the scripts/l10n/<lang> tables.

Usage: make_strings.py <project-root>
"""
import importlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts" / "l10n"))
from languages import LANGUAGES  # noqa: E402


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write(lang, table):
    folder = root / "Resources" / f"{lang}.lproj"
    folder.mkdir(parents=True, exist_ok=True)
    lines = [f'"{escape(k)}" = "{escape(v)}";' for k, v in sorted(table.items())]
    (folder / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")


# English needs entries only for context keys whose English text differs from the key (scripts/l10n/en.py).
english = root / "scripts" / "l10n" / "en.py"
write("en", importlib.import_module("en").EN if english.exists() else {})
for code, (module, name) in LANGUAGES.items():
    if not (root / "scripts" / "l10n" / f"{module}.py").exists():
        continue
    table = getattr(importlib.import_module(module), name)
    write(code, table)
    print(f"{code}: {len(table)} strings")
