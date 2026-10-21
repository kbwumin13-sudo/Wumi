#!/usr/bin/env python3
"""Generate only DirDesk's private, deterministic performance fixtures. Never launch an app."""

import argparse
import json
import math
import os
from pathlib import Path

EXTENSIONS = ("txt", "md", "json", "csv", "html", "png", "pdf", "dirdeskperfunknown")


def make_manifest(count):
    if count not in (5000, 20000):
        raise ValueError("large count must be 5000 or 20000")
    specs = [("small", 32), ("large", count), ("switch-a", 37), ("switch-b", 53)]
    specs += [(f"tab-{index:02}", 24 + index) for index in range(8)]
    directories = []
    for name, length in specs:
        # Coprime multipliers give unique, deliberately unrelated size/date/name orders.
        assert math.gcd(7919, length) == math.gcd(3571, length) == 1
        entries = [
            {
                "name": f"{name}-{index:05}.{EXTENSIONS[index % len(EXTENSIONS)]}",
                "size": 32 + (index * 7919 + 17) % length,
                "mtime": 1700000000 + (index * 3571) % length,
            }
            for index in range(length)
        ]
        directories.append({"path": name, "entries": entries})
    return {"schemaVersion": 1, "largeCount": count, "directories": directories}


def require_real_path(path):
    if path.resolve() != path.absolute():
        raise ValueError(f"refusing a path containing symlinks: {path}")


def verify(root, manifest):
    require_real_path(root)
    if set(p.name for p in root.iterdir()) != {"manifest.json"} | {
        directory["path"] for directory in manifest["directories"]
    }:
        raise ValueError("unexpected fixture root entries; nothing removed")
    for directory in manifest["directories"]:
        folder = root / directory["path"]
        require_real_path(folder)
        if {p.name for p in folder.iterdir()} != {entry["name"] for entry in directory["entries"]}:
            raise ValueError(f"unexpected/missing entries in {folder}; nothing removed")
        for entry in directory["entries"]:
            file = folder / entry["name"]
            require_real_path(file)
            info = file.stat()
            if not file.is_file() or info.st_size != entry["size"] or abs(info.st_mtime - entry["mtime"]) > 0.001:
                raise ValueError(f"fixture metadata mismatch: {file}")


def generate(root, manifest, verify_only=False):
    require_real_path(root)
    manifest_file = root / "manifest.json"
    if root.exists():
        # Existing data are verified, never replaced or deleted, including interrupted generations.
        require_real_path(manifest_file)
        if json.loads(manifest_file.read_text()) != manifest:
            raise ValueError(f"existing manifest differs: {manifest_file}; nothing changed")
        verify(root, manifest)
        return
    if verify_only:
        raise ValueError(f"missing fixture: {root}")
    root.mkdir(parents=True, exist_ok=False)
    for directory in manifest["directories"]:
        folder = root / directory["path"]
        folder.mkdir()
        for entry in directory["entries"]:
            path = folder / entry["name"]
            with path.open("xb") as handle:
                handle.write(b"DirDesk performance fixture\n")
                handle.truncate(entry["size"])
            os.utime(path, (entry["mtime"], entry["mtime"]), follow_symlinks=False)
    manifest_file.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    verify(root, manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, choices=(5000, 20000), default=5000)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    project = Path(__file__).absolute().parents[2]
    root = project / "artifacts/performance-20261020/fixtures" / str(args.count)
    generate(root, make_manifest(args.count), args.verify_only)
    print(root)


if __name__ == "__main__":
    main()
