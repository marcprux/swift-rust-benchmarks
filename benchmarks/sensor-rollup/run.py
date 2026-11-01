#!/usr/bin/env python3
"""Build and run the sensor-rollup benchmark in Swift and Rust, then compare.

    ./run.py                          # defaults: 1000 sensors, 5M readings
    ./run.py --readings 20000000 --sensors 4000
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tools"))
import harness  # noqa: E402

KNOBS = [
    harness.Knob("sensors", int, 1_000, "number of sensors (devices) emitting readings"),
    harness.Knob("readings", int, 5_000_000, "total number of readings, interleaved across sensors"),
    harness.Knob("seed", int, 42, "PRNG seed (same seed => identical readings in both languages)"),
]

if __name__ == "__main__":
    sys.exit(harness.main("sensor-rollup", KNOBS, HERE))
