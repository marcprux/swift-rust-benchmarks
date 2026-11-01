#!/usr/bin/env python3
"""Render the JSON files the harness writes into one HTML report of Vega-Lite charts.

    ./tools/report.py                              # results/*.json -> results/report.html
    ./tools/report.py --open                       # ... and open it in the default browser
    ./tools/report.py results other-results --site site
                                                   # merged page plus the raw JSON, for GitHub Pages

The harness writes one JSON file per benchmark and machine. This script reads every
file in the directories it is given, groups them by machine, and emits a single page.
Each chart is a Vega-Lite specification embedded in the page and drawn by vega-embed
when the page is opened, so this script only shapes data; it never draws. Colors and
fonts are read from the page's CSS at render time, which is how the charts follow
light and dark mode. Python 3 standard library only.
"""

import argparse
import datetime as dt
import json
import math
import os
import shutil
import webbrowser
from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

VEGA = "https://cdn.jsdelivr.net/npm/vega@6.4.0"
VEGA_LITE = "https://cdn.jsdelivr.net/npm/vega-lite@6.5.0"
VEGA_EMBED = "https://cdn.jsdelivr.net/npm/vega-embed@7.3.0"
VL_SCHEMA = "https://vega.github.io/schema/vega-lite/v6.json"

SWIFT, RUST = "swift", "rust"
LANG_LABEL = {SWIFT: "Swift", RUST: "Rust"}
SYSTEM_LABEL = {"Darwin": "macOS", "Linux": "Linux", "Windows": "Windows"}

# Short explanations shown under "Reading the results". Numbers are filled in
# from the selected machine's medians so the text never disagrees with the charts.
NOTES = {
    "sensor-rollup": (
        "Telemetry readings in arrays of plain structs, with no heap objects or strings "
        "in the loop. The two finish within {wall_pct} of each other and Swift generates "
        "the data faster ({generate}). Read the other five against this one: the gaps "
        "elsewhere come from reference types, not from code generation."
    ),
    "document-tree": (
        "A 500k-node document is built, serialized, parsed back, queried and mutated. "
        "Swift nodes are classes under ARC; Rust nodes are owned enums. Building is close "
        "({build}); every later phase that walks node pointers runs {parse} to {query} "
        "slower. Memory is {rss}."
    ),
    "order-graph": (
        "Orders share customers and products. Reading through a shared reference is cheap "
        "(reprice {reprice}); storing four million references and releasing them again is "
        "not (build {build}, free {free}). Memory is {rss} because a Swift reference is "
        "twice the width of a Rust index and each entity is its own heap object."
    ),
    "log-analytics": (
        "Half a million log lines are generated, parsed into owned records and aggregated "
        "by service. Parsing is the gap ({parse}): Swift's String.Index arithmetic and "
        "substring search on UTF-8 views cost more than Rust's byte slices, and each record "
        "adds retain and release traffic. Both keep the same records, so memory matches "
        "({rss})."
    ),
    "request-churn": (
        "A million HTTP requests served from a pool of ten thousand. Both footprints stay "
        "flat across the run, so per-request state dies with the request in both languages. "
        "Swift serves {serve} slower with no single hot spot: string building, malloc and "
        "retain/release each take a share."
    ),
    "parallel-ledger": (
        "Transactions point at shared, read-only account records, aggregated on one thread "
        "and then on {threads}. Rust scales {rust_speedup}. Swift's for-in loop retains and "
        "releases each account on every read, and those atomic writes bounce cache lines "
        "between cores, so it gains {swift_speedup}; an indexed loop avoids the retain and "
        "reaches {swift_speedup_indexed}."
    ),
}

# Benchmarks appear in this order everywhere: the control first, then by the
# memory-management pattern they add.
ORDER = ["sensor-rollup", "document-tree", "log-analytics", "order-graph", "request-churn",
         "parallel-ledger"]


# ---------------------------------------------------------------------------------
# data


def load(dirs):
    runs = {}
    for d in dirs:
        for f in sorted(Path(d).glob("*.json")):
            try:
                data = json.loads(f.read_text(encoding="utf-8"))
            except ValueError:
                continue
            if "medians" not in data or "platform" not in data:
                continue
            data["_file"] = f
            runs.setdefault(machine_slug(data), {})[data["benchmark"]] = data
    return runs


def machine_slug(data):
    p = data["platform"]
    return f"{p['system'].lower()}-{p['machine'].lower()}"


def platform_title(data):
    p = data["platform"]
    return f"{p['cpu']} · {SYSTEM_LABEL.get(p['system'], p['system'])}"


def ordered(bench):
    return [n for n in ORDER if n in bench] + sorted(n for n in bench if n not in ORDER)


def phases(medians):
    return [k for k in medians[SWIFT] if k.endswith("_ms") and k not in ("total_ms", "wall_ms")]


def phase_label(key):
    return key[:-3].replace("_", " ")


def ratio(m, key):
    r = m[RUST].get(key, 0)
    s = m[SWIFT].get(key, 0)
    return s / r if r and r >= 0.1 else None


def fmt_ratio(x):
    return "n/a" if x is None else f"{x:.1f}x" if x >= 1.05 or x < 0.95 else f"{x:.2f}x"


