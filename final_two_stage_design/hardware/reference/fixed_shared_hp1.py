"""Bit-exact vectors for the candidate 1 Hz high-pass/shared-feature Stage 2.

Only synthetic input is written, to the caller-selected temporary directory.
The coefficients and all-data SVM weights are frozen from
hw_shared_pipeline/stage2/results/stage2_shared_alldata.mat.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import fixed_stage2

N = 240
B = [509480620, -1528441861, 1528441861, -509480620]
A = [-1554398152, 1501088162, -483487738]
W_Q13 = [-20428, -168, 562, 62, -5540, -2026]
BIAS_Q29 = 676986880


def filter_samples(raw_q16: list[int]) -> list[int]:
    xs = [0, 0, 0]
    ys = [0, 0, 0]
    out = []
    for raw in raw_q16:
        x = fixed_stage2.clamp(fixed_stage2.tz_div(raw, 256), -2048, 2047) << 21
        total = x * B[0] + sum(v * w for v, w in zip(xs, B[1:]))
        total -= sum(v * w for v, w in zip(ys, A))
        y = fixed_stage2.wrap_signed(fixed_stage2.tz_div(total, 1 << 29), 40)
        xs = [x, *xs[:2]]
        ys = [y, *ys[:2]]
        out.append(fixed_stage2.clamp(fixed_stage2.tz_div(y, 1 << 21), -8192, 8191))
    return out


def features(window: list[int]) -> list[int]:
    mean = fixed_stage2.tz_div(sum(window), N)
    centered = [x - mean for x in window]
    magnitude = [abs(x) for x in centered]
    difference = [b - a for a, b in zip(window, window[1:])]
    signs = [d < 0 for d in difference if d]
    zc = sum(a != b for a, b in zip(signs, signs[1:]))
    peak = max(magnitude)
    above = [peak != 0 and 5 * x >= peak for x in magnitude]
    crossings = sum(a != b for a, b in zip(above, above[1:]))
    blocks = [sum(magnitude[i:i + 30]) for i in range(0, N, 30)]
    return [
        fixed_stage2.clamp(sum(magnitude) // N, 0, 4095),
        zc,
        fixed_stage2.clamp(sum(map(abs, difference)) // 2, 0, 65535),
        crossings,
        fixed_stage2.clamp((max(blocks) - min(blocks)) // 30, 0, 4095),
        fixed_stage2.clamp(sum(abs(b - a) for a, b in zip(blocks, blocks[1:])) // 210, 0, 1023),
        0,
    ]


def score(row: list[int]) -> int:
    # Features in Q16.16: Q8 units shift 8; counts shift 16, zc / 2 shift 15.
    shifts = [8, 15, 8, 16, 8, 8]
    return BIAS_Q29 + sum((v << s) * w for v, s, w in zip(row, shifts, W_Q13))


def pack(row: list[int]) -> int:
    widths = [12, 9, 17, 9, 12, 12, 12]
    bits = 0
    for value, width in zip(reversed(row), reversed(widths)):
        bits = (bits << width) | (value & ((1 << width) - 1))
    return bits


def generate(destination: Path, count: int, mode: str) -> None:
    fixed_stage2.generate_smoke_vectors(destination, count=count, mode=mode,
                                        shared_frontend=True)
    raw = [int(line, 16) for line in (destination / "input.mem").read_text().splitlines()]
    raw = [fixed_stage2.wrap_signed(value, 32) for value in raw]
    filtered = filter_samples(raw)
    all_rows = [features(filtered[i:i + N]) for i in range(count - N + 1)]
    (destination / "filter.mem").write_text(
        "".join(f"{value & 0x3fff:04x}\n" for value in filtered), encoding="ascii")
    (destination / "all_features.mem").write_text(
        "".join(f"{pack(row):021x}\n" for row in all_rows), encoding="ascii")
    (destination / "all_scores.mem").write_text(
        "".join(f"{score(row) & ((1 << 64) - 1):016x}\n" for row in all_rows),
        encoding="ascii")
    print(f"candidate 1 Hz high-pass: {count} samples, {len(all_rows)} windows")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    parser.add_argument("--count", type=int, default=1200)
    parser.add_argument("--mode", choices=("mixed", "persistent", "reactivation", "stress"),
                        default="mixed")
    args = parser.parse_args()
    generate(args.destination, args.count, args.mode)
