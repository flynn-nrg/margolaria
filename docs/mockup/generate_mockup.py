#!/usr/bin/env python3
"""Generates the Margolaria main-window mockup as SVG (no dependencies)."""
from xml.sax.saxutils import escape

W, H = 1600, 1000
SANS = "Helvetica Neue, Helvetica, Arial, sans-serif"
MONO = "Menlo, monospace"

C = dict(
    win="#1c1c1e", toolbar="#2b2b2e", sidebar="#232326", canvas="#18181a",
    panel="#202023", sep="#3a3a3e", text="#e8e8ea", dim="#9a9aa0", faint="#6a6a70",
    accent="#3d8bfd", sel="#2f5fb3", ok="#4cc38a", warn="#f0b429", err="#f06a6a",
)
T = {  # MaterialX type colours (pins + wires)
    "float": "#a7a7b0", "color3": "#f2b84b", "vector2": "#6cc788", "vector3": "#5aa9f0",
    "surfaceshader": "#e0607e", "material": "#c58af9", "filename": "#7d7d85",
    "displacementshader": "#d08bd0",
}
CAT = {  # node header colours by library group
    "geometry": "#2f6b5a", "texture": "#7a5a22", "procedural": "#4f4a86",
    "math": "#3d4f66", "pbr": "#8a3346", "material": "#5d3f87", "adjust": "#4a5f3a",
}

out = []
def add(s): out.append(s)
def rect(x, y, w, h, fill, rx=0, stroke=None, sw=1, extra=""):
    st = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}"{st} {extra}/>')
def text(x, y, s, size=12, fill=None, weight="normal", anchor="start", font=SANS, extra=""):
    add(f'<text x="{x}" y="{y}" font-family="{font}" font-size="{size}" fill="{fill or C["text"]}" '
        f'font-weight="{weight}" text-anchor="{anchor}" {extra}>{escape(s)}</text>')
def line(x1, y1, x2, y2, stroke=None, sw=1, extra=""):
    add(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke or C["sep"]}" stroke-width="{sw}" {extra}/>')
