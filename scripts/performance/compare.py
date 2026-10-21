#!/usr/bin/env python3
"""Validate one or more real-app reports; compare medians of labeled, repeated runs."""

import argparse
import json
import math
import statistics
from pathlib import Path

PHASES = ("small_browse", "large_load", "repeated_sort", "application_grouping", "rapid_switch", "restore_tabs")
RESOURCE_KEYS = (
    "wallMilliseconds", "cpuMilliseconds", "footprintStartBytes", "footprintEndBytes",
    "footprintPeakSampledBytes", "wakeups", "readBytes", "writeBytes",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0


def validate(report):
    require(report.get("schemaVersion") == 1, "unknown schemaVersion")
    require(report.get("harnessVersion") == "20261020.1", "different harnessVersion")
    require(report.get("completed") is True and report.get("passed") is True, "incomplete or failed run")
    require(report.get("failures") == [], "run has failures")
    require(report.get("finishedAt"), "missing finishedAt")
    require(report.get("largeCount") in (5000, 20000), "unsupported fixture count")
    validations = report.get("validations", [])
    require(validations and all(check.get("passed") is True for check in validations), "missing/failed validation")
    phases = report.get("phases", [])
    require([phase.get("name") for phase in phases] == list(PHASES), "missing/reordered phase")
    for phase in phases:
        name = phase["name"]
        checks = phase.get("validations", [])
        require(checks and all(check.get("passed") is True for check in checks), f"{name}: missing/failed validation")
        require(any(check.get("name") == f"{name} final UI barrier" for check in checks), f"{name}: missing final UI barrier")
        resources = phase.get("resources", {})
        require(all(number(resources.get(key)) for key in RESOURCE_KEYS), f"{name}: missing/invalid process resources")
        require(resources["wallMilliseconds"] > 0, f"{name}: zero wall time")
        require(resources["footprintPeakSampledBytes"] >= max(resources["footprintStartBytes"], resources["footprintEndBytes"]),
                f"{name}: invalid sampled footprint peak")
        heartbeat = phase.get("mainThreadHeartbeat", {})
        require(heartbeat.get("intervalMilliseconds") == 20, f"{name}: wrong heartbeat interval")
        delays = heartbeat.get("delaysMilliseconds", [])
        require(delays and all(number(delay) for delay in delays), f"{name}: missing/invalid heartbeat samples")
        require(heartbeat.get("sampleCount") == len(delays), f"{name}: heartbeat sample count mismatch")
        skipped = heartbeat.get("skippedTicksWhilePending")
        require(isinstance(skipped, int) and not isinstance(skipped, bool) and skipped >= 0, f"{name}: invalid skipped ticks")
        ordered = sorted(delays)
        for field, quantile in (("p50Milliseconds", 0.50), ("p95Milliseconds", 0.95), ("maxMilliseconds", 1)):
            expected = ordered[max(0, math.ceil(len(ordered) * quantile) - 1)]
            require(number(heartbeat.get(field)) and abs(heartbeat[field] - expected) < 0.000001,
                    f"{name}: invalid {field}")
    return report


def comparable(a, b):
    require(a["harnessVersion"] == b["harnessVersion"], "harness differs")
    require(a["largeCount"] == b["largeCount"] and a["fixturePath"] == b["fixturePath"], "fixture differs")
    for key in ("operatingSystem", "hardwareModel", "processorCount", "physicalMemoryBytes"):
        require(a.get("environment", {}).get(key) == b.get("environment", {}).get(key), f"environment differs: {key}")


def summarize(groups):
    first = next(iter(groups.values()))[0]
    for reports in groups.values():
        for report in reports:
            comparable(first, report)
    metrics = {
        "wall_ms": ("resources", "wallMilliseconds"),
        "cpu_ms": ("resources", "cpuMilliseconds"),
        "footprint_peak_bytes": ("resources", "footprintPeakSampledBytes"),
        "wakeups": ("resources", "wakeups"),
        "read_bytes": ("resources", "readBytes"),
        "write_bytes": ("resources", "writeBytes"),
        "heartbeat_p50_ms": ("mainThreadHeartbeat", "p50Milliseconds"),
        "heartbeat_p95_ms": ("mainThreadHeartbeat", "p95Milliseconds"),
        "heartbeat_max_ms": ("mainThreadHeartbeat", "maxMilliseconds"),
    }
    result = {"statistic": "median of per-run phase measurements", "groups": {}, "ratiosToFirstGroup": {}}
    baseline = None
    for label, reports in groups.items():
        data = {}
        for index, name in enumerate(PHASES):
            data[name] = {
                metric: statistics.median(report["phases"][index][section][key] for report in reports)
                for metric, (section, key) in metrics.items()
            }
        result["groups"][label] = {"runs": len(reports), "phases": data}
        if baseline is None:
            baseline = data
        else:
            result["ratiosToFirstGroup"][label] = {
                name: {metric: value / baseline[name][metric] if baseline[name][metric] else None for metric, value in values.items()}
                for name, values in data.items()
            }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", help="LABEL=/path/performance.json; repeat labels for multiple runs")
    args = parser.parse_args()
    groups = {}
    for argument in args.reports:
        label, separator, path = argument.partition("=")
        if not separator:
            path = label
            label = Path(path).parent.name
        groups.setdefault(label, []).append(validate(json.loads(Path(path).read_text())))
    print(json.dumps(summarize(groups), indent=2, sort_keys=True, allow_nan=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f"FAIL: {error}") from error
