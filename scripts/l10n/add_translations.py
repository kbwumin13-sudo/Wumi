#!/usr/bin/env python3
"""Adds keys to every scripts/l10n/<language>.py table in one go (keys already present are skipped; --replace
overwrites their values).

Usage: add_translations.py <project-root> <strings.json> [--replace]

strings.json maps each English key to its translations by table module:
  {"Expand All": {"zh_hans": "全部展开", "zh_hant": "全部展開", "fr": "Tout développer", "de": "Alle aufklappen",
                  "es": "Expandir todo", "it": "Espandi tutto", "pt_br": "Expandir tudo", "ja": "すべて展開", "ko": "모두 펼치기"}}
"""
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
data = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
replace = "--replace" in sys.argv
sys.path.insert(0, str(root / "scripts" / "l10n"))
from languages import LANGUAGES  # noqa: E402

for module, _ in LANGUAGES.values():
    path = root / "scripts" / "l10n" / f"{module}.py"
    text = path.read_text(encoding="utf-8")
    added = replaced = 0
    for key, values in data.items():
        if module not in values:
            continue
        k = json.dumps(key, ensure_ascii=False)
        v = json.dumps(values[module], ensure_ascii=False)
        line = re.compile(r"^    " + re.escape(k) + r": .*,$", re.M)
        if line.search(text):
            if replace:
                text = line.sub(lambda _: f"    {k}: {v},", text, count=1)
                replaced += 1
            continue
        text = text.rstrip().rstrip("}") + f"    {k}: {v},\n}}\n"
        added += 1
    path.write_text(text, encoding="utf-8")
    print(f"{module}: added {added}, replaced {replaced}")
