#!/usr/bin/env python3
"""Build and run the parallel-ledger benchmark in Swift and Rust, then compare.

    ./run.py                          # defaults: 50k accounts, 10M transactions, all cores
    ./run.py --threads 4 --passes 10
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tools"))
import harness  # noqa: E402

KNOBS = [
    harness.Knob("accounts", int, 50_000, "number of shared, immutable account records"),
    harness.Knob("transactions", int, 10_000_000, "number of transactions, each pointing at one account"),
    harness.Knob("threads", int, 0, "worker threads for the parallel passes (0 = all hardware threads)"),
    harness.Knob("passes", int, 5, "number of parallel aggregation passes"),
    harness.Knob("seed", int, 42, "PRNG seed (same seed => identical ledger in both languages)"),
]

COLUMNS = [
    harness.Column("threads", "threads"),
    harness.Column("speedup", "speedup", "ratio"),
    harness.Column("speedup_indexed", "speedup (indexed)", "ratio"),
]

if __name__ == "__main__":
    sys.exit(harness.main("parallel-ledger", KNOBS, HERE, columns=COLUMNS))
