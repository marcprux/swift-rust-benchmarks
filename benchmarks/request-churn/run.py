#!/usr/bin/env python3
"""Build and run the request-churn benchmark in Swift and Rust, then compare.

    ./run.py                          # defaults: 1M requests over a 10k-request pool
    ./run.py --requests 5000000 --sessions 20000
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tools"))
import harness  # noqa: E402

KNOBS = [
    harness.Knob("requests", int, 1_000_000, "number of requests to serve"),
    harness.Knob("pool", int, 10_000, "number of distinct pre-generated raw requests to draw from"),
    harness.Knob("sessions", int, 5_000, "session cache capacity (older sessions are evicted)"),
    harness.Knob("seed", int, 42, "PRNG seed (same seed => identical traffic in both languages)"),
]

COLUMNS = [
    harness.Column("requests_per_sec", "req/s"),
    harness.Column("rss_growth_bytes", "RSS growth (MB)", "bytes"),
]

if __name__ == "__main__":
    sys.exit(harness.main("request-churn", KNOBS, HERE, columns=COLUMNS))
