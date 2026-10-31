#!/usr/bin/env python3
"""Build and run the document-tree benchmark in Swift and Rust, then compare.

    ./run.py                        # defaults: 500k nodes, 3 query passes
    ./run.py --nodes 2000000 --passes 5
    ./run.py --fanout 2              # deep, narrow tree
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tools"))
import harness  # noqa: E402

KNOBS = [
    harness.Knob("nodes", int, 500_000, "total number of element and text nodes in the tree"),
    harness.Knob("fanout", int, 6, "average children per element (1..2*fanout, uniformly)"),
    harness.Knob("passes", int, 3, "number of full traversal + lookup passes in the query phase"),
    harness.Knob("lookups", int, 200_000, "random root-to-leaf walks per query pass"),
    harness.Knob("seed", int, 42, "PRNG seed (same seed => identical tree in both languages)"),
]

if __name__ == "__main__":
    sys.exit(harness.main("document-tree", KNOBS, HERE))
