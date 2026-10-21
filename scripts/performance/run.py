#!/usr/bin/env python3
"""Package isolated benchmark apps and run one sequential, externally bounded measurement."""
import argparse
import json
import plistlib
import shutil
import subprocess
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
ARTIFACTS = PROJECT / "artifacts/performance-20261020"
GROUPS = ("baseline-debug", "baseline-release", "optimized-release")


def package(group, binary, template=None):
    app = ARTIFACTS / "apps" / f"{group}.app"
    if app.exists():
        shutil.rmtree(app)
    shutil.copytree(template or ARTIFACTS / "baseline-debug.app", app)
    executable = app / "Contents/MacOS/DirDesk"
    shutil.copy2(binary, executable)
    info = app / "Contents/Info.plist"
    data = plistlib.loads(info.read_bytes())
    data.update(CFBundleIdentifier=f"com.kbwumin13.dirdesk.performance.{group}",
                CFBundleName="DirDesk", CFBundleDisplayName="DirDesk",
                CFBundleVersion="20261020perf")
    info.write_bytes(plistlib.dumps(data))
    sdk = subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip()
    subprocess.run(["vtool", "-set-build-version", "macos", "15.0", sdk, "-replace",
                    "-output", str(executable), str(executable)], check=True, capture_output=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)], check=True)
    return app


def run(group, label, action):
    app = ARTIFACTS / "apps" / f"{group}.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == f"com.kbwumin13.dirdesk.performance.{group}"
    output = ARTIFACTS / "runs" / label / group
    output.mkdir(parents=True, exist_ok=False)
    subprocess.run(["defaults", "delete", info["CFBundleIdentifier"]], capture_output=True)
    fixture = ARTIFACTS / "fixtures/5000"
    args = ["open", "-W", "-g", "-j", "-n", str(app), "--args",
            "-DirDeskSnapshotAction", action, "-DirDeskSnapshotDir", str(output),
            "-DirDeskPerformanceFixture", str(fixture), "-DirDeskSnapshotHidden", "YES",
            "-DirDeskApplicationSupport", str(output / "support"),
            "-dirdesk-startup-location-mode-v1", "fixedFolder",
            "-dirdesk-startup-fixed-path-v1", str(fixture / "small")]
    (output / "launch.json").write_text(json.dumps({"argv": args, "started": time.time()}, indent=2))
    with (output / "launcher.log").open("w") as log:
        process = subprocess.Popen(args, stdout=log, stderr=log)
        try:
            if action == "performance":
                code = process.wait(timeout=150)
                report = json.loads((output / "performance.json").read_text())
                from compare import validate
                validate(report)
                assert code == 0
                print(f"PASS {label}/{group}", flush=True)
            else:
                deadline = time.monotonic() + 150
                while time.monotonic() < deadline and not (output / "selftest-done").exists():
                    time.sleep(0.25)
                assert (output / "selftest-done").exists(), "selftest timeout"
                report = (output / "selftest.txt").read_text()
                print(report, flush=True)
                assert "FAIL " not in report
                print(f"PASS {label}/{group}; selfTest app remains open for GUI inspection", flush=True)
        except BaseException:
            # Only terminate an exact executable belonging to the isolated benchmark bundle.
            executable = str(app / "Contents/MacOS/DirDesk")
            for line in subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True).splitlines():
                pid, _, command = line.strip().partition(" ")
                if command.strip() == executable:
                    subprocess.run(["kill", "-TERM", pid], check=False)
            process.terminate()
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", choices=GROUPS)
    parser.add_argument("--binary", type=Path, help="Package the specified compiled binary; do not launch.")
    parser.add_argument("--template", type=Path, help="App template for current resources; default is the frozen baseline.")
    parser.add_argument("--label", default="pilot")
    parser.add_argument("--action", choices=("performance", "selfTest"), default="performance")
    args = parser.parse_args()
    if args.binary:
        print(package(args.group, args.binary.resolve(), args.template.resolve() if args.template else None))
    else:
        run(args.group, args.label, args.action)


if __name__ == "__main__":
    main()
