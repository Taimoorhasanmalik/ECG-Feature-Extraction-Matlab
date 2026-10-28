"""Summarize a matched pair; never treat absent coverage as a pass."""
import csv
import math
import re
import sys
from pathlib import Path

MODES = ("gated_500hz", "ungated_100khz")


def results(log):
    pattern = re.compile(r"^RESULT .*stage2=(\d+) id=(\d+) code=(\d+) score_q40=(-?\d+)", re.M)
    values = pattern.findall(log)
    if not values or not re.search(r"^PASS:", log, re.M):
        raise ValueError("Missing classification results or simulation PASS")
    return values


def config(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)


def coverage(text):
    for prefix in ("Inputs", "Flop", "Driver nets", "RTL Driver nets"):
        row = re.search(r"^\s*" + re.escape(prefix) + r"\s+(.+)$", text, re.M)
        if not row:
            raise ValueError(f"Missing mapped coverage row: {prefix}")
        fields = row.group(1).split()
        if len(fields) != 8 or int(fields[2]) != 0:
            raise ValueError(f"Missing/unsupported/default mapped activity: {prefix}")
        counts = list(map(int, fields[:7]))
        if sum(counts[:6]) != counts[6]:
            raise ValueError(f"Inconsistent mapped coverage: {prefix}")
        if prefix in ("Inputs", "Flop") and counts[0] != counts[6]:
            raise ValueError(f"Not all {prefix} directly annotated")


def summarize(pair_dir):
    pair = Path(pair_dir).resolve()
    rows, traces, configs, libraries = [], [], [], []
    for mode in MODES:
        directory = pair / mode
        log = (directory / "simulation.log").read_text()
        traces.append(results(log))
        cfg = config(directory / "config.txt")
        if cfg.get("mode") != mode or cfg.get("direct_clock") != "1":
            raise ValueError("Incorrect case configuration")
        configs.append(tuple(cfg[key] for key in ("workload", "warmup_samples", "measure_samples", "rtl_dir")))
        reports = directory / "genus" / "reports"
        coverage((reports / "mapped_annotation.rpt").read_text())
        notes = (reports / "analysis_notes.txt").read_text()
        lib = re.search(r"^library=(.+)$", notes, re.M)
        if not lib:
            raise ValueError("Missing library provenance")
        libraries.append(lib[1])
        power = (reports / "preliminary_power.rpt").read_text()
        if not re.search(r"^Power Unit:\s*W\s*$", power, re.M):
            raise ValueError("Expected power unit W")
        subtotal = re.search(r"^\s*Subtotal\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", power, re.M)
        if not subtotal:
            raise ValueError("No power subtotal")
        leakage, internal, switching, total = map(float, subtotal.groups())
        if not all(math.isfinite(x) and x >= 0 for x in (leakage, internal, switching, total)) or total == 0:
            raise ValueError("Invalid power values")
        if not math.isclose(leakage + internal + switching, total, rel_tol=0.001):
            raise ValueError("Power subtotal is inconsistent")
        duration_s = int(cfg["measure_samples"]) / 120
        rows.append({"mode": mode, "seconds": duration_s, "leakage_uW": leakage * 1e6,
                     "internal_uW": internal * 1e6, "switching_uW": switching * 1e6,
                     "dynamic_uW": (internal + switching) * 1e6, "total_uW": total * 1e6,
                     "energy_uJ": total * 1e6 * duration_s})
    if traces[0] != traces[1] or configs[0] != configs[1] or libraries[0] != libraries[1]:
        raise ValueError("Classification scores/IDs, workload, duration, RTL location or libraries differ")
    proposed, baseline = rows
    saving = 100 * (baseline["total_uW"] - proposed["total_uW"]) / baseline["total_uW"]
    dynamic_saving = 100 * (baseline["dynamic_uW"] - proposed["dynamic_uW"]) / baseline["dynamic_uW"] if baseline["dynamic_uW"] else float("nan")
    with (pair / "comparison.csv").open("x", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    lines = ["# Direct-clock normal-workload comparison", "",
             "Pipeline-only pre-layout ASIC estimate. Divider, mailbox and external clock-generation power are excluded.", "",
             "| Case | Dynamic (uW) | Leakage (uW) | Total (uW) | Energy (uJ) |",
             "| --- | ---: | ---: | ---: | ---: |"]
    for row in rows:
        lines.append(f"| {row['mode']} | {row['dynamic_uW']:.6f} | {row['leakage_uW']:.6f} | {row['total_uW']:.6f} | {row['energy_uJ']:.6f} |")
    lines += ["", f"Combined frequency-and-gating total-power reduction: {saving:.3f}%.",
              f"Dynamic-power reduction: {dynamic_saving:.3f}%.",
              f"Matched {len(traces[0])} Stage 1 IDs/decisions/scores; each measurement spans {rows[0]['seconds']:g} s.",
              "", "This two-point comparison does not isolate frequency scaling from clock gating or establish FPGA/silicon power."]
    with (pair / "comparison.md").open("x") as handle:
        handle.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 summarize.py PAIR_DIRECTORY")
    try:
        summarize(sys.argv[1])
    except (OSError, ValueError, KeyError) as exc:
        raise SystemExit(f"Comparison not accepted: {exc}") from exc
