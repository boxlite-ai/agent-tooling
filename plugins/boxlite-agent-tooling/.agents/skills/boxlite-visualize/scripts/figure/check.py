"""Layout checks for a hand-placed figure: evidence IDs, collisions, key coverage, readability."""
from __future__ import annotations

import math
import re
from itertools import combinations

from .iso import arrow_paths, label_boxes, solid_points
from .style import (MIN_EFFECTIVE_PX, NODE_PADDING, PRESETS, READABLE_AT, ROLE_HUES, TYPE, chip_box, contrast,
                    key_box, mono_width, sans_width, zone_colours, zone_title_box)

MAX_ACCENTS = 2
SLACK = 3.0  # an endpoint within this many pixels of a node counts as attached to it
ARROW_END_SLACK = 12.0  # isometric arrows may meet where they start or land
ID = re.compile(r"(boundary|node|edge):[A-Za-z0-9_.-]{1,128}")
SHAPES = {"box", "pill", "cylinder"}
# Fields drawn as numbers, per item group: n = number, p = [x, y], q = [x, y] or [x, y, z], b = [x0, x1, y0, y1].
GEOMETRY = {
    ("zones",): {"x": "n", "y": "n", "w": "n", "h": "n"},
    ("nodes",): {"x": "n", "y": "n", "w": "n", "h": "n"},
    ("edges",): {"at": "p?"},
    ("iso", "layers"): {"box": "b", "z": "n", "t": "n?", "label_at": "p?"},
    ("iso", "blocks"): {"box": "b", "z": "n", "h": "n"},
    ("iso", "cylinders"): {"center": "p", "r": "n", "z": "n", "h": "n"},
    ("iso", "pills"): {"x": "n", "y": "n", "w": "n", "h": "n"},
    ("iso", "arrows"): {"from": "q", "to": "q", "bend": "n?", "at": "p?"},
}


def _number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _fits(value, kind: str) -> bool:
    sizes = {"p": (2,), "q": (2, 3), "b": (4,)}.get(kind)
    if sizes is None:
        return _number(value)
    return isinstance(value, list) and len(value) in sizes and all(_number(v) for v in value)


def _texts(value) -> bool:
    """A label field: one string or a list of strings."""
    return isinstance(value, str) or (isinstance(value, list) and all(isinstance(v, str) for v in value))


def _check_item(item, group: str, fields: dict, errors: list[str]) -> None:
    if not isinstance(item, dict):
        errors.append(f"{group}: every entry must be an object")
        return
    where, also = str(item.get("id", group)), item.get("also", [])
    if not all(isinstance(i, str) and ID.fullmatch(i) for i in [item.get("id"), *(also if isinstance(also, list) else [0])]):
        errors.append(f"{where}: IDs are boundary:, node: or edge: plus letters, digits, '_', '.' or '-'")
    for field, kind in fields.items():
        if (field in item or not kind.endswith("?")) and not _fits(item.get(field), kind.rstrip("?")):
            errors.append(f"{where}: {field} must be numeric")
    if group == "edges" and not (isinstance(item.get("points"), list) and len(item["points"]) >= 2
                                 and all(_fits(p, "p") for p in item["points"]) and ("at" in item or not item.get("label"))):
        errors.append(f"{where}: needs two or more [x, y] points, and `at` for a label")
    if group not in ("edges", "arrows") and not (isinstance(item.get("role"), str) and item["role"] in ROLE_HUES):
        errors.append(f"{where}: role must be one of {sorted(ROLE_HUES)}")
    if not (isinstance(item.get("shape", "box"), str) and item.get("shape", "box") in SHAPES):
        errors.append(f"{where}: shape must be one of {sorted(SHAPES)}")
    if not all(_texts(item.get(k, "")) for k in ("title", "sub", "caption", "tag", "label", "anchor")):
        errors.append(f"{where}: title, sub, caption, tag, label and anchor must be text")


