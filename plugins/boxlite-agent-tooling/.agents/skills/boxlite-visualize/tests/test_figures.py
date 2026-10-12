from __future__ import annotations

import copy
import json
import math
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = SKILL_ROOT / "references" / "examples" / "figure-2"
sys.path.insert(0, str(SKILL_ROOT / "scripts"))

from figure.check import check_figure, validate_spec
from figure.style import PRESETS, ROLE_HUES, SUBJECT
from figure.render import ROUGH, render, render_svg


def example() -> tuple[dict, dict]:
    """The shipped Figure 2 spec and the evidence manifest it was drawn from."""
    return tuple(json.loads((EXAMPLE / name).read_text(encoding="utf-8")) for name in ("figure.json", "evidence.json"))


def manifest() -> dict:
    """Evidence manifest IDs a figure may draw; the checker reads only these."""
    return {
        "nodes": [{"id": "runtime"}, {"id": "vmm"}, {"id": "guest"}],
        "edges": [{"id": "spawn"}, {"id": "probe"}],
        "boundaries": [{"id": "host"}, {"id": "shim"}],
    }


def clean_spec() -> dict:
    """Two zones and three nodes on a 1200 px canvas; the only edge crosses borders right of every title."""
    return {
        "canvas": {"width": 1200, "height": 900},
        "title": "Figure 2 · Inside one machine",
        "alt": "BoxliteRuntime spawns a jailed shim whose VMM runs the guest.",
        "version": "boxlite 5b3321c",
        "zones": [
            {"id": "boundary:host", "role": "compute", "x": 60, "y": 110, "w": 1080, "h": 200, "title": "Host process"},
            {"id": "boundary:shim", "role": "execution", "x": 60, "y": 390, "w": 720, "h": 430, "title": "boxlite-shim"},
        ],
        "nodes": [
            {"id": "node:runtime", "role": "compute", "shape": "box", "x": 470, "y": 180, "w": 280, "h": 76,
             "title": "BoxliteRuntime"},
            {"id": "node:vmm", "role": "subject", "shape": "box", "x": 440, "y": 470, "w": 300, "h": 110,
             "title": "VMM", "accent": True},
            {"id": "node:guest", "role": "subject", "shape": "box", "x": 110, "y": 640, "w": 300, "h": 90,
             "title": "boxlite-guest"},
        ],
        "edges": [
            {"id": "edge:spawn", "points": [[600, 256], [600, 470]], "label": ["spawns shim"], "at": [600, 350]},
        ],
        "key": {"x": 820, "y": 700, "roles": ["compute", "execution", "subject"]},
    }


def kinds(spec: dict) -> set[str]:
    return {finding["kind"] for finding in check_figure(spec, manifest())}


