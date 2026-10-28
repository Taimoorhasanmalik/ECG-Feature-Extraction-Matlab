"""Builds the two-stage pipeline figure for the hardware-shared design in the
visual style of Publication_Figures/Two-Stage ECG Classification Pipeline.png,
with the flow taken from the code (hw_shared_pipeline):

  ECG -> shared Q3.8 front end
  Stage 1: 3rd-order 5 Hz HPF -> Q3.8 -> 240/120 window -> 4 features
           -> linear SVM (4 w + b) -> s1 -> d[n] = (s1 >= T) -> 2-of-3 gate
  Gate no  -> Normal / other rhythm
  Gate yes -> enables Stage 2 (power gate)
  Stage 2: 3rd-order 1 Hz HPF -> Q5.8 -> 240/120 window -> 6 features
           -> linear SVM (6 w + b, Q3.12) -> s2 -> sign(s2) -> VT or VF
  Feature extraction + SVM are one shared engine + one MAC (time-multiplexed).

ECG traces and |H(f)| curves are computed from real data and the real filters.
Writes the .drawio file plus an HTML preview rendered to PNG with Chrome.

Modifies no existing file.
"""

from __future__ import annotations

import base64
import html
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import escape

import numpy as np
import scipy.io
from scipy.signal import butter, freqz, lfilter

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "stage2"))
import build_stage2_shared as s2

OUT = Path("E:/Thesis/Publication_Figures/hw_shared_two_stage_pipeline.drawio")
PREVIEW_HTML = HERE / "pipeline_preview.html"
PREVIEW_PNG = HERE / "pipeline_preview.png"
DB = Path("E:/Thesis/databases")
W, H = 1550, 905
TNR = "Times New Roman"


# ---------------------------------------------------------------- data
def front_end(record_path):
    import wfdb

    rec = wfdb.rdrecord(str(record_path))
    raw = s2.base.interpolate_nonfinite(np.asarray(rec.p_signal[:, 0], dtype=np.float64))
    return s2.q(s2.linear_resample_like_matlab(raw, float(rec.fs)), 3, 8)


def signals():
    normal = front_end(DB / "mit-bih-arrhythmia-database-1.0.0" / "100")
    d = scipy.io.loadmat(HERE.parent / "stage2" / "results" / "stage2_shared_alldata.mat")
    rid = [str(np.atleast_1d(r)[0]).strip() for r in d["test_record_id"].ravel()]
    labels = d["test_true_label"].ravel()
    starts = d["test_start_sample"].ravel()
    vf = int(d["vf_label"].ravel()[0])
    k = next(i for i, (r, l) in enumerate(zip(rid, labels)) if r == "cudb/cu01" and l == vf)
    vf_signal = front_end(DB / "cu-ventricular-tachyarrhythmia-database-1.0.0" / "cu01")
    s = int(starts[k])
    return normal[60 * 120:63 * 120], normal[120 * 120:120 * 120 + 300], vf_signal[s:s + 300]


# ---------------------------------------------------------------- SVG glyphs
def uri(svg):
    return "data:image/svg+xml," + base64.b64encode(svg.encode()).decode()


def svg_open(w, h):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" font-family="{TNR}">'


ARROW_DEFS = ('<defs><marker id="a" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto">'
              '<path d="M0,0 L8,4 L0,8 z" fill="#222"/></marker></defs>')


def trace_svg(y, color, lim, w=150, h=100):
    x0, x1, top, bot = 36, w - 3, 8, h - 8
    yy = np.clip(y - np.median(y), -lim, lim)
    pts = " ".join(f"{x0 + (x1 - x0) * i / (yy.size - 1):.1f},{(top + bot) / 2 - (bot - top) / 2 * v / lim:.1f}"
                   for i, v in enumerate(yy))
    mid = (top + bot) / 2
    ticks = "".join(f'<line x1="{x0 - 3}" y1="{ty}" x2="{x0}" y2="{ty}" stroke="#222" stroke-width="1"/>'
                    f'<text x="{x0 - 5}" y="{ty + 3.5}" font-size="10" text-anchor="end">{lab}</text>'
                    for ty, lab in ((top, f"{lim:g} mV"), (mid, "0"), (bot, f"&#8722;{lim:g} mV")))
    return uri(svg_open(w, h) + f'<line x1="{x0}" y1="{top}" x2="{x0}" y2="{bot}" stroke="#222" stroke-width="1"/>'
               + ticks + f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="1.5" '
               'stroke-linejoin="round"/></svg>')


