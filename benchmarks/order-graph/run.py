#!/usr/bin/env python3
"""Build and run the order-graph benchmark in Swift and Rust, then compare.

    ./run.py                          # defaults: 50k customers, 200k products, 1M orders
    ./run.py --orders 4000000 --passes 5
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tools"))
import harness  # noqa: E402

KNOBS = [
    harness.Knob("customers", int, 50_000, "number of customers (shared by orders)"),
    harness.Knob("products", int, 200_000, "number of products (shared by order lines)"),
    harness.Knob("orders", int, 1_000_000, "number of orders, each with 1-5 lines"),
    harness.Knob("passes", int, 3, "number of full reporting passes"),
    harness.Knob("seed", int, 42, "PRNG seed (same seed => identical data in both languages)"),
]

if __name__ == "__main__":
    sys.exit(harness.main("order-graph", KNOBS, HERE))
