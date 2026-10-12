"""Render a figure spec in one preset: SVG for blueprint, editorial, walls and isometric; HTML for whiteboard."""
from __future__ import annotations

import hashlib
import json
from html import escape
from pathlib import Path

from .style import (HAND, MONO, NODE_RADIUS, PRESETS, ROLE_HUES, SANS, SUBJECT, TYPE, WALL_BADGE, ZONE_RADIUS,
                    chip_box, entry_name, key_layout, mix, mono_width, zone_colours)

FONTS = ("https://fonts.googleapis.com/css2?family=Inter:wght@400;600&family=IBM+Plex+Mono:wght@400;500"
         "&family=Kalam:wght@400;700&display=block")
ROUGH = Path(__file__).parent / "vendor" / "rough-4.6.6.min.js"
# Byte-identical to https://unpkg.com/roughjs@4.6.6/bundled/rough.js.
ROUGH_SHA256 = "6853af8619532f3939b156cd16824d2e14f31e71d3df306ad5558eeafacab194"


def attr(value) -> str:
    """A spec value placed inside a double-quoted SVG attribute."""
    return escape(str(value), True)


def _rough() -> str:
    data = ROUGH.read_bytes()
    if hashlib.sha256(data).hexdigest() != ROUGH_SHA256:
        raise ValueError(f"{ROUGH.name} does not match roughjs 4.6.6 (sha256 {ROUGH_SHA256})")
    return data.decode("utf-8")


def render(spec: dict, preset: str) -> str:
    """A self-contained HTML page for screenshots; whiteboard draws its shapes in the browser."""
    body = _whiteboard(spec) if preset == "whiteboard" else render_svg(spec, preset)
    bg = PRESETS[preset]["bg"]
    return (f'<!doctype html><html><head><meta charset="utf-8"><link href="{FONTS}" rel="stylesheet">'
            f'<style>html,body{{margin:0;background:{bg}}}</style></head><body>{body}</body></html>')


def render_svg(spec: dict, preset: str) -> str:
    if preset == "whiteboard":
        raise ValueError("whiteboard draws in the browser; use render() for its HTML page")
    if preset == "isometric":
        from .iso import render_iso
        return render_iso(spec)
    return _flat(spec, preset)


def svg_open(spec: dict, preset: str, under: str = "") -> list[str]:
    """SVG head, background, title and footer; `under` sits above the background, below everything else."""
    p, w, h = PRESETS[preset], spec["canvas"]["width"], spec["canvas"]["height"]
    grid = {"lines": '<path d="M40 0H0V40" fill="none" stroke="#ffffff" stroke-opacity=".06"/>',
            "dots": '<circle cx="2" cy="2" r="1.4" fill="#ffffff" fill-opacity=".09"/>'}.get(p["grid"])
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" '
           f'aria-label="{escape(spec.get("alt", ""))}"><title>{escape(spec.get("title", ""))}</title>',
           f'<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
           f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{p["edge"]}"/></marker>'
           f'<filter id="glow" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="0" '
           f'stdDeviation="9" flood-color="{SUBJECT}" flood-opacity="{.65 if p["dark"] else .3}"/></filter>'
           f'<filter id="shadow" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="4" '
           f'stdDeviation="6" flood-color="#000000" flood-opacity=".08"/></filter>'
           + (f'<pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse">{grid}</pattern>' if grid else "")
           + f'</defs><rect width="100%" height="100%" fill="{p["bg"]}"/>']
    if grid:
        out.append('<rect width="100%" height="100%" fill="url(#grid)"/>')
    out.append(under)
    title = spec.get("title", "")
    if p["upper"]:
        out.append(_text(40, 56, title.upper(), MONO, TYPE["figure"], SUBJECT, spacing=3))
    else:
        family = HAND if preset == "whiteboard" else SANS
        out.append(_text(40, 56, title, family, TYPE["figure"] + 4, p["ink"], weight=600))
    footer = " · ".join(filter(None, [spec.get("brand", "BoxLite"), spec.get("version")]))
    out.append(_text(w - 40, h - 26, footer, MONO, TYPE["footer"], p["muted"], anchor="end"))
    return out


def _text(x, y, text, family, size, fill, weight=400, anchor="start", spacing=0.0) -> str:
    extra = f' letter-spacing="{spacing}"' if spacing else ""
    return (f'<text x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}" font-family="{escape(family, True)}" '
            f'font-size="{size}" font-weight="{weight}" fill="{fill}"{extra}>{escape(text)}</text>')