def hf_svg(fc, w=150, h=96):
    b, a = butter(3, fc / 60.0, btype="high")
    fmax = 15.0
    f = np.linspace(0.01, fmax, 200)
    _, resp = freqz(b, a, worN=f, fs=120.0)
    mag = np.abs(resp)
    x0, x1, y0, y1 = 30, w - 12, h - 22, 14
    pts = " ".join(f"{x0 + (x1 - x0) * fi / fmax:.1f},{y0 - (y0 - y1) * m:.1f}" for fi, m in zip(f, mag))
    xt = x0 + (x1 - x0) * fc / fmax
    return uri(svg_open(w, h) + ARROW_DEFS
               + f'<line x1="{x0}" y1="{y0}" x2="{x0}" y2="6" stroke="#222" stroke-width="1.2" marker-end="url(#a)"/>'
               + f'<line x1="{x0}" y1="{y0}" x2="{w - 4}" y2="{y0}" stroke="#222" stroke-width="1.2" marker-end="url(#a)"/>'
               + f'<polyline points="{pts}" fill="none" stroke="#1f6fd1" stroke-width="2"/>'
               + f'<line x1="{xt}" y1="{y0}" x2="{xt}" y2="{y0 + 4}" stroke="#222"/>'
               + f'<text x="{xt}" y="{y0 + 15}" font-size="12" text-anchor="middle">{fc:g}</text>'
               + f'<text x="{w - 6}" y="{y0 + 15}" font-size="12" text-anchor="end" font-style="italic">f (Hz)</text>'
               + f'<text x="2" y="20" font-size="12" font-style="italic">|H(f)|</text></svg>')


def buffer_svg(w=172, h=100):
    cells = ""
    n, cw, x0, y0, ch = 9, 18.5, 3, 8, 26
    for i in range(n):
        fill = "#ffffff" if i == 4 else "#a9cbf2"
        cells += f'<rect x="{x0 + i * cw}" y="{y0}" width="{cw}" height="{ch}" fill="{fill}" stroke="#4a7cc0" stroke-width="1"/>'
    cells += f'<text x="{x0 + 4.5 * cw}" y="{y0 + 18}" font-size="14" text-anchor="middle">&#8230;</text>'
    xe = x0 + n * cw

    def bracket(xa, xb, yb, label):
        return (f'<line x1="{xa}" y1="{yb - 5}" x2="{xa}" y2="{yb + 5}" stroke="#222"/>'
                f'<line x1="{xb}" y1="{yb - 5}" x2="{xb}" y2="{yb + 5}" stroke="#222"/>'
                f'<line x1="{xa}" y1="{yb}" x2="{xb}" y2="{yb}" stroke="#222"/>'
                f'<text x="{(xa + xb) / 2}" y="{yb + 16}" font-size="12" text-anchor="middle">{label}</text>')

    return uri(svg_open(w, h) + cells + bracket(x0, xe, 48, "N = 240") + bracket(x0 + xe / 4, x0 + 3 * xe / 4, 76, "stride = 120") + "</svg>")


def scatter_svg(w=146, h=124):
    dots = [(30, 62), (42, 80), (55, 70), (30, 92), (48, 98), (66, 92), (24, 76)]
    crosses = [(82, 22), (100, 22), (92, 36), (114, 40), (108, 56), (122, 62), (112, 80)]
    body = "".join(f'<circle cx="{x}" cy="{y}" r="5" fill="#1f5fd6"/>' for x, y in dots)
    body += "".join(f'<path d="M{x - 5},{y - 5} L{x + 5},{y + 5} M{x - 5},{y + 5} L{x + 5},{y - 5}" stroke="#e02020" stroke-width="2"/>'
                    for x, y in crosses)
    return uri(svg_open(w, h) + ARROW_DEFS + body
               + f'<line x1="16" y1="{h - 14}" x2="16" y2="6" stroke="#222" stroke-width="1.5" marker-end="url(#a)"/>'
               + f'<line x1="16" y1="{h - 14}" x2="{w - 4}" y2="{h - 14}" stroke="#222" stroke-width="1.5" marker-end="url(#a)"/>'
               + f'<line x1="22" y1="10" x2="{w - 14}" y2="{h - 18}" stroke="#222" stroke-width="1.4" stroke-dasharray="5,4"/></svg>')


