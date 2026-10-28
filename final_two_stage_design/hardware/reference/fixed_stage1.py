"""Integer reference for the copied Stage 1 filter and fixed classifier."""
from __future__ import annotations

from pathlib import Path

from scipy.io import loadmat

from fixed_stage2 import clamp, tz_div

MODEL = Path(__file__).resolve().parents[2] / "stage1" / "models" / "pthighpass_svm_cpu_export.mat"
def signed32(n: int) -> int:
    return n if n < (1 << 31) else n - (1 << 32)


# Decode the exact two's-complement constants in 01_highpass_iir_filter.v.
COEFF = [signed32(x) for x in
         [0x000C4E29, 0xFFDB1585, 0x0024EA7B, 0xFFF3B1D7,
          0x0027A52B, 0xFFDEAA9C, 0x000976B8]]


def filter_samples(raw_q16_16: list[int]) -> list[int]:
    x = [0, 0, 0]
    y = [0, 0, 0]
    output = []
    for raw in raw_q16_16:
        sample = clamp(tz_div(raw, 1 << 8), -2048, 2047)
        next_y = (sample * COEFF[0] + x[0] * COEFF[1] +
                  x[1] * COEFF[2] + x[2] * COEFF[3] +
                  (y[0] * COEFF[4] >> 20) +
                  (y[1] * COEFF[5] >> 20) +
                  (y[2] * COEFF[6] >> 20))
        next_y = ((next_y + (1 << 63)) % (1 << 64)) - (1 << 63)
        x = [sample, x[0], x[1]]
        y = [next_y, y[0], y[1]]
        output.append(clamp(tz_div(next_y, 1 << 20), -2048, 2047))
    return output


def features(window_q8: list[int]) -> list[int]:
    assert len(window_q8) == 240
    mean_q8 = tz_div(sum(window_q8), 240)
    centered = [x - mean_q8 for x in window_q8]
    differences = [b - a for a, b in zip(window_q8, window_q8[1:])]
    signs = [d < 0 for d in differences if d != 0]
    zero_crossings = sum(a != b for a, b in zip(signs, signs[1:]))
    peak = max(map(abs, centered))
    above = [peak != 0 and 5 * abs(x) >= peak for x in centered]
    threshold_crossings = sum(a != b for a, b in zip(above, above[1:]))
    return [tz_div(sum(map(abs, centered)), 240), zero_crossings,
            sum(map(abs, differences)), threshold_crossings]


def coeffs() -> tuple[list[int], int]:
    model = loadmat(MODEL)
    weights = [round(float(v) * (1 << 24)) for v in model["W"].ravel()]
    bias = round(float(model["Bhw"].item()) * (1 << 40))
    return weights, bias


def score(feature_units: list[int]) -> int:
    weights, bias = coeffs()
    mean, zero, line, crossing = feature_units
    feature_q16_16 = [mean << 8, zero << 15, line << 7, crossing << 16]
    return bias + sum(w * x for w, x in zip(weights, feature_q16_16))
