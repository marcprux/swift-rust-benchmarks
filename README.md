# swift-vs-rust

Side-by-side Swift and Rust implementations of realistic workloads, built to
compare execution time and memory behaviour of the two languages, and in
particular the cost of Swift's automatic reference counting (ARC) versus Rust's
compile-time ownership and borrow checking.

Each benchmark is a pair of small programs that do the same job the way a
competent engineer in each language would write it, plus a script that builds
both, runs them with identical parameters, checks that they produced identical
results, and prints a comparison table. The same script runs on a developer
machine and in GitHub Actions on macOS, Linux and Windows.

## Ground rules

- **Real-world shaped.** Workloads are things programs actually do (parse logs,
  build object graphs, serve requests), not micro-benchmarks of a single
  operation. They are seeded and deterministic so both languages process
  byte-identical input.
- **Idiomatic, not hand-tuned.** Each side uses its standard library the way its
  documentation recommends. No `unsafe`, no hand-written allocators, no
  compiler flags beyond the stock release configuration (`swift build -c
  release`, `cargo build --release`). When a standard-library API turns out to
  be pathologically slow, the workaround and the measurement that justified it
  are documented in the benchmark's README.
- **Verified equivalence.** Every benchmark prints a checksum of its result and
  the harness fails if Swift and Rust disagree.
- **No third-party dependencies.** Both languages use only their standard
  library plus a tiny shared support module in this repository
  (`common/`) for timing, peak-RSS lookup, a shared PRNG and JSON output.
  The harness is Python 3 standard library only.
- **Latest stable toolchains.** CI installs the latest stable Swift and Rust.

## Layout

```
run-all.py                 run every benchmark (CI entry point)
tools/harness.py           shared build / run / compare / report logic
common/
  rust/benchkit/           Rust support crate (timing, peak RSS, PRNG, JSON)
  swift/BenchKit/          Swift support package (mirror of the above); its
                           CBenchKit target holds the OS-specific calls (peak
                           RSS, CPU count, stderr) as C, since psapi is not in
                           the WinSDK module and C's `stderr` global is rejected
                           by Swift 6 strict concurrency on Linux
benchmarks/
  log-analytics/           one directory per benchmark pair
    README.md              what it does, knobs, findings
    run.py                 builds and runs both sides; declares the knobs
    rust/                  Cargo crate
    swift/                 SwiftPM package
results/                   JSON output from the last local run (git-ignored)
.github/workflows/         runs run-all.py on macOS, Ubuntu and Windows
```

## Running

Requirements: Swift 6.x, Rust stable, Python 3.

```sh
# everything, with the defaults (3 measured runs + 1 warm-up per language)
./run-all.py

# one benchmark, more runs, a bigger working set
./benchmarks/log-analytics/run.py --runs 10 --lines 2000000

# options common to every benchmark
./benchmarks/log-analytics/run.py --help
```

Every `run.py` accepts `--runs`, `--warmup`, `--lang swift|rust|both`,
`--skip-build`, `--verbose`, `--results-dir` and `--summary <file>` (a Markdown
file to append the table to; defaults to `$GITHUB_STEP_SUMMARY` in CI), plus the
benchmark-specific knobs listed in its README. Each binary can also be run
directly; it prints a human-readable summary followed by one JSON line with its
measurements:

```sh
./benchmarks/log-analytics/rust/target/release/log-analytics --lines 100000
```

## What is measured

| column | meaning |
|---|---|
| wall | process wall time measured by the harness, including startup |
| in-process | wall time measured inside the program from first to last phase |
| per phase | time of each phase as reported by the program (`generate`, `parse`, ...) |
| peak RSS | peak resident set size reported by the OS for the process (`getrusage` / `GetProcessMemoryInfo`) |
| binary | size of the release executable |

Some benchmarks add columns of their own (requests per second, parallel
speedup, ...); their READMEs define them.

Numbers are the median over `--runs` runs. The `swift / rust` row is the ratio
of the two medians (values above 1 mean Swift took longer or used more).

## Benchmarks

| benchmark | what it exercises |
|---|---|
| [log-analytics](benchmarks/log-analytics/) | string building, byte-level parsing into owned records, hash-map aggregation, bulk deallocation |
| [document-tree](benchmarks/document-tree/) | a DOM of reference-counted class nodes vs owned enum nodes: build, serialize, parse, traverse, mutate in place, free |
| [order-graph](benchmarks/order-graph/) | genuinely shared entities (orders referencing customers and products): class references vs an index-addressed arena, including deleting orders and sweeping orphaned entities |
| [request-churn](benchmarks/request-churn/) | a web-service hot path: zero-copy request parsing, session cache with eviction, JSON responses; steady-state throughput and footprint growth |
| [sensor-rollup](benchmarks/sensor-rollup/) | the control: a telemetry pipeline over arrays of plain structs with no heap objects, strings or reference counting, where both compilers should be at parity |
| [parallel-ledger](benchmarks/parallel-ledger/) | shared read-only records touched from every core: class references with atomic retain/release vs `&T` borrows, serial and parallel, with the Swift element loop and index loop measured separately |

Read the others against `sensor-rollup`: it shows how close the two compilers
are when memory management is out of the picture, so the gaps elsewhere can be
attributed to heap objects, strings and reference counting rather than to code
generation.

## Roadmap

1. **Shared ownership, Rc variant** - order-graph with Rust using
   `Rc<RefCell<T>>` instead of an arena, so both languages reference count.

## CI

`.github/workflows/bench.yml` runs `python3 run-all.py --runs 5` on
`ubuntu-latest`, `macos-latest` and `windows-latest`, writes the tables to the
job summary, and uploads `results/` as an artifact. Hosted runners are noisy
shared machines; treat CI numbers as indicative and local numbers as the
reference.