class FigureCheckTests(unittest.TestCase):
    def test_clean_figure_has_no_findings(self) -> None:
        self.assertEqual(check_figure(clean_spec(), manifest()), [])

    def test_edge_through_a_zone_title_is_reported(self) -> None:
        spec = clean_spec()
        spec["edges"][0]["points"] = [[150, 330], [150, 640]]
        self.assertIn("edge_crosses_title", kinds(spec))

    def test_edge_through_an_unrelated_node_is_reported(self) -> None:
        spec = clean_spec()
        spec["nodes"][2]["y"] = 500
        spec["edges"][0]["points"] = [[600, 256], [600, 340], [260, 340], [260, 700]]
        self.assertIn("edge_crosses_node", kinds(spec))

    def test_crossing_edges_are_reported(self) -> None:
        spec = clean_spec()
        spec["edges"].append({"id": "edge:probe", "points": [[300, 420], [760, 420]], "label": ["probe"], "at": [380, 440]})
        self.assertIn("edge_crossing", kinds(spec))

    def test_overlapping_labels_are_reported(self) -> None:
        spec = clean_spec()
        spec["edges"].append(copy.deepcopy(spec["edges"][0]) | {"id": "edge:probe", "label": ["also here"]})
        self.assertIn("label_overlap", kinds(spec))

    def test_node_over_a_zone_title_is_reported(self) -> None:
        spec = clean_spec()
        spec["nodes"][2]["x"], spec["nodes"][2]["y"] = 70, 400
        self.assertIn("label_overlap", kinds(spec))

    def test_key_columns_keep_a_long_key_on_the_canvas(self) -> None:
        spec = clean_spec()
        spec["key"] |= {"x": 40, "y": 760, "roles": ["compute", "execution", "subject", "state", "external"], "columns": 3}
        self.assertNotIn("out_of_canvas", kinds(spec))
        spec["key"]["columns"] = 1
        self.assertIn("out_of_canvas", kinds(spec))

    def test_element_outside_the_canvas_is_reported(self) -> None:
        spec = clean_spec()
        spec["nodes"][0]["x"] = 1000
        self.assertIn("out_of_canvas", kinds(spec))

    def test_id_missing_from_the_evidence_is_reported(self) -> None:
        spec = clean_spec()
        spec["nodes"][0]["id"] = "node:invented"
        self.assertIn("unknown_id", kinds(spec))

    def test_a_summary_edge_checks_every_evidence_id_it_draws(self) -> None:
        spec = clean_spec()
        spec["edges"][0]["also"] = ["edge:probe"]
        self.assertNotIn("unknown_id", kinds(spec))
        spec["edges"][0]["also"].append("edge:invented")
        self.assertIn("unknown_id", kinds(spec))

    def test_more_than_two_accents_are_reported(self) -> None:
        spec = clean_spec()
        for node in spec["nodes"]:
            node["accent"] = True
        self.assertIn("accent_limit", kinds(spec))

    def test_subject_role_counts_toward_the_cyan_limit(self) -> None:
        spec = clean_spec()
        spec["nodes"][0]["role"] = "subject"
        self.assertIn("accent_limit", kinds(spec))

    def test_shipped_figure_2_passes_every_check(self) -> None:
        spec, evidence = example()
        self.assertEqual(validate_spec(spec), [])
        self.assertEqual(check_figure(spec, evidence), [])


class IsometricCheckTests(unittest.TestCase):
    def iso_kinds(self, spec: dict, evidence: dict) -> set[str]:
        return {f["kind"] for f in check_figure(spec, evidence) if f["where"].startswith("iso")}

    def test_chip_over_a_layer_label_is_reported(self) -> None:
        spec, evidence = example()
        next(a for a in spec["iso"]["arrows"] if a.get("label"))["at"] = list(spec["iso"]["layers"][0]["label_at"])
        self.assertIn("label_overlap", self.iso_kinds(spec, evidence))

    def test_label_outside_the_canvas_is_reported(self) -> None:
        spec, evidence = example()
        spec["iso"]["layers"][2]["label_at"] = [1500, 860]
        self.assertIn("out_of_canvas", self.iso_kinds(spec, evidence))

    def test_crossing_arrows_are_reported(self) -> None:
        spec, evidence = example()
        # Screen points; edge:e_block runs from about (801, 503) down to (781, 649).
        spec["iso"]["arrows"].append({"id": "edge:e_net", "from": [700, 576], "to": [880, 576]})
        self.assertIn("edge_crossing", self.iso_kinds(spec, evidence))


