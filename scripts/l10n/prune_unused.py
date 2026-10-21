#!/usr/bin/env python3
"""Removes keys that no Swift source mentions any more (not in an L()/LF() call, not in dynamic_keys.txt and not as
any string literal) from every language table.

Usage: prune_unused.py <project-root> [--dry-run]
"""
import importlib
import json
import pathlib
import re
import sys
import warnings

warnings.filterwarnings("ignore", category=DeprecationWarning)

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts" / "l10n"))
from languages import LANGUAGES  # noqa: E402

LIT = re.compile(r'"((?:[^"\\]|\\.)*)"')
literals = set()
for path in (root / "Sources").rglob("*.swift"):
    for match in LIT.finditer(path.read_text(encoding="utf-8")):
        raw = match.group(1)
        try:
            literals.add(raw.encode().decode("unicode_escape").encode("latin-1").decode("utf-8"))
        except (UnicodeDecodeError, UnicodeEncodeError):
            literals.add(raw)
dynamic = {line.strip() for line in (root / "scripts" / "l10n" / "dynamic_keys.txt").read_text(encoding="utf-8").splitlines()
           if line.strip() and not line.startswith("#")}
keep = literals | dynamic

for code, (module, name) in LANGUAGES.items():
    path = root / "scripts" / "l10n" / f"{module}.py"
    if not path.exists():
        continue
    table = getattr(importlib.import_module(module), name)
    kept = {k: v for k, v in table.items() if k in keep}
    removed = len(table) - len(kept)
    print(f"{code}: {len(table)} -> {len(kept)} (removed {removed})")
    if "--dry-run" in sys.argv or removed == 0:
        continue
    text = path.read_text(encoding="utf-8")
    header = text[: text.index(name + " = {")]
    body = "".join(f"    {json.dumps(k, ensure_ascii=False)}: {json.dumps(v, ensure_ascii=False)},\n" for k, v in kept.items())
    path.write_text(header + name + " = {\n" + body + "}\n", encoding="utf-8")
