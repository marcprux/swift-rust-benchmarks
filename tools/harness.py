#!/usr/bin/env python3
"""Shared build-and-run harness for every Swift-vs-Rust benchmark pair.

Each benchmark directory has a tiny `run.py` that declares its knobs and calls
`harness.main(...)`. The harness then:

  1. builds the Swift package and the Rust crate in release mode,
  2. runs each binary `--warmup` + `--runs` times with identical arguments,
  3. reads the JSON line each binary prints (phase timings, peak RSS, checksum),
  4. verifies that both languages produced the same checksum,
  5. prints a Markdown table, writes `results/<benchmark>-<os>-<arch>.json`,
     and appends the table to `$GITHUB_STEP_SUMMARY` when running in CI.

Only the Python 3 standard library is used; the same script runs on macOS, Linux
and Windows, both on a developer machine and inside GitHub Actions.
"""

import argparse
import json
import os
import platform
import re
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ".exe" if os.name == "nt" else ""


@dataclass
class Knob:
    """A benchmark parameter exposed as `--name` on the command line and passed
    through verbatim to both binaries."""

    name: str
    type: type
    default: object
    help: str


@dataclass
class Column:
    """An extra numeric field from the binaries' JSON line to show in the table,
    after the phase timings. `unit` is "count" or "bytes"."""

    key: str
    label: str
    unit: str = "count"


# ---------------------------------------------------------------------------------
# helpers


def log(msg):
    print(msg, flush=True)


def run(cmd, **kwargs):
    log("$ " + " ".join(str(c) for c in cmd))
    return subprocess.run(cmd, check=True, text=True, **kwargs)


def capture(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True)
        return (p.stdout or "") + (p.stderr or "")
    except FileNotFoundError:
        return ""


def tool_version(cmd, pattern):
    out = capture(cmd)
    m = re.search(pattern, out)
    if m:
        return m.group(1)
    return out.strip().splitlines()[0] if out.strip() else "not found"


