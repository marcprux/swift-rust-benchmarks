# parallel-ledger

A ledger of transactions where every transaction points at one of a table of
shared, immutable account records, aggregated once on a single thread and then
across all cores. It isolates what happens to the two memory models when
read-only shared data is touched from many threads at once: Rust threads read
through `&Account` borrows for free, while every Swift read of a class
reference is an atomic retain and release on the shared object.

## What it does

1. **build** - `--accounts` account records (id, region, tier, credit limit)
   and `--transactions` transactions (account, amount, category, hour). Account
   choice is skewed (the minimum of two uniform draws) so some accounts are
   hot. Swift transactions hold an `Account` class reference; Rust transactions
   hold a `&Account` borrowed from the account vector. Both are 16 bytes.

2. **serial** - one pass over all transactions on the calling thread, written
   as `for tx in txs`: per-account totals (indexed by the account's id), revenue
   by region and tier (read through the account), counts by category and hour,
   and a flag when an amount exceeds a tenth of the account's credit limit.

3. **parallel** - `--passes` rounds of the same pass split into `--threads`
   contiguous chunks, Swift with a `TaskGroup` child task per chunk and Rust
   with `std::thread::scope`, partial totals merged on the calling thread.
   Every pass is checked against the serial result.

4. **serial indexed / parallel indexed** - the same two passes written as an
   index loop (`for i in txs.indices { ... txs[i].account.id ... }`) instead of
   an element loop. In Rust the two phrasings compile to the same code. In
   Swift the element loop copies each `Transaction` out of the array, which
   retains and releases its account; the index loop reads through the array
   element in place and does not.

5. **free** - release everything.

The reported **speedup** columns are serial time divided by per-pass parallel
time for each phrasing. `--threads 0` (the default) uses every hardware
thread; Rust spawns exactly that many OS threads, Swift submits that many
child tasks to its cooperative pool, which is itself sized to the core count.

## Knobs

| knob | default | effect |
|---|---|---|
| `--accounts` | 50000 | shared account records; small enough to stay in cache (see findings) |
| `--transactions` | 10000000 | transactions (160 MB of structs at the default) |
| `--threads` | 0 | workers for the parallel passes; 0 = all hardware threads |
| `--passes` | 5 | parallel passes per phrasing |
| `--seed` | 42 | PRNG seed |

```sh
./run.py
./run.py --threads 4 --passes 10
./run.py --accounts 1000000
```

## Sample result

Apple M1 Max (8 performance + 2 efficiency cores), macOS, Swift 6.4,
Rust 1.99, 2026-11-01, median of 5 runs:

| language | wall (ms) | in-process (ms) | build (ms) | serial (ms) | parallel (ms) | serial indexed (ms) | parallel indexed (ms) | free (ms) | threads | speedup | speedup (indexed) | peak RSS (MB) | binary (KB) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| swift 6.4 | 1,194.8 | 1,185.5 | 116.2 | 132.7 | 662.0 | 81.5 | 141.4 | 29.7 | 10 | 0.99x | 2.82x | 168.8 | 134 |
| rust 1.99.0 | 230.1 | 223.2 | 65.7 | 41.1 | 39.6 | 36.8 | 37.6 | 0.0 | 10 | 5.30x | 4.76x | 162.1 | 537 |
| swift / rust | 5.19x | 5.31x | 1.77x | 3.23x | 16.71x | 2.21x | 3.76x | n/a | 1.00x | 0.19x | 0.59x | 1.04x | 0.25x |

(The parallel columns are the total over 5 passes. Rust's free is below the
timer's resolution: a `Vec` of `Copy` structs is released with one call.)

## Findings and caveats

- **Ten cores buy idiomatic Swift nothing here.** The element loop's parallel
  pass takes as long as the serial pass (speedup 0.99x), while Rust scales
  5.3x. The cause is visible in the Swift loop body: `for tx in txs` copies
  each transaction out of the slice, which is a `swift_retain` of its account
  at the top of the iteration and a `swift_release` at the bottom. Those are
  atomic read-modify-writes on the account object's header. With every core
  doing them against the same 50k objects, the cache lines holding the
  accounts bounce between cores on every access, and the extra traffic eats
  the parallelism. Data that is read-only in every other sense is written on
  every read.

- **Phrasing matters in Swift and not in Rust.** Reading fields through
  `txs[i].account` instead of a copied element removes the retain/release pair.
  Serially that is worth 40% (81 vs 133 ms, about 5 ns per uncontended
  retain/release pair); in parallel it is worth 4.7x (141 vs 662 ms). Rust's
  element and index loops are within measurement noise of each other because
  both read through the same borrow. The index form is normal Swift, but it is
  not what one writes first, and the compiler does not perform this
  transformation itself.

- **Even without the retains Swift scales less well** (2.8x vs 4.8x). The
  remaining loop body still makes five non-inlined
  `swift_isUniquelyReferenced` calls per transaction, one per copy-on-write
  array update, though those arrays are per-worker and uncontended. Whether
  the rest is those calls or the cooperative pool's scheduling across
  performance and efficiency cores was not separated out.

- **The account count is a trade-off knob.** With the default 50k accounts
  the account table fits in cache and the measurement is about reference
  traffic. With `--accounts 1000000` both languages become bound by DRAM
  latency and by faulting in the per-worker 8 MB totals arrays: Rust scales
  only 1.75x and Swift 2.4x, and the ARC difference shrinks to a 3.6x per-pass
  gap. The default is chosen so that the benchmark measures what it is named
  for, and the knob is there to see the other regime.

- **Build and free are the order-graph story again.** Storing 10M references
  costs 10M retains (116 vs 66 ms) and dropping them costs 10M releases
  (30 ms vs effectively zero). Peak memory is equal: a reference and a borrow
  are both pointer-sized, and the account objects themselves are small.

- **Smaller machines show a smaller effect.** On a 4-core Intel N100 running
  Ubuntu 26.04 (Swift 6.4.2, Rust 1.98) the chip's memory bandwidth limits
  Rust to 1.9x and Swift's element loop reaches 1.6x (index loop 2.1x), with
  Swift 4.0x slower serially and 5.0x slower in parallel. Hosted CI runners
  also have four cores, so look at the shape of the result there (the element
  loop scaling worse than the index loop, and both worse than Rust) rather
  than the absolute speedups.