def fmt_ms(x):
    if x >= 1000:
        return f"{x / 1000:.2f}".rstrip("0").rstrip(".") + " s"
    return f"{x:,.0f} ms" if x >= 10 else f"{x:.1f} ms"


def fmt_mb(b):
    return f"{b / 1_048_576:,.0f} MB"


def log_ticks(lo, hi):
    """1-2-5 ticks covering [lo, hi] on a log axis, thinned to at most seven."""
    ticks = []
    k = math.floor(math.log10(lo)) if lo > 0 else 0
    while 10 ** k <= hi:
        for m in (1, 2, 5):
            v = m * 10 ** k
            if lo <= v <= hi:
                ticks.append(v)
        k += 1
    for keep in ((1, 2, 5), (1, 5), (1,)):
        thinned = [t for t in ticks if int(str(f"{t:e}")[0]) in keep]
        if len(thinned) <= 7:
            return thinned
    return thinned


# ---------------------------------------------------------------------------------
# vega-lite specs
#
# Every spec sizes to its container and reads nothing but data; colors, fonts and
# axis styling come from the config the page builds from its CSS variables, so the
# same spec renders in both themes.

MS_LABELS = ("datum.value >= 1000 ? format(datum.value / 1000, '~g') + ' s'"
             " : format(datum.value, '~g') + ' ms'")
MB_LABELS = "format(datum.value, '~g') + ' MB'"
RATIO_LABELS = "format(datum.value, '~g') + 'x'"

LANG_COLOR = {"field": "language", "type": "nominal",
              "scale": {"domain": ["Swift", "Rust"]}, "legend": None}


def log_x(values, lo, hi, labels, title=None):
    return {"field": "value", "type": "quantitative", "title": title,
            "scale": {"type": "log", "domain": [lo, hi], "nice": False},
            "axis": {"values": values, "labelExpr": labels}}


def dumbbell_spec(bench, names, key, unit):
    """One row per benchmark: a mark per language at its median, ticks for the
    individual runs behind it, a connector whose length is the ratio, and the
    ratio printed at the right."""
    # Bytes are plotted in MB so the axis reads in the unit the labels use.
    fmt, scale = (fmt_ms, 1.0) if unit == "ms" else (fmt_mb, 1 / 1_048_576)
    rows = []
    for n in names:
        m = bench[n]["medians"]
        for lang in (SWIFT, RUST):
            v = m[lang][key]
            rows.append({"benchmark": n, "language": LANG_LABEL[lang], "value": v * scale,
                         "label": fmt(v), "kind": "median"})
            for i, run in enumerate(bench[n]["results"][lang], 1):
                rows.append({"benchmark": n, "language": LANG_LABEL[lang], "value": run[key] * scale,
                             "label": f"run {i}: {fmt(run[key])}", "kind": "run"})
        rows.append({"benchmark": n, "value": max(m[SWIFT][key], m[RUST][key]) * scale,
                     "text": fmt_ratio(ratio(m, key)), "kind": "label"})
    values = [r["value"] for r in rows if r["kind"] != "label"]
    lo, hi = min(values) / 1.4, max(values) * 1.25
    labels = MS_LABELS if unit == "ms" else MB_LABELS
    tooltip = [{"field": "benchmark", "title": "benchmark"}, {"field": "language", "title": "language"},
               {"field": "label", "title": "value"}]
    return {
        "$schema": VL_SCHEMA, "width": "container", "height": {"step": 36},
        "padding": {"left": 4, "top": 6, "right": 54, "bottom": 4},
        "data": {"values": rows},
        "encoding": {"y": {"field": "benchmark", "type": "nominal", "sort": names, "title": None,
                           "axis": {"labelFontSize": 13}}},
        "layer": [
            {"transform": [{"filter": "datum.kind == 'median'"}],
             "mark": {"type": "rule", "strokeWidth": 2},
             "encoding": {"x": {"field": "value", "aggregate": "min", "type": "quantitative"},
                          "x2": {"field": "value", "aggregate": "max"}}},
            {"transform": [{"filter": "datum.kind == 'run'"}],
             "mark": {"type": "tick", "thickness": 1.5, "size": 18, "opacity": 0.45},
             "encoding": {"x": log_x(log_ticks(lo, hi), lo, hi, labels), "color": LANG_COLOR,
                          "tooltip": tooltip}},
            {"transform": [{"filter": "datum.kind == 'median'"}],
             "mark": {"type": "point", "filled": True, "size": 130},
             "encoding": {"x": {"field": "value", "type": "quantitative"}, "color": LANG_COLOR,
                          "tooltip": tooltip}},
            {"transform": [{"filter": "datum.kind == 'label'"}],
             "mark": {"type": "text", "align": "left", "dx": 14, "fontWeight": 600, "fontSize": 13},
             "encoding": {"x": {"field": "value", "type": "quantitative"}, "text": {"field": "text"}}},
        ],
    }