# ---------------------------------------------------------------- document
class Doc:
    def __init__(self):
        self.vertices, self.edges = [], []

    def box(self, cid, value, x, y, w, h, style):
        self.vertices.append(dict(id=cid, value=value, x=x, y=y, w=w, h=h, style=style))

    def edge(self, cid, src, dst, style, points=(), value="", label_at=None):
        self.edges.append(dict(id=cid, src=src, dst=dst, style=style, points=list(points), value=value, label_at=label_at))

    def drawio(self):
        cells = []
        for v in self.vertices:
            cells.append(f'<mxCell id="{v["id"]}" value="{escape(v["value"], {chr(34): "&quot;"})}" style="{v["style"]}" '
                         f'vertex="1" parent="1"><mxGeometry x="{v["x"]}" y="{v["y"]}" width="{v["w"]}" height="{v["h"]}" as="geometry" /></mxCell>')
        for e in self.edges:
            pts = "".join(f'<mxPoint x="{px}" y="{py}" />' for px, py in e["points"])
            arr = f'<Array as="points">{pts}</Array>' if pts else ""
            cells.append(f'<mxCell id="{e["id"]}" value="{escape(e["value"], {chr(34): "&quot;"})}" style="{e["style"]}" edge="1" '
                         f'parent="1" source="{e["src"]}" target="{e["dst"]}"><mxGeometry relative="1" as="geometry">{arr}</mxGeometry></mxCell>')
        return (f'<mxfile host="app.diagrams.net"><diagram id="pipeline" name="Two-stage pipeline">'
                f'<mxGraphModel dx="1500" dy="900" grid="1" gridSize="5" guides="1" tooltips="1" connect="1" arrows="1" fold="1" '
                f'page="1" pageScale="1" pageWidth="{W}" pageHeight="{H}" math="0" shadow="0"><root><mxCell id="0" />'
                f'<mxCell id="1" parent="0" />' + "".join(cells) + "</root></mxGraphModel></diagram></mxfile>")


def style(**kw):
    base = {"rounded": 1, "whiteSpace": "wrap", "html": 1, "fontFamily": TNR}
    base.update(kw)
    return ";".join(f"{k}={v}" for k, v in base.items()) + ";"