def path_d(points, r: float = 10) -> str:
    """Orthogonal polyline with rounded bends."""
    d = f"M{points[0][0]},{points[0][1]}"
    for (x0, y0), (x1, y1), (x2, y2) in zip(points, points[1:], points[2:]):
        sx0, sy0 = (x1 > x0) - (x1 < x0), (y1 > y0) - (y1 < y0)
        sx1, sy1 = (x2 > x1) - (x2 < x1), (y2 > y1) - (y2 < y1)
        d += f" L{x1 - sx0 * r},{y1 - sy0 * r} Q{x1},{y1} {x1 + sx1 * r},{y1 + sy1 * r}"
    return d + f" L{points[-1][0]},{points[-1][1]}"


def _surface(spec: dict, preset: str, x: float, y: float) -> str:
    """Fill under a point: the innermost zone there, else the page."""
    hits = [z for z in spec.get("zones", []) if z["x"] <= x <= z["x"] + z["w"] and z["y"] <= y <= z["y"] + z["h"]]
    if not hits:
        return PRESETS[preset]["bg"]
    return zone_colours(preset, ROLE_HUES[min(hits, key=lambda z: z["w"] * z["h"])["role"]])[0]


def _node_text(node: dict, preset: str, family_title: str, family_sub: str) -> str:
    p = PRESETS[preset]
    lines = [(node["title"], MONO if node.get("mono") else family_title, TYPE["node"], 600, p["ink"])]
    lines += [(s, family_sub, TYPE["sub"], 400, p["muted"]) for s in node.get("sub", [])]
    heights = [size * 1.25 for _, _, size, _, _ in lines]
    y = node["y"] + node["h"] / 2 - sum(heights) / 2 - (16 if node.get("tag") else 0)
    if node.get("shape") == "cylinder":
        y += 8
    out = []
    for (text, family, size, weight, fill), height in zip(lines, heights):
        y += height
        out.append(_text(node["x"] + node["w"] / 2, y - height * .28, text, family, size, fill, weight, "middle"))
    if node.get("tag"):
        tw, cx = mono_width(node["tag"], TYPE["sub"] - 4) + 24, node["x"] + node["w"] / 2
        out.append(f'<rect x="{cx - tw / 2:.1f}" y="{node["y"] + node["h"] - 42}" width="{tw:.1f}" height="28" rx="14" '
                   f'fill="{mix(p["bg"], SUBJECT, .18)}" stroke="{SUBJECT}"/>')
        out.append(_text(cx, node["y"] + node["h"] - 22.5, node["tag"], MONO, TYPE["sub"] - 4,
                         "#7fd8ff" if p["dark"] else "#0369a1", anchor="middle"))
    return "".join(out)


def _shape(node: dict, fill: str, stroke: str, width: float, extra: str = "") -> str:
    x, y, w, h = node["x"], node["y"], node["w"], node["h"]
    if node.get("shape") == "cylinder":
        return (f'<path d="M{x},{y + 10} L{x},{y + h - 10} A{w / 2},10 0 0 0 {x + w},{y + h - 10} L{x + w},{y + 10}" '
                f'fill="{fill}" stroke="{stroke}" stroke-width="{width}"{extra}/>'
                f'<ellipse cx="{x + w / 2}" cy="{y + 10}" rx="{w / 2}" ry="10" fill="{fill}" stroke="{stroke}" stroke-width="{width}"/>')
    rx = h / 2 if node.get("shape") == "pill" else NODE_RADIUS
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" '
            f'stroke-width="{width}"{extra}/>')