def validate_spec(spec) -> list[str]:
    """Problems that make a spec unsafe or impossible to draw; empty when it is usable.

    The renderer interpolates numbers and IDs into SVG and script, so they are typed here
    before any drawing; labels are escaped as text where they are drawn.
    """
    if not isinstance(spec, dict) or not isinstance(spec.get("canvas"), dict):
        return ["figure: needs a JSON object with a canvas"]
    errors = [f"canvas: {k} must be a positive number" for k in ("width", "height")
              if not (_number(spec["canvas"].get(k)) and spec["canvas"][k] > 0)]
    if not all(isinstance(spec.get(k, ""), str) for k in ("title", "alt", "version", "brand")):
        errors.append("figure: title, alt, version and brand must be text")
    iso = spec.get("iso", {})
    if not isinstance(iso, dict):
        errors.append("iso: must be an object")
        iso = {}
    view = iso.get("view", {})
    if not (isinstance(view, dict) and _fits(view.get("scale", 1), "n") and _fits(view.get("origin", [0, 0]), "p")
            and _fits(view.get("callout_x", 0), "n")):
        errors.append("iso view: scale and callout_x must be numbers, origin an [x, y] pair")
    for path, fields in GEOMETRY.items():
        items = (iso if path[0] == "iso" else spec).get(path[-1], [])
        for item in items if isinstance(items, list) else [None]:
            _check_item(item, path[-1], fields, errors)
    key = spec.get("key", {})
    entries = [key.get(k, []) for k in ("roles", "shapes", "lines")] if isinstance(key, dict) else [None]
    if not (isinstance(key, dict) and _fits(key.get("x", 0), "n") and _fits(key.get("y", 0), "n")
            and type(key.get("columns", 1)) is int and key.get("columns", 1) >= 1
            and all(isinstance(e, list) and all(isinstance(v, str) for v in e) for e in entries)
            and all(role in ROLE_HUES for role in entries[0])):
        errors.append(f"key: x and y must be numbers, columns a positive integer, roles from {sorted(ROLE_HUES)}")
    return errors


def check_figure(spec: dict, manifest: dict) -> list[dict]:
    """Every finding is {kind, where, detail}; an empty list means the figure passes."""
    findings: list[dict] = []

    def add(kind: str, where: str, detail: str) -> None:
        findings.append({"kind": kind, "where": where, "detail": detail})

    for field in ("alt", "version"):
        if not str(spec.get(field, "")).strip():
            add(f"missing_{field}", "figure", f"figure needs {field!r} text")
    _check_ids(spec, manifest, add)
    _check_bounds(spec, add)
    _check_edges(spec, add)
    _check_labels(spec, add)
    _check_key(spec, add)
    _check_text(spec, add)
    _check_contrast(spec, add)
    _check_iso(spec, add)
    iso = spec.get("iso", {})
    for view, items in (("flat", spec.get("zones", []) + spec.get("nodes", [])),
                        ("iso", sum((iso.get(k, []) for k in ("layers", "blocks", "cylinders", "pills")), []))):
        # Accent and the subject role both draw in the subject hue.
        cyan = [e["id"] for e in items if e.get("accent") or e.get("role") == "subject"]
        if len(cyan) > MAX_ACCENTS:
            add("accent_limit", f"{view}: {', '.join(cyan)}",
                f"cyan marks only the subject, at most {MAX_ACCENTS} elements per view")
    return findings


def _check_ids(spec: dict, manifest: dict, add) -> None:
    known = {kind: {item["id"] for item in manifest.get(f"{kind}s" if kind != "boundary" else "boundaries", [])}
             for kind in ("node", "edge", "boundary")}
    iso = spec.get("iso", {})
    groups = {"boundary": spec.get("zones", []) + iso.get("layers", []),
              "node": spec.get("nodes", []) + iso.get("blocks", []) + iso.get("cylinders", []) + iso.get("pills", []),
              "edge": spec.get("edges", []) + iso.get("arrows", [])}
    # `also` lets one drawn element summarise several evidence items, e.g. three parallel writes.
    drawn = [(element_id, kind) for kind, items in groups.items()
             for e in items for element_id in [e["id"], *e.get("also", [])]]
    for element_id, kind in drawn:
        prefix, _, name = element_id.partition(":")
        if prefix != kind or name not in known[kind]:
            add("unknown_id", element_id, f"expected a {kind}:<id> present in the evidence manifest")


def _rect(item: dict) -> tuple[float, float, float, float]:
    return item["x"], item["y"], item["x"] + item["w"], item["y"] + item["h"]