def circle(cx, cy, r, fill, stroke=None, sw=1):
    st = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
    add(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{fill}"{st}/>')

# ---------------------------------------------------------------- defs
add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">')
add("""<defs>
<radialGradient id="copper" cx="38%" cy="32%" r="75%">
  <stop offset="0" stop-color="#ffe2c4"/><stop offset="0.12" stop-color="#f0a46e"/>
  <stop offset="0.45" stop-color="#b8673a"/><stop offset="0.8" stop-color="#5a2a14"/>
  <stop offset="1" stop-color="#2a120a"/></radialGradient>
<radialGradient id="rough" cx="40%" cy="35%" r="75%">
  <stop offset="0" stop-color="#cfcfcf"/><stop offset="0.6" stop-color="#6d6d6d"/><stop offset="1" stop-color="#2e2e2e"/></radialGradient>
<linearGradient id="albedo" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#d7905d"/><stop offset="0.5" stop-color="#a65a30"/><stop offset="1" stop-color="#d48b57"/></linearGradient>
<linearGradient id="normal" x1="0" y1="0" x2="1" y2="0">
  <stop offset="0" stop-color="#7f7ff5"/><stop offset="0.5" stop-color="#8a86ff"/><stop offset="1" stop-color="#7b8af0"/></linearGradient>
<linearGradient id="uv" x1="0" y1="1" x2="1" y2="0">
  <stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#e0e030"/></linearGradient>
<linearGradient id="vpbg" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#3a3d44"/><stop offset="0.62" stop-color="#26272b"/><stop offset="1" stop-color="#151517"/></linearGradient>
<radialGradient id="shadow" cx="50%" cy="50%" r="50%">
  <stop offset="0" stop-color="#000" stop-opacity="0.6"/><stop offset="1" stop-color="#000" stop-opacity="0"/></radialGradient>
<radialGradient id="spec" cx="50%" cy="50%" r="50%">
  <stop offset="0" stop-color="#fff" stop-opacity="0.85"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
<pattern id="dots" width="20" height="20" patternUnits="userSpaceOnUse">
  <circle cx="1" cy="1" r="1" fill="#2c2c30"/></pattern>
<pattern id="brushed" width="64" height="3" patternUnits="userSpaceOnUse">
  <rect width="64" height="1" fill="#ffffff" opacity="0.06"/></pattern>
<filter id="noiseF" x="0" y="0" width="100%" height="100%">
  <feTurbulence type="fractalNoise" baseFrequency="0.08 0.6" numOctaves="3" seed="4"/>
  <feColorMatrix type="saturate" values="0"/></filter>
<filter id="drop" x="-10%" y="-10%" width="130%" height="140%">
  <feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="#000" flood-opacity="0.45"/></filter>
<clipPath id="vpclip"><rect x="1151" y="53" width="449" height="347"/></clipPath>
<clipPath id="graphclip"><rect x="231" y="85" width="918" height="634"/></clipPath>
</defs>""")

# ---------------------------------------------------------------- window chrome
rect(0, 0, W, H, C["win"], rx=12)
rect(0, 0, W, 52, C["toolbar"], rx=12)
rect(0, 30, W, 22, C["toolbar"])
line(0, 52, W, 52)
for i, col in enumerate(["#ff5f57", "#febc2e", "#28c840"]):
    circle(22 + i * 20, 26, 6.5, col)
# sidebar toggle
rect(92, 17, 20, 16, "none", rx=3, stroke=C["dim"], sw=1.4); line(99, 17, 99, 33, C["dim"], 1.4)
text(130, 24, "copper_set.mtlx", 14, weight="bold")
text(130, 41, "Edited · MaterialX 1.39", 11, C["dim"])
# view mode segmented control
sx = 620
rect(sx, 13, 246, 26, "#3a3a3e", rx=6)
rect(sx + 2, 15, 80, 22, "#5a5a60", rx=5)
for i, lab in enumerate(["Graph", "Split", "Text"]):
    text(sx + 42 + i * 82, 30, lab, 12, anchor="middle", weight="bold" if i == 0 else "normal")
# right toolbar items
def pill(x, w, label, dot=None, chevron=False):
    rect(x, 13, w, 26, "#3a3a3e", rx=6)
    tx = x + 12
    if dot:
        circle(x + 14, 26, 4.5, dot); tx = x + 26
    text(tx, 30, label, 12)
    if chevron:
        text(x + w - 14, 30, "▾", 11, C["dim"])
pill(930, 96, "Valid", dot=C["ok"])
pill(1036, 186, "Preview: Storm · Metal", chevron=True)
pill(1232, 110, "Target: MSL", chevron=True)
pill(1352, 92, "Export", chevron=True)
# add-node + inspector toggle icons
rect(1456, 13, 32, 26, "#3a3a3e", rx=6); text(1472, 31, "+", 17, anchor="middle")
rect(1498, 13, 32, 26, "#3a3a3e", rx=6)
rect(1506, 19, 16, 14, "none", rx=2, stroke=C["dim"], sw=1.4); line(1517, 19, 1517, 33, C["dim"], 1.4)
rect(1540, 13, 44, 26, "#3a3a3e", rx=6); text(1562, 30, "⌘K", 11, C["dim"], anchor="middle")

# ---------------------------------------------------------------- sidebar
rect(0, 53, 230, 919, C["sidebar"])
line(230, 53, 230, 972)
rect(12, 64, 206, 26, "#2e2e32", rx=6)
rect(14, 66, 100, 22, "#4a4a50", rx=5)
text(64, 81, "Document", 12, anchor="middle", weight="bold")
text(166, 81, "Library", 12, C["dim"], anchor="middle")

def section(y, title):
    text(16, y, title.upper(), 10, C["faint"], weight="bold", extra='letter-spacing="0.8"')
def item(y, label, icon_col, selected=False, indent=0, badge=None, sub=None):
    if selected:
        rect(8, y - 14, 214, 22, C["sel"], rx=5)
    x = 20 + indent
    rect(x, y - 9, 10, 10, icon_col, rx=2)
    text(x + 18, y, label, 12, C["text"] if selected else "#d6d6da")
    if sub:
        text(214, y, sub, 10, C["dim"] if not selected else "#c9d8ff", anchor="end")
    if badge:
        circle(x + 26 + len(label) * 6.9, y - 4, 4, badge)

y = 116
section(y, "Materials"); y += 22
item(y, "M_BrushedCopper", T["material"], selected=True, sub="open_pbr"); y += 24
item(y, "M_Rubber", T["material"], sub="std_surface"); y += 24
item(y, "M_FrostedGlass", T["material"], sub="open_pbr", badge=C["warn"]); y += 32
section(y, "Node Graphs"); y += 22
item(y, "NG_copper", "#5f6b80"); y += 24
item(y, "NG_scratches", "#5f6b80"); y += 32
section(y, "Looks & Assignments"); y += 22
item(y, "look_default", "#4f7f6b", sub="3 assigns"); y += 24
item(y, "look_aged", "#4f7f6b", sub="3 assigns"); y += 32
section(y, "Custom Definitions"); y += 22
item(y, "ND_brushed_metal", "#8a6f3a", sub="nodedef"); y += 34

line(12, y - 12, 218, y - 12)
section(y + 6, "Node Library"); y += 22
rect(12, y, 206, 26, "#2e2e32", rx=6)
text(26, y + 17, "⌕", 13, C["dim"]); text(42, y + 17, "Search nodes…", 12, C["faint"])
text(206, y + 17, "Tab", 10, C["faint"], anchor="end")
y += 46
def cat(y, label, open_=False, count=None):
    text(18, y, "▾" if open_ else "▸", 10, C["dim"])
    text(32, y, label, 12, "#d6d6da", weight="bold" if open_ else "normal")
    if count: text(214, y, str(count), 10, C["faint"], anchor="end")
cat(y, "PBR / Surface", True, 9); y += 22
for n in ["open_pbr_surface", "standard_surface", "UsdPreviewSurface", "gltf_pbr", "surface_unlit"]:
    rect(36, y - 9, 10, 10, CAT["pbr"], rx=2); text(54, y, n, 12, "#cfcfd4"); y += 21
y += 4
for lab, n in [("Texture", 14), ("Procedural", 23), ("Geometry", 12), ("Math", 48), ("Adjustment", 19),
               ("Compositing", 21), ("Conditional", 9), ("Channel", 11), ("Organization", 4)]:
    cat(y, lab, count=n); y += 22

# ---------------------------------------------------------------- graph canvas
rect(231, 53, 918, 666, C["canvas"])
rect(231, 85, 918, 634, "url(#dots)")
# breadcrumb bar
rect(231, 53, 918, 32, "#202023")
line(231, 85, 1149, 85)
text(246, 74, "‹", 16, C["dim"])
text(266, 73, "copper_set.mtlx", 12, C["dim"])
text(366, 73, "›", 12, C["faint"])
text(380, 73, "M_BrushedCopper", 12, C["dim"])
text(492, 73, "›", 12, C["faint"])
text(506, 73, "NG_copper", 12, weight="bold")
for i, lab in enumerate(["Auto-layout", "Frame (F)", "Previews: On"]):
    rect(830 + i * 104, 60, 96, 20, "#2e2e32", rx=5)
    text(878 + i * 104, 74, lab, 11, C["dim"], anchor="middle")

add('<g clip-path="url(#graphclip)">')

# backdrop group
rect(258, 432, 470, 196, "#4f4a86", rx=8, extra='fill-opacity="0.12" stroke="#6d66b8" stroke-opacity="0.5"')
text(270, 451, "Brushed anisotropy", 12, "#b5b0f0", weight="bold")
text(716, 451, "backdrop", 10, "#7d78c0", anchor="end")

ROW, HEAD = 20, 24
nodes = {}
def node(key, x, y, w, title, cat_col, ins, outs, thumb=None, selected=False, subtitle=None):
    th = 64 if thumb else 0
    h = HEAD + th + ROW * max(len(ins) + len(outs), 1) + 6
    add('<g filter="url(#drop)">')
    rect(x, y, w, h, "#2c2c30", rx=7, stroke=C["accent"] if selected else "#45454b",
         sw=2.2 if selected else 1)
    add('</g>')
    add(f'<path d="M{x},{y + HEAD} v-{HEAD - 7} a7,7 0 0 1 7,-7 h{w - 14} a7,7 0 0 1 7,7 v{HEAD - 7} z" fill="{cat_col}"/>')
    text(x + 9, y + 16, title, 12, weight="bold")
    if subtitle:
        text(x + w - 8, y + 16, subtitle, 10, "#d9d9e0", anchor="end", extra='fill-opacity="0.7"')
    pins = {}
    cy = y + HEAD
    if thumb:
        tx, tw = x + 8, w - 16
        if thumb == "sphere":
            rect(tx, cy + 4, tw, 56, "#1a1a1c", rx=4)
            circle(x + w / 2, cy + 32, 25, "url(#copper)")
        elif thumb == "noise":
            add(f'<rect x="{tx}" y="{cy + 4}" width="{tw}" height="56" rx="4" filter="url(#noiseF)"/>')
        else:
            rect(tx, cy + 4, tw, 56, f"url(#{thumb})", rx=4)
        cy += th
    for name, typ in outs:
        py = cy + ROW / 2 + 3
        text(x + w - 14, py + 4, name, 11, "#cfcfd4", anchor="end")
        circle(x + w, py, 5, T[typ], stroke="#1c1c1e", sw=1.5)
        pins["out:" + name] = (x + w, py, typ)
        cy += ROW
    for name, typ, val in ins:
        py = cy + ROW / 2 + 3
        connected = val is None
        circle(x, py, 5, T[typ] if connected else "#2c2c30", stroke=T[typ], sw=1.8)
        text(x + 13, py + 4, name, 11, "#cfcfd4")
        if not connected and val:
            if val.startswith("#"):
                rect(x + w - 32, py - 6, 24, 12, val, rx=2, stroke="#55555b")
            else:
                text(x + w - 9, py + 4, val, 11, C["dim"], anchor="end", font=MONO)
        pins["in:" + name] = (x, py, typ)
        cy += ROW
    nodes[key] = pins
    return pins

def wire(a, ap, b, bp):
    x1, y1, typ = nodes[a]["out:" + ap]
    x2, y2, _ = nodes[b]["in:" + bp]
    dx = max(40, (x2 - x1) * 0.5)
    add(f'<path d="M{x1},{y1} C{x1 + dx},{y1} {x2 - dx},{y2} {x2},{y2}" fill="none" '
        f'stroke="{T[typ]}" stroke-width="2.2" stroke-opacity="0.9"/>')

node("tc", 262, 128, 128, "texcoord", CAT["geometry"], [], [("out", "vector2")], thumb="uv")
node("pl", 418, 112, 150, "place2d", CAT["math"],
     [("texcoord", "vector2", None), ("scale", "vector2", "4, 1"), ("rotate", "float", "0.0")],
     [("out", "vector2")])
node("bc", 598, 100, 160, "base_color_tex", CAT["texture"],
     [("file", "filename", "albedo.exr"), ("texcoord", "vector2", None)],
     [("out", "color3")], thumb="albedo", subtitle="image")
node("nm", 598, 282, 160, "normal_tex", CAT["texture"],
     [("file", "filename", "normal.png"), ("texcoord", "vector2", None)],
     [("out", "vector3")], thumb="normal", subtitle="image")
node("po", 270, 476, 120, "position", CAT["geometry"], [("space", "filename", "object")],
     [("out", "vector3")])
node("nz", 418, 466, 150, "noise3d", CAT["procedural"],
     [("position", "vector3", None), ("amplitude", "float", "0.25"), ("pivot", "float", "0.5")],
     [("out", "float")], thumb="noise")
node("mu", 598, 486, 120, "add", CAT["math"],
     [("in1", "float", None), ("in2", "float", "0.3")], [("out", "float")])
sr = node("sr", 790, 120, 180, "SR_copper", CAT["pbr"],
     [("base_color", "color3", None), ("base_metalness", "float", "1.0"),
      ("specular_roughness", "float", None), ("specular_anisotropy", "float", "0.8"),
      ("coat_weight", "float", "0.0"), ("geometry_normal", "vector3", None)],
     [("out", "surfaceshader")], thumb="sphere", selected=True, subtitle="open_pbr_surface")
# "+38 inputs" footer
text(880, 120 + HEAD + 64 + ROW * 7 + 18, "+ 38 more inputs", 10, C["faint"], anchor="middle")
node("mat", 1000, 210, 136, "M_BrushedCopper", CAT["material"],
     [("surfaceshader", "surfaceshader", None), ("displacement", "displacementshader", "")],
     [("out", "material")], subtitle="")

wire("tc", "out", "pl", "texcoord")
wire("pl", "out", "bc", "texcoord")
wire("pl", "out", "nm", "texcoord")
wire("po", "out", "nz", "position")
wire("nz", "out", "mu", "in1")
wire("bc", "out", "sr", "base_color")
wire("mu", "out", "sr", "specular_roughness")
wire("nm", "out", "sr", "geometry_normal")
wire("sr", "out", "mat", "surfaceshader")

# add-node popup (Tab menu) – shows the search-driven creation flow
px, py = 752, 412
add('<g filter="url(#drop)">')
rect(px, py, 256, 236, "#2a2a2e", rx=9, stroke="#4a4a50")
add('</g>')
rect(px + 10, py + 10, 236, 28, "#1e1e21", rx=6, stroke=C["accent"], sw=1.5)
text(px + 22, py + 29, "⌕", 13, C["dim"]); text(px + 40, py + 29, "fractal", 13)
add(f'<line x1="{px + 89}" y1="{py + 17}" x2="{px + 89}" y2="{py + 33}" stroke="{C["accent"]}" stroke-width="1.5"/>')
results = [("fractal3d", "Procedural", "float · vector3 → float", True),
           ("fractal2d", "Procedural", "float · vector2 → float", False),
           ("fractal3d", "Procedural", "→ color3", False),
           ("fractal3d", "Procedural", "→ vector3", False),
           ("ND_brushed_metal", "Custom", "nodedef · copper_set", False)]
ry = py + 50
for name, group, sig, hl in results:
    if hl:
        rect(px + 6, ry, 244, 30, C["sel"], rx=5)
    text(px + 18, ry + 13, name, 12, weight="bold" if hl else "normal")
    text(px + 18, ry + 26, sig, 10, "#c9d8ff" if hl else C["faint"], font=MONO)
    text(px + 240, ry + 18, group, 10, "#c9d8ff" if hl else C["dim"], anchor="end")
    ry += 32
text(px + 128, py + 225, "↩ insert  ·  ⌥↩ insert & connect", 10, C["faint"], anchor="middle")

add('</g>')
# minimap + zoom
rect(1028, 640, 110, 68, "#202023", rx=5, stroke="#3a3a3e", extra='fill-opacity="0.92"')
for (mx, my, mw, mh, col) in [(1036, 652, 10, 6, CAT["geometry"]), (1050, 650, 12, 8, CAT["math"]),
                              (1066, 648, 14, 12, CAT["texture"]), (1066, 664, 14, 12, CAT["texture"]),
                              (1086, 650, 16, 18, CAT["pbr"]), (1106, 656, 12, 8, CAT["material"]),
                              (1036, 684, 10, 6, CAT["geometry"]), (1050, 682, 12, 10, CAT["procedural"]),
                              (1066, 686, 10, 6, CAT["math"])]:
    rect(mx, my, mw, mh, col, rx=1)
rect(1032, 645, 92, 58, "none", rx=2, stroke=C["accent"], sw=1)
rect(244, 690, 64, 20, "#202023", rx=5, stroke="#3a3a3e")
text(276, 704, "100%", 11, C["dim"], anchor="middle")

# ---------------------------------------------------------------- bottom panel
line(231, 719, 1149, 719)
rect(231, 720, 918, 252, C["panel"])
tabs = [("XML", True), ("Generated Shader", False), ("Issues  2", False), ("Console", False)]
tx = 244
for lab, act in tabs:
    w = 18 + len(lab) * 7
    if act:
        rect(tx - 6, 726, w, 22, "#3a3a3e", rx=5)
    text(tx + w / 2 - 6, 741, lab, 12, C["text"] if act else C["dim"], anchor="middle",
         weight="bold" if act else "normal")
    tx += w + 10
text(1138, 741, "Two-way sync · edits re-parse on pause", 11, C["faint"], anchor="end")
line(231, 754, 1149, 754)
# xml listing (split: code left, issues right)
xml = [
    ('<nodegraph name="NG_copper">', 0),
    ('<texcoord name="tc" type="vector2" />', 1),
    ('<place2d name="pl" type="vector2">', 1),
    ('<input name="scale" type="vector2" value="4, 1" />', 2),
    ('</place2d>', 1),
    ('<open_pbr_surface name="SR_copper" type="surfaceshader">', 1),
    ('<input name="base_color" type="color3" nodename="base_color_tex" />', 2),
    ('<input name="base_metalness" type="float" value="1.0" />', 2),
    ('<input name="specular_roughness" type="float" nodename="add" />', 2),
]
ly = 774
for i, (src, ind) in enumerate(xml):
    hl = 5 <= i <= 8
    if hl:
        rect(232, ly - 13, 610, 19, "#2a3550")
    text(260, ly, str(41 + i), 11, C["faint"], anchor="end", font=MONO)
    # crude syntax colouring: tag name / attrs / values
    xx = 274 + ind * 16
    import re
    for m in re.finditer(r'(</?[\w_]+)|(\s[\w_]+=)|("[^"]*")|(\s*/?>)', src):
        tok = m.group(0)
        col = "#f28b82" if m.group(1) else "#9ecbff" if m.group(2) else "#a8e6a3" if m.group(3) else "#cfcfd4"
        text(xx, ly, tok, 11, col, font=MONO, extra='xml:space="preserve"')
        xx += len(tok) * 6.62
    ly += 21
line(850, 755, 850, 972)
text(864, 776, "ISSUES", 10, C["faint"], weight="bold", extra='letter-spacing="0.8"')
issues = [(C["warn"], "M_FrostedGlass", "transmission_color has no colorspace;"),
          (None, "", "assuming lin_rec709"),
          (C["warn"], "normal_tex", "file 'normal.png' is sRGB-encoded;"),
          (None, "", "expected raw for vector3 data"),
          (C["ok"], "copper_set.mtlx", "upgraded from v1.38 → v1.39 on load")]
iy = 800
for col, who, msg in issues:
    if col:
        circle(870, iy - 4, 4, col)
        text(882, iy, who, 11, weight="bold"); iy += 16
    text(882, iy, msg, 11, C["dim"]); iy += 20

# ---------------------------------------------------------------- right column: viewport
line(1150, 53, 1150, 972)
rect(1151, 53, 449, 347, "url(#vpbg)")
add('<g clip-path="url(#vpclip)">')
add('<ellipse cx="1375" cy="340" rx="120" ry="20" fill="url(#shadow)"/>')
circle(1375, 228, 112, "url(#copper)")
add('<circle cx="1375" cy="228" r="112" fill="url(#brushed)"/>')
add('<ellipse cx="1335" cy="178" rx="34" ry="12" fill="url(#spec)" transform="rotate(-30 1335 178)"/>')
add('</g>')
# viewport overlays
rect(1162, 62, 230, 24, "#000000", rx=6, extra='fill-opacity="0.45"')
for i, lab in enumerate(["Sphere", "Shaderball", "Plane", "Mesh…"]):
    if i == 0:
        rect(1164, 64, 54, 20, "#ffffff", rx=5, extra='fill-opacity="0.18"')
    text(1191 + i * 56, 78, lab, 11, C["text"] if i == 0 else C["dim"], anchor="middle")
rect(1460, 62, 128, 24, "#000000", rx=6, extra='fill-opacity="0.45"')
text(1472, 78, "☀ studio_small_03", 11, C["dim"])
rect(1162, 366, 250, 24, "#000000", rx=6, extra='fill-opacity="0.45"')
text(1174, 382, "Previewing  M_BrushedCopper  ·  2.1 ms", 11, C["dim"])
rect(1500, 366, 88, 24, "#000000", rx=6, extra='fill-opacity="0.45"')
text(1544, 382, "ACES 2.0 ▾", 11, C["dim"], anchor="middle")

# ---------------------------------------------------------------- inspector
line(1150, 400, 1600, 400)
rect(1151, 401, 449, 571, C["sidebar"])
rect(1166, 414, 28, 28, CAT["pbr"], rx=6)
text(1180, 433, "S", 13, anchor="middle", weight="bold")
text(1204, 426, "SR_copper", 14, weight="bold")
text(1204, 441, "open_pbr_surface · ND_open_pbr_surface_surfaceshader", 10, C["dim"])
rect(1530, 418, 56, 20, "#3a3a3e", rx=5); text(1558, 432, "Docs", 11, C["dim"], anchor="middle")

def group(y, title, open_=True):
    line(1162, y - 16, 1588, y - 16, "#303034")
    text(1166, y, ("▾ " if open_ else "▸ ") + title, 12, weight="bold")
def slider(y, label, val, frac):
    text(1180, y, label, 12, "#cfcfd4")
    rect(1330, y - 10, 190, 12, "#2f2f33", rx=6)
    rect(1330, y - 10, 190 * frac, 12, C["accent"], rx=6, extra='fill-opacity="0.75"')
    circle(1330 + 190 * frac, y - 4, 7, "#e8e8ea")
    text(1586, y, val, 11, C["dim"], anchor="end", font=MONO)
def colorrow(y, label, col, cs):
    text(1180, y, label, 12, "#cfcfd4")
    rect(1330, y - 12, 56, 16, col, rx=3, stroke="#55555b")
    text(1396, y, cs, 10, C["faint"])
    text(1586, y, "0.95 0.64 0.54", 11, C["dim"], anchor="end", font=MONO)
def linked(y, label, src, typ):
    text(1180, y, label, 12, "#cfcfd4")
    rect(1330, y - 13, 258, 18, "#2f2f33", rx=5, stroke=T[typ], sw=1)
    circle(1341, y - 4, 4, T[typ])
    text(1352, y, "← " + src, 11, "#d6d6da")
    text(1580, y, "⤳", 11, C["dim"], anchor="end")

y = 476
group(y, "Base"); y += 26
slider(y, "Weight", "1.000", 1.0); y += 24
linked(y, "Color", "base_color_tex.out", "color3"); y += 24
slider(y, "Metalness", "1.000", 1.0); y += 24
slider(y, "Diffuse Roughness", "0.000", 0.0); y += 34
group(y, "Specular"); y += 26
slider(y, "Weight", "1.000", 1.0); y += 24
colorrow(y, "Color", "#f4a48a", "lin_rec709"); y += 24
linked(y, "Roughness", "add.out", "float"); y += 24
slider(y, "Anisotropy", "0.800", 0.8); y += 24
slider(y, "IOR", "1.500", 0.3); y += 34
for g in ["Transmission", "Subsurface", "Coat", "Fuzz", "Thin Film", "Emission"]:
    group(y, g, open_=False); y += 25
group(y, "Geometry", open_=False)
# promote hint
rect(1162, 936, 426, 26, "#2a3550", rx=6)
text(1176, 953, "⌥-drag any input onto the graph edge to promote it to the material interface", 11, "#a9c1f5")

# ---------------------------------------------------------------- status bar
line(0, 972, W, 972)
rect(0, 973, W, 27, C["toolbar"], rx=0)
add(f'<path d="M0,973 H{W} V988 a12,12 0 0 1 -12,12 H12 a12,12 0 0 1 -12,-12 z" fill="{C["toolbar"]}"/>')
text(14, 991, "MaterialX 1.39.4  ·  OpenUSD 26.08  ·  OCIO: ACES 2.0 studio config  ·  working space ACEScg", 11, C["dim"])
text(W - 14, 991, "17 nodes · 9 connections · 1 selected", 11, C["dim"], anchor="end")

add("</svg>")
open(__import__("os").path.join(__import__("os").path.dirname(__file__), "margolaria-mockup.svg"), "w").write("\n".join(out))
