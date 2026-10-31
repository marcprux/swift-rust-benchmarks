#!/usr/bin/env python3
"""Run every benchmark pair under benchmarks/ with the given harness options.

Knobs are benchmark-specific, so only generic options (--runs, --warmup, --lang,
--skip-build, --summary, --results-dir, --verbose) make sense here; they are
passed through verbatim to each benchmark's run.py.

    ./run-all.py --runs 5
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def main(argv):
    scripts = sorted((ROOT / "benchmarks").glob("*/run.py"))
    if not scripts:
        print("no benchmarks found", file=sys.stderr)
        return 1
    failures = []
    for script in scripts:
        print(f"\n######## {script.parent.name} ########", flush=True)
        rc = subprocess.call([sys.executable, str(script), *argv])
        if rc != 0:
            failures.append(script.parent.name)
    if failures:
        print(f"\nFAILED: {', '.join(failures)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