def _check_bounds(spec: dict, add) -> None:
    width, height = spec["canvas"]["width"], spec["canvas"]["height"]
    boxes = [(e["id"], _rect(e)) for e in spec.get("zones", []) + spec.get("nodes", [])]
    boxes += [(e["id"], chip_box(e)) for e in spec.get("edges", []) if e.get("label")]
    boxes += [(f"{e['id']} point", (x, y, x, y)) for e in spec.get("edges", []) for x, y in e["points"]]
    if spec.get("key"):
        boxes.append(("key", key_box(spec)))
    for where, (x0, y0, x1, y1) in boxes:
        if x0 < 0 or y0 < 0 or x1 > width or y1 > height:
            add("out_of_canvas", where, f"extends outside the {width}x{height} canvas")


def _segments(edge: dict) -> list[tuple[tuple[float, float], tuple[float, float]]]:
    points = [tuple(p) for p in edge["points"]]
    return list(zip(points, points[1:]))


def _inside(point, rect, slack: float = 0.0) -> bool:
    x, y = point
    return rect[0] - slack <= x <= rect[2] + slack and rect[1] - slack <= y <= rect[3] + slack


def _segment_hits_rect(a, b, rect) -> bool:
    """Liang-Barsky clip: does segment a-b pass through the rectangle's interior?"""
    (x0, y0), (x1, y1) = a, b
    dx, dy, t0, t1 = x1 - x0, y1 - y0, 0.0, 1.0
    for p, q in ((-dx, x0 - rect[0]), (dx, rect[2] - x0), (-dy, y0 - rect[1]), (dy, rect[3] - y0)):
        if p == 0:
            if q < 0:
                return False
            continue
        t = q / p
        if p < 0:
            t0 = max(t0, t)
        else:
            t1 = min(t1, t)
        if t0 > t1:
            return False
    return t1 - t0 > 1e-6


def _intersection(a, b, c, d):
    """Proper intersection point of segments a-b and c-d, or None (parallel and collinear runs excluded)."""
    (x1, y1), (x2, y2), (x3, y3), (x4, y4) = a, b, c, d
    den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    if den == 0:
        return None
    t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
    u = ((x1 - x3) * (y1 - y2) - (y1 - y3) * (x1 - x2)) / den
    return (x1 + t * (x2 - x1), y1 + t * (y2 - y1)) if 0 <= t <= 1 and 0 <= u <= 1 else None


def _check_edges(spec: dict, add) -> None:
    nodes = [(n["id"], _rect(n)) for n in spec.get("nodes", [])]
    titles = [(z["id"], zone_title_box(z)) for z in spec.get("zones", [])]
    edges = spec.get("edges", [])
    for edge in edges:
        ends = (tuple(edge["points"][0]), tuple(edge["points"][-1]))
        attached = {nid for nid, rect in nodes if any(_inside(p, rect, SLACK) for p in ends)}
        for zone_id, box in titles:
            if any(_segment_hits_rect(a, b, box) for a, b in _segments(edge)):
                add("edge_crosses_title", edge["id"], f"passes through the title of {zone_id}")
        for node_id, rect in nodes:
            if node_id not in attached and any(_segment_hits_rect(a, b, rect) for a, b in _segments(edge)):
                add("edge_crosses_node", edge["id"], f"passes through {node_id}")
    for first, second in combinations(edges, 2):
        for a, b in _segments(first):
            for c, d in _segments(second):
                point = _intersection(a, b, c, d)
                if point and not any(_inside(point, rect, SLACK) for _, rect in nodes):
                    add("edge_crossing", f"{first['id']} x {second['id']}", f"cross at {point[0]:.0f},{point[1]:.0f}")


def _overlap(r, s) -> bool:
    return r[0] < s[2] and s[0] < r[2] and r[1] < s[3] and s[1] < r[3]


def _check_labels(spec: dict, add) -> None:
    boxes = [(e["id"], chip_box(e)) for e in spec.get("edges", []) if e.get("label")]
    if spec.get("key"):
        boxes.append(("key", key_box(spec)))
    fixed = [(n["id"], _rect(n)) for n in spec.get("nodes", [])]
    fixed += [(f"{z['id']} title", zone_title_box(z)) for z in spec.get("zones", [])]
    for (a, r), (b, s) in combinations(boxes, 2):
        if _overlap(r, s):
            add("label_overlap", f"{a} / {b}", "labels overlap")
    for a, r in boxes:
        for b, s in fixed:
            if _overlap(r, s):
                add("label_overlap", f"{a} / {b}", "label covers another element")
    for node in spec.get("nodes", []):
        for zone in spec.get("zones", []):
            if _overlap(_rect(node), zone_title_box(zone)):
                add("label_overlap", f"{node['id']} / {zone['id']} title", "node covers a zone title")


