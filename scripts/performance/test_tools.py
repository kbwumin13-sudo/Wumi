"""Pure-data tests only: no app, subprocess, fixture writes, or user files."""

import copy
import unittest

from compare import PHASES, RESOURCE_KEYS, comparable, summarize, validate
from make_fixtures import make_manifest


def good_report():
    return {
        "schemaVersion": 1, "harnessVersion": "20261020.1", "completed": True, "passed": True,
        "finishedAt": "2026-10-20T00:00:00Z", "failures": [], "largeCount": 5000,
        "fixturePath": "/fixture/5000", "environment": {},
        "validations": [{"name": "fixture", "passed": True}],
        "phases": [
            {"name": name, "resources": {key: 100 for key in RESOURCE_KEYS},
             "validations": [{"name": name + " final UI barrier", "passed": True}],
             "mainThreadHeartbeat": {"intervalMilliseconds": 20, "sampleCount": 4, "skippedTicksWhilePending": 2,
                                     "p50Milliseconds": 2, "p95Milliseconds": 100, "maxMilliseconds": 100,
                                     "delaysMilliseconds": [100, 2, 3, 1]}}
            for name in PHASES
        ],
    }


class ToolsTest(unittest.TestCase):
    def test_manifest_deterministic_disjoint_unique_orders(self):
        for count in (5000, 20000):
            manifest = make_manifest(count)
            self.assertEqual(manifest, make_manifest(count))
            self.assertEqual(len(manifest["directories"]), 12)
            seen = set()
            for directory in manifest["directories"]:
                entries = directory["entries"]
                names = {entry["name"] for entry in entries}
                self.assertTrue(seen.isdisjoint(names))
                seen |= names
                self.assertEqual(len(names), len(entries))
                self.assertEqual(len({entry["size"] for entry in entries}), len(entries))
                self.assertEqual(len({entry["mtime"] for entry in entries}), len(entries))
                self.assertNotEqual(sorted(entries, key=lambda x: x["name"]), sorted(entries, key=lambda x: x["size"]))
            self.assertEqual(len(next(d for d in manifest["directories"] if d["path"] == "large")["entries"]), count)

    def test_accept_complete_report_and_repeated_group_medians(self):
        report = validate(good_report())
        slower = copy.deepcopy(report)
        slower["phases"][0]["resources"]["wallMilliseconds"] = 300
        result = summarize({"baseline": [report, slower, slower], "optimized": [report]})
        self.assertEqual(result["groups"]["baseline"]["phases"][PHASES[0]]["wall_ms"], 300)
        self.assertAlmostEqual(result["ratiosToFirstGroup"]["optimized"][PHASES[0]]["wall_ms"], 1 / 3)

    def test_reject_false_success_missing_resources_and_bad_tail_latency(self):
        mutations = [
            lambda r: r.update(completed=False),
            lambda r: r["failures"].append("timeout"),
            lambda r: r["validations"][0].update(passed=False),
            lambda r: r["phases"].pop(),
            lambda r: r["phases"][0]["resources"].pop("cpuMilliseconds"),
            lambda r: r["phases"][0]["validations"].clear(),
            lambda r: r["phases"][0]["mainThreadHeartbeat"].update(p95Milliseconds=3),
            lambda r: r["phases"][0]["mainThreadHeartbeat"].update(sampleCount=3),
            lambda r: r["phases"][0]["resources"].update(wallMilliseconds=float("nan")),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                report = good_report()
                mutate(report)
                with self.assertRaises(ValueError):
                    validate(report)

    def test_reject_different_fixture(self):
        a, b = good_report(), good_report()
        b["largeCount"] = 20000
        with self.assertRaises(ValueError):
            comparable(a, b)


if __name__ == "__main__":
    unittest.main()
