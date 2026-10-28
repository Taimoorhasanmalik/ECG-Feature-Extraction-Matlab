"""Two-stage pipeline figure showing the exact hardware-shared flow, in the
style of Publication_Figures/Two-Stage ECG Classification Pipeline.png:

  ECG -> shared Q3.8 front end
  Stage 1 path (always on):   3rd-order 5 Hz HPF -> Q3.8 -> window W1
  Stage 2 path (power-gated): 3rd-order 1 Hz HPF -> Q5.8 -> window W2
  Shared datapath (time-multiplexed by the scheduler every 1 s step):
      MUX (A: W1, B: W2) -> ONE feature engine -> ONE MAC + weight ROM
      slot A: 4 features x S1 weights -> s1 -> d[n] = (s1 >= T) -> 2-of-3 gate
      slot B: 6 features x S2 weights -> s2 -> sign(s2) -> VT or VF
  Gate no  -> Normal / other rhythm; gate yes -> enable Stage 2 + slot B.

Reuses the glyph / preview helpers of make_pipeline_figure.py (real ECG traces
and real |H(f)| curves). Modifies no existing file.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

import make_pipeline_figure as base
from make_pipeline_figure import Doc, buffer_svg, hf_svg, scatter_svg, signals, style, trace_svg

HERE = Path(__file__).resolve().parent
OUT = Path("E:/Thesis/Publication_Figures/hw_shared_two_stage_datapath.drawio")
base.W, base.H = 1690, 905
base.PREVIEW_HTML = HERE / "datapath_preview.html"
base.PREVIEW_PNG = HERE / "datapath_preview.png"


def timeline_svg(w=420, h=70):
    segments = [(10, 120, "#9ec5f0", "#2f5fa8", "slot A: Stage 1"), (120, 240, "#f4b6b6", "#c00000", "slot B: Stage 2"),
                (240, 410, "#e6e6e6", "#888888", "idle (clock-gated)")]
    body = f'<text x="{w / 2}" y="13" font-size="13" text-anchor="middle" font-style="italic">one 1 s step (every window)</text>'
    for x0, x1, fill, stroke, lab in segments:
        body += (f'<rect x="{x0}" y="22" width="{x1 - x0}" height="26" fill="{fill}" stroke="{stroke}" stroke-width="1.2"/>'
                 f'<text x="{(x0 + x1) / 2}" y="40" font-size="13" text-anchor="middle">{lab}</text>')
    body += ('<line x1="10" y1="50" x2="10" y2="56" stroke="#222"/><text x="10" y="67" font-size="12" text-anchor="middle">0</text>'
             '<line x1="410" y1="50" x2="410" y2="56" stroke="#222"/><text x="410" y="67" font-size="12" text-anchor="middle">1 s</text>')
    return base.uri(base.svg_open(w, h) + body + "</svg>")


def build():
    ecg_in, ecg_normal, ecg_vf = signals()
    vf_lim = float(np.ceil(np.max(np.abs(ecg_vf - np.median(ecg_vf)))))
    d = Doc()

    def panel(fill, grad, stroke, size=20):
        return style(arcSize=4, fillColor=fill, gradientColor=grad, gradientDirection="north", strokeColor=stroke,
                     strokeWidth=3, verticalAlign="top", fontSize=size, fontStyle=1, spacingTop=6)

    block = style(arcSize=8, fillColor="#e4eefa", strokeColor="#5b84c4", strokeWidth=1.5, verticalAlign="top", fontSize=17, spacingTop=6)
    feat = style(arcSize=6, fillColor="#e6f2de", strokeColor="#82b366", strokeWidth=1.5, verticalAlign="top", fontSize=17, spacingTop=6)
    mac = style(arcSize=6, fillColor="#e4eefa", strokeColor="#5b84c4", strokeWidth=1.5, verticalAlign="top", fontSize=17, spacingTop=6)
    pill = style(arcSize=22, fillColor="#d3eac4", strokeColor="#82b366", fontSize=14)
    pill2 = style(arcSize=22, fillColor="#bfe0a8", strokeColor="#5f9a3e", fontSize=14)
    img = "shape=image;html=1;imageAspect=0;image="
    arrow = "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;strokeWidth=2.5;strokeColor=#111111;"
    label = "fontFamily=Times New Roman;fontStyle=1;fontSize=14;labelBackgroundColor=#ffffff;"
    ctrl = ("edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;strokeWidth=1.5;dashed=1;"
            "strokeColor=#555555;fontColor=#333333;fontFamily=Times New Roman;fontSize=13;labelBackgroundColor=#ffffff;")
    red = ("edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;strokeWidth=2.5;strokeColor=#c00000;"
           "fontColor=#c00000;fontStyle=1;fontSize=15;fontFamily=Times New Roman;")

    # input
    d.box("in", "<b><font style=\"font-size:18px\">ECG Input</font></b><br>(single lead)", 8, 330, 165, 290,
          style(arcSize=6, fillColor="#e8edf6", strokeColor="#7d8fb0", strokeWidth=2, verticalAlign="top", fontSize=16, spacingTop=12))
    d.box("in_tr", "", 16, 415, 150, 100, img + trace_svg(ecg_in, "#1f5fd6", 1.5) + ";")
    d.box("in_txt", "120 Hz, Q3.8<br>(shared front end)", 8, 550, 165, 50, style(fillColor="none", strokeColor="none", fontSize=16))

    # per-stage paths: only the filter and the window are stage-specific
    d.box("p1", "Stage 1 path: Normal / Abnormal<br>(always on)", 215, 110, 415, 300, panel("#d9e7f7", "#eef5fd", "#1f4e9a"))
    d.box("p2", "Stage 2 path: VT / VF<br>(power-gated)", 215, 540, 415, 300, panel("#f9dcdc", "#fdf1f1", "#c00000"))
    for stage, y, fc, q, bits in ((1, 175, 5, "Q3.8", 12), (2, 605, 1, "Q5.8", 14)):
        d.box(f"hpf{stage}", f"<b>3rd-Order HPF</b><br>{fc} Hz (causal)<br>then {q}", 226, y, 180, 215, block)
        d.box(f"hpf{stage}_img", "", 241, y + 110, 150, 96, img + hf_svg(fc) + ";")
        d.box(f"win{stage}", f"<b>Window W{stage}</b><br>240 samples x {bits} bit<br>(stride = 120)", 420, y, 198, 215, block)
        d.box(f"win{stage}_img", "", 433, y + 100, 172, 100, img + buffer_svg() + ";")
        d.edge(f"a{stage}", f"hpf{stage}", f"win{stage}", arrow)

    # shared datapath
    d.box("sh", "Shared Datapath (time-multiplexed)", 650, 110, 505, 730, panel("#ece2f7", "#f8f4fd", "#7b4fb3", 22))
    d.box("timeline", "", 692, 185, 420, 70, img + timeline_svg() + ";")
    d.box("mux", "<b>A</b><br><br><b>MUX</b><br><br><b>B</b>", 662, 430, 56, 110,
          style(arcSize=10, fillColor="#e7dcf3", strokeColor="#7b4fb3", strokeWidth=1.5, fontSize=14))
    d.box("feat", "<b>Feature Extraction</b><br>(one shared engine)", 735, 330, 200, 310, feat)
    names = ["Mean abs. amplitude", "Zero-crossing count", "Line length (&Sigma;|&Delta;x|)", "Threshold crossings",
             "Local amp. range <i>(S2)</i>", "Amplitude transition <i>(S2)</i>"]
    for i, n in enumerate(names):
        d.box(f"f{i}", n, 747, 400 + 38 * i, 176, 30, pill if i < 4 else pill2)
    d.box("mac", "<b>Linear SVM</b><br>(one shared MAC)<br><font style=\"font-size:15px\">weight ROM<br>S1: 4 w + b &nbsp;|&nbsp; S2: 6 w + b</font>",
          955, 345, 185, 280, mac)
    d.box("mac_img", "", 975, 488, 146, 124, img + scatter_svg() + ";")
    d.box("sched", "<b>Scheduler</b> (every 1 s step)<br>slot A: W1 &#8594; 4 features &#8594; S1 weights &#8594; <i>s</i><sub>1</sub><br>"
                   "slot B (gate on): W2 &#8594; 6 features &#8594; S2 weights &#8594; <i>s</i><sub>2</sub>",
          735, 750, 405, 76, style(arcSize=10, fillColor="#f5f5f5", strokeColor="#666666", strokeWidth=1.5, fontSize=14, align="left", spacingLeft=10))
    d.edge("m1", "mux", "feat", arrow)
    d.edge("m2", "feat", "mac", arrow)
    d.edge("c1", "sched", "mux", ctrl + "exitX=0;exitY=0.6;entryX=0.5;entryY=1;", [(690, 795.6)], value="select",
           label_at=(668, 650))
    d.edge("c2", "sched", "mac", ctrl + "exitX=0.654;exitY=0;entryX=0.243;entryY=1;", value="ROM select",
           label_at=(966, 680))

    # windows into the shared MUX
    d.edge("w1", "win1", "mux", arrow + "exitX=1;exitY=0.5;entryX=0;entryY=0.25;", [(640, 282.5), (640, 457.5)])
    d.edge("w2", "win2", "mux", arrow + "exitX=1;exitY=0.5;entryX=0;entryY=0.75;", [(640, 712.5), (640, 512.5)])

    # MAC results
    d.box("s1", "<i><b><font style=\"font-size:20px\">s</font><sub>1</sub></b></i><br>(normal/abnormal<br>score)", 1175, 235, 105, 100,
          style(arcSize=10, fillColor="#dfeaf8", strokeColor="#2f5fa8", strokeWidth=1.5, fontSize=14))
    d.box("s2", "<i><b><font style=\"font-size:20px\">s</font><sub>2</sub></b></i><br>(VT/VF score)", 1175, 665, 105, 100,
          style(arcSize=10, fillColor="#fbd9d9", strokeColor="#c00000", strokeWidth=1.5, fontSize=14))
    d.edge("r1", "mac", "s1", arrow + label + "exitX=0.5;exitY=0;entryX=0;entryY=0.5;", [(1047.5, 285)], value="slot A",
           label_at=(1062, 292))
    d.edge("r2", "mac", "s2", arrow + label + "exitX=0.5;exitY=1;entryX=0;entryY=0.5;", [(1047.5, 715)], value="slot B",
           label_at=(1062, 690))

    # gate
    d.box("gate", "<b><font style=\"font-size:17px\">Sequence Gate</font></b><br>d[n] = 1 if <i>s</i><sub>1</sub> &ge; T<br>2-of-3 vote over<br>3 consecutive windows",
          1300, 320, 185, 275, style(arcSize=8, fillColor="#fde2bd", strokeColor="#e69500", strokeWidth=2.5, verticalAlign="top", fontSize=16, spacingTop=12))
    reg = style(arcSize=12, fillColor="#e7dcf3", strokeColor="#8e6bbf", strokeWidth=1.5, fontSize=13)
    for i, lab in enumerate(["d[n&#8722;2]", "d[n&#8722;1]", "d[n]"]):
        d.box(f"rg{i}", lab, 1309 + 57 * i, 455, 54, 34, reg)
    d.box("sum", "&Sigma; <i>d<sub>i</sub></i> &ge; 2", 1322, 528, 140, 40, style(arcSize=10, fillColor="#ffffff", strokeColor="#333333", strokeWidth=1.5, fontSize=16))
    thin = "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;strokeWidth=1.5;strokeColor=#111111;"
    for i in range(3):
        d.edge(f"rs{i}", f"rg{i}", "sum", thin + f"exitX=0.5;exitY=1;entryX={0.18 + 0.32 * i:.2f};entryY=0;")
    d.edge("g1", "s1", "gate", arrow + "exitX=1;exitY=0.5;entryX=0.5;entryY=0;", [(1392.5, 285)])

    # outputs
    d.box("o1", "<b><font style=\"font-size:18px\">Normal /<br>Other Rhythm</font></b>", 1510, 170, 172, 215,
          style(arcSize=8, fillColor="#eaf6ea", strokeColor="#2e8b3a", strokeWidth=2.5, verticalAlign="top", spacingTop=10))
    d.box("o1_tr", "", 1520, 267, 150, 100, img + trace_svg(ecg_normal, "#1f5fd6", 1.5) + ";")
    d.box("o2", "<b><font style=\"font-size:18px\">VT or VF</font></b>", 1510, 615, 172, 200,
          style(arcSize=8, fillColor="#fdeaea", strokeColor="#c00000", strokeWidth=2.5, verticalAlign="top", spacingTop=10))
    d.box("o2_tr", "", 1520, 675, 150, 100, img + trace_svg(ecg_vf, "#e02020", vf_lim) + ";")

    green = ("edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;strokeWidth=2.5;strokeColor=#2e8b3a;"
             "fontColor=#2e8b3a;fontStyle=1;fontSize=17;labelBackgroundColor=none;fontFamily=Times New Roman;")
    d.edge("no", "gate", "o1", green + "exitX=1;exitY=0.4;entryX=0;entryY=0.5;", [(1497, 430), (1497, 277.5)])
    d.box("no_lbl", "No", 1503, 392, 40, 26,
          style(fillColor="none", strokeColor="none", fontColor="#2e8b3a", fontStyle=1, fontSize=17, align="left"))
    d.edge("vt", "s2", "o2", red + "exitX=1;exitY=0.5;entryX=0;entryY=0.5;labelBackgroundColor=#ffffff;",
           value="sign(<i>s</i><sub>2</sub>)", label_at=(1320, 690))
    d.edge("yes", "gate", "p2", red + "dashed=1;jumpStyle=arc;jumpSize=12;exitX=0.5;exitY=1;entryX=0.5;entryY=1;",
           [(1392.5, 872), (422.5, 872)])
    d.box("yes_lbl", "Yes: enable Stage 2 (power gate + slot B)", 700, 874, 420, 26,
          style(fillColor="none", strokeColor="none", fontColor="#c00000", fontStyle=1, fontSize=15))

    d.edge("i1", "in", "hpf1", arrow + "exitX=1;exitY=0.5;entryX=0;entryY=0.5;", [(194, 475), (194, 282.5)])
    d.edge("i2", "in", "hpf2", arrow + "exitX=1;exitY=0.5;entryX=0;entryY=0.5;", [(194, 475), (194, 712.5)])
    return d


if __name__ == "__main__":
    doc = build()
    OUT.write_text(doc.drawio().replace(f'pageWidth="1550" pageHeight="905"', f'pageWidth="{base.W}" pageHeight="{base.H}"'),
                   encoding="ascii", errors="xmlcharrefreplace")
    base.preview(doc)
    print(f"Wrote {OUT}\nPreview {base.PREVIEW_PNG}")