def phase_spec(data):
    """Grouped horizontal bars, Swift above Rust, for each phase the program reports,
    with the per-phase ratio printed at the right."""
    m = data["medians"]
    keys = phases(m)
    order = [phase_label(k) for k in keys]
    rows = []
    for k in keys:
        for lang in (SWIFT, RUST):
            rows.append({"phase": phase_label(k), "language": LANG_LABEL[lang], "value": m[lang][k],
                         "label": fmt_ms(m[lang][k]), "kind": "bar"})
        rows.append({"phase": phase_label(k), "value": max(m[SWIFT][k], m[RUST][k]),
                     "text": fmt_ratio(ratio(m, k)), "kind": "label"})
    return {
        # A fixed height per phase: a step height would be doubled by the offset bars.
        "$schema": VL_SCHEMA, "width": "container", "height": 30 * len(keys),
        "padding": {"left": 4, "top": 4, "right": 46, "bottom": 4},
        "data": {"values": rows},
        "encoding": {"y": {"field": "phase", "type": "nominal", "sort": order, "title": None,
                           "scale": {"paddingInner": 0.3, "paddingOuter": 0.15}}},
        "layer": [
            {"transform": [{"filter": "datum.kind == 'bar'"}],
             "mark": {"type": "bar", "cornerRadiusEnd": 3},
             "encoding": {
                 "x": {"field": "value", "type": "quantitative", "title": None,
                       "axis": {"labelExpr": MS_LABELS, "tickCount": 4}},
                 "yOffset": {"field": "language", "sort": ["Swift", "Rust"], "scale": {"paddingInner": 0.15}},
                 "color": LANG_COLOR,
                 "tooltip": [{"field": "phase", "title": "phase"}, {"field": "language", "title": "language"},
                             {"field": "label", "title": "median"}]}},
            {"transform": [{"filter": "datum.kind == 'label'"}],
             "mark": {"type": "text", "align": "left", "dx": 8, "fontSize": 12},
             "encoding": {"x": {"field": "value", "type": "quantitative"}, "text": {"field": "text"}}},
        ],
    }


def scaling_spec(data):
    """parallel-ledger: for each language and loop phrasing, the single-thread time
    (hollow) and the per-pass time on all threads (filled), joined by a connector,
    with the speedup printed at the right."""
    m = data["medians"]
    passes = max(int(data["knobs"].get("passes", 1)), 1)
    threads = int(m[RUST].get("threads", 0))
    rows = []
    order = []
    for lang in (SWIFT, RUST):
        for phrasing, serial, parallel, speedup in (
                ("for-in", "serial_ms", "parallel_ms", "speedup"),
                ("indexed", "serial_indexed_ms", "parallel_indexed_ms", "speedup_indexed")):
            if serial not in m[lang]:
                continue
            row = f"{LANG_LABEL[lang]} {phrasing}"
            order.append(row)
            one, many = m[lang][serial], m[lang][parallel] / passes
            rows.append({"row": row, "language": LANG_LABEL[lang], "value": one, "which": "one",
                         "label": f"one thread: {fmt_ms(one)}"})
            rows.append({"row": row, "language": LANG_LABEL[lang], "value": many, "which": "many",
                         "label": f"{threads} threads: {fmt_ms(many)} per pass"})
            rows.append({"row": row, "value": max(one, many), "which": "label",
                         "text": fmt_ratio(m[lang].get(speedup))})
    values = [r["value"] for r in rows if r["which"] != "label"]
    lo, hi = min(values) / 1.4, max(values) * 1.25
    tooltip = [{"field": "row", "title": "variant"}, {"field": "label", "title": "time"}]
    return {
        "$schema": VL_SCHEMA, "width": "container", "height": {"step": 36},
        "padding": {"left": 4, "top": 6, "right": 54, "bottom": 4},
        "data": {"values": rows},
        "encoding": {"y": {"field": "row", "type": "nominal", "sort": order, "title": None,
                           "axis": {"labelFontSize": 13}}},
        "layer": [
            {"transform": [{"filter": "datum.which != 'label'"}],
             "mark": {"type": "rule", "strokeWidth": 2},
             "encoding": {"x": {"field": "value", "aggregate": "min", "type": "quantitative"},
                          "x2": {"field": "value", "aggregate": "max"}}},
            {"transform": [{"filter": "datum.which == 'one'"}],
             "mark": {"type": "point", "filled": False, "strokeWidth": 2.5, "size": 120},
             "encoding": {"x": log_x(log_ticks(lo, hi), lo, hi, MS_LABELS), "color": LANG_COLOR,
                          "tooltip": tooltip}},
            {"transform": [{"filter": "datum.which == 'many'"}],
             "mark": {"type": "point", "filled": True, "size": 130},
             "encoding": {"x": {"field": "value", "type": "quantitative"}, "color": LANG_COLOR,
                          "tooltip": tooltip}},
            {"transform": [{"filter": "datum.which == 'label'"}],
             "mark": {"type": "text", "align": "left", "dx": 14, "fontWeight": 600, "fontSize": 13},
             "encoding": {"x": {"field": "value", "type": "quantitative"}, "text": {"field": "text"}}},
        ],
    }, threads


MACHINE_SHAPES = ["circle", "square", "diamond", "triangle-up", "cross"]