def build():
    ecg_in, ecg_normal, ecg_vf = signals()
    vf_lim = float(np.ceil(np.max(np.abs(ecg_vf - np.median(ecg_vf)))))
    d = Doc()

    panel1 = style(arcSize=4, fillColor="#d9e7f7", gradientColor="#eef5fd", gradientDirection="north", strokeColor="#1f4e9a",
                   strokeWidth=3, verticalAlign="top", fontSize=25, fontStyle=1, spacingTop=6)
    panel2 = style(arcSize=4, fillColor="#f9dcdc", gradientColor="#fdf1f1", gradientDirection="north", strokeColor="#c00000",
                   strokeWidth=3, verticalAlign="top", fontSize=25, fontStyle=1, spacingTop=6)
    block = style(arcSize=8, fillColor="#e4eefa", strokeColor="#5b84c4", strokeWidth=1.5, verticalAlign="top", fontSize=17, spacingTop=6)
    feat = style(arcSize=8, fillColor="#e6f2de", strokeColor="#82b366", strokeWidth=1.5, verticalAlign="top", fontSize=17, spacingTop=6)
    pill = style(arcSize=22, fillColor="#d3eac4", strokeColor="#82b366", fontSize=14)
    pill2 = style(arcSize=22, fillColor="#bfe0a8", strokeColor="#5f9a3e", fontSize=14)
    img = "shape=image;html=1;imageAspect=0;image="
    arrow = "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;strokeWidth=2.5;strokeColor=#111111;"

    # input
    d.box("in", "<b><font style=\"font-size:18px\">ECG Input</font></b><br>(single lead)", 8, 345, 165, 290,
          style(arcSize=6, fillColor="#e8edf6", strokeColor="#7d8fb0", strokeWidth=2, verticalAlign="top", fontSize=16, spacingTop=12))
    d.box("in_tr", "", 16, 430, 150, 100, img + trace_svg(ecg_in, "#1f5fd6", 1.5) + ";")
    d.box("in_txt", "120 Hz, Q3.8<br>(shared front end)", 8, 565, 165, 50, style(fillColor="none", strokeColor="none", fontSize=16))

    # stage 1 panel
    d.box("p1", "Stage 1: Normal / Abnormal Classifier (always on)", 220, 118, 912, 315, panel1)
    d.box("p2", "Stage 2: VT / VF Classifier (power-gated, runs only if Stage 1 flags abnormal)", 220, 518, 912, 315, panel2)
    for stage, y, fc, q, nfeat in ((1, 183, 5, "Q3.8", 4), (2, 583, 1, "Q5.8", 6)):
        d.box(f"hpf{stage}", f"<b>3rd-Order HPF</b><br>{fc} Hz (causal)<br>then {q}", 232, y, 162, 235, block)
        d.box(f"hpf{stage}_img", "", 238, y + 128, 150, 96, img + hf_svg(fc) + ";")
        d.box(f"win{stage}", "<b>Windowing</b><br>2 s (240 samples)<br>50% overlap<br>(stride = 120)", 412, y, 188, 235, block)
        d.box(f"win{stage}_img", "", 420, y + 120, 172, 100, img + buffer_svg() + ";")
        d.box(f"feat{stage}", f"<b>Feature Extraction</b><br>({nfeat} features)", 618, y, 184, 235, feat)
        names = ["Mean abs. amplitude", "Zero-crossing count", "Line length (&Sigma;|&Delta;x|)", "Threshold crossings"]
        if nfeat == 4:
            for i, n in enumerate(names):
                d.box(f"f{stage}_{i}", n, 630, y + 70 + 40 * i, 160, 32, pill)
        else:
            for i, n in enumerate(names + ["Local amp. range", "Amplitude transition"]):
                d.box(f"f{stage}_{i}", n, 630, y + 58 + 29 * i, 160, 25, pill if i < 4 else pill2)
        weights = "(4 weights + bias)" if stage == 1 else "(6 weights + bias)"
        d.box(f"svm{stage}", f"<b>Linear SVM</b><br>{weights}", 820, y, 166, 235, block)
        d.box(f"svm{stage}_img", "", 830, y + 88, 146, 124, img + scatter_svg() + ";")
        d.edge(f"a{stage}1", f"hpf{stage}", f"win{stage}", arrow)
        d.edge(f"a{stage}2", f"win{stage}", f"feat{stage}", arrow)
        d.edge(f"a{stage}3", f"feat{stage}", f"svm{stage}", arrow)
    d.box("s1", "<i><b><font style=\"font-size:20px\">s</font><sub>1</sub></b></i><br>(normal/abnormal<br>score)", 1004, 244, 112, 112,
          style(arcSize=10, fillColor="#dfeaf8", strokeColor="#2f5fa8", strokeWidth=1.5, fontSize=14))
    d.box("s2", "<i><b><font style=\"font-size:20px\">s</font><sub>2</sub></b></i><br>(VT/VF score)", 1004, 644, 112, 112,
          style(arcSize=10, fillColor="#fbd9d9", strokeColor="#c00000", strokeWidth=1.5, fontSize=14))
    d.edge("a14", "svm1", "s1", arrow)
    d.edge("a24", "svm2", "s2", arrow)

    d.box("shared", "<b>Shared hardware:</b> one feature engine + one MAC,<br>time-multiplexed between Stage 1 and Stage 2", 560, 452, 400, 46,
          style(arcSize=30, fillColor="#efe6f9", strokeColor="#8e6bbf", strokeWidth=1.5, dashed=1, fontSize=14))

    # gate
    d.box("gate", "<b><font style=\"font-size:17px\">Sequence Gate</font></b><br>d[n] = 1 if <i>s</i><sub>1</sub> &ge; T<br>2-of-3 vote over<br>3 consecutive windows",
          1150, 318, 190, 292, style(arcSize=8, fillColor="#fde2bd", strokeColor="#e69500", strokeWidth=2.5, verticalAlign="top", fontSize=16, spacingTop=12))
    reg = style(arcSize=12, fillColor="#e7dcf3", strokeColor="#8e6bbf", strokeWidth=1.5, fontSize=13)
    for i, lab in enumerate(["d[n&#8722;2]", "d[n&#8722;1]", "d[n]"]):
        d.box(f"r{i}", lab, 1160 + 58 * i, 462, 54, 34, reg)
    d.box("sum", "&Sigma; <i>d<sub>i</sub></i> &ge; 2", 1175, 540, 140, 40, style(arcSize=10, fillColor="#ffffff", strokeColor="#333333", strokeWidth=1.5, fontSize=16))
    thin = "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;strokeWidth=1.5;strokeColor=#111111;"
    for i in range(3):
        d.edge(f"rs{i}", f"r{i}", "sum", thin + f"exitX=0.5;exitY=1;entryX={0.18 + 0.32 * i:.2f};entryY=0;")

    # outputs
    d.box("o1", "<b><font style=\"font-size:18px\">Normal /<br>Other Rhythm</font></b>", 1368, 175, 172, 215,
          style(arcSize=8, fillColor="#eaf6ea", strokeColor="#2e8b3a", strokeWidth=2.5, verticalAlign="top", spacingTop=10))
    d.box("o1_tr", "", 1378, 272, 150, 100, img + trace_svg(ecg_normal, "#1f5fd6", 1.5) + ";")
    d.box("o2", "<b><font style=\"font-size:18px\">VT or VF</font></b>", 1368, 600, 172, 200,
          style(arcSize=8, fillColor="#fdeaea", strokeColor="#c00000", strokeWidth=2.5, verticalAlign="top", spacingTop=10))
    d.box("o2_tr", "", 1378, 660, 150, 100, img + trace_svg(ecg_vf, "#e02020", vf_lim) + ";")

    # flow edges
    d.edge("i1", "in", "hpf1", arrow + "exitX=1;exitY=0.5;entryX=0;entryY=0.5;", [(196, 490), (196, 300)])
    d.edge("i2", "in", "hpf2", arrow + "exitX=1;exitY=0.5;entryX=0;entryY=0.5;", [(196, 490), (196, 700)])
    d.edge("g1", "s1", "gate", arrow + "exitX=1;exitY=0.5;entryX=0.5;entryY=0;", [(1245, 300)])
    green = "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;strokeWidth=2.5;strokeColor=#2e8b3a;fontColor=#2e8b3a;fontStyle=1;fontSize=17;labelBackgroundColor=none;fontFamily=Times New Roman;"
    d.edge("no", "gate", "o1", green + "exitX=1;exitY=0.3836;entryX=0;entryY=0.535;", [(1354, 430), (1354, 290)], value="No", label_at=(1358, 400))
    red = "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;strokeWidth=2.5;strokeColor=#c00000;fontColor=#c00000;fontStyle=1;fontSize=15;fontFamily=Times New Roman;labelBackgroundColor=none;"
    d.edge("yes", "gate", "p2", red + "dashed=1;exitX=0;exitY=0.541;entryX=0.9375;entryY=0;", [(1075, 476)])
    d.box("yes_lbl", "Yes:<br>enable Stage 2", 965, 452, 106, 46,
          style(fillColor="none", strokeColor="none", fontColor="#c00000", fontStyle=1, fontSize=15, align="right"))
    d.edge("vt", "s2", "o2", red + "exitX=1;exitY=0.5;entryX=0;entryY=0.5;labelBackgroundColor=#ffffff;",
           value="sign(<i>s</i><sub>2</sub>)", label_at=(1218, 676))
    return d