class SpecValidationTests(unittest.TestCase):
    def test_unsafe_or_malformed_values_are_rejected(self) -> None:
        self.assertEqual(validate_spec(clean_spec()), [])
        cases = {
            "text coordinate": lambda s: s["nodes"][0].update(x='0" onload="alert(1)'),
            "quoted id": lambda s: s["nodes"][0].update(id='node:runtime" onload="alert(1)'),
            "unknown role": lambda s: s["zones"][0].update(role="neon"),
            "unknown shape": lambda s: s["nodes"][0].update(shape="</script>"),
            "label without a position": lambda s: s["edges"][0].pop("at"),
            "text iso height": lambda s: s.update(iso={"layers": [{"id": "boundary:host", "role": "compute",
                                                                   "box": [0, 1, 0, 1], "z": "0", "title": "host"}]}),
        }
        for name, change in cases.items():
            spec = clean_spec()
            change(spec)
            with self.subTest(case=name):
                self.assertNotEqual(validate_spec(spec), [])

    def test_key_must_cover_every_role_shape_and_line_style_in_use(self) -> None:
        for change in (
            lambda s: s["key"]["roles"].remove("execution"),
            lambda s: s["nodes"][0].update(shape="cylinder"),
            lambda s: s["edges"][0].update(dash=True),
        ):
            spec = clean_spec()
            change(spec)
            with self.subTest(change=change):
                self.assertIn("key_incomplete", kinds(spec))

    def test_text_must_stay_readable_at_a_700_px_column(self) -> None:
        spec = clean_spec()
        spec["canvas"]["width"] = 1600
        self.assertIn("text_too_small", kinds(spec))

    def test_text_wider_than_its_node_is_reported(self) -> None:
        spec = clean_spec()
        spec["nodes"][2]["title"] = "boxlite-guest gRPC server and agent"
        self.assertIn("text_overflow", kinds(spec))

    def test_low_contrast_colour_is_reported(self) -> None:
        with unittest.mock.patch.dict(ROLE_HUES, {"compute": "#1a1a1a"}):
            self.assertIn("contrast", kinds(clean_spec()))

    def test_alt_text_and_version_are_required(self) -> None:
        for field in ("alt", "version"):
            spec = clean_spec()
            del spec[field]
            with self.subTest(field=field):
                self.assertIn(f"missing_{field}", kinds(spec))