def machines_spec(runs, slugs, names, key):
    """Swift-over-Rust ratio per benchmark, one shape per machine, against a shaded
    band of ratios within 25% of parity."""
    rows = []
    for s in slugs:
        for n in names:
            r = ratio(runs[s][n]["medians"], key)
            if r is not None:
                rows.append({"benchmark": n, "machine": platform_title(runs[s][n]), "value": r,
                             "label": fmt_ratio(r)})
    values = [r["value"] for r in rows] + [0.8, 1.25]
    lo, hi = min(values) / 1.25, max(values) * 1.25
    machines = [platform_title(next(iter(runs[s].values()))) for s in slugs]
    return {
        "$schema": VL_SCHEMA, "width": "container", "height": {"step": 36},
        "padding": {"left": 4, "top": 6, "right": 8, "bottom": 4},
        "encoding": {"y": {"field": "benchmark", "type": "nominal", "sort": names, "title": None,
                           "axis": {"labelFontSize": 13}}},
        "layer": [
            {"data": {"values": [{"lo": 0.8, "hi": 1.25}]},
             "mark": {"type": "rect"},
             "encoding": {"x": {"field": "lo", "type": "quantitative"}, "x2": {"field": "hi"},
                          "y": None}},
            {"data": {"values": [{"x": 1}]},
             "mark": {"type": "rule", "strokeWidth": 1.5},
             "encoding": {"x": {"field": "x", "type": "quantitative"}, "y": None}},
            {"data": {"values": rows},
             "mark": {"type": "point", "filled": True, "size": 110, "opacity": 0.9},
             "encoding": {
                 "x": log_x(log_ticks(lo, hi), lo, hi, RATIO_LABELS, "Swift / Rust"),
                 "shape": {"field": "machine", "type": "nominal", "legend": None,
                           "scale": {"domain": machines, "range": MACHINE_SHAPES[:len(machines)]}},
                 "tooltip": [{"field": "benchmark", "title": "benchmark"}, {"field": "machine", "title": "machine"},
                             {"field": "label", "title": "Swift / Rust"}]}},
        ],
    }


# ---------------------------------------------------------------------------------
# html pieces


class Page:
    """Collects the specs as the page is assembled; each chart in the HTML is a
    placeholder that names its spec."""

    def __init__(self):
        self.specs = {}

    def chart(self, spec, label):
        key = f"c{len(self.specs)}"
        self.specs[key] = spec
        return f'<div class="vis" data-spec="{key}" role="img" aria-label="{escape(label)}"></div>'


