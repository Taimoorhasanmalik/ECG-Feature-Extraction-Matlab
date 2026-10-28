"""Generate a synthetic 10-second, 120 Hz Q3.8 BRAM demonstration waveform."""
from __future__ import annotations

import math
from pathlib import Path

OUTPUT = Path(__file__).resolve().parents[1] / "mem_vectors" / "synthetic_two_stage_demo_q3_8.mem"


def main() -> None:
    values = []
    for i in range(1200):
        if i < 600:
            value = (0.65 * math.sin(2 * math.pi * 7 * i / 120)
                     + 0.27 * math.sin(2 * math.pi * 17 * i / 120)
                     + 0.08 * (i // 120))
        else:
            value = 0.10 if i % 2 == 0 else -0.10
        q8 = max(-2048, min(2047, math.trunc(value * 256)))
        values.append(f"{q8 & 0xfff:03x}\n")
    OUTPUT.write_text("".join(values), encoding="ascii")
    print(f"Generated {len(values)} synthetic samples at {OUTPUT}")


if __name__ == "__main__":
    main()
