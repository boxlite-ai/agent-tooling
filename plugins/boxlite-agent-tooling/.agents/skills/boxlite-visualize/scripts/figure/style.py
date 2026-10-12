"""House style shared by the renderer and the checker: role hues, presets, type scale, text metrics."""
from __future__ import annotations

# Four hues plus neutrals; with SUBJECT they pass the dataviz gates all-pairs (CVD dE >= 10.6, normal >= 15.1).
ROLE_HUES = {
    "external": "#8b949e",
    "edge": "#c9d1d9",
    "compute": "#34d399",
    "execution": "#fbbf24",
    "state": "#db61a2",
    "observability": "#d95926",
    "subject": "#00b0f0",
}
SUBJECT = ROLE_HUES["subject"]
ROLE_NAMES = {
    "external": "External", "edge": "Public edge", "compute": "Compute", "execution": "Execution",
    "state": "State", "observability": "Observability", "subject": "Subject",
}
SHAPE_NAMES = {"pill": "Actor", "cylinder": "Stored state"}
LINE_NAMES = {"dashed": "Virtual channel"}

# Text sizes in canvas pixels. The smallest must stay >= 12 px when the canvas shows 700 px wide.
TYPE = {"figure": 24, "zone": 21, "node": 23, "sub": 21, "edge": 21, "key": 21, "footer": 21}
READABLE_AT, MIN_EFFECTIVE_PX = 700, 12
SANS = "Inter, 'Helvetica Neue', Arial, sans-serif"
MONO = "'IBM Plex Mono', SFMono-Regular, Menlo, monospace"
HAND = "Kalam, 'Comic Sans MS', cursive"
NODE_RADIUS, ZONE_RADIUS = 8, 16
NODE_PADDING = 16
WALL_BADGE = 34  # width reserved for a numbered wall badge before a zone title

# Text colours are opaque so contrast is checkable; "dark" picks dark-card fills.
PRESETS = {
    "blueprint": {"bg": "#000000", "ink": "#ffffff", "muted": "#a3a3a3", "label": "#c7c7c7",
                  "edge": "#8c8c8c", "dark": True, "upper": True, "grid": "lines"},
    "editorial": {"bg": "#f6f5f1", "ink": "#111111", "muted": "#5f6368", "label": "#3d4148",
                  "edge": "#7d828b", "dark": False, "upper": False, "grid": None},
    "whiteboard": {"bg": "#fbfaf6", "ink": "#1f1f1f", "muted": "#555555", "label": "#2f2f2f",
                   "edge": "#3b3b3b", "dark": False, "upper": False, "grid": None},
    "walls": {"bg": "#070b14", "ink": "#e8ecf3", "muted": "#a5adba", "label": "#c9d0da",
              "edge": "#8a93a3", "dark": True, "upper": True, "grid": "dots"},
    "isometric": {"bg": "#060912", "ink": "#e8ecf3", "muted": "#a5adba", "label": "#c9d0da",
                  "edge": "#8a93a3", "dark": True, "upper": True, "grid": None},
}


def mix(a: str, b: str, t: float) -> str:
    """Blend colour a toward b by t (0 keeps a, 1 gives b)."""
    pa, pb = (tuple(int(c[i:i + 2], 16) for i in (1, 3, 5)) for c in (a, b))
    return "#%02x%02x%02x" % tuple(round(x + (y - x) * t) for x, y in zip(pa, pb))


def contrast(a: str, b: str) -> float:
    """WCAG 2 contrast ratio of two opaque hex colours."""
    def luminance(colour: str) -> float:
        channels = [int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def zone_colours(preset: str, hue: str) -> tuple[str, str, str]:
    """Fill, border and title colour of a zone in this preset."""
    p = PRESETS[preset]
    if p["dark"]:
        return mix(p["bg"], hue, .08), hue if preset == "walls" else mix(p["bg"], hue, .75), hue
    return mix("#ffffff", hue, .10), mix("#ffffff", hue, .45), mix(hue, "#000000", .45)


def sans_width(text: str, size: float, bold: bool = False) -> float:
    return len(text) * size * (0.57 if bold else 0.55)


def mono_width(text: str, size: float, spacing: float = 0) -> float:
    return len(text) * (size * 0.6 + spacing)


def zone_title_box(zone: dict) -> tuple[float, float, float, float]:
    """Widest rendering of a zone title (wall badge, uppercase mono, subtitle) as x0, y0, x1, y1."""
    width = (WALL_BADGE if zone.get("wall") else 0) + mono_width(zone["title"], TYPE["zone"], 1)
    if zone.get("sub"):
        width += 16 + sans_width(zone["sub"], TYPE["sub"])
    return zone["x"] + 20, zone["y"] + 10, zone["x"] + 20 + width, zone["y"] + 42


def chip_box(edge: dict) -> tuple[float, float, float, float]:
    x, y = edge["at"]
    w = max(mono_width(line, TYPE["edge"]) for line in edge["label"]) + 20
    h = len(edge["label"]) * TYPE["edge"] * 1.3 + 10
    return x - w / 2, y - h / 2, x + w / 2, y + h / 2


def key_entries(spec: dict) -> list[tuple[str, str]]:
    key = spec.get("key", {})
    return ([("role", r) for r in key.get("roles", [])] + [("shape", s) for s in key.get("shapes", [])]
            + [("line", s) for s in key.get("lines", [])])


def key_layout(spec: dict) -> list[tuple[str, str, float, float]]:
    """Each key entry as (kind, value, x, y-centre), filled row by row across `columns`."""
    key, entries = spec.get("key", {}), key_entries(spec)
    columns = max(1, key.get("columns", 1))
    names = [entry_name(kind, value) for kind, value in entries] or ["Key"]
    column = max(sans_width(name, TYPE["key"]) for name in names) + 34 + 24
    return [(kind, value, key.get("x", 0) + (i % columns) * column, key.get("y", 0) + 47 + 34 * (i // columns))
            for i, (kind, value) in enumerate(entries)]


def key_box(spec: dict) -> tuple[float, float, float, float]:
    key, layout = spec.get("key", {}), key_layout(spec)
    x0, y0 = key.get("x", 0), key.get("y", 0)
    right = max((x + 34 + sans_width(entry_name(kind, value), TYPE["key"]) for kind, value, x, _ in layout), default=x0 + 60)
    bottom = max((y + 17 for *_, y in layout), default=y0 + 30)
    return x0, y0, right, bottom


def entry_name(kind: str, value: str) -> str:
    return {"role": ROLE_NAMES, "shape": SHAPE_NAMES, "line": LINE_NAMES}[kind].get(value, value)
