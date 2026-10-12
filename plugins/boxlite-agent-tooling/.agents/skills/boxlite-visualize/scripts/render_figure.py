#!/usr/bin/env python3
"""Render a figure spec in one preset, or as a light/dark pair with a <picture> snippet; optionally to PNG."""
from __future__ import annotations

import argparse
import html
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from figure.check import validate_spec  # noqa: E402
from figure.render import render, render_svg  # noqa: E402
from figure.style import PRESETS  # noqa: E402

BROWSERS = ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "google-chrome", "chromium", "chromium-browser")


def _browser() -> str | None:
    candidates = [os.environ.get("BOXLITE_FIGURE_CHROME", "")] + list(BROWSERS)
    return next((found for c in candidates if c and (found := shutil.which(c) or (c if Path(c).is_file() else None))), None)


def _png(page: Path, spec: dict, browser: str) -> Path:
    target = page.with_suffix(".png")
    width, height = spec["canvas"]["width"], spec["canvas"]["height"]
    subprocess.run([browser, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2",
                    f"--window-size={width},{height}", "--virtual-time-budget=15000",
                    f"--screenshot={target}", page.resolve().as_uri()],
                   check=True, capture_output=True, timeout=120)
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, type=Path, help="figure.json")
    parser.add_argument("--out", required=True, type=Path, help="output directory")
    parser.add_argument("--preset", default="blueprint", choices=sorted(PRESETS))
    parser.add_argument("--pair", action="store_true", help="write editorial (light) and blueprint (dark) SVGs plus <picture>")
    parser.add_argument("--png", action="store_true", help="also screenshot each page at 2x with Chrome")
    args = parser.parse_args()
    try:
        spec = json.loads(args.spec.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"render_figure: cannot read {args.spec}: {error}", file=sys.stderr)
        return 2
    if problems := validate_spec(spec):
        print("render_figure: unusable spec: " + "; ".join(problems), file=sys.stderr)
        return 2
    args.out.mkdir(parents=True, exist_ok=True)
    stem, pages = args.spec.stem, []
    if args.pair:
        for variant, preset in (("light", "editorial"), ("dark", "blueprint")):
            (args.out / f"{stem}.{variant}.svg").write_text(render_svg(spec, preset), encoding="utf-8")
            pages.append(args.out / f"{stem}.{variant}.html")
            pages[-1].write_text(render(spec, preset), encoding="utf-8")
        ext = "png" if args.png else "svg"  # PNGs carry the web fonts; SVGs fall back to system fonts
        (args.out / f"{stem}.picture.html").write_text(
            f'<picture>\n  <source srcset="{stem}.dark.{ext}" media="(prefers-color-scheme: dark)">\n'
            f'  <img src="{stem}.light.{ext}" alt="{html.escape(spec.get("alt", ""))}">\n</picture>\n', encoding="utf-8")
    else:
        pages.append(args.out / f"{stem}.{args.preset}.html")
        pages[0].write_text(render(spec, args.preset), encoding="utf-8")
        if args.preset != "whiteboard":
            (args.out / f"{stem}.{args.preset}.svg").write_text(render_svg(spec, args.preset), encoding="utf-8")
    if args.spec.resolve().parent != args.out.resolve():
        shutil.copyfile(args.spec, args.out / args.spec.name)  # editable source beside the image
    if args.png:
        browser = _browser()
        if browser is None:
            print("render_figure: no Chrome found; set BOXLITE_FIGURE_CHROME", file=sys.stderr)
            return 2
        for page in pages:
            print(_png(page, spec, browser))
    return 0


if __name__ == "__main__":
    sys.exit(main())
