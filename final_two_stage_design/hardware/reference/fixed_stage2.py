"""Bit-exact integer reference for the Stage 2 RTL in this package.

The original model uses float64 IIR coefficients. This module defines the
deployable fixed-point model by rounding those coefficients to signed Q2.29,
then uses only Python integers for every filter and feature operation.
"""
from __future__ import annotations

import argparse
import json
import math
import random
from pathlib import Path

MODEL = Path(__file__).resolve().parents[2] / "stage2" / "deliverable" / "stage2_hardware_model.json"
N = 240
SHARED_FRONTEND_WEIGHTS_Q13 = [-7552, 188, -1, 3, -7552, -5190, 1166]
SHARED_FRONTEND_BIAS_Q13 = 8118


def tz_div(n: int, d: int) -> int:
    return n // d if n >= 0 else -((-n) // d)


def clamp(n: int, low: int, high: int) -> int:
    return min(max(n, low), high)


def wrap_signed(n: int, bits: int) -> int:
    return ((n + (1 << (bits - 1))) % (1 << bits)) - (1 << (bits - 1))


def coeffs() -> tuple[list[int], list[list[int]], list[int], int]:
    model = json.loads(MODEL.read_text(encoding="utf-8"))
    # These integer constants are frozen in RTL after export. Python round
    # uses ties-to-even, as does the coefficient-generation step.
    dc = [535469054, -535469054, -534067196]
    sos = [[round(v * (1 << 29)) for v in row] for row in model["filter"]["sos_with_gain_folded_in"]]
    weights = [int(v * 8192) for v in model["classifier"]["weight_fixed_point_q2_13"]]
    bias = int(model["classifier"]["bias_fixed_point_q2_13"] * 8192)
    return dc, sos, weights, bias


def filter_samples(raw_q16_16: list[int]) -> list[int]:
    dc, sos, _, _ = coeffs()
    dx1 = dy1 = 0
    state = [[0, 0, 0, 0] for _ in sos]  # x1,x2,y1,y2, all Q16.29
    result = []
    for raw in raw_q16_16:
        dy = wrap_signed(tz_div(raw * dc[0] + dx1 * dc[1] - dy1 * dc[2], 1 << 29), 32)
        dx1, dy1 = raw, dy
        x = clamp(tz_div(dy, 1 << 8), -8192, 8191) << 21
        for row, s in zip(sos, state):
            b0, b1, b2, _, a1, a2 = row
            y = wrap_signed(tz_div(x * b0 + s[0] * b1 + s[1] * b2 - s[2] * a1 - s[3] * a2, 1 << 29), 40)
            s[1], s[0], s[3], s[2] = s[0], x, s[2], y
            x = y
        result.append(clamp(tz_div(x, 1 << 21), -8192, 8191))
    return result