def cpu_name():
    try:
        system = platform.system()
        if system == "Darwin":
            return capture(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
        if system == "Linux":
            for line in Path("/proc/cpuinfo").read_text().splitlines():
                if line.lower().startswith("model name"):
                    return line.split(":", 1)[1].strip()
        if system == "Windows":
            out = capture(["powershell", "-NoProfile", "-Command",
                           "(Get-CimInstance Win32_Processor).Name"])
            if out.strip():
                return out.strip().splitlines()[0]
    except Exception:
        pass
    return platform.processor() or platform.machine()


def platform_info():
    return {
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "cpu": cpu_name(),
        "python": platform.python_version(),
        "ci": bool(os.environ.get("GITHUB_ACTIONS")),
        "runner": os.environ.get("RUNNER_OS", ""),
    }


def slug(info):
    return f"{info['system'].lower()}-{info['machine'].lower()}"


# ---------------------------------------------------------------------------------
# building


def swift_bin_dir(package: Path) -> Path:
    out = subprocess.run(
        ["swift", "build", "-c", "release", "--package-path", str(package), "--show-bin-path"],
        check=True, capture_output=True, text=True,
    ).stdout.strip().splitlines()[-1]
    return Path(out)


def build_swift(package: Path, exe: str) -> Path:
    run(["swift", "build", "-c", "release", "--package-path", str(package)])
    return swift_bin_dir(package) / (exe + EXE)


def rust_bin_dir(crate: Path) -> Path:
    return Path(os.environ.get("CARGO_TARGET_DIR", crate / "target")) / "release"


def build_rust(crate: Path, exe: str) -> Path:
    run(["cargo", "build", "--release", "--manifest-path", str(crate / "Cargo.toml")])
    return rust_bin_dir(crate) / (exe + EXE)


# ---------------------------------------------------------------------------------
# running


def run_once(binary: Path, args):
    t0 = time.perf_counter()
    p = subprocess.run([str(binary), *args], capture_output=True, text=True)
    wall_ms = (time.perf_counter() - t0) * 1000.0
    if p.returncode != 0:
        sys.stdout.write(p.stdout)
        sys.stderr.write(p.stderr)
        raise SystemExit(f"{binary.name} exited with status {p.returncode}")
    json_lines = [l for l in p.stdout.splitlines() if l.startswith("{")]
    if not json_lines:
        sys.stdout.write(p.stdout)
        raise SystemExit(f"{binary.name} did not print a JSON result line")
    data = json.loads(json_lines[-1])
    data["wall_ms"] = round(wall_ms, 3)
    return data


def median(values):
    return statistics.median(values)


def phase_keys(sample):
    """Timing keys reported by the binary, in the order they were emitted,
    excluding the totals which get their own columns."""
    return [k for k in sample if k.endswith("_ms") and k not in ("total_ms", "wall_ms")]


def fmt_ms(x):
    return f"{x:,.1f}"


def fmt_mb(b):
    return f"{b / 1_048_576:,.1f}"


def fmt_ratio(a, b):
    if not b:
        return "n/a"
    return f"{a / b:.2f}x"


# ---------------------------------------------------------------------------------
# main


def main(name: str, knobs, bench_dir, exe=None, columns=()):
    bench_dir = Path(bench_dir).resolve()
    exe = exe or name

    ap = argparse.ArgumentParser(
        description=f"Build and run the `{name}` benchmark in Swift and Rust, then compare.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--runs", type=int, default=3, help="measured runs per language")
    ap.add_argument("--warmup", type=int, default=1, help="unmeasured warm-up runs per language")
    ap.add_argument("--lang", choices=["both", "swift", "rust"], default="both",
                    help="which implementation(s) to build and run")
    ap.add_argument("--skip-build", action="store_true", help="reuse the existing release binaries")
    ap.add_argument("--results-dir", default=str(ROOT / "results"),
                    help="where to write the JSON results file")
    ap.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"),
                    help="Markdown file to append the results table to")
    ap.add_argument("--verbose", action="store_true", help="print every individual run")
    for k in knobs:
        ap.add_argument(f"--{k.name}", type=k.type, default=k.default, help=k.help)
    opts = ap.parse_args()

    knob_values = {k.name: getattr(opts, k.name) for k in knobs}
    bin_args = []
    for k, v in knob_values.items():
        bin_args += [f"--{k}", str(v)]
    bin_args.append("--quiet")

    languages = ["swift", "rust"] if opts.lang == "both" else [opts.lang]
    info = platform_info()
    toolchains = {
        "swift": tool_version(["swift", "--version"], r"Swift version (\S+)"),
        "rust": tool_version(["rustc", "--version"], r"rustc (\S+)"),
    }

    log(f"== {name} on {info['system']} {info['machine']} ({info['cpu']})")
    log(f"   swift {toolchains['swift']} | rust {toolchains['rust']}")
    log(f"   knobs: {knob_values} | runs: {opts.runs} (+{opts.warmup} warm-up)")

    binaries = {}
    for lang in languages:
        if lang == "swift":
            pkg = bench_dir / "swift"
            binaries[lang] = swift_bin_dir(pkg) / (exe + EXE) if opts.skip_build else build_swift(pkg, exe)
        else:
            crate = bench_dir / "rust"
            binaries[lang] = rust_bin_dir(crate) / (exe + EXE) if opts.skip_build else build_rust(crate, exe)
        if not binaries[lang].exists():
            raise SystemExit(f"expected binary not found: {binaries[lang]}")

    results = {}
    for lang in languages:
        binary = binaries[lang]
        log(f"-- running {lang}: {binary.name} {' '.join(bin_args)}")
        for _ in range(opts.warmup):
            run_once(binary, bin_args)
        runs = []
        for i in range(opts.runs):
            data = run_once(binary, bin_args)
            runs.append(data)
            if opts.verbose:
                log(f"   run {i + 1}: {json.dumps(data)}")
            else:
                log(f"   run {i + 1}: total {fmt_ms(data['total_ms'])} ms, "
                    f"wall {fmt_ms(data['wall_ms'])} ms, peak RSS {fmt_mb(data['peak_rss_bytes'])} MB")
        results[lang] = runs

    # Correctness: every run of every language must agree on the checksum.
    checksums = {(lang, r.get("checksum")) for lang, runs in results.items() for r in runs}
    distinct = {c for _, c in checksums}
    if len(distinct) != 1:
        raise SystemExit(f"CHECKSUM MISMATCH: {sorted(checksums)}")
    checksum = distinct.pop()

    # Medians per language.
    sample = next(iter(results.values()))[0]
    phases = phase_keys(sample)
    extra = {c.key: c for c in columns}
    table_columns = ["wall_ms", "total_ms", *phases, *extra, "peak_rss_bytes"]
    medians = {}
    for lang, runs in results.items():
        medians[lang] = {c: median([r[c] for r in runs]) for c in table_columns}
        medians[lang]["binary_bytes"] = binaries[lang].stat().st_size

    # Markdown table.
    def pretty(col):
        if col in extra:
            return extra[col].label
        return {"wall_ms": "wall (ms)", "total_ms": "in-process (ms)",
                "peak_rss_bytes": "peak RSS (MB)"}.get(
            col, col[:-3].replace("_", " ") + " (ms)")

    def cell(col, value):
        if col == "peak_rss_bytes":
            return fmt_mb(value)
        if col in extra:
            return fmt_mb(value) if extra[col].unit == "bytes" else f"{value:,.0f}"
        return fmt_ms(value)

    header = ["language", *[pretty(c) for c in table_columns], "binary (KB)"]
    rows = []
    for lang in languages:
        m = medians[lang]
        cells = [f"{lang} {toolchains[lang]}"]
        for c in table_columns:
            cells.append(cell(c, m[c]))
        cells.append(f"{m['binary_bytes'] / 1024:,.0f}")
        rows.append(cells)
    if len(languages) == 2:
        s, r = medians["swift"], medians["rust"]
        cells = ["swift / rust"]
        for c in table_columns:
            cells.append(fmt_ratio(s[c], r[c]))
        cells.append(fmt_ratio(s["binary_bytes"], r["binary_bytes"]))
        rows.append(cells)

    knob_text = ", ".join(f"{k}={v}" for k, v in knob_values.items())
    title = (f"### {name} on {info['system']} {info['machine']}\n\n"
             f"`{knob_text}`, median of {opts.runs} runs, {info['cpu']}\n\n")
    table = "| " + " | ".join(header) + " |\n|" + "|".join("---" for _ in header) + "|\n"
    for cells in rows:
        table += "| " + " | ".join(cells) + " |\n"
    md = title + table + "\n"
    log("")
    log(md)

    if opts.summary:
        with open(opts.summary, "a", encoding="utf-8") as f:
            f.write(md)

    results_dir = Path(opts.results_dir)
    results_dir.mkdir(parents=True, exist_ok=True)
    out = results_dir / f"{name}-{slug(info)}.json"
    out.write_text(json.dumps({
        "benchmark": name,
        "platform": info,
        "toolchains": toolchains,
        "knobs": knob_values,
        "runs": opts.runs,
        "warmup": opts.warmup,
        "checksum": checksum,
        "medians": medians,
        "results": results,
        "markdown": md,
    }, indent=2) + "\n", encoding="utf-8")
    log(f"wrote {out}")
    return 0
