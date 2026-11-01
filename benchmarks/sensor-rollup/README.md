# sensor-rollup

A telemetry pipeline over plain value types: millions of sensor readings held
in arrays of structs, rolled up into per-minute statistics, scanned for
anomalies and binned into histograms. There are no heap objects, no strings
and no reference counting anywhere in the hot path, so this is the control
benchmark: it shows how the two compilers compare when memory management is
not in the picture. The other benchmarks' gaps should be read against it.

## What it does

1. **generate** - `--readings` readings interleaved across `--sensors`
   devices. Each device follows its own random walk; timestamps advance by
   1-20 ms; 1% of readings carry a device-flagged spike. A reading is a
   24-byte struct (sensor, quality flag, timestamp, value).

2. **rollup** - one pass over the readings accumulating count, sum, min, max
   and sum of squares per (sensor, one-minute window) into a dense
   sensors x windows array of 40-byte structs, skipping flagged readings and
   tracking the global value range.

3. **anomaly** - for every sensor, walk its window means in time order with a
   60-window trailing ring buffer and flag windows whose mean lies more than
   three standard deviations from the trailing mean (compared as squared
   deviation against nine times the variance, so no square root is needed).

4. **quantile** - a 256-bin histogram per sensor over the global range, then
   the bin holding the 50th, 95th and 99th percentile of each sensor.

5. **free** - release everything.

All arithmetic is performed in the same order in both languages and the
checksum includes the bit patterns of floating-point results, so the harness
verifies that the two produce bit-identical numbers, not merely close ones.

## Knobs

| knob | default | effect |
|---|---|---|
| `--sensors` | 1000 | number of devices (rows in the rollup and histogram tables) |
| `--readings` | 5000000 | total readings (120 MB of structs at the default) |
| `--seed` | 42 | PRNG seed |

```sh
./run.py
./run.py --readings 20000000 --sensors 4000
```

## Sample result

Apple M1 Max, macOS, Swift 6.4, Rust 1.99, 2026-11-01, median of 5 runs:

| language | wall (ms) | in-process (ms) | generate (ms) | rollup (ms) | anomaly (ms) | quantile (ms) | free (ms) | peak RSS (MB) | binary (KB) |
|---|---|---|---|---|---|---|---|---|---|
| swift 6.4 | 116.1 | 108.0 | 30.6 | 61.5 | 3.7 | 11.6 | 0.0 | 154.6 | 100 |
| rust 1.99.0 | 108.6 | 101.4 | 36.0 | 56.9 | 2.1 | 5.4 | 0.0 | 150.7 | 486 |
| swift / rust | 1.07x | 1.07x | 0.85x | 1.08x | 1.73x | 2.15x | 1.00x | 1.03x | 0.21x |

## Findings and caveats

- **Parity.** End to end the two are within 7%, and the two phases that
  dominate the run split: Swift is faster at generation (0.85x) and slightly
  slower at the rollup (1.08x). Memory is equal because the struct layouts are
  identical. When there are no reference types, Swift and Rust emit comparable
  machine code; the 2x to 3x gaps in the other benchmarks in this repository
  are the cost of heap objects, strings and reference counting, not of the
  Swift compiler.

- **Floating point is bit-identical.** Neither compiler fuses multiply-add
  sequences by default, so the window sums, variances and bit-pattern hashes
  agree exactly across languages and platforms.

- **`Int(Double)` is checked in Swift.** The quantile phase is the one clear
  gap (11.6 vs 5.4 ms over 5M conversions, about 1.2 ns each). Swift's
  `Int(_:)` initializer traps on out-of-range values: the loop body carries two
  floating-point compares, the convert and an overflow branch, plus the bounds
  check on the histogram write. Rust's `as usize` is a single saturating
  convert instruction. The idiom is left as written since it is what both
  languages' programmers type. On a 4-core Intel N100 under Linux the same
  phase is at exact parity (18.2 ms each) and the whole benchmark is 1.08x, so
  the checks cost nothing measurable on that x86 core.

- **The anomaly phase is too short to read.** 3.7 vs 2.1 ms is a real
  ratio but a tiny absolute difference over 875k window structs, and was not
  investigated.