class FigureRenderTests(unittest.TestCase):
    def test_every_flat_preset_draws_each_node_and_the_key(self) -> None:
        spec = clean_spec()
        for preset in sorted(set(PRESETS) - {"isometric"}):
            with self.subTest(preset=preset):
                page = render(spec, preset)
                for node in spec["nodes"]:
                    self.assertIn(node["title"], page)
                for role in spec["key"]["roles"]:
                    self.assertIn(ROLE_HUES[role].lower(), page.lower())

    def test_walls_numbers_each_wall(self) -> None:
        spec = clean_spec()
        spec["zones"][1]["wall"] = 2
        self.assertIn('data-wall="2"', render(spec, "walls"))

    def test_isometric_needs_layer_geometry(self) -> None:
        with self.assertRaisesRegex(ValueError, "iso"):
            render(clean_spec(), "isometric")

    def test_isometric_paints_layers_bottom_to_top(self) -> None:
        spec = clean_spec() | {"iso": {"layers": [
            {"id": "boundary:shim", "role": "execution", "box": [0, 600, 0, 600], "z": 200, "title": "shim"},
            {"id": "boundary:host", "role": "compute", "box": [0, 1000, 0, 800], "z": 0, "title": "host"},
        ]}}
        page = render(spec, "isometric")
        self.assertLess(page.index('data-id="boundary:host"'), page.index('data-id="boundary:shim"'))

    def test_figure_2_renders_in_every_preset(self) -> None:
        spec, _ = example()
        for preset in PRESETS:
            with self.subTest(preset=preset):
                self.assertIn("VMM · libkrun", render(spec, preset))

    def test_spec_values_cannot_break_out_of_markup(self) -> None:
        spec = clean_spec()
        spec["nodes"][0]["id"] = 'node:a"><script>alert(1)</script>'
        spec["nodes"][1]["shape"] = "</script><script>alert(2)</script>"
        svg = render_svg(spec, "blueprint")
        self.assertNotIn("<script", svg)
        self.assertIn('data-id="node:a&quot;&gt;&lt;script&gt;', svg)
        self.assertEqual(render(spec, "whiteboard").count("</script>"), 2)  # rough.js and the drawing script

    def test_whiteboard_refuses_a_modified_rough_js(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tampered = Path(tmp) / ROUGH.name
            tampered.write_bytes(ROUGH.read_bytes() + b"\n")
            with unittest.mock.patch("figure.render.ROUGH", tampered):
                with self.assertRaisesRegex(ValueError, "roughjs 4.6.6"):
                    render(clean_spec(), "whiteboard")


def _lin(channel: int) -> float:
    c = channel / 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _rgb(hex_color: str) -> list[float]:
    return [_lin(int(hex_color[i:i + 2], 16)) for i in (1, 3, 5)]


# Machado, Oliveira and Fernandes 2009 at severity 1.0, applied to linear sRGB.
MACHADO = {
    "protan": [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
    "deutan": [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
}


def _oklab(rgb: list[float]) -> tuple[float, float, float]:
    r, g, b = rgb
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def _delta_e(a: str, b: str, kind: str | None = None) -> float:
    def view(hex_color: str) -> list[float]:
        rgb = _rgb(hex_color)
        if kind is None:
            return rgb
        return [max(0.0, min(1.0, sum(row[i] * rgb[i] for i in range(3)))) for row in MACHADO[kind]]
    return 100 * math.dist(_oklab(view(a)), _oklab(view(b)))


def _contrast(a: str, b: str) -> float:
    def luminance(hex_color: str) -> float:
        return sum(w * c for w, c in zip((0.2126, 0.7152, 0.0722), _rgb(hex_color)))
    hi, lo = sorted((luminance(a), luminance(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


class PaletteGateTests(unittest.TestCase):
    def test_role_hues_stay_distinct_for_colour_blind_and_normal_vision(self) -> None:
        hues = [ROLE_HUES[r] for r in ("compute", "execution", "state", "observability")] + [SUBJECT]
        for i, a in enumerate(hues):
            for b in hues[i + 1:]:
                with self.subTest(pair=(a, b)):
                    self.assertGreaterEqual(_delta_e(a, b), 15)
                    self.assertGreaterEqual(min(_delta_e(a, b, "protan"), _delta_e(a, b, "deutan")), 8)

    def test_every_preset_meets_text_and_line_contrast(self) -> None:
        for name, preset in PRESETS.items():
            for token, floor in (("ink", 4.5), ("muted", 4.5), ("label", 4.5), ("edge", 3.0)):
                with self.subTest(preset=name, token=token):
                    self.assertGreaterEqual(_contrast(preset[token], preset["bg"]), floor)


class FigureCliTests(unittest.TestCase):
    def _run(self, script: str, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(SKILL_ROOT / "scripts" / script), *args],
                              capture_output=True, text=True, check=False)

    def test_check_cli_exits_one_on_findings_and_zero_when_clean(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "evidence.json").write_text(json.dumps(manifest()), encoding="utf-8")
            dirty = clean_spec()
            dirty["edges"][0]["points"] = [[150, 330], [150, 640]]
            for name, spec, code in (("clean", clean_spec(), 0), ("dirty", dirty, 1)):
                path = root / f"{name}.json"
                path.write_text(json.dumps(spec), encoding="utf-8")
                result = self._run("check_figure.py", "--spec", str(path), "--evidence", str(root / "evidence.json"))
                with self.subTest(spec=name):
                    self.assertEqual(result.returncode, code, result.stdout + result.stderr)

    def test_render_cli_writes_a_light_and_dark_pair_with_alt_text(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            spec = root / "figure.json"
            spec.write_text(json.dumps(clean_spec()), encoding="utf-8")
            result = self._run("render_figure.py", "--spec", str(spec), "--out", str(root / "out"), "--pair")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            picture = (root / "out" / "figure.picture.html").read_text(encoding="utf-8")
            self.assertIn("prefers-color-scheme: dark", picture)
            self.assertIn(clean_spec()["alt"], picture)
            for variant in ("figure.light.svg", "figure.dark.svg"):
                self.assertTrue((root / "out" / variant).is_file(), variant)

    def test_render_cli_refuses_an_unusable_spec(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            spec = clean_spec()
            spec["nodes"][0]["x"] = '0" onload="alert(1)'
            (root / "figure.json").write_text(json.dumps(spec), encoding="utf-8")
            result = self._run("render_figure.py", "--spec", str(root / "figure.json"), "--out", str(root / "out"), "--pair")
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertFalse((root / "out").exists())


if __name__ == "__main__":
    unittest.main()