# ---------------------------------------------------------------- preview (HTML -> PNG via Chrome)
def parse_style(s):
    return dict(kv.split("=", 1) if "=" in kv else (kv, "1") for kv in s.strip(";").split(";") if kv)


def anchor(v, sx, sy):
    return v["x"] + sx * v["w"], v["y"] + sy * v["h"]


def preview(d):
    vs = {v["id"]: v for v in d.vertices}
    parts = []
    for v in d.vertices:
        st = parse_style(v["style"])
        if st.get("shape") == "image":
            src = v["style"].split("image=", 1)[1].rstrip(";").replace("data:image/svg+xml,", "data:image/svg+xml;base64,")
            parts.append(f'<img src="{src}" style="position:absolute;left:{v["x"]}px;top:{v["y"]}px;width:{v["w"]}px;height:{v["h"]}px">')
            continue
        fill, grad = st.get("fillColor", "none"), st.get("gradientColor")
        bg = "transparent" if fill == "none" else (f"linear-gradient(to top,{fill},{grad})" if grad else fill)
        stroke = st.get("strokeColor", "#000")
        border = "none" if stroke == "none" else f'{st.get("strokeWidth", 1)}px {"dashed" if st.get("dashed") == "1" else "solid"} {stroke}'
        radius = min(v["w"], v["h"]) * float(st.get("arcSize", 15)) / 100 if st.get("rounded") == "1" else 0
        top = st.get("verticalAlign") == "top"
        weight = "bold" if st.get("fontStyle") == "1" else "normal"
        color = st.get("fontColor", "#000")
        parts.append(
            f'<div style="position:absolute;box-sizing:border-box;left:{v["x"]}px;top:{v["y"]}px;width:{v["w"]}px;height:{v["h"]}px;'
            f'background:{bg};border:{border};border-radius:{radius}px;display:flex;justify-content:center;'
            f'align-items:{"flex-start" if top else "center"};padding-top:{st.get("spacingTop", 0) if top else 0}px;'
            f'font:{weight} {st.get("fontSize", 12)}px \'{TNR}\';color:{color};text-align:center;line-height:1.2">'
            f'<div>{v["value"]}</div></div>')
    svg = [f'<svg width="{W}" height="{H}" style="position:absolute;left:0;top:0;overflow:visible">'
           '<defs><marker id="m" markerWidth="5" markerHeight="5" refX="4" refY="2.5" orient="auto" markerUnits="strokeWidth">'
           '<path d="M0,0 L5,2.5 L0,5 z" fill="context-stroke"/></marker></defs>']
    labels = []
    for e in d.edges:
        st = parse_style(e["style"])
        s, t = vs[e["src"]], vs[e["dst"]]
        sp = anchor(s, float(st["exitX"]), float(st["exitY"])) if "exitX" in st else anchor(s, 1, 0.5) if t["x"] > s["x"] + s["w"] else anchor(s, 0.5, 1)
        tp = anchor(t, float(st["entryX"]), float(st["entryY"])) if "entryX" in st else anchor(t, 0, 0.5) if t["x"] > s["x"] + s["w"] else anchor(t, 0.5, 0)
        pts = [sp] + e["points"] + [tp]
        if "exitX" not in st and len(pts) == 2:
            pts = [(sp[0], sp[1]), (tp[0], sp[1])] if abs(sp[1] - tp[1]) < 1 else pts
        col = st.get("strokeColor", "#000")
        dash = 'stroke-dasharray="9,6"' if st.get("dashed") == "1" else ""
        svg.append(f'<polyline points="{" ".join(f"{x},{y}" for x, y in pts)}" fill="none" stroke="{col}" '
                   f'stroke-width="{st.get("strokeWidth", 1)}" {dash} marker-end="url(#m)"/>')
        if e["value"]:
            lx, ly = e["label_at"]
            labels.append(f'<div style="position:absolute;left:{lx}px;top:{ly}px;font:bold {st.get("fontSize", 12)}px \'{TNR}\';'
                          f'color:{st.get("fontColor", col)}">{e["value"]}</div>')
    svg.append("</svg>")
    page = (f'<html><body style="margin:0;background:#fff"><div style="position:relative;width:{W}px;height:{H}px">'
            + "".join(parts) + "".join(svg) + "".join(labels) + "</div></body></html>")
    PREVIEW_HTML.write_text(page, encoding="utf-8")
    chrome = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
    subprocess.run([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", f"--window-size={W},{H}",
                    f"--screenshot={PREVIEW_PNG}", PREVIEW_HTML.as_uri()], check=True, capture_output=True, timeout=120)


if __name__ == "__main__":
    doc = build()
    OUT.write_text(doc.drawio(), encoding="ascii", errors="xmlcharrefreplace")
    preview(doc)
    print(f"Wrote {OUT}\nPreview {PREVIEW_PNG}")
