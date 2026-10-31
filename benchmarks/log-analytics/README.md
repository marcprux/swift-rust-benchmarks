# log-analytics

A structured-log processing pipeline, the kind of thing behind every
`grep | awk` replacement, log shipper or incident dashboard.

## What it does

1. **generate** - synthesise `--lines` log lines into one contiguous text
   buffer (what you would have after reading a log file into memory). Lines look
   like:

   ```
   2024-03-15T12:34:56.789Z level=INFO service=payments-gateway request_id=1a2a0c53d550114d user=u33775 latency_ms=123 status=200 msg="GET /api/v1/users/12345 completed"
   ```

   Levels, services, status codes, latencies and messages are drawn from a seeded
   SplitMix64 generator that both languages implement identically, so the input
   is byte-for-byte the same.

2. **parse** - walk the buffer line by line and parse each one into an owned
   `LogRecord` (timestamp converted to epoch milliseconds, level enum, service
   and user strings, request id as an integer, latency, status, message). Rust
   borrows each line as a `&str` from the buffer; Swift uses a
   `Substring.UTF8View`. Both copy the three string fields into the record.

3. **aggregate** - per-service count / error rate / average / p50 / p99 latency,
   top-10 users by request count, and a status-code histogram. Rust keys its hash
   maps with `&str` borrowed from the records; Swift keys its dictionaries with
   `String` values that share storage with the records (a retain each).

4. **free** - explicitly drop the records and the text buffer so that the cost
   of bulk deallocation is visible as its own phase.

The aggregate output is rendered to a canonical text and FNV-1a hashed; the
harness fails unless Swift and Rust produce the same hash.

## Knobs

| knob | default | effect |
|---|---|---|
| `--lines` | 500000 | number of log lines (roughly 167 bytes each, so about 84 MB of text at the default) |
| `--seed` | 42 | PRNG seed |

```sh
./run.py                       # defaults
./run.py --lines 2000000 --runs 5
```

## Sample result

Apple M1 Max, macOS, Swift 6.4, Rust 1.99, 2026-10-31, median of 5 runs:

| language | wall (ms) | in-process (ms) | generate (ms) | parse (ms) | aggregate (ms) | free (ms) | peak RSS (MB) | binary (KB) |
|---|---|---|---|---|---|---|---|---|
| swift 6.4 | 1,551.2 | 1,543.1 | 582.6 | 851.8 | 88.0 | 17.0 | 179.4 | 168 |
| rust 1.99.0 | 458.6 | 452.6 | 213.8 | 169.8 | 52.7 | 15.9 | 172.2 | 543 |
| swift / rust | 3.38x | 3.41x | 2.73x | 5.02x | 1.67x | 1.07x | 1.04x | 0.31x |

## Findings and caveats

- **Peak memory is essentially equal.** Swift's 16-byte `String` with inline
  storage for up to 15 bytes means `user=u33775` and the level never touch the
  heap, which offsets the per-object header on its heap strings. Rust's `String`
  is 24 bytes and always heap-allocates when non-empty.

- **The parse gap is mostly not ARC.** A sampling profile of the Swift binary
  shows roughly 45% of samples in byte-level index walking
  (`Collection.firstIndex(of:)`, `Substring.UTF8View.subscript`,
  `elementsEqual`) and about 10% in `swift_retain` / `swift_release` /
  `swift_bridgeObjectRetain`. Swift's `String.Index` is an opaque, validated
  position, so scanning a UTF-8 view byte by byte costs several instructions per
  byte where Rust scans a `&[u8]` with SIMD `memchr`. A follow-up variant will
  parse through `Span<UInt8>` / `withUTF8` to separate indexing cost from
  reference-counting cost.

- **`Collection.firstRange(of:)` is avoided on purpose.** The obvious Swift
  equivalent of Rust's `str::find` took about 40 µs per 170-byte line on Swift
  6.4 (the generic two-way searcher), 160x slower than a plain byte scan and
  enough to make the parse phase 130x slower than Rust. Swift uses a six-line
  byte-scan helper instead, which is what Rust's `find` does internally anyway.

- **Swift's `split` allocates an array; Rust's is lazy.** Both sides therefore
  tokenise with a small lazy helper so that neither allocates per token.

- **Deallocation costs the same.** Freeing 500k records plus the text buffer
  takes about 16-17 ms in both languages: Swift's release of each string is as
  cheap as Rust's drop at this scale.
