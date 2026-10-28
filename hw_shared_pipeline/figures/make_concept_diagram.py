"""Builds the compact concept figure of the hardware-shared two-stage design
as a draw.io file, with small ECG traces computed by the actual pipeline
(shared Q3.8 front end, Stage 1's 5 Hz high-pass, Stage 2's 1 Hz high-pass)
on a real MIT-BIH record. Also writes a PNG preview for checking.

Modifies no existing file.
"""

from __future__ import annotations

import base64
import math
import sys
from pathlib import Path
from xml.sax.saxutils import escape

import numpy as np
from scipy.signal import butter, lfilter

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "stage2"))
import build_stage2_shared as s2

OUT = Path("E:/Thesis/Publication_Figures/hw_shared_two_stage_concept.drawio")
RECORD = "E:/Thesis/databases/mit-bih-arrhythmia-database-1.0.0/100"
START_S, SECONDS = 60.0, 3.0
FONT = "fontFamily=Times New Roman;"


def traces():
    import wfdb

    rec = wfdb.rdrecord(RECORD)
    raw = np.asarray(rec.p_signal[:, 0], dtype=np.float64)
    x = s2.q(s2.linear_resample_like_matlab(raw, float(rec.fs)), 3, 8)
    b5, a5 = butter(3, 5.0 / 60.0, btype="high")
    b1, a1 = butter(3, 1.0 / 60.0, btype="high")
    s1 = s2.q(lfilter(b5, a5, x), 3, 8)
    st2 = s2.q(lfilter(b1, a1, x), 5, 8)
    i0, n = int(START_S * 120), int(SECONDS * 120)
    return x[i0:i0 + n], s1[i0:i0 + n], st2[i0:i0 + n]


def sparkline_uri(y, color="#333333", w=160, h=48):
    y = (y - y.min()) / max(1e-9, y.max() - y.min())
    pts = " ".join(f"{w * i / (y.size - 1):.1f},{h - 4 - (h - 8) * v:.1f}" for i, v in enumerate(y))
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">'
           f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="1.8" '
           f'stroke-linejoin="round" stroke-linecap="round"/></svg>')
    return "data:image/svg+xml," + base64.b64encode(svg.encode()).decode()


class Doc:
    def __init__(self):
        self.cells = []

    def box(self, cid, value, x, y, w, h, style):
        self.cells.append(
            f'<mxCell id="{cid}" value="{escape(value, {chr(34): "&quot;"})}" style="{style}" vertex="1" parent="1">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry" /></mxCell>')

    def edge(self, cid, src, dst, style, points=(), value=""):
        pts = "".join(f'<mxPoint x="{px}" y="{py}" />' for px, py in points)
        arr = f'<Array as="points">{pts}</Array>' if points else ""
        self.cells.append(
            f'<mxCell id="{cid}" value="{escape(value)}" style="{style}" edge="1" parent="1" source="{src}" target="{dst}">'
            f'<mxGeometry relative="1" as="geometry">{arr}</mxGeometry></mxCell>')

    def xml(self, width, height):
        body = "\n".join(self.cells)
        return (f'<mxfile host="app.diagrams.net"><diagram id="concept" name="Concept">'
                f'<mxGraphModel dx="900" dy="400" grid="1" gridSize="5" guides="1" tooltips="1" connect="1" arrows="1" '
                f'fold="1" page="1" pageScale="1" pageWidth="{width}" pageHeight="{height}" math="0" shadow="0"><root>'
                f'<mxCell id="0" /><mxCell id="1" parent="0" />\n{body}\n</root></mxGraphModel></diagram></mxfile>')


