# order-graph

An order-management model: customers, products and orders, where every order
refers to one customer and several products, and popular products appear in
thousands of orders. This is the first benchmark where plain tree ownership
does not fit the data, so each language has to pick a sharing strategy.

## What it does

1. **build** - create `--customers` customers (name, region), `--products`
   products (name, category, price) and `--orders` orders, each with 1 to 5
   lines of (product, quantity). Customer and product choices are skewed (the
   minimum of two uniform draws) so a few entities are very popular and the
   tail is rarely referenced.

2. **report** - `--passes` rounds of a full reporting pass: reset counters,
   walk every order line to accumulate units sold per product and total spend
   per customer (through the shared references), bucket revenue by the
   customer's region, then rank the top 10 customers and top 10 products.

3. **reprice** - raise the price of every product in one category by 10%
   through the shared product records, then re-total every order so the change
   is observed through the references.

4. **prune** - delete the oldest 30% of orders, then remove every product and
   customer that no remaining order refers to. Swift asks ARC directly:
   `isKnownUniquelyReferenced` on each catalogue slot says whether any order
   still holds the entity. Rust's arena has no reference counts, so it scans
   the remaining orders to count references first. A hash of the surviving ids
   proves both reach the same answer.

5. **free** - release everything.

Swift models customers and products as `final class` objects; orders are
structs holding a `Customer` reference and an array of `Line` structs that each
hold a `Product` reference. Rust models the same data as an arena: `Vec<Option<Customer>>`
and `Vec<Option<Product>>` addressed by `u32` index from the orders, which is the
idiomatic Rust answer to shared, mutable, deletable entities (the alternative,
`Rc<RefCell<T>>`, would make Rust pay for reference counting as well).

## Knobs

| knob | default | effect |
|---|---|---|
| `--customers` | 50000 | customers shared by orders |
| `--products` | 200000 | products shared by order lines |
| `--orders` | 1000000 | orders, 1-5 lines each (about 3M lines) |
| `--passes` | 3 | reporting passes |
| `--seed` | 42 | PRNG seed |

```sh
./run.py
./run.py --orders 4000000 --passes 5
```

## Sample result

Apple M1 Max, macOS, Swift 6.4, Rust 1.99, 2026-10-31, median of 5 runs:

| language | wall (ms) | in-process (ms) | build (ms) | report (ms) | reprice (ms) | prune (ms) | free (ms) | peak RSS (MB) | binary (KB) |
|---|---|---|---|---|---|---|---|---|---|
| swift 6.4 | 481.2 | 471.9 | 216.7 | 97.6 | 10.9 | 54.4 | 81.7 | 150.2 | 122 |
| rust 1.99.0 | 173.3 | 167.5 | 58.3 | 62.1 | 9.3 | 18.1 | 15.8 | 93.2 | 506 |
| swift / rust | 2.78x | 2.82x | 3.72x | 1.57x | 1.17x | 3.00x | 5.18x | 1.61x | 0.24x |

## Findings and caveats

- **Reading through shared references is nearly free.** The reprice pass,
  which follows 3M product references and does arithmetic, is within 17% of
  Rust's index lookups. The reporting pass, which also writes through the
  references, is 1.6x slower.

- **Creating and destroying references is where ARC costs.** Building 1M
  orders stores 4M references (one customer and about three products each) and
  each store is a retain; freeing them is 4M releases plus 1M array
  deallocations. A sampling profile of build and free shows `swift_release`
  and its deallocation path at roughly 30% of samples, with malloc/free
  another 15%. Rust's build writes plain `u32` indices and its free is a walk
  over contiguous vectors.

- **Prune is a trade.** Swift's orphan sweep is O(entities) and trivially
  simple because ARC already maintains the reference counts; Rust needs an
  O(orders) scan to compute them. Swift still loses the phase 3x because
  deleting 300k orders means releasing 1.2M references, which dominates.

- **Memory is 1.6x higher in Swift**, by layout: a `Line` is a 16-byte
  (reference, quantity) pair against Rust's 8-byte (index, quantity), each
  order's line array carries a 32-byte header, and each customer and product
  is a separate heap object with a 16-byte header where Rust stores them inline
  in the arena vectors.

- **The arena is a design choice, not a free lunch.** Rust pays for it in
  code: `Option` slots, `as_mut().expect(..)` at every access, borrow-splitting
  the store into its fields before iterating, and the explicit reference scan
  in prune. `Rc<RefCell<T>>` would remove that ceremony and make Rust pay for
  reference counting too; it is on the roadmap as a variant.