def _flat(spec: dict, preset: str) -> str:
    p = PRESETS[preset]
    out = svg_open(spec, preset)
    for zone in spec.get("zones", []):
        hue = SUBJECT if zone.get("accent") else ROLE_HUES[zone["role"]]
        fill, stroke, ink = zone_colours(preset, hue)
        dash = ' stroke-dasharray="8 6"' if zone.get("dash") else ""
        glow = ' filter="url(#glow)"' if zone.get("accent") else ""
        out.append(f'<rect data-id="{attr(zone["id"])}" x="{zone["x"]}" y="{zone["y"]}" width="{zone["w"]}" height="{zone["h"]}" '
                   f'rx="{ZONE_RADIUS}" fill="{fill}" stroke="{stroke}" stroke-width="{2 if zone.get("accent") else 1.5}"{dash}{glow}/>')
        x, y = zone["x"] + 20, zone["y"] + 34
        if zone.get("wall") and preset == "walls":
            out.append(f'<g data-wall="{attr(zone["wall"])}"><circle cx="{x + 14}" cy="{y - 8}" r="14" fill="{hue}"/>'
                       + _text(x + 14, y - 1, str(zone["wall"]), MONO, TYPE["zone"] - 3, p["bg"], 600, "middle") + "</g>")
            x += WALL_BADGE
        title = zone["title"].upper() if p["upper"] else zone["title"]
        family, spacing = (MONO, 1) if p["upper"] else (SANS, 0)
        out.append(_text(x, y, title, family, TYPE["zone"], ink, 500 if p["upper"] else 600, spacing=spacing))
        if zone.get("sub"):
            out.append(_text(x + mono_width(title, TYPE["zone"], 1) + 16, y, zone["sub"], SANS, TYPE["sub"], p["muted"]))
        if zone.get("caption"):
            out.append(_text(zone["x"] + 20, zone["y"] + zone["h"] - 20, zone["caption"], SANS, TYPE["sub"], p["muted"]))
    for edge in spec.get("edges", []):
        dash = ' stroke-dasharray="9 7"' if edge.get("dash") else ""
        out.append(f'<path data-id="{attr(edge["id"])}" d="{path_d(edge["points"])}" fill="none" stroke="{p["edge"]}" '
                   f'stroke-width="2"{dash} marker-end="url(#arrow)"/>')
    for node in spec.get("nodes", []):
        hue = ROLE_HUES[node["role"]]
        if node.get("accent"):
            fill, stroke, width, extra = mix(p["bg"], SUBJECT, .2 if p["dark"] else .06), SUBJECT, 2.5, ' filter="url(#glow)"'
        elif p["dark"]:
            fill, stroke, width, extra = mix(p["bg"], hue, .14), hue, 1.2, ""
        else:
            fill, stroke, width, extra = "#ffffff", "#e3e1db", 1, ' filter="url(#shadow)"'
        out.append(f'<g data-id="{attr(node["id"])}">' + _shape(node, fill, stroke, width, extra))
        if not p["dark"] and node.get("shape", "box") == "box":
            out.append(f'<rect x="{node["x"]}" y="{node["y"] + 12}" width="5" height="{node["h"] - 24}" rx="2.5" fill="{hue}"/>')
        out.append(_node_text(node, preset, SANS, SANS) + "</g>")
    out += _chips(spec, preset)
    out += _key(spec, preset)
    out.append("</svg>")
    return "".join(out)


def _chips(spec: dict, preset: str, family: str = MONO) -> list[str]:
    p, out = PRESETS[preset], []
    for edge in (e for e in spec.get("edges", []) if e.get("label")):
        x0, y0, x1, y1 = chip_box(edge)
        out.append(f'<rect x="{x0:.1f}" y="{y0:.1f}" width="{x1 - x0:.1f}" height="{y1 - y0:.1f}" rx="6" '
                   f'fill="{_surface(spec, preset, *edge["at"])}"/>')
        for i, line in enumerate(edge["label"]):
            out.append(_text(edge["at"][0], y0 + 5 + (i + 1) * TYPE["edge"] * 1.3 - TYPE["edge"] * .3, line, family,
                             TYPE["edge"], p["label"], anchor="middle"))
    return out


def _key(spec: dict, preset: str) -> list[str]:
    if not spec.get("key"):
        return []
    p, x, y = PRESETS[preset], spec["key"]["x"], spec["key"]["y"]
    out = [_text(x, y + 20, "Key", SANS, TYPE["key"], p["muted"], 600)]
    for kind, value, x, cy in key_layout(spec):
        if kind == "role":
            out.append(f'<rect x="{x}" y="{cy - 9}" width="18" height="18" rx="4" fill="{ROLE_HUES[value]}"/>')
        elif kind == "shape":
            rx = 9 if value == "pill" else 3
            out.append(f'<rect x="{x}" y="{cy - 9}" width="18" height="18" rx="{rx}" fill="none" stroke="{p["ink"]}" stroke-width="1.5"/>')
        else:
            out.append(f'<line x1="{x}" y1="{cy}" x2="{x + 18}" y2="{cy}" stroke="{p["edge"]}" stroke-width="2" stroke-dasharray="5 4"/>')
        out.append(_text(x + 30, cy + 7, entry_name(kind, value), SANS, TYPE["key"], p["ink"]))
    return out