def _check_key(spec: dict, add) -> None:
    key = spec.get("key", {})
    used_roles = {e["role"] for e in spec.get("zones", []) + spec.get("nodes", [])}
    used_shapes = {n.get("shape", "box") for n in spec.get("nodes", [])} - {"box"}
    used_lines = {"dashed"} if any(e.get("dash") for e in spec.get("edges", [])) else set()
    missing = sorted((used_roles - set(key.get("roles", []))) | (used_shapes - set(key.get("shapes", [])))
                     | (used_lines - set(key.get("lines", []))))
    if missing:
        add("key_incomplete", "key", f"no key entry for {', '.join(missing)}")


def _check_contrast(spec: dict, add) -> None:
    """Text needs 4.5:1 and lines 3:1 in every preset, including each zone title on its own fill."""
    iso = spec.get("iso", {})
    roles = sorted({e["role"] for e in spec.get("zones", []) + spec.get("nodes", []) + iso.get("layers", [])})
    for name, preset in PRESETS.items():
        pairs = [(token, preset[token], preset["bg"], 4.5) for token in ("ink", "muted", "label")]
        pairs.append(("edge", preset["edge"], preset["bg"], 3.0))
        for role in roles:
            fill, _, title = zone_colours(name, ROLE_HUES[role])
            pairs.append((f"{role} title", title, fill, 4.5))
        for what, fg, bg, floor in pairs:
            if contrast(fg, bg) < floor:
                add("contrast", f"{name} {what}", f"{contrast(fg, bg):.1f}:1 is below {floor}:1")


def _check_iso(spec: dict, add) -> None:
    """The isometric view's own layout: solids, arrows and labels on the canvas, labels apart, arrows uncrossed."""
    if not spec.get("iso", {}).get("layers"):
        return
    width, height = spec["canvas"]["width"], spec["canvas"]["height"]
    paths, labels = arrow_paths(spec), label_boxes(spec)
    shapes = solid_points(spec) + paths + [(f"{owner} label", [box[:2], box[2:]]) for owner, box in labels]
    for where, points in shapes:
        if any(not (0 <= x <= width and 0 <= y <= height) for x, y in points):
            add("out_of_canvas", f"iso {where}", f"extends outside the {width}x{height} canvas")
    for (a, r), (b, s) in combinations(labels, 2):
        if _overlap(r, s):
            add("label_overlap", f"iso {a} / {b}", "labels overlap")
    for (a, first), (b, second) in combinations(paths, 2):
        ends = (first[0], first[-1], second[0], second[-1])
        crossing = next((point for p, q in zip(first, first[1:]) for r, s in zip(second, second[1:])
                         if (point := _intersection(p, q, r, s))
                         and all(math.dist(point, end) > ARROW_END_SLACK for end in ends)), None)
        if crossing:
            add("edge_crossing", f"iso {a} x {b}", f"cross at {crossing[0]:.0f},{crossing[1]:.0f}")


def _check_text(spec: dict, add) -> None:
    width = spec["canvas"]["width"]
    effective = min(TYPE.values()) * READABLE_AT / width
    if effective < MIN_EFFECTIVE_PX:
        add("text_too_small", "figure", f"smallest text is {effective:.1f} px at {READABLE_AT} px wide; "
            f"needs {MIN_EFFECTIVE_PX}")
    for node in spec.get("nodes", []):
        room = node["w"] - 2 * NODE_PADDING
        title = mono_width(node["title"], TYPE["node"]) if node.get("mono") else sans_width(node["title"], TYPE["node"], True)
        if title > room or any(sans_width(line, TYPE["sub"]) > room for line in node.get("sub", [])):
            add("text_overflow", node["id"], "text is wider than its box")
    for zone in spec.get("zones", []):
        if zone_title_box(zone)[2] > zone["x"] + zone["w"]:
            add("text_overflow", zone["id"], "title is wider than its zone")
