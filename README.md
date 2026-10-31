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
  swift/BenchKit/          Swift support package (mirror of the above)
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

Numbers are the median over `--runs` runs. The `swift / rust` row is the ratio
of the two medians (values above 1 mean Swift took longer or used more).

## Benchmarks

| benchmark | what it exercises |
|---|---|
| [log-analytics](benchmarks/log-analytics/) | string building, byte-level parsing into owned records, hash-map aggregation, bulk deallocation |

More are planned; see the roadmap below.

## Roadmap

Each new pair should isolate a different memory-management pattern:

1. **Document tree** - build, traverse and mutate a tree of heap-allocated
   nodes (Swift classes vs Rust `Box`/`Vec`), the textbook ARC-vs-ownership case.
2. **Borrowed views** - a variant of log-analytics where records keep slices of
   the input (Rust `&str` lifetimes vs Swift `Substring` sharing storage).
3. **Shared ownership** - a graph with genuinely shared nodes (`Rc`/`Arc`
   vs class references), where Rust also pays for reference counting.
4. **Request simulation** - a long-running loop allocating and freeing
   per-request state, measuring steady-state throughput and allocator churn.
5. **Concurrent aggregation** - the same work spread over threads (Swift
   structured concurrency vs Rust scoped threads), where ARC becomes atomic.

## CI

`.github/workflows/bench.yml` runs `python3 run-all.py --runs 5` on
`ubuntu-latest`, `macos-latest` and `windows-latest`, writes the tables to the
job summary, and uploads `results/` as an artifact. Hosted runners are noisy
shared machines; treat CI numbers as indicative and local numbers as the
reference.
