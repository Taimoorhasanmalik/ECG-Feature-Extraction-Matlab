# Native 100 kHz full-core routed power comparison

Same 100 kHz source, 120 Hz input, 60 s synthetic normal workload; 0.9 V / 125 C.

| Case | Dynamic (uW) | Leakage (uW) | Total (uW) | Energy (uJ) |
| --- | ---: | ---: | ---: | ---: |
| adaptive_gated | 0.031860 | 2.241710 | 2.273570 | 136.414200 |
| fixed_ungated | 1.972390 | 2.241620 | 4.214010 | 252.840600 |

Combined frequency-and-gating total-power reduction: 46.047%.
Dynamic-power reduction: 98.385%.
Matched 66 classification IDs/codes and capture membership; latencies may differ.

Includes clock controller, mailbox and routed clock trees. External clock generation is excluded.
Functional gate simulation without SDF: no delay-dependent glitch estimate.
This comparison does not isolate gating alone or establish manufacturing/silicon power.

| Case | Non-filler cells | Cell area (um^2) | Setup WNS (ns) | Hold WNS (ns) |
| --- | ---: | ---: | ---: | ---: |
| adaptive_gated | 30363 | 117552.240 | 4998.200 | 0.022 |
| fixed_ungated | 30323 | 117652.788 | 4998.100 | 0.013 |

Non-filler area excludes row fillers and is not pad-inclusive die area.