def build():
    raw, t1, t2 = traces()
    d = Doc()
    chip = "rounded=1;arcSize=30;whiteSpace=wrap;html=1;strokeWidth=1.2;fontSize=12;" + FONT
    blue = chip + "fillColor=#dae8fc;strokeColor=#6c8ebf;"
    purple = chip + "fillColor=#e1d5e7;strokeColor=#9673a6;"
    pink = chip + "fillColor=#fad9d5;strokeColor=#ae4132;fontStyle=1;"
    img = "shape=image;html=1;imageAspect=0;aspect=fixed;verticalLabelPosition=bottom;verticalAlign=top;fontSize=11;" + FONT
    arrow = "edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;endArrow=blockThin;endFill=1;strokeWidth=1.6;strokeColor=#333333;"
    band = "rounded=1;arcSize=12;whiteSpace=wrap;html=1;verticalAlign=top;align=left;spacingLeft=8;spacingTop=2;fontSize=11;fontStyle=1;" + FONT

    d.box("bandA", "STAGE 1 &middot; always on", 205, 30, 275, 95, band + "fillColor=#eef4fb;strokeColor=none;fontColor=#3d5a80;")
    d.box("bandB", "STAGE 2 &middot; power-gated", 205, 165, 275, 95,
          band + "fillColor=#fbf0f1;strokeColor=#b85450;dashed=1;dashPattern=5 4;fontColor=#a33a3a;")

    d.box("ecg", "ECG", 10, 120, 90, 30, img + f"image={sparkline_uri(raw)};")
    d.box("fe", "Q3.8<br>front end", 115, 112, 72, 46, purple)

    d.box("hp5", "5 Hz HP", 215, 62, 66, 34, blue)
    d.box("trA", "", 290, 64, 92, 30, img + f"image={sparkline_uri(t1, '#3d5a80')};")
    d.box("w1", "W1", 392, 62, 74, 34, blue)
    d.box("hp1", "1 Hz HP", 215, 197, 66, 34, blue + "opacity=85;")
    d.box("trB", "", 290, 199, 92, 30, img + f"image={sparkline_uri(t2, '#a33a3a')};")
    d.box("w2", "W2", 392, 197, 74, 34, blue + "opacity=85;")

    d.box("core", "<b>Shared</b><br>feature engine<br>+ MAC", 505, 30, 120, 230,
          purple + "arcSize=10;fontSize=13;verticalAlign=top;spacingTop=58;")
    d.box("slots", "slot A: W1 &#8594; S1<br>slot B: W2 &#8594; S2", 520, 200, 90, 44,
          chip + "fillColor=#ffffff;strokeColor=#9673a6;fontSize=10;dashed=0;")

    d.box("out1", "2-of-3<br>Normal / Abnormal", 650, 56, 100, 46, pink)
    d.box("out2", "VT / VF", 650, 194, 100, 40, pink)

    d.edge("e0", "ecg", "fe", arrow)
    d.edge("e1", "fe", "hp5", arrow + "exitX=1;exitY=0.5;entryX=0;entryY=0.5;", [(198, 135), (198, 79)])
    d.edge("e2", "fe", "hp1", arrow + "exitX=1;exitY=0.5;entryX=0;entryY=0.5;", [(198, 135), (198, 214)])
    d.edge("e3", "w1", "core", arrow + "exitX=1;exitY=0.5;entryX=0;entryY=0.213;")
    d.edge("e4", "w2", "core", arrow + "exitX=1;exitY=0.5;entryX=0;entryY=0.8;")
    d.edge("e5", "core", "out1", arrow + "exitX=1;exitY=0.213;entryX=0;entryY=0.5;")
    d.edge("e6", "core", "out2", arrow + "exitX=1;exitY=0.8;entryX=0;entryY=0.5;")
    d.edge("wake", "out1", "bandB",
           "edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;endArrow=blockThin;endFill=1;strokeWidth=1.8;strokeColor=#CC0066;"
           "fontColor=#CC0066;fontStyle=1;fontSize=11;labelBackgroundColor=#ffffff;exitX=1;exitY=0.5;entryX=0.5;entryY=1;" + FONT,
           [(770, 79), (770, 282), (342.5, 282)], value="wake")
    OUT.write_text(d.xml(780, 300), encoding="ascii", errors="xmlcharrefreplace")
    return raw, t1, t2