def markdown_table_to_html(md):
    lines = [l for l in md.splitlines() if l.startswith("|")]
    if len(lines) < 2:
        return ""
    cells = lambda l: [c.strip() for c in l.strip().strip("|").split("|")]
    head = cells(lines[0])
    rows = [cells(l) for l in lines[2:]]
    out = ["<table><thead><tr>"]
    out += [f"<th>{escape(c)}</th>" for c in head]
    out.append("</tr></thead><tbody>")
    for r in rows:
        out.append("<tr>" + "".join(f"<td>{escape(c)}</td>" for c in r) + "</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def stat_tile(label, value, note):
    return (f'<div class="tile"><div class="tile-label">{escape(label)}</div>'
            f'<div class="tile-value">{escape(value)}</div><div class="tile-note">{escape(note)}</div></div>')


def legend_languages(tool):
    return ('<div class="legend">'
            f'<span><i class="swatch swift"></i>Swift {escape(tool.get(SWIFT, ""))}</span>'
            f'<span><i class="swatch rust"></i>Rust {escape(tool.get(RUST, ""))}</span></div>')


SHAPE_SVG = {
    "circle": '<circle cx="7" cy="7" r="5"/>',
    "square": '<rect x="2.5" y="2.5" width="9" height="9"/>',
    "diamond": '<path d="M7 1.5 12.5 7 7 12.5 1.5 7Z"/>',
    "triangle-up": '<path d="M7 1.5 12.5 12 1.5 12Z"/>',
    "cross": '<path d="M5 1.5h4v3.5h3.5v4H9v3.5H5V9H1.5V5H5Z"/>',
}


def legend_marker(shape):
    return (f'<svg class="marker" width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">'
            f'{SHAPE_SVG[shape]}</svg>')


def note_values(name, data):
    m = data["medians"]
    vals = {k[:-3]: fmt_ratio(ratio(m, k)) for k in phases(m)}
    vals["rss"] = fmt_ratio(ratio(m, "peak_rss_bytes"))
    wall = ratio(m, "wall_ms") or 1
    vals["wall"] = fmt_ratio(wall)
    vals["wall_pct"] = f"{abs(wall - 1) * 100:.0f}%"
    if name == "parallel-ledger":
        vals["threads"] = f"{int(m[RUST].get('threads', 0))} threads"
        vals["rust_speedup"] = fmt_ratio(m[RUST].get("speedup"))
        vals["swift_speedup"] = fmt_ratio(m[SWIFT].get("speedup"))
        vals["swift_speedup_indexed"] = fmt_ratio(m[SWIFT].get("speedup_indexed"))
    return vals


def platform_section(page, slug, bench, first):
    names = ordered(bench)
    sample = bench[names[0]]
    tool = sample["toolchains"]
    runs_text = ", ".join(sorted({str(bench[n]["runs"]) for n in names}))
    p = sample["platform"]
    header = (f'<p class="machine-line"><strong>{escape(p["cpu"])}</strong> · '
              f'{escape(SYSTEM_LABEL.get(p["system"], p["system"]))} {escape(p["release"])} · '
              f'Swift {escape(tool[SWIFT])} · Rust {escape(tool[RUST])} · median of {escape(runs_text)} runs'
              + (" · GitHub Actions runner" if p.get("ci") else "") + "</p>")

    # Stat tiles.
    wall = {n: ratio(bench[n]["medians"], "wall_ms") for n in names}
    rss = {n: ratio(bench[n]["medians"], "peak_rss_bytes") for n in names}
    control = "sensor-rollup" if "sensor-rollup" in wall else None
    others = sorted(wall[n] for n in names if n != control and wall[n])
    median = others[len(others) // 2] if others else None
    measured = [n for n in names if wall[n]]
    tiles = []
    if control and wall[control]:
        tiles.append(stat_tile("Control benchmark", fmt_ratio(wall[control]), "sensor-rollup, value types only"))
    if median:
        tiles.append(stat_tile("Typical time gap", fmt_ratio(median), "median of the other benchmarks"))
    if measured:
        widest = max(measured, key=lambda n: wall[n])
        tiles.append(stat_tile("Widest time gap", fmt_ratio(wall[widest]), widest))
    rss_vals = [v for v in rss.values() if v]
    if rss_vals:
        tiles.append(stat_tile("Peak memory", f"{fmt_ratio(min(rss_vals))} to {fmt_ratio(max(rss_vals))}",
                               "Swift relative to Rust"))

    # Dumbbells, ordered by time ratio so the eye travels from parity to divergence.
    by_gap = sorted(names, key=lambda n: wall[n] or 0)
    time_chart = page.chart(dumbbell_spec(bench, by_gap, "wall_ms", "ms"),
                            "Wall time per benchmark, Swift and Rust, log scale")
    mem_chart = page.chart(dumbbell_spec(bench, by_gap, "peak_rss_bytes", "mb"),
                           "Peak resident memory per benchmark, Swift and Rust, log scale")

    panels = "".join(
        f'<figure class="panel"><figcaption><strong>{escape(n)}</strong>'
        f'<span>wall {fmt_ratio(wall[n])} · peak RSS {fmt_ratio(rss[n])}</span></figcaption>'
        f'{page.chart(phase_spec(bench[n]), f"Phase timings for {n}, Swift and Rust")}</figure>'
        for n in names)

    scaling = ""
    ledger = bench.get("parallel-ledger")
    if ledger and "parallel_ms" in ledger["medians"][SWIFT]:
        spec, threads = scaling_spec(ledger)
        scaling = f'''
<section>
  <h2>Parallel scaling</h2>
  <p class="lead">parallel-ledger aggregates ten million transactions that point at shared account records,
  first on one thread and then on {threads}. Hollow marks are the single-thread time, filled marks the
  per-pass time on all threads; the number at the right is the speedup.</p>
  <div class="legend"><span><i class="swatch swift"></i>Swift</span><span><i class="swatch rust"></i>Rust</span>
  <span><i class="swatch hollow"></i>one thread</span><span><i class="swatch filled"></i>{threads} threads</span></div>
  <figure class="panel wide">{page.chart(spec, "Single-thread and all-thread times for each language and loop phrasing")}</figure>
</section>'''

    notes = "".join(
        f'<div class="note"><h3>{escape(n)}</h3><p>{escape(NOTES[n].format(**note_values(n, bench[n])))}</p></div>'
        for n in names if n in NOTES)

    tables = "".join(
        f'<details><summary>{escape(n)}</summary><div class="scroll">{markdown_table_to_html(bench[n]["markdown"])}</div>'
        f'<p class="knobs">knobs: {escape(", ".join(f"{k}={v}" for k, v in bench[n]["knobs"].items()))}'
        f' · checksum {escape(str(bench[n]["checksum"]))}</p></details>'
        for n in names)

    hidden = "" if first else " hidden"
    return f'''
<div class="platform" data-platform="{escape(slug)}"{hidden}>
{header}
<div class="tiles">{"".join(tiles)}</div>

<section>
  <h2>Time and memory, side by side</h2>
  <p class="lead">Each row is one benchmark. The large marks are the median run of each language on a log axis,
  so the length of the connector is the ratio; the thin ticks behind them are the individual runs. Rows are
  ordered from closest to widest gap in time, and the memory chart keeps the same order.</p>
  {legend_languages(tool)}
  <div class="pair">
    <figure class="panel"><figcaption><strong>Wall time</strong><span>whole process, including startup</span></figcaption>{time_chart}</figure>
    <figure class="panel"><figcaption><strong>Peak memory</strong><span>resident set size reported by the OS</span></figcaption>{mem_chart}</figure>
  </div>
</section>

<section>
  <h2>Where the time goes</h2>
  <p class="lead">The same runs broken into the phases each program reports. Bars are to scale within a panel
  but not across panels; the number at the right of each row is Swift's time over Rust's.</p>
  {legend_languages(tool)}
  <div class="grid">{panels}</div>
</section>
{scaling}
<section>
  <h2>Reading the results</h2>
  <div class="notes">{notes}</div>
</section>

<section>
  <h2>Every number</h2>
  <p class="lead">The harness tables for this machine, one per benchmark.</p>
  <div class="tables">{tables}</div>
</section>
</div>'''


def machines_section(page, runs, slugs):
    if len(slugs) < 2:
        return ""
    names = [n for n in ORDER if all(n in runs[s] for s in slugs)]
    if not names:
        return ""
    legend = '<div class="legend">' + "".join(
        f'<span>{legend_marker(MACHINE_SHAPES[i % len(MACHINE_SHAPES)])}{escape(platform_title(runs[s][names[0]]))}</span>'
        for i, s in enumerate(slugs)) + "</div>"
    time_chart = page.chart(machines_spec(runs, slugs, names, "wall_ms"),
                            "Swift over Rust wall time ratio per benchmark and machine")
    mem_chart = page.chart(machines_spec(runs, slugs, names, "peak_rss_bytes"),
                           "Swift over Rust peak memory ratio per benchmark and machine")
    return f'''
<section class="machines">
  <h2>Across machines</h2>
  <p class="lead">The Swift-over-Rust ratio for each benchmark on every machine in the results. The shaded band
  marks ratios within 25% of parity. Absolute times differ a great deal between machines; the question here is
  whether the shape of the comparison holds.</p>
  {legend}
  <div class="pair">
    <figure class="panel"><figcaption><strong>Time ratio</strong><span>Swift wall time over Rust wall time</span></figcaption>{time_chart}</figure>
    <figure class="panel"><figcaption><strong>Memory ratio</strong><span>Swift peak RSS over Rust peak RSS</span></figcaption>{mem_chart}</figure>
  </div>
</section>'''


def provenance(runs, data_files):
    """The footer line about where the numbers came from: the commit and workflow run
    when rendered in GitHub Actions, the local results directory otherwise."""
    when = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    repo = os.environ.get("GITHUB_REPOSITORY")
    sha = os.environ.get("GITHUB_SHA", "")
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    run_id = os.environ.get("GITHUB_RUN_ID")
    parts = [f"Rendered {when}"]
    if repo and sha:
        parts.append(f'from commit <a href="{escape(server)}/{escape(repo)}/commit/{escape(sha)}"><code>{escape(sha[:7])}</code></a>')
    if repo and run_id:
        parts.append(f'by <a href="{escape(server)}/{escape(repo)}/actions/runs/{escape(run_id)}">this workflow run</a>')
    line = " ".join(parts) + "."
    if data_files:
        links = ", ".join(f'<a href="results/{escape(f.name)}"><code>{escape(f.name)}</code></a>' for f in data_files)
        line += f" Raw data: {links}."
    return line


def render(runs, fragment=False, data_files=()):
    page = Page()
    # macOS first when present (the reference machine), then the rest alphabetically.
    slugs = sorted(runs, key=lambda s: (0 if s.startswith("darwin") else 1, s))
    first_bench = runs[slugs[0]]
    any_data = next(iter(first_bench.values()))
    tool = any_data["toolchains"]
    count = len({n for s in slugs for n in runs[s]})

    switcher = ""
    if len(slugs) > 1:
        switcher = '<div class="switcher"><span class="label">Machine</span>' + "".join(
            f'<button type="button" data-platform="{escape(s)}" aria-pressed="{"true" if i == 0 else "false"}">'
            f'{escape(platform_title(next(iter(runs[s].values()))))}</button>' for i, s in enumerate(slugs)) + "</div>"

    sections = "".join(platform_section(page, s, runs[s], i == 0) for i, s in enumerate(slugs))
    machines = machines_section(page, runs, slugs)
    specs_json = json.dumps(page.specs, separators=(",", ":")).replace("</", "<\\/")
    body = f'''<main>
<header>
  <h1>Swift vs Rust</h1>
  <p class="subtitle">{count} paired workloads written the way a working engineer in each language would write them,
  run with identical inputs and checked for identical output. Both languages use only their standard library.</p>
  <p class="subtitle">Swift {escape(tool[SWIFT])} and Rust {escape(tool[RUST])} in release configuration. Every figure
  is the median of repeated runs; ratios are Swift over Rust, so 2x means Swift took twice as long or used twice the memory.</p>
  {switcher}
</header>
{sections}
{machines}
<footer>
  <p>{provenance(runs, data_files)}</p>
  <p>Generated by <code>tools/report.py</code> from the JSON files the harness writes to <code>results/</code>.
  Each benchmark directory in the repository has a README with the workload, its knobs and the measurements
  behind the explanations above.</p>
</footer>
</main>
<script type="application/json" id="specs">{specs_json}</script>
<script src="{VEGA}" crossorigin="anonymous"></script>
<script src="{VEGA_LITE}" crossorigin="anonymous"></script>
<script src="{VEGA_EMBED}" crossorigin="anonymous"></script>
<script>{JS}</script>'''

    head = f'<title>Swift vs Rust Benchmarks</title>\n<style>{CSS}</style>'
    if fragment:
        return head + "\n" + body
    return ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            f'{head}\n</head>\n<body>\n{body}\n</body>\n</html>\n')


CSS = """
/* Layout: a single reading column (max 1040px) of stacked sections; charts sit on
   hairline-bordered panels in pairs or a two-column grid, collapsing to one column
   on narrow screens. The chart script reads the color tokens below at render time. */
:root {
  --page: #f9f9f7; --surface: #fcfcfb; --ink: #0b0b0b; --ink-2: #52514e; --ink-3: #898781;
  --grid: #e1e0d9; --axis: #c3c2b7; --border: rgba(11,11,11,0.10); --band: rgba(11,11,11,0.045);
  --swift: #eb6834; --rust: #2a78d6; --accent: #1c5cab;
  --sans: system-ui, -apple-system, "Segoe UI", sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --page: #0d0d0d; --surface: #1a1a19; --ink: #f0efec; --ink-2: #c3c2b7; --ink-3: #898781;
    --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10); --band: rgba(255,255,255,0.06);
    --swift: #d95926; --rust: #3987e5; --accent: #6da7ec; color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --page: #0d0d0d; --surface: #1a1a19; --ink: #f0efec; --ink-2: #c3c2b7; --ink-3: #898781;
  --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10); --band: rgba(255,255,255,0.06);
  --swift: #d95926; --rust: #3987e5; --accent: #6da7ec; color-scheme: dark;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--page); color: var(--ink); font: 15px/1.5 var(--sans);
  padding-block: 32px 64px; padding-left: max(16px, env(safe-area-inset-left, 0px));
  padding-right: max(16px, env(safe-area-inset-right, 0px)); }
main { max-width: 1040px; margin: 0 auto; }
h1 { font-size: 34px; line-height: 1.15; margin: 0 0 8px; letter-spacing: -0.01em; text-wrap: balance; }
h2 { font-size: 21px; margin: 0 0 6px; letter-spacing: -0.005em; text-wrap: balance; }
h3 { font-size: 15px; margin: 0 0 4px; }
p { margin: 0; }
a { color: var(--accent); }
.subtitle { color: var(--ink-2); max-width: 64ch; font-size: 16px; }
.subtitle + .subtitle { margin-top: 6px; }
header { display: grid; gap: 4px; margin-bottom: 20px; }
section { margin-top: 44px; display: grid; gap: 12px; }
.lead { color: var(--ink-2); max-width: 70ch; }
.switcher { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 18px; }
.switcher .label { font-size: 12px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ink-3); margin-right: 4px; }
.switcher button { font: 600 13px/1 var(--sans); color: var(--ink-2); background: var(--surface);
  border: 1px solid var(--border); border-radius: 999px; padding: 8px 14px; cursor: pointer; }
.switcher button[aria-pressed="true"] { color: var(--page); background: var(--ink); border-color: var(--ink); }
.switcher button:focus-visible, summary:focus-visible, a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.machine-line { color: var(--ink-2); margin-top: 22px; font-size: 14px; }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 12px; margin-top: 14px; }
.tile { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px 12px; min-width: 0; }
.tile-label { font-size: 12px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ink-3); }
.tile-value { font-size: 32px; font-weight: 600; line-height: 1.15; margin-top: 6px; }
.tile-note { font-size: 13px; color: var(--ink-2); margin-top: 2px; }
.legend { display: flex; flex-wrap: wrap; gap: 6px 18px; font-size: 13px; color: var(--ink-2); align-items: center; }
.legend span { display: inline-flex; align-items: center; gap: 6px; }
.swatch { display: inline-block; width: 10px; height: 10px; border-radius: 50%; }
.swatch.swift { background: var(--swift); } .swatch.rust { background: var(--rust); }
.swatch.hollow { border: 2.5px solid var(--ink-2); width: 11px; height: 11px; }
.swatch.filled { background: var(--ink-2); }
.marker { fill: var(--ink-2); }
.pair { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 14px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 14px; }
.panel { margin: 0; background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px 10px; min-width: 0; }
.panel.wide { max-width: 720px; }
figcaption { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 4px 12px; font-size: 13px; color: var(--ink-2); margin-bottom: 8px; }
figcaption strong { color: var(--ink); font-size: 14px; }
.vis { width: 100%; min-height: 120px; }
.vis svg { display: block; max-width: 100%; }
.vis text { font-variant-numeric: tabular-nums; }
.vis .unavailable { color: var(--ink-3); font-size: 13px; padding: 24px 0; }
.notes { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 16px 28px; }
.note p { color: var(--ink-2); font-size: 14.5px; max-width: 60ch; }
.tables { display: grid; gap: 8px; }
details { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 0 16px; }
summary { cursor: pointer; padding: 12px 0; font-weight: 600; }
details[open] summary { border-bottom: 1px solid var(--border); }
.scroll { overflow-x: auto; padding: 12px 0 4px; }
table { border-collapse: collapse; font-size: 13px; font-variant-numeric: tabular-nums; white-space: nowrap; }
th, td { text-align: right; padding: 6px 10px; border-bottom: 1px solid var(--grid); }
th:first-child, td:first-child { text-align: left; }
th { color: var(--ink-3); font-weight: 600; font-size: 12px; }
tbody tr:last-child td { font-weight: 600; border-bottom: 0; }
.knobs { font: 12px/1.5 var(--mono); color: var(--ink-3); padding: 8px 0 12px; overflow-wrap: anywhere; }
footer { margin-top: 56px; color: var(--ink-3); font-size: 13px; max-width: 70ch; display: grid; gap: 8px; }
footer code { font-family: var(--mono); font-size: 12px; }
#vg-tooltip-element.vg-tooltip.report-theme { background: var(--ink); color: var(--page); border: 0; border-radius: 6px;
  font: 12.5px/1.35 var(--sans); padding: 6px 9px; max-width: 280px; box-shadow: 0 2px 10px rgba(0,0,0,0.18); }
#vg-tooltip-element.vg-tooltip.report-theme td.key { color: var(--page); opacity: 0.7; font-weight: 400; }
#vg-tooltip-element.vg-tooltip.report-theme td.value { color: var(--page); font-weight: 600; }
@media (prefers-reduced-motion: no-preference) { .switcher button { transition: background 120ms, color 120ms; } }
"""

JS = """
(function () {
  var specs = JSON.parse(document.getElementById('specs').textContent);
  var charts = Array.prototype.slice.call(document.querySelectorAll('.vis'));

  // The chart theme is the page theme: read the tokens the CSS defines right now.
  function token(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  }
  function config() {
    var font = token('--sans') || 'system-ui, sans-serif';
    return {
      background: 'transparent',
      font: font,
      axis: { labelColor: token('--ink-2'), titleColor: token('--ink-3'), gridColor: token('--grid'),
              domainColor: token('--axis'), tickColor: token('--axis'), labelFontSize: 12,
              titleFontSize: 12, titleFontWeight: 400, labelFontWeight: 400, labelPadding: 6 },
      axisX: { domain: false, ticks: false, grid: true },
      axisY: { domain: false, ticks: false, grid: false, labelPadding: 10, labelLimit: 160 },
      text: { color: token('--ink-2') },
      rule: { color: token('--axis') },
      rect: { fill: token('--band') },
      point: { color: token('--ink-2') },
      view: { stroke: null },
      range: { category: [token('--swift'), token('--rust')] }
    };
  }

  var rendered = 0;
  function visible(el) { return !el.closest('[hidden]'); }
  function render(force) {
    if (typeof vegaEmbed === 'undefined') {
      charts.forEach(function (el) {
        el.innerHTML = '<p class="unavailable">The chart library could not be loaded. The tables under “Every number” have every value.</p>';
      });
      return;
    }
    var cfg = config();
    charts.forEach(function (el) {
      if (!visible(el) || (el.dataset.rendered === String(rendered) && !force)) return;
      el.dataset.rendered = String(rendered);
      vegaEmbed(el, specs[el.dataset.spec], { actions: false, renderer: 'svg', config: cfg,
                                              tooltip: { theme: 'report' } })
        .catch(function (err) {
          el.innerHTML = '<p class="unavailable">Chart failed to render: ' + String(err).replace(/</g, '&lt;') + '</p>';
        });
    });
  }
  function retheme() { rendered += 1; render(true); }

  var buttons = document.querySelectorAll('.switcher button');
  function select(slug, remember) {
    document.querySelectorAll('.platform').forEach(function (p) { p.hidden = p.getAttribute('data-platform') !== slug; });
    buttons.forEach(function (b) { b.setAttribute('aria-pressed', String(b.getAttribute('data-platform') === slug)); });
    if (remember) { try { localStorage.setItem('swift-rust-benchmarks-platform', slug); } catch (_) {} }
    render(false);
  }
  buttons.forEach(function (b) { b.addEventListener('click', function () { select(b.getAttribute('data-platform'), true); }); });
  var saved = null;
  try { saved = localStorage.getItem('swift-rust-benchmarks-platform'); } catch (_) {}
  if (saved && document.querySelector('.platform[data-platform="' + saved + '"]')) select(saved, false);

  render(false);
  if (window.matchMedia) {
    var dark = window.matchMedia('(prefers-color-scheme: dark)');
    if (dark.addEventListener) dark.addEventListener('change', retheme); else if (dark.addListener) dark.addListener(retheme);
  }
  new MutationObserver(retheme).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
})();
"""


# ---------------------------------------------------------------------------------
# main


def main():
    ap = argparse.ArgumentParser(description="Render harness JSON results into an HTML report of Vega-Lite charts.")
    ap.add_argument("dirs", nargs="*", default=[str(ROOT / "results")], help="directories of harness JSON files")
    ap.add_argument("--out", default=str(ROOT / "results" / "report.html"), help="output HTML file")
    ap.add_argument("--site", metavar="DIR",
                    help="write DIR/index.html and copy the JSON files to DIR/results/, ready to publish")
    ap.add_argument("--fragment", action="store_true", help="omit the document skeleton (title, style and body only)")
    ap.add_argument("--open", action="store_true", help="open the report in the default browser")
    opts = ap.parse_args()

    runs = load(opts.dirs)
    if not runs:
        raise SystemExit("no results found; run ./run-all.py first")
    files = sorted({b["_file"] for bench in runs.values() for b in bench.values()}, key=lambda f: f.name)

    if opts.site:
        site = Path(opts.site)
        (site / "results").mkdir(parents=True, exist_ok=True)
        for f in files:
            shutil.copyfile(f, site / "results" / f.name)
        (site / ".nojekyll").write_text("", encoding="utf-8")
        out = site / "index.html"
        html = render(runs, fragment=opts.fragment, data_files=files)
    else:
        out = Path(opts.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        html = render(runs, fragment=opts.fragment)
    out.write_text(html, encoding="utf-8")
    machines = ", ".join(platform_title(next(iter(runs[s].values()))) for s in sorted(runs))
    print(f"wrote {out} ({len(files)} result files; {machines})")
    if opts.open:
        webbrowser.open(out.resolve().as_uri())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
