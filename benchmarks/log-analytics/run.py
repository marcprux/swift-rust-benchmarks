#!/usr/bin/env python3
"""Build and run the log-analytics benchmark in Swift and Rust, then compare.

    ./run.py                      # defaults: 500k lines, 3 runs each
    ./run.py --lines 2000000      # bigger working set
    ./run.py --runs 10 --lang rust
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tools"))
import harness  # noqa: E402

KNOBS = [
    harness.Knob("lines", int, 500_000, "number of synthetic log lines to generate and parse"),
    harness.Knob("seed", int, 42, "PRNG seed (same seed => identical workload in both languages)"),
]

if __name__ == "__main__":
    sys.exit(harness.main("log-analytics", KNOBS, HERE))
