"""Exploded isometric preset: each boundary is a floating layer, painted bottom to top."""
from __future__ import annotations

import math
from html import escape

from .render import _shape, _text, attr, svg_open
from .style import MONO, PRESETS, ROLE_HUES, SANS, SUBJECT, TYPE, chip_box, mix, mono_width, sans_width

COS30 = math.cos(math.radians(30))
DESCENT = 0.25  # share of a font size drawn below the baseline


def projector(spec: dict):
    """World (x, y, z) to a screen point for the spec's view, plus the view scale."""
    view = spec["iso"].get("view", {})
    scale = view.get("scale", 0.5)
    ox, oy = view.get("origin", [spec["canvas"]["width"] * 0.55, spec["canvas"]["height"] * 0.42])

    def P(x: float, y: float, z: float = 0) -> tuple[float, float]:
        return ox + (x - y) * COS30 * scale, oy + (x + y) * 0.5 * scale - z * scale
    return P, scale


def curve(arrow: dict, P) -> tuple[tuple[float, float], tuple[float, float], tuple[float, float]]:
    """Start, control and end of an arrow's quadratic; a two-number point is already on screen."""
    (x1, y1), (x2, y2) = (tuple(p) if len(p) == 2 else P(*p) for p in (arrow["from"], arrow["to"]))
    bend = arrow.get("bend", 0.0)
    return (x1, y1), ((x1 + x2) / 2 - (y2 - y1) * bend, (y1 + y2) / 2 + (x2 - x1) * bend), (x2, y2)


def chip_at(arrow: dict, P) -> list[float]:
    """Hand-placed `at`, else the curve's midpoint."""
    (x1, y1), (qx, qy), (x2, y2) = curve(arrow, P)
    return arrow.get("at") or [0.25 * x1 + 0.5 * qx + 0.25 * x2, 0.25 * y1 + 0.5 * qy + 0.25 * y2]


def layer_label(layer: dict, P, view: dict) -> tuple[float, float, str]:
    """Label point and anchor: `label_at`, else the callout column level with the layer's front corner."""
    x0, _, _, y1 = layer["box"]
    lx, ly = layer.get("label_at", [view.get("callout_x", 330), P(x0, y1, layer["z"] + layer.get("t", 20))[1]])
    return lx, ly, layer.get("anchor", "end")


def solid_points(spec: dict) -> list[tuple[str, list[tuple[float, float]]]]:
    """Screen extremes of every solid `render_iso` draws: slab corners, cylinder outlines, pills."""
    iso, (P, scale) = spec["iso"], projector(spec)
    solids = []
    for item in iso.get("layers", []) + iso.get("blocks", []):
        x0, x1, y0, y1 = item["box"]
        top = item["z"] + (item["h"] if "h" in item else item.get("t", 20))
        solids.append((item["id"], [P(x, y, z) for x in (x0, x1) for y in (y0, y1) for z in (item["z"], top)]))
    for cyl in iso.get("cylinders", []):
        rx, ry = cyl["r"] * math.sqrt(2) * COS30 * scale, cyl["r"] * math.sqrt(2) * 0.5 * scale
        (tx, ty), (_, by) = P(*cyl["center"], cyl["z"] + cyl["h"]), P(*cyl["center"], cyl["z"])
        solids.append((cyl["id"], [(tx - rx, ty - ry), (tx + rx, by + ry)]))
    solids += [(pill["id"], [(pill["x"], pill["y"]), (pill["x"] + pill["w"], pill["y"] + pill["h"])])
               for pill in iso.get("pills", [])]
    return solids


def arrow_paths(spec: dict, steps: int = 24) -> list[tuple[str, list[tuple[float, float]]]]:
    """Each arrow's quadratic as a polyline of `steps` segments."""
    P, _ = projector(spec)
    paths = []
    for arrow in spec["iso"].get("arrows", []):
        a, q, b = curve(arrow, P)
        paths.append((arrow["id"], [tuple((1 - t) ** 2 * a[i] + 2 * (1 - t) * t * q[i] + t * t * b[i] for i in (0, 1))
                                    for t in (k / steps for k in range(steps + 1))]))
    return paths


def _span(x: float, width: float, anchor: str) -> tuple[float, float]:
    return {"start": (x, x + width), "end": (x - width, x)}.get(anchor, (x - width / 2, x + width / 2))