def _whiteboard(spec: dict) -> str:
    """SVG text and labels drawn here; rough.js draws the shapes client-side from the JSON payload."""
    preset, p = "whiteboard", PRESETS["whiteboard"]
    out = svg_open(spec, preset, under='<g id="sketch"></g>')
    for zone in spec.get("zones", []):
        hue = SUBJECT if zone.get("accent") else ROLE_HUES[zone["role"]]
        out.append(_text(zone["x"] + 20, zone["y"] + 34, zone["title"], HAND, TYPE["zone"] + 3, mix(hue, "#000000", .5), 700))
        if zone.get("sub"):
            out.append(_text(zone["x"] + 20 + mono_width(zone["title"], TYPE["zone"], 1) + 16, zone["y"] + 34, zone["sub"],
                             HAND, TYPE["sub"], p["muted"]))
        if zone.get("caption"):
            out.append(_text(zone["x"] + 20, zone["y"] + zone["h"] - 20, zone["caption"], HAND, TYPE["sub"], p["muted"]))
    for node in spec.get("nodes", []):
        out.append(f'<g data-id="{attr(node["id"])}">' + _node_text(node, preset, HAND, HAND) + "</g>")
    out += _chips(spec, preset)
    out += _key(spec, preset)
    out.append("</svg>")
    shapes = {
        "zones": [{"x": z["x"], "y": z["y"], "w": z["w"], "h": z["h"], "accent": bool(z.get("accent")),
                   "stroke": mix(SUBJECT if z.get("accent") else ROLE_HUES[z["role"]], "#000000", .35),
                   "fill": mix("#ffffff", ROLE_HUES[z["role"]], .4)} for z in spec.get("zones", [])],
        "nodes": [{"x": n["x"], "y": n["y"], "w": n["w"], "h": n["h"], "shape": n.get("shape", "box"),
                   "accent": bool(n.get("accent")), "fill": "#e3f6fd" if n.get("accent") else mix("#ffffff", ROLE_HUES[n["role"]], .22)}
                  for n in spec.get("nodes", [])],
        "edges": [{"points": e["points"], "dash": bool(e.get("dash"))} for e in spec.get("edges", [])],
    }
    # Escaped so no spec string can close the <script> element or open markup inside it.
    data = json.dumps(shapes).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    script = ("const D=" + data + ";(async()=>{await document.fonts.ready;"
              "const svg=document.querySelector('svg'),rc=rough.svg(svg),g=document.getElementById('sketch'),add=e=>g.appendChild(e);let s=7;"
              "for(const z of D.zones)add(rc.rectangle(z.x,z.y,z.w,z.h,{roughness:1.3,seed:s++,stroke:z.stroke,strokeWidth:z.accent?2.6:1.6,"
              "fill:z.fill,fillStyle:'hachure',hachureGap:18,fillWeight:.6,hachureAngle:-41}));"
              "for(const n of D.nodes){const o={roughness:1.1,seed:s++,stroke:n.accent?'#00a3e0':'#2f2f2f',strokeWidth:n.accent?3:1.6,fill:n.fill,fillStyle:'solid'};"
              "if(n.shape==='cylinder'){add(rc.path(`M${n.x},${n.y+10} L${n.x},${n.y+n.h-10} A${n.w/2},10 0 0 0 ${n.x+n.w},${n.y+n.h-10} L${n.x+n.w},${n.y+10}`,o));"
              "add(rc.ellipse(n.x+n.w/2,n.y+10,n.w,20,o));}else if(n.shape==='pill'){const r=n.h/2;"
              "add(rc.path(`M${n.x+r},${n.y} L${n.x+n.w-r},${n.y} A${r},${r} 0 0 1 ${n.x+n.w-r},${n.y+n.h} L${n.x+r},${n.y+n.h} A${r},${r} 0 0 1 ${n.x+r},${n.y} Z`,o));}"
              "else add(rc.rectangle(n.x,n.y,n.w,n.h,o));}"
              "for(const e of D.edges){const o={roughness:.9,seed:s++,stroke:'#3b3b3b',strokeWidth:1.8,strokeLineDash:e.dash?[9,7]:undefined};"
              "add(rc.linearPath(e.points,o));const [a,b]=e.points.slice(-2),t=Math.atan2(b[1]-a[1],b[0]-a[0]),"
              "p=d=>[b[0]-15*Math.cos(t+d),b[1]-15*Math.sin(t+d)];add(rc.linearPath([p(.42),b,p(-.42)],{...o,strokeLineDash:undefined}));}})();")
    return "".join(out) + f"<script>{_rough()}</script><script>{script}</script>"