def preview(raw, t1, t2):
    import re
    import xml.etree.ElementTree as ET

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import FancyBboxPatch

    root = ET.parse(OUT).getroot()
    cells = root.find("diagram/mxGraphModel/root").findall("mxCell")
    geo, fig = {}, plt.figure(figsize=(9.5, 3.7))
    ax = fig.add_axes([0, 0, 1, 1])
    traces_by_id = {"ecg": (raw, "#333333"), "trA": (t1, "#3d5a80"), "trB": (t2, "#a33a3a")}
    for c in cells:
        if c.get("vertex") != "1":
            continue
        g = c.find("mxGeometry")
        x, y, w, h = (float(g.get(k)) for k in ("x", "y", "width", "height"))
        geo[c.get("id")] = (x, y, w, h)
        st = c.get("style")
        if c.get("id") in traces_by_id:
            yv, col = traces_by_id[c.get("id")]
            yy = (yv - yv.min()) / (yv.max() - yv.min())
            ax.plot(x + w * np.linspace(0, 1, yy.size), y + h - h * yy, color=col, lw=1.1)
            if c.get("value"):
                ax.text(x + w / 2, y + h + 9, c.get("value"), ha="center", fontsize=8, family="serif")
            continue
        fc = re.search(r"fillColor=([^;]+)", st).group(1)
        ec = re.search(r"strokeColor=([^;]+)", st).group(1)
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=6", fc=fc,
                                    ec="none" if ec == "none" else ec, ls="--" if "dashed=1" in st else "-", lw=1))
        txt = re.sub(r"<br\s*/?>", "\n", c.get("value")).replace("&middot;", "·").replace("&#8594;", "→").replace("&nbsp;", " ")
        txt = re.sub(r"<[^>]+>", "", txt)
        if "verticalAlign=top" in st and "spacingLeft" in st:
            ax.text(x + 8, y + 12, txt, fontsize=8, fontweight="bold", family="serif", color=re.search(r"fontColor=([^;]+)", st).group(1))
        elif c.get("id") == "core":
            ax.text(x + w / 2, y + 95, txt, ha="center", va="center", fontsize=9, family="serif")
        else:
            ax.text(x + w / 2, y + h / 2, txt, ha="center", va="center", fontsize=8, family="serif")
    for c in cells:
        if c.get("edge") != "1":
            continue
        st = c.get("style")
        s, t = geo[c.get("source")], geo[c.get("target")]

        def anchor(g, kx, ky, default):
            mx, my = re.search(kx + r"=([\d.]+)", st), re.search(ky + r"=([\d.]+)", st)
            return (g[0] + float(mx.group(1)) * g[2], g[1] + float(my.group(1)) * g[3]) if mx and my else default

        sp = anchor(s, "exitX", "exitY", (s[0] + s[2], s[1] + s[3] / 2))
        tp = anchor(t, "entryX", "entryY", (t[0], t[1] + t[3] / 2))
        pts = [sp] + [(float(p.get("x")), float(p.get("y"))) for p in c.findall("mxGeometry/Array/mxPoint")] + [tp]
        col = re.search(r"strokeColor=([^;]+)", st).group(1)
        ax.plot([p[0] for p in pts], [p[1] for p in pts], color=col, lw=1.2)
        ax.annotate("", xy=pts[-1], xytext=pts[-2], arrowprops=dict(arrowstyle="-|>", color=col, lw=1.2))
        if c.get("value"):
            ax.text(560, 282, c.get("value"), color=col, fontsize=8, fontweight="bold", ha="center", va="center",
                    bbox=dict(fc="w", ec="none", pad=1), family="serif")
    ax.set_xlim(0, 785)
    ax.set_ylim(300, 0)
    ax.axis("off")
    fig.savefig(HERE / "concept_preview.png", dpi=120)


if __name__ == "__main__":
    preview(*build())
    print(f"Wrote {OUT} and {HERE / 'concept_preview.png'}")