def label_boxes(spec: dict) -> list[tuple[str, tuple[float, float, float, float]]]:
    """Screen boxes of every label `render_iso` draws, as (owner, (x0, y0, x1, y1))."""
    iso, (P, scale) = spec["iso"], projector(spec)
    boxes = [(arrow["id"], chip_box({"at": chip_at(arrow, P), "label": arrow["label"]}))
             for arrow in iso.get("arrows", []) if arrow.get("label")]
    for layer in iso.get("layers", []):
        lx, ly, anchor = layer_label(layer, P, iso.get("view", {}))
        width = max(mono_width(layer["title"].upper(), TYPE["zone"], 1), sans_width(layer.get("caption", ""), TYPE["sub"]))
        bottom = ly + TYPE["sub"] + 2 + DESCENT * TYPE["sub"] if layer.get("caption") else ly - 6 + DESCENT * TYPE["zone"]
        x0, x1 = _span(lx, width, anchor)
        boxes.append((layer["id"], (x0, ly - 6 - TYPE["zone"], x1, bottom)))
    # Block titles sit 4 px above the top-face centre; cylinder titles start right of the lid.
    uprights = []
    for block in iso.get("blocks", []):
        x0, x1, y0, y1 = block["box"]
        uprights.append((block, *P((x0 + x1) / 2, (y0 + y1) / 2, block["z"] + block["h"]), "middle", -4))
    for cyl in iso.get("cylinders", []):
        x, y = P(*cyl["center"], cyl["z"] + cyl["h"])
        uprights.append((cyl, x + cyl["r"] * scale * 1.3, y, "start", 8))
    for item, x, y, anchor, shift in uprights:
        sub, tag = item.get("sub"), item.get("tag")
        width = max(sans_width(item["title"], TYPE["node"], True), sans_width(sub or "", TYPE["sub"]),
                    len(tag) * (TYPE["sub"] - 4) * 0.6 + 24 if tag else 0)
        bottom = y + shift + (TYPE["sub"] + 4 if sub else 0) + DESCENT * TYPE["sub"]
        if tag:
            bottom = y + (2 if sub else 1) * (TYPE["sub"] + 4) + 8
        x0, x1 = _span(x, width, anchor)
        boxes.append((item["id"], (x0, y + shift - TYPE["node"], x1, bottom)))
    return boxes


