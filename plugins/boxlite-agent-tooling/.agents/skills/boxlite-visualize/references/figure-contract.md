# Figure contract

For figures read outside the repository: blog posts, slides, social cards. Repository
docs keep live Mermaid under the [output contract](output-contract.md); a figure draws the
same validated facts by hand, so nothing collides and the brand fits.

## Workflow

1. Validate `diagram.md` and `evidence.json` first. The figure may draw only those IDs.
2. Write `figure.json` beside them and place every element by hand.
3. Check, then render:

```bash
python3 .agents/skills/boxlite-visualize/scripts/check_figure.py \
  --spec "$TASK_DIR/figure.json" --evidence "$TASK_DIR/evidence.json"
python3 .agents/skills/boxlite-visualize/scripts/render_figure.py \
  --spec "$TASK_DIR/figure.json" --out "$TASK_DIR/figure" --pair --png
```

`check_figure.py` exits `0` clean, `1` with findings, `2` on unusable input.
`render_figure.py --pair` writes the light (`editorial`) and dark (`blueprint`) images and a
`<picture>` snippet with the alt text; `--preset <name>` renders one preset. Both scripts
exit `2` before drawing when a number, ID, role, shape or label has the wrong type.
`figure.json` is copied beside the output as the editable source.

`--png` needs Chrome (`BOXLITE_FIGURE_CHROME` overrides the path) and network access:
pages load Inter, IBM Plex Mono and Kalam from Google Fonts. Offline, Chrome substitutes
system fonts whose widths differ from the checker's text metrics. Checking needs no network.

[`examples/figure-2/`](examples/figure-2/) holds a complete set: `diagram.md` and
`evidence.json` validated at boxlite `5b3321c`, and the `figure.json` the tests check in
every preset.

4. Open every PNG and run the visual QA below.

## Spec

```json
{
  "canvas": {"width": 1200, "height": 900},
  "title": "Figure 2 · Inside one machine",
  "alt": "BoxliteRuntime spawns a jailed shim whose VMM runs the guest.",
  "version": "boxlite 5b3321c",
  "zones": [{"id": "boundary:shim", "role": "execution", "x": 60, "y": 390, "w": 720, "h": 430,
             "title": "boxlite-shim", "sub": "jailed", "caption": "bwrap + seccomp on Linux"}],
  "nodes": [{"id": "node:vmm", "role": "subject", "shape": "box", "x": 440, "y": 470, "w": 300,
             "h": 110, "title": "VMM", "sub": ["libkrun"], "accent": true, "tag": "→ our own VMM"}],
  "edges": [{"id": "edge:spawn", "points": [[600, 256], [600, 470]], "label": ["spawns shim"],
             "at": [600, 350]}],
  "key": {"x": 820, "y": 700, "roles": ["execution", "subject"], "shapes": [], "lines": []}
}
```

- **IDs** are `boundary:`, `node:` or `edge:` plus the `evidence.json` ID.
- **Roles** are `external`, `edge`, `compute`, `execution`, `state`, `observability`, `subject`.
- **Shapes** are `box`, `pill` (actor) and `cylinder` (stored state).
- **Optional fields:** `wall: <n>` numbers a boundary in `walls`; `dash` marks a virtual
  channel or soft boundary; `mono` sets a code identifier in monospace.
- **`iso`** holds `view`, `layers`, `blocks`, `cylinders`, `pills` and `arrows` in world
  units for `isometric`.

## Presets

| Preset | Look | Use |
| --- | --- | --- |
| `blueprint` (default) | black grid, dark role-coloured cards, cyan subject | dark pages; matches the BoxLite cover |
| `editorial` | off-white, white cards, tinted zones | light pages, docs, print |
| `whiteboard` | hand-drawn, vendored rough.js 4.6.6 (MIT), pinned by SHA-256 to the npm release | informal explainers |
| `walls` | navy, numbered nested boundaries | isolation and defence-in-depth stories |
| `isometric` | floating layers with upright labels | hero images; needs `iso` geometry |

## Checked rules

`check_figure.py` fails a figure that breaks any of these:

- `alt` text and a `version` naming the source revision;
- no edge crossing another edge, a node or a zone title ([Purchase 1997](https://eprints.gla.ac.uk/35804):
  crossings matter most);
- no overlapping labels, and everything on the canvas;
- a key entry for every role, non-box shape and dashed line in use ([C4](https://c4model.com/diagrams/notation));
- text at least 12 px when the figure shows 700 px wide ([AWS conventions](https://aws.github.io/aws-networking-best-practices/community/conventions/)),
  so a 1200 px canvas uses the 21 px floor;
- text inside its box, and cyan on at most two elements per view, counting `accent` and
  role `subject`;
- in `iso`, projected solids, arrows and labels on the canvas, labels apart, and arrows
  that cross only where they meet.

The tests also hold every preset to 4.5:1 for text and 3:1 for lines, and keep the role
hues distinct for colour-blind and normal vision.

## Composition

- **One message per figure.** Title it with its type and scope.
- **Group with whitespace first.** Box only real boundaries, because an enclosure overrides
  proximity ([NN/g](https://www.nngroup.com/articles/common-region/)).
- **Edges:** right-angled with rounded bends, one-way from initiator to dependency, each
  labelled with intent and protocol.
- **Shapes:** pill actors, rounded services (radius 8), cylinder state, zones with radius 16
  ([IBM](https://www.ibm.com/design/language/infographics/technical-diagrams/design/)).
- **Capitals:** uppercase monospace zone titles only in the dark presets, a deliberate brand
  deviation; use sentence case elsewhere.
- **Light and dark:** publish both through `<picture>`
  ([web.dev](https://web.dev/articles/prefers-color-scheme)).

## Visual QA

Open each PNG at the width readers will see:

1. the message reads in seconds;
2. labels are unclipped and legible at 700 px;
3. each boundary truthfully surrounds its members;
4. cyan marks only the subject;
5. no empty region or long return edge distorts the layout.