def features(window_q8: list[int]) -> list[int]:
    assert len(window_q8) == N
    total = sum(window_q8)
    centered = [N * x - total for x in window_q8]
    magnitudes = [abs(x) for x in centered]
    peak = max(magnitudes)
    differences = [b - a for a, b in zip(window_q8, window_q8[1:])]
    derivative_abs_sum = sum(map(abs, differences))
    retained = [d < 0 for d in differences if 4780 * abs(d) > derivative_abs_sum]
    zc = sum(a != b for a, b in zip(retained, retained[1:]))
    above = [peak != 0 and 5 * a >= peak for a in magnitudes]
    crossing = sum(a != b for a, b in zip(above, above[1:]))
    blocks = [sum(magnitudes[i:i + 30]) for i in range(0, N, 30)]
    mean = clamp(sum(magnitudes) // 57600, 0, 2047)
    return [
        mean,
        clamp(sum(map(abs, differences)), 0, 65535),
        zc,
        crossing,
        mean,
        clamp((max(blocks) - min(blocks)) // 7200, 0, 2047),
        clamp(sum(abs(b - a) for a, b in zip(blocks, blocks[1:])) // 50400, 0, 2047),
    ]


def score(feature_units: list[int], shared_frontend: bool = False) -> int:
    _, _, weights, bias = coeffs()
    if shared_frontend:
        weights, bias = SHARED_FRONTEND_WEIGHTS_Q13, SHARED_FRONTEND_BIAS_Q13
    scales = [8, 8, 16, 16, 8, 8, 8]
    return (bias << 16) + sum((v << shift) * w for v, shift, w in zip(feature_units, scales, weights))


def shared_raw_q16_16(raw_q16_16: list[int]) -> list[int]:
    """One pre-filter Q3.8 quantizer shared by both filter paths."""
    return [clamp(tz_div(v, 1 << 8), -2048, 2047) << 8 for v in raw_q16_16]


def generate_smoke_vectors(destination: Path, count: int = 600, mode: str = "mixed",
                           shared_frontend: bool = False) -> None:
    import fixed_stage1
    destination.mkdir(parents=True, exist_ok=True)
    # Values fit Q16.16. Mixed components exercise both filter poles and
    # all local-amplitude/block features; no database material is copied.
    if mode == "stress":
        rng = random.Random(29)
        raw = [rng.randint(-20*65536,20*65536) if i % 97 else
               (25*65536 if i % 2 else -25*65536) for i in range(count)]
    else:
        raw = [round(((0.65 * math.sin(2 * math.pi * 7 * i / 120)
                       + 0.27 * math.sin(2 * math.pi * 17 * i / 120)
                       + 0.08 * (i // 120)) if
                      (i < 600 if mode == "mixed" else
                       i < 900 if mode == "persistent" else
                       i < 360 or i >= 1800) else
                      (0.10 if i % 2 == 0 else -0.10)) * (1 << 16))
               for i in range(count)]
    filtered = filter_samples(shared_raw_q16_16(raw) if shared_frontend else raw)
    windows = [features(filtered[i:i + N]) for i in range(0, count - N + 1, 120)]
    stage1_filtered = fixed_stage1.filter_samples(raw)
    stage1_windows = [fixed_stage1.features(stage1_filtered[i:i + N])
                      for i in range(0, count - N + 1, 120)]
    stage1_scores = [fixed_stage1.score(row) for row in stage1_windows]
    votes = [v >= 0 for v in stage1_scores]
    (destination / "input.mem").write_text("".join(f"{v & 0xffffffff:08x}\n" for v in raw), encoding="ascii")
    (destination / "filter.mem").write_text("".join(f"{v & 0x3fff:04x}\n" for v in filtered), encoding="ascii")
    (destination / "stage1_filter.mem").write_text(
        "".join(f"{v & 0xfff:03x}\n" for v in stage1_filtered), encoding="ascii")
    widths = [12, 17, 9, 9, 12, 12, 12]
    def packed(row: list[int]) -> int:
        value = 0
        for item, width in zip(reversed(row), reversed(widths)):
            value = (value << width) | (item & ((1 << width) - 1))
        return value
    (destination / "features.mem").write_text("".join(f"{packed(row):021x}\n" for row in windows), encoding="ascii")
    (destination / "scores.mem").write_text("".join(f"{score(row, shared_frontend) & ((1 << 64) - 1):016x}\n" for row in windows), encoding="ascii")
    if shared_frontend:
        # Trigger-aligned Stage 2 starts are not restricted to the 120-sample
        # Stage 1 phase. Export every possible complete 240-sample span.
        all_windows = [features(filtered[i:i + N]) for i in range(count - N + 1)]
        (destination / "all_features.mem").write_text(
            "".join(f"{packed(row):021x}\n" for row in all_windows), encoding="ascii")
        (destination / "all_scores.mem").write_text(
            "".join(f"{score(row, True) & ((1 << 64) - 1):016x}\n"
                    for row in all_windows), encoding="ascii")
        all_stage1 = [fixed_stage1.score(fixed_stage1.features(stage1_filtered[i:i + N]))
                      for i in range(count - N + 1)]
        (destination / "all_stage1_scores.mem").write_text(
            "".join(f"{v & ((1 << 64) - 1):016x}\n" for v in all_stage1),
            encoding="ascii")
    (destination / "features.csv").write_text(
        "".join(",".join(map(str, row)) + "\n" for row in windows), encoding="ascii")
    (destination / "scores_dec.csv").write_text(
        "".join(f"{score(row, shared_frontend)}\n" for row in windows), encoding="ascii")
    (destination / "stage1_scores.mem").write_text(
        "".join(f"{v & ((1 << 64) - 1):016x}\n" for v in stage1_scores), encoding="ascii")
    if not shared_frontend:
        classes = [0 if sum(votes[i-2:i+1]) < 2 else
                   (2 if score(windows[i]) > 0 else 1)
                   for i in range(2, len(windows))]
        (destination / "combined.mem").write_text(
            "".join(f"{v:01x}\n" for v in classes), encoding="ascii")
    print(f"generated {count} samples and {len(windows)} windows in {destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    parser.add_argument("--count", type=int, default=600)
    parser.add_argument("--mode", choices=["mixed","stress","reactivation","persistent"], default="mixed")
    parser.add_argument("--shared-frontend", action="store_true")
    args = parser.parse_args()
    generate_smoke_vectors(args.destination, args.count, args.mode, args.shared_frontend)
