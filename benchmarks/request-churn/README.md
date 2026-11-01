# request-churn

A small in-memory shop API served in a tight loop: the shape of a web service
hot path, where every request allocates a little state that dies when the
response is written. Unlike the other benchmarks there is no big data set; the
question is steady-state throughput and whether the footprint stays flat.

## What it does

1. **generate** - build a 500-item catalogue and a pool of `--pool` raw HTTP
   requests (request line, five or six headers, optional form body) drawn from
   `2 * --sessions` session tokens:

   ```
   GET /api/v1/items?category=lamps&max_price=24000&sort=price&limit=20 HTTP/1.1
   Host: shop.example.com
   User-Agent: bench-client/1.0 (+https://example.com/bench)
   Accept: application/json
   Cookie: session=3f9c1a7e5b20
   X-Request-Id: 9d2c4b6a8e1f0a3c
   ```

   Traffic mix: 50% catalogue search, 25% single item (some 404s), 10% add to
   cart (POST with form body), 7% view cart, 6% health check, 2% unknown route.

2. **serve** - for `--requests` iterations: pick a raw request from the pool,
   parse it zero-copy (method, path, query parameters, headers and body are
   views into the raw bytes), look up or create the session in a capacity-bound
   cache with FIFO eviction, route, build a JSON response body into a fresh
   buffer, and record per-route metrics. Every 1000th response is folded into a
   checksum. Peak RSS is sampled at 10% of the run and at the end; the
   difference is reported as RSS growth.

3. **shutdown** - drop the server state and the request pool.

Rust's `Request<'a>` borrows `&str` slices from the raw request and the session
cache is a `HashMap<String, Session>` plus a `VecDeque` of tokens. Swift's
`Request` holds `ArraySlice<UInt8>` views (each a retain of the pool buffer),
sessions are `final class` objects in a `[String: Session]` dictionary, and the
eviction queue is a small ring buffer since the standard library has no deque.

## Knobs

| knob | default | effect |
|---|---|---|
| `--requests` | 1000000 | requests served |
| `--pool` | 10000 | distinct raw requests to draw from |
| `--sessions` | 5000 | session cache capacity; smaller means more eviction churn |
| `--seed` | 42 | PRNG seed |

```sh
./run.py
./run.py --requests 5000000 --sessions 20000
```

## Sample result

Apple M1 Max, macOS, Swift 6.4, Rust 1.99, 2026-10-31, median of 5 runs:

| language | wall (ms) | in-process (ms) | generate (ms) | serve (ms) | shutdown (ms) | req/s | RSS growth (MB) | peak RSS (MB) | binary (KB) |
|---|---|---|---|---|---|---|---|---|---|
| swift 6.4 | 5,222.2 | 5,215.6 | 11.8 | 5,203.2 | 0.5 | 192,188 | 0.0 | 9.9 | 148 |
| rust 1.99.0 | 1,642.4 | 1,637.8 | 2.0 | 1,635.5 | 0.2 | 611,433 | 0.0 | 6.7 | 526 |
| swift / rust | 3.18x | 3.18x | 6.04x | 3.18x | 2.05x | 0.31x | 0.00x | 1.47x | 0.28x |

## Findings and caveats

- **Both footprints are flat.** Neither process grows between 10% and 100% of
  the run: per-request state really does die with the request in both
  languages, and the session cache is bounded by eviction (about 175k evictions
  over the run with the default capacity).

- **Throughput is 3.2x apart, and it is death by a thousand cuts.** A sampling
  profile of the Swift serve loop shows no single hot spot: JSON body
  building (`String` append, integer formatting, interpolation) about 25%,
  malloc/free about 12%, retain/release/deallocation about 12%, byte scanning
  for header and query delimiters about 10%, and sorting the search matches
  about 7%. Rust's `write!` into a `String` and `split_once` on `&str` are
  cheaper versions of the same steps, and its borrowed `Request<'a>` costs
  nothing to create or drop, where each Swift `ArraySlice` field is a retain
  and a release of the pool buffer.

- **The 5 µs vs 1.6 µs per request includes everything** that a framework
  would do apart from I/O: parsing, routing, session lookup, business logic,
  serialization and metrics. Neither side uses a JSON library or a regex;
  both hand-build the response text.
