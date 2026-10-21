#!/usr/bin/env python3
"""Appends new key/value pairs to scripts/l10n/zh_hans.py (skips keys already present).

Usage: add_strings.py <project-root> < pairs.tsv   (each line: English<TAB>中文)
"""
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
path = root / "scripts" / "l10n" / "zh_hans.py"
text = path.read_text(encoding="utf-8")
added = 0
lines = []
for raw in sys.stdin.read().splitlines():
    if not raw.strip():
        continue
    key, value = raw.split("\t", 1)
    if json.dumps(key, ensure_ascii=False) + ":" in text:
        continue
    lines.append(f"    {json.dumps(key, ensure_ascii=False)}: {json.dumps(value, ensure_ascii=False)},\n")
    added += 1
text = text.rstrip().rstrip("}") + "".join(lines) + "}\n"
path.write_text(text, encoding="utf-8")
print(f"added {added}")