def render_iso(spec: dict) -> str:
    iso = spec.get("iso")
    if not iso or not iso.get("layers"):
        raise ValueError("the isometric preset needs spec['iso'] layers")
    p = PRESETS["isometric"]
    view = iso.get("view", {})
    P, scale = projector(spec)

    def poly(points, fill, stroke, width, extra="") -> str:
        pts = " ".join(f"{a:.1f},{b:.1f}" for a, b in points)
        return f'<polygon points="{pts}" fill="{fill}" stroke="{stroke}" stroke-width="{width}" stroke-linejoin="round"{extra}/>'

    def slab(item: dict, height: float, top_tint: float) -> str:
        x0, x1, y0, y1 = item["box"]
        z, hue = item["z"], SUBJECT if item.get("accent") else ROLE_HUES[item["role"]]
        glow = ' filter="url(#glow)"' if item.get("accent") else ""
        top = [P(x0, y0, z + height), P(x1, y0, z + height), P(x1, y1, z + height), P(x0, y1, z + height)]
        left = [P(x0, y1, z + height), P(x1, y1, z + height), P(x1, y1, z), P(x0, y1, z)]
        right = [P(x1, y0, z + height), P(x1, y1, z + height), P(x1, y1, z), P(x1, y0, z)]
        return (f'<g data-id="{attr(item["id"])}">' + poly(left, mix(p["bg"], hue, .10), hue, 1.2)
                + poly(right, mix(p["bg"], hue, .06), hue, 1.2) + poly(top, mix(p["bg"], hue, top_tint), hue, 1.6, glow) + "</g>")

    def cylinder(item: dict) -> str:
        (cx, cy), r, z, h = item["center"], item["r"], item["z"], item["h"]
        hue, k = ROLE_HUES[item["role"]], math.sqrt(2)
        rx, ry = r * k * COS30 * scale, r * k * 0.5 * scale
        (tx, ty), (bx, by) = P(cx, cy, z + h), P(cx, cy, z)
        return (f'<g data-id="{attr(item["id"])}"><path d="M{bx - rx:.1f},{by:.1f} L{tx - rx:.1f},{ty:.1f} L{tx + rx:.1f},{ty:.1f} '
                f'L{bx + rx:.1f},{by:.1f} A{rx:.1f},{ry:.1f} 0 0 1 {bx - rx:.1f},{by:.1f} Z" fill="{mix(p["bg"], hue, .10)}" '
                f'stroke="{hue}" stroke-width="1.2"/><ellipse cx="{tx:.1f}" cy="{ty:.1f}" rx="{rx:.1f}" ry="{ry:.1f}" '
                f'fill="{mix(p["bg"], hue, .22)}" stroke="{hue}" stroke-width="1.4"/></g>')

    def upright(x, y, title, sub=None, anchor="middle") -> str:
        halo = f' paint-order="stroke" stroke="{p["bg"]}" stroke-width="4"'
        out = (f'<text x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}" font-family="{escape(SANS, True)}" font-size="{TYPE["node"]}" '
               f'font-weight="600" fill="{p["ink"]}"{halo}>{escape(title)}</text>')
        if sub:
            out += (f'<text x="{x:.1f}" y="{y + TYPE["sub"] + 4:.1f}" text-anchor="{anchor}" font-family="{escape(SANS, True)}" '
                    f'font-size="{TYPE["sub"]}" fill="{p["muted"]}"{halo}>{escape(sub)}</text>')
        return out

    drawables = [(layer["z"], 0, 0, slab(layer, layer.get("t", 20), .14)) for layer in iso["layers"]]
    drawables += [(b["z"], 1, sum(b["box"]), slab(b, b["h"], .24)) for b in iso.get("blocks", [])]
    drawables += [(c["z"], 1, sum(c["center"]), cylinder(c)) for c in iso.get("cylinders", [])]
    out = svg_open(spec, "isometric")
    out += [svg for *_, svg in sorted(drawables, key=lambda d: d[:3])]
    for node in iso.get("pills", []):
        hue = ROLE_HUES[node["role"]]
        out.append(_shape(node | {"shape": "pill"}, mix(p["bg"], hue, .16), hue, 1.2)
                   + upright(node["x"] + node["w"] / 2, node["y"] + node["h"] / 2 + 8, node["title"]))
    chips = []
    for arrow in iso.get("arrows", []):
        (x1, y1), (qx, qy), (x2, y2) = curve(arrow, P)
        dash = ' stroke-dasharray="9 7"' if arrow.get("dash") else ""
        out.append(f'<path data-id="{attr(arrow["id"])}" d="M{x1:.1f},{y1:.1f} Q{qx:.1f},{qy:.1f} {x2:.1f},{y2:.1f}" fill="none" '
                   f'stroke="{p["edge"]}" stroke-width="2"{dash} marker-end="url(#arrow)"/>')
        if arrow.get("label"):
            at = chip_at(arrow, P)
            bx0, by0, bx1, by1 = chip_box({"at": at, "label": arrow["label"]})
            chips.append(f'<rect x="{bx0:.1f}" y="{by0:.1f}" width="{bx1 - bx0:.1f}" height="{by1 - by0:.1f}" rx="6" fill="{p["bg"]}"/>'
                         + "".join(_text(at[0], by0 + 5 + (i + 1) * TYPE["edge"] * 1.3 - TYPE["edge"] * .3, line, MONO,
                                         TYPE["edge"], p["label"], anchor="middle") for i, line in enumerate(arrow["label"])))
    for block in iso.get("blocks", []):
        x0, x1, y0, y1 = block["box"]
        x, y = P((x0 + x1) / 2, (y0 + y1) / 2, block["z"] + block["h"])
        out.append(upright(x, y - 4, block["title"], block.get("sub")))
        if block.get("tag"):
            tw, ty = len(block["tag"]) * (TYPE["sub"] - 4) * 0.6 + 24, y + (2 if block.get("sub") else 1) * (TYPE["sub"] + 4)
            out.append(f'<rect x="{x - tw / 2:.1f}" y="{ty - 20:.1f}" width="{tw:.1f}" height="28" rx="14" '
                       f'fill="{mix(p["bg"], SUBJECT, .22)}" stroke="{SUBJECT}"/>'
                       + _text(x, ty - 1, block["tag"], MONO, TYPE["sub"] - 4, "#7fd8ff", anchor="middle"))
    for cyl in iso.get("cylinders", []):
        x, y = P(*cyl["center"], cyl["z"] + cyl["h"])
        out.append(upright(x + cyl["r"] * scale * 1.3, y + 8, cyl["title"], cyl.get("sub"), anchor="start"))
    for layer in iso["layers"]:
        # The leader starts at the top-face corner nearest the hand-placed label.
        x0, x1, y0, y1 = layer["box"]
        hue = SUBJECT if layer.get("accent") else ROLE_HUES[layer["role"]]
        top = layer["z"] + layer.get("t", 20)
        lx, ly, anchor = layer_label(layer, P, view)
        cx, cy = min((P(x, y, top) for x in (x0, x1) for y in (y0, y1)), key=lambda c: math.dist(c, (lx, ly)))
        tip = lx + (12 if anchor == "end" else -12)
        out.append(f'<path d="M{cx:.1f},{cy:.1f} L{tip:.1f},{ly}" fill="none" stroke="{hue}" stroke-opacity=".75"/>'
                   f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="4" fill="{hue}"/>')
        out.append(_text(lx, ly - 6, layer["title"].upper(), MONO, TYPE["zone"], hue, 500, anchor, 1))
        if layer.get("caption"):
            out.append(_text(lx, ly + TYPE["sub"] + 2, layer["caption"], SANS, TYPE["sub"], p["muted"], anchor=anchor))
    out += chips
    out.append("</svg>")
    return "".join(out)
