"""Unit-Tests für die Prüfungen in report.py (Stufe A). Nur Standardbibliothek:

    python3 -m unittest oracle/signed/test_report.py
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import report  # noqa: E402

DAY = report.DAY


def day(iso: str) -> int:
    return report.day_of(iso)


def write_report(out: Path, week_iso: str, weeks: dict[str, int]) -> None:
    (out / f"{week_iso}.json").write_text(json.dumps({"week_ending": week_iso, "weeks_used": weeks}))


class PlausibleTest(unittest.TestCase):
    def test_normal_values(self):
        report.check_plausible(250_000, 240_000)

    def test_range(self):
        report.check_plausible(80_000, 80_000)
        report.check_plausible(1_000_000, 1_000_000)
        for r, b in ((79_999, 100_000), (100_000, 79_999), (1_000_001, 900_000), (900_000, 1_000_001)):
            with self.assertRaises(report.ReportError):
                report.check_plausible(r, b)

    def test_ratio_including_exactly_two_to_one(self):
        report.check_plausible(400_000, 200_000)      # genau 2:1
        report.check_plausible(100_000, 200_000)      # genau 1:2
        with self.assertRaises(report.ReportError):
            report.check_plausible(400_001, 200_000)
        with self.assertRaises(report.ReportError):
            report.check_plausible(99_999, 200_000)


class DriftTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_small_correction_ok(self):
        write_report(self.out, "2026-09-05", {"2026-09-05": 60_000, "2026-08-29": 61_000})
        now = {day("2026-09-05"): 60_560, day("2026-08-29"): 61_000}     # +0,93 %
        self.assertEqual(report.drift_check(self.out, now), [])

    def test_plus_15_percent_reported(self):
        write_report(self.out, "2026-09-05", {"2026-09-05": 60_000})
        problems = report.drift_check(self.out, {day("2026-09-05"): 69_000})
        self.assertEqual(len(problems), 1)
        self.assertIn("2026-09-05", problems[0])

    def test_decrease_reported(self):
        write_report(self.out, "2026-09-05", {"2026-09-05": 60_000})
        self.assertEqual(len(report.drift_check(self.out, {day("2026-09-05"): 57_000})), 1)   # -5 %

    def test_missing_week_is_no_error(self):
        write_report(self.out, "2026-09-05", {"2026-09-05": 60_000, "2023-09-09": 55_000})
        self.assertEqual(report.drift_check(self.out, {day("2026-09-05"): 60_100}), [])

    def test_broken_file_reported(self):
        (self.out / "2026-09-05.json").write_text("{kaputt")
        (self.out / "2026-09-12.json").write_text(json.dumps({"keine": "weeks_used"}))
        problems = report.drift_check(self.out, {})
        self.assertEqual(len(problems), 2)
        self.assertTrue(all("unlesbar" in p for p in problems))

    def test_only_last_eight_files(self):
        # Die älteste von neun Dateien hat eine grosse Abweichung, wird aber nicht mehr geprüft.
        weeks = [f"2026-{m:02d}-{d:02d}" for m, d in ((7, 4), (7, 11), (7, 18), (7, 25), (8, 1),
                                                      (8, 8), (8, 15), (8, 22), (8, 29))]
        for w in weeks:
            write_report(self.out, w, {w: 60_000})
        now = {day(w): 60_000 for w in weeks}
        now[day(weeks[0])] = 80_000
        self.assertEqual(report.drift_check(self.out, now), [])
        now[day(weeks[1])] = 80_000
        self.assertEqual(len(report.drift_check(self.out, now)), 1)

    def test_threshold_configurable(self):
        write_report(self.out, "2026-09-05", {"2026-09-05": 60_000})
        now = {day("2026-09-05"): 61_500}                                   # +2,5 %
        self.assertEqual(report.drift_check(self.out, now), [])
        self.assertEqual(len(report.drift_check(self.out, now, max_drift=0.02)), 1)

    def test_index_json_and_other_files_ignored(self):
        (self.out / "index.json").write_text("[]")
        (self.out / "notiz.txt").write_text("x")
        self.assertEqual(report.drift_check(self.out, {}), [])


class StatusTest(unittest.TestCase):
    def test_status(self):
        self.assertEqual(report.status_of({"tx": "0x1"}), "ausgeführt")          # vor S6
        self.assertEqual(report.status_of({"tx": None}), "nicht gesendet")
        self.assertEqual(report.status_of({"proposed_tx": "0x1", "tx": "0x1"}), "offen")
        self.assertEqual(report.status_of({"proposed_tx": "0x1", "executed_tx": "0x2"}), "ausgeführt")
        self.assertEqual(report.status_of({"proposed_tx": "0x1", "vetoed": True}), "verworfen")


if __name__ == "__main__":
    unittest.main()
