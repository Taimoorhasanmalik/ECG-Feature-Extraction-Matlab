"""Synthetic report tests. These fixtures are NOT measured power results."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("direct_summary", Path(__file__).resolve().parents[1] / "summarize.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SummaryTests(unittest.TestCase):
    def test_results_ignore_clock_latency_but_compare_scores(self):
        first = "RESULT time_ns=10 stage2=0 id=2 code=0 score_q40=-7 measured=0\nPASS:\n"
        second = "RESULT time_ns=20 stage2=0 id=2 code=0 score_q40=-7 measured=1\nPASS:\n"
        self.assertEqual(MODULE.results(first), MODULE.results(second))
        self.assertNotEqual(MODULE.results(first), MODULE.results(second.replace("-7", "-8")))

    def test_coverage_requires_no_defaults(self):
        text = "\n".join(f"{row} 10 0 0 20 0 0 30 33.33%" for row in ("Driver nets", "RTL Driver nets"))
        text += "\nInputs 2 0 0 0 0 0 2 100.00%\nFlop 9 0 0 0 0 0 9 100.00%\n"
        MODULE.coverage(text)
        with self.assertRaises(ValueError):
            MODULE.coverage(text.replace("10 0 0 20", "10 0 1 19"))

    def test_pair_report_calculates_savings(self):
        with tempfile.TemporaryDirectory(prefix="ecg_direct_summary_") as root:
            pair = Path(root)
            for mode, total in (("gated_500hz", "3e-6"), ("ungated_100khz", "6e-6")):
                case = pair / mode
                reports = case / "genus" / "reports"
                reports.mkdir(parents=True)
                (case / "simulation.log").write_text("RESULT time_ns=10 stage2=0 id=2 code=0 score_q40=-7 measured=1\nPASS:\n")
                (case / "config.txt").write_text(f"mode={mode}\ndirect_clock=1\nworkload=normal\nwarmup_samples=1200\nmeasure_samples=7200\nrtl_dir=/fixture/FinalRTL\n")
                (reports / "mapped_annotation.rpt").write_text("\n".join(f"{row} 10 0 0 0 0 0 10 100.00%" for row in ("Inputs", "Flop", "Driver nets", "RTL Driver nets")))
                (reports / "analysis_notes.txt").write_text("library=/fixture/library.lib\n")
                internal = "1e-6" if mode == "gated_500hz" else "4e-6"
                (reports / "preliminary_power.rpt").write_text(f"Power Unit: W\nSubtotal 1e-6 {internal} 1e-6 {total} 100.00%\n")
            MODULE.summarize(pair)
            self.assertIn("50.000%", (pair / "comparison.md").read_text())
            self.assertIn("gated_500hz", (pair / "comparison.csv").read_text())
            with self.assertRaises(FileExistsError):
                MODULE.summarize(pair)


if __name__ == "__main__":
    unittest.main()
